#if os(macOS)
import Foundation

/// Keeps one reader per open Claude conversation and answers history reads from its
/// in-memory index. The reader is a single long-lived `tail -F` of the transcript: a
/// local `/bin/sh` process, or one SSH command for a remote device. A history poll
/// therefore never opens a connection. Readers nobody has asked for in a while stop.
public actor ClaudeTranscriptStore {
    public enum Snapshot: Sendable {
        case ready(ClaudeTranscriptIndex)
        /// A `ConversationPage.availability` code the drawer explains.
        case unavailable(String)
    }

    private struct Key: Hashable {
        let deviceID: UUID
        let sessionID: String
    }

    private final class Feed {
        let reader: ClaudeTranscriptReader
        var index: ClaudeTranscriptIndex
        var lastUse = Date()
        init(reader: ClaudeTranscriptReader, sessionID: String) {
            self.reader = reader
            index = ClaudeTranscriptIndex(sessionID: sessionID)
        }
    }

    private var feeds: [Key: Feed] = [:]
    /// Sessions whose transcript was not found, so polls do not respawn a reader every second.
    private var missingUntil: [Key: Date] = [:]
    private var reaper: Task<Void, Never>?
    private let idleTimeout: TimeInterval
    private let maximumFeeds = 4
    /// How long one read waits for a reader to deliver the transcript written so far.
    private let catchUpWait: Duration = .seconds(3)

    public init(idleTimeout: TimeInterval = 45) {
        self.idleTimeout = idleTimeout
    }

    public static func isSupported(_ device: Device) -> Bool {
        !device.isTailcat && device.osID?.lowercased() != "windows"
    }

    /// Claude session ids are UUIDs; anything else never reaches a shell.
    static func isValidSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public func snapshot(device: Device, sessionID: String) async throws -> Snapshot {
        guard Self.isSupported(device) else { return .unavailable("unsupported_device") }
        guard Self.isValidSessionID(sessionID) else { return .unavailable("no_binding") }
        let key = Key(deviceID: device.id, sessionID: sessionID)
        if let until = missingUntil[key], until > Date() { return .unavailable("source_missing") }

        let feed = feeds[key] ?? start(key, device: device)
        feed.lastUse = Date()
        let deadline = ContinuousClock.now + catchUpWait
        while true {
            feed.index.ingest(feed.reader.take())
            switch feed.reader.state {
            case .missing:
                stop(key)
                missingUntil[key] = Date().addingTimeInterval(10)
                return .unavailable("source_missing")
            case .failed:
                stop(key)
                throw ConversationHistoryError.disconnected
            case .running(let caughtUp):
                if caughtUp { return .ready(feed.index) }
                if ContinuousClock.now >= deadline { return .unavailable("loading") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Ends every reader, e.g. when the app quits.
    public func stopAll() {
        for key in Array(feeds.keys) { stop(key) }
        reaper?.cancel(); reaper = nil
    }

    private func start(_ key: Key, device: Device) -> Feed {
        if feeds.count >= maximumFeeds,
           let oldest = feeds.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            stop(oldest)
        }
        missingUntil[key] = nil
        let feed = Feed(reader: ClaudeTranscriptReader(device: device, sessionID: key.sessionID), sessionID: key.sessionID)
        feeds[key] = feed
        feed.reader.start()
        scheduleReaper()
        return feed
    }

    private func stop(_ key: Key) {
        feeds.removeValue(forKey: key)?.reader.stop()
    }

    private func scheduleReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, await self.reapIdle() else { return }
            }
        }
    }

    /// Stops idle readers; returns false once none are left.
    private func reapIdle() -> Bool {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        for (key, feed) in feeds where feed.lastUse < cutoff { stop(key) }
        if feeds.isEmpty { reaper = nil; return false }
        return true
    }
}

/// The transcript as a byte stream. The command prints `herdrm-transcript <size>` and
/// then `tail -c +1 -F`s the file, so the size tells when the history written before
/// the reader started is fully in.
final class ClaudeTranscriptReader: @unchecked Sendable {
    enum State: Equatable {
        case running(caughtUp: Bool)
        case missing
        case failed(String)
    }

    static let missingStatus: Int32 = 44
    static let headerPrefix = "herdrm-transcript "

    private let device: Device
    private let sessionID: String
    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()
    private var header = Data()
    private var expected: Int?
    private var received = 0
    private var errors = Data()
    private var exitStatus: Int32?
    private var authentication: SSHAuthenticationConfiguration?

    init(device: Device, sessionID: String) {
        self.device = device
        self.sessionID = sessionID
    }

    /// Looks in `$CLAUDE_CONFIG_DIR` first, then `~/.claude`, then every `CLAUDE_CONFIG_DIR`
    /// the user's running processes were started with: an alias, wrapper or account
    /// switcher sets it on the `claude` process alone, never in the shell that runs this.
    /// macOS's `ps` separates the environment with spaces, so there a directory whose
    /// path has a space is missed. Exits 44 when none has it.
    static func command(sessionID: String) -> String {
        """
        id=\(HerdrService.shellQuoted(sessionID))
        open_first() {
          for d in "$@"; do
            for f in "$d"/projects/*/"$id".jsonl; do
              if [ -f "$f" ]; then
                printf '\(headerPrefix)%s\\n' "$(wc -c < "$f" | tr -d ' ')"
                exec tail -c +1 -F -- "$f"
              fi
            done
          done
        }
        open_first "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$HOME/.claude"
        IFS='
        '
        open_first $(
          if [ -r /proc/self/environ ]; then
            for e in /proc/[0-9]*/environ; do tr '\\0' '\\n' 2>/dev/null < "$e"; done
          else
            ps -E -ww -o command= -U "$(id -u)" 2>/dev/null | tr ' ' '\\n'
          fi | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | sort -u
        )
        exit \(missingStatus)
        """
    }

    /// sshd runs a command in the login shell, and zsh stops it at the first glob
    /// that matches nothing.
    static func remoteCommand(sessionID: String) -> String {
        "exec /bin/sh -c \(HerdrService.shellQuoted(command(sessionID: sessionID)))"
    }

    func start() {
        let command = Self.command(sessionID: sessionID)
        if let target = device.sshTarget {
            let auth = SSHTunnel.authenticationConfiguration(for: device.id)
            authentication = auth
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-T"] + auth.arguments + [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "LogLevel=ERROR",
                SSHTunnel.sshDestination(target),
                Self.remoteCommand(sessionID: sessionID),
            ]
            process.environment = ProcessInfo.processInfo.environment.merging(auth.environment) { _, new in new }
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
        }
        let output = Pipe(), errorPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorPipe
        // Both handlers uninstall themselves at EOF: a dead pipe stays readable
        // forever and would otherwise be polled in a hot loop.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consume(chunk)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consumeError(chunk)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(status: process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            consumeError(Data(error.localizedDescription.utf8))
            finish(status: -1)
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
        discardAuthorization()
    }

    /// Transcript bytes received since the last call.
    func take() -> Data {
        lock.lock(); defer { lock.unlock() }
        let data = buffer
        buffer.removeAll(keepingCapacity: true)
        return data
    }

    var state: State {
        lock.lock(); defer { lock.unlock() }
        switch exitStatus {
        case nil: return .running(caughtUp: expected.map { received >= $0 } ?? false)
        case Self.missingStatus?: return .missing
        case let status?:
            let detail = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(detail.isEmpty ? "transcript reader exited \(status)" : String(detail.suffix(500)))
        }
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        var data = chunk
        if expected == nil {
            header.append(data)
            guard let newline = header.firstIndex(of: 0x0A) else {
                if header.count > 256 { header.removeAll() }
                lock.unlock(); return
            }
            let line = String(decoding: header[header.startIndex..<newline], as: UTF8.self)
            expected = line.hasPrefix(Self.headerPrefix) ? Int(line.dropFirst(Self.headerPrefix.count)) ?? 0 : 0
            data = header[header.index(after: newline)...]
            header.removeAll()
        }
        buffer.append(data)
        received += data.count
        lock.unlock()
        // Output means ssh authenticated; the one-shot askpass grant is spent.
        discardAuthorization()
    }

    private func consumeError(_ chunk: Data) {
        lock.lock()
        errors.append(chunk)
        if errors.count > 16_384 { errors = errors.suffix(16_384) }
        lock.unlock()
    }

    private func finish(status: Int32) {
        lock.lock()
        exitStatus = status
        lock.unlock()
        discardAuthorization()
    }

    private func discardAuthorization() {
        lock.lock()
        let auth = authentication
        authentication = nil
        lock.unlock()
        auth?.discardAuthorization()
    }
}
#endif
