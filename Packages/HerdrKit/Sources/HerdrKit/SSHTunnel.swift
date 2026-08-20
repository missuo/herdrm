import Foundation

struct SSHAuthenticationConfiguration {
    let arguments: [String]
    let environment: [String: String]
    let authorizationID: UUID?

    func discardAuthorization() {
        guard let authorizationID else { return }
        try? SSHCredentialStore.removeAuthorization(authorizationID)
    }
}

/// Collects asynchronous OpenSSH diagnostics without blocking its stderr pipe.
private final class SSHErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > 16_384 {
            data = data.suffix(16_384)
        }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Forwards a remote herdr Unix socket to a local one using the system OpenSSH client
/// (`ssh -N -L local.sock:remote.sock target`), so remote devices reuse SocketRPC as-is.
/// Auth uses OpenSSH config/agent/Tailscale SSH, with Keychain-backed askpass as a fallback.
public actor SSHTunnel {
    static let maximumUploadBytes = 50 * 1024 * 1024

    public let target: String
    public private(set) var localSocketPath: String?
    private let credentialID: UUID?
    private var process: Process?
    private var errorOutput: Pipe?
    private var errorBuffer: SSHErrorBuffer?
    private var remoteHome: String?

    /// PATH prepended on the remote side; sshd exec is not a login shell (mirrors Heeler).
    public static let remotePathExport =
        "export PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\""

    public init(target: String, credentialID: UUID? = nil) {
        self.target = target
        self.credentialID = credentialID
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Probing

    /// Resolves the remote $HOME once; also proves SSH reachability.
    public func probeRemoteHome() async throws -> String {
        if let remoteHome { return remoteHome }
        let output = try await Self.runSSH(
            target: target,
            command: "echo \"$HOME\"",
            timeout: 12,
            credentialID: credentialID
        )
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else {
            throw HerdrError.tunnelFailed("could not resolve remote home (got: \(output))")
        }
        remoteHome = home
        return home
    }

    public func remoteSocketPath() async throws -> String {
        let home = try await probeRemoteHome()
        return "\(home)/.config/herdr/herdr.sock"
    }

    // MARK: - Tunnel lifecycle

    /// Ensures the forward is up and returns the local socket path.
    public func ensureUp() async throws -> String {
        if let localSocketPath, let process, process.isRunning {
            return localSocketPath
        }
        process?.terminate()
        process = nil
        resetErrorCapture()

        let remoteSock = try await remoteSocketPath()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-tunnels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep the path short: sockaddr_un caps at 104 bytes.
        let localSock = dir.appendingPathComponent("\(abs(target.hashValue) % 100_000).sock").path
        try? FileManager.default.removeItem(atPath: localSock)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let authentication = Self.authenticationConfiguration(for: credentialID)
        defer { authentication.discardAuthorization() }
        proc.arguments = ["-N"] + authentication.arguments + [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "StreamLocalBindUnlink=yes",
            "-L", "\(localSock):\(remoteSock)",
            Self.sshDestination(target),
        ]
        proc.environment = ProcessInfo.processInfo.environment.merging(authentication.environment) { _, new in new }
        let errorOutput = Pipe()
        let errorBuffer = SSHErrorBuffer()
        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            errorBuffer.append(handle.availableData)
        }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errorOutput
        self.errorOutput = errorOutput
        self.errorBuffer = errorBuffer
        // The probe above can suspend for seconds; if the session was cancelled meanwhile
        // (app quitting), spawning here would leak an ssh nobody is left to tear down.
        do {
            try Task.checkCancellation()
            try proc.run()
        } catch {
            resetErrorCapture()
            throw error
        }
        process = proc

        // Wait for the local socket to appear (ssh creates it once the session is up).
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: localSock) {
                localSocketPath = localSock
                return localSock
            }
            if !proc.isRunning {
                let errorText = finishErrorCapture()
                throw HerdrError.tunnelFailed(Self.failureReason(status: proc.terminationStatus, stderr: errorText))
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        proc.terminate()
        process = nil
        resetErrorCapture()
        throw HerdrError.tunnelFailed("timed out waiting for forwarded socket")
    }

    public func tearDown() {
        process?.terminate()
        process = nil
        resetErrorCapture()
        if let localSocketPath {
            try? FileManager.default.removeItem(atPath: localSocketPath)
        }
        localSocketPath = nil
    }

    /// Returns an asynchronous forwarding error emitted after a client used the local socket.
    public func forwardingFailure() async -> String? {
        // OpenSSH writes channel failures just after the forwarded connection closes.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let errorBuffer else { return nil }
        return Self.forwardingFailure(in: errorBuffer.text)
    }

    static func forwardingFailure(in stderr: String) -> String? {
        stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.contains("open failed:") }
    }

    private func finishErrorCapture() -> String {
        guard let errorOutput, let errorBuffer else { return "" }
        errorOutput.fileHandleForReading.readabilityHandler = nil
        errorBuffer.append(errorOutput.fileHandleForReading.readDataToEndOfFile())
        let text = errorBuffer.text
        self.errorOutput = nil
        self.errorBuffer = nil
        return text
    }

    private func resetErrorCapture() {
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        errorOutput = nil
        errorBuffer = nil
    }

    /// Turns "user@host:2222" into an OpenSSH `ssh://` URI so a custom port
    /// survives being passed as the single destination argument (there is no
    /// separate `-p` in the argv). Anything else — config aliases, plain
    /// user@host, existing ssh:// URIs, bare IPv6 addresses — passes through
    /// untouched; bracketed IPv6 with a port ("[::1]:2222") is recognized.
    public static func sshDestination(_ target: String) -> String {
        if target.hasPrefix("ssh://") { return target }
        guard let lastColon = target.lastIndex(of: ":") else { return target }
        let port = target[target.index(after: lastColon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber),
              let portNumber = Int(port), (1...65535).contains(portNumber)
        else { return target }
        let hostPart = target[..<lastColon]
        let hostStart = hostPart.lastIndex(of: "@").map { hostPart.index(after: $0) } ?? hostPart.startIndex
        let host = hostPart[hostStart...]
        guard !host.isEmpty else { return target }
        if host.contains(":"), !(host.hasPrefix("[") && host.hasSuffix("]")) { return target }
        return "ssh://\(target)"
    }

    // MARK: - Silent-forward diagnosis

    /// Explains a forward that answers with silence: ssh accepted the local connection,
    /// failed to open the far side, and closed it, so the first read hit EOF before any
    /// reply. The session itself is fine — the home probe and the tunnel both came up —
    /// which points at the remote end of the forward. One extra round-trip tells the two
    /// cases apart: no socket file (herdr isn't running over there, by far the common
    /// case) vs a socket that exists but stays mute. OpenSSH's own stderr can't be
    /// relied on here: a stock remote sshd reports the failed channel as just
    /// "connect failed: open failed", and when the user's ssh config muxes the
    /// connection (ControlMaster), the message lands on the master's stderr, not ours.
    public func diagnoseSilentForward() async -> HerdrError? {
        guard let remoteSock = try? await remoteSocketPath(),
              let output = try? await Self.runSSH(
                  target: target,
                  command: "test -S \"\(remoteSock)\" && echo exists || echo missing",
                  timeout: 10,
                  credentialID: credentialID
              )
        else { return nil }
        return Self.silentForwardDiagnosis(
            probeOutput: output,
            target: target,
            remoteSocketPath: remoteSock
        )
    }

    static func silentForwardDiagnosis(
        probeOutput: String,
        target: String,
        remoteSocketPath: String
    ) -> HerdrError? {
        switch probeOutput.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "missing":
            return .remoteHerdrDown(target: target, socketPath: remoteSocketPath)
        case "exists":
            return .tunnelFailed(
                "\(remoteSocketPath) exists on \(target) but forwarded connections get no reply"
                    + " — herdr may have left a stale socket, or sshd forbids Unix-socket"
                    + " forwards (AllowStreamLocalForwarding)"
            )
        default:
            return nil
        }
    }

    /// Sniffs the remote OS: "macos", an os-release ID like "ubuntu"/"debian", or a uname fallback.
    public static func probeOS(target: String, credentialID: UUID? = nil) async throws -> String {
        let command = """
        case "$(uname -s)" in Darwin) echo macos;; Linux) . /etc/os-release 2>/dev/null; echo "${ID:-linux}";; *) uname -s | tr '[:upper:]' '[:lower:]';; esac
        """
        let output = try await runSSH(
            target: target,
            command: command,
            timeout: 10,
            credentialID: credentialID
        )
        let os = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !os.isEmpty else { throw HerdrError.tunnelFailed("empty OS probe result") }
        return os
    }

    // MARK: - File transfer

    /// Streams one regular file to a private cache on the remote host and returns
    /// its absolute remote path. The generated name preserves only a safe extension.
    public func uploadFile(from localURL: URL) async throws -> String {
        guard localURL.isFileURL else {
            throw HerdrError.tunnelFailed("file upload requires a local file URL")
        }
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw HerdrError.tunnelFailed("file upload supports regular files only")
        }
        let fileSize = values.fileSize ?? 0
        guard fileSize <= Self.maximumUploadBytes else {
            throw HerdrError.tunnelFailed("file is larger than the 50 MB upload limit")
        }

        return try await Self.uploadFile(
            target: target,
            localURL: localURL,
            remoteFilename: Self.uploadFilename(for: localURL),
            credentialID: credentialID
        )
    }

    static func uploadFile(
        target: String,
        localURL: URL,
        remoteFilename: String,
        credentialID: UUID?,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")
    ) async throws -> String {
        let command = """
        umask 077
        dir="${XDG_CACHE_HOME:-$HOME/.cache}/herdrm/attachments"
        mkdir -p "$dir" && chmod 700 "$dir"
        find "$dir" -type f -mtime +7 -delete 2>/dev/null || true
        tmp="$dir/.\(remoteFilename).part"
        path="$dir/\(remoteFilename)"
        if cat > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$path"; then
            printf '%s\\n' "$path"
        else
            rm -f "$tmp"
            exit 1
        fi
        """

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = executableURL
                let authentication = authenticationConfiguration(for: credentialID)
                defer { authentication.discardAuthorization() }
                proc.arguments = authentication.arguments + [
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=8",
                    "-o", "ServerAliveInterval=15",
                    sshDestination(target),
                    command,
                ]
                proc.environment = ProcessInfo.processInfo.environment.merging(authentication.environment) { _, new in new }
                let output = Pipe()
                let errorOutput = Pipe()
                proc.standardOutput = output
                proc.standardError = errorOutput
                do {
                    proc.standardInput = try FileHandle(forReadingFrom: localURL)
                    try proc.run()
                } catch {
                    continuation.resume(throwing: HerdrError.tunnelFailed("file upload spawn: \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                    if proc.isRunning { proc.terminate() }
                }
                proc.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(throwing: HerdrError.tunnelFailed(
                        "file upload: \(failureReason(status: proc.terminationStatus, stderr: errorData))"
                    ))
                    return
                }
                let lines = String(data: data, encoding: .utf8)?
                    .split(whereSeparator: \.isNewline)
                    .map(String.init) ?? []
                guard let remotePath = lines.last(where: { $0.hasPrefix("/") }) else {
                    continuation.resume(throwing: HerdrError.tunnelFailed("file upload returned no remote path"))
                    return
                }
                continuation.resume(returning: remotePath)
            }
        }
    }

    static func uploadFilename(for localURL: URL) -> String {
        let rawExtension = localURL.pathExtension.lowercased()
        let isSafeExtension = !rawExtension.isEmpty
            && rawExtension.utf8.count <= 16
            && rawExtension.utf8.allSatisfy { byte in
                switch byte {
                case 48...57, 97...122: return true
                default: return false
                }
            }
        let suffix = isSafeExtension ? ".\(rawExtension)" : ""
        return "\(UUID().uuidString.lowercased())\(suffix)"
    }

    // MARK: - One-shot exec

    /// Runs a command on the remote host and returns stdout. Used for probes.
    public static func runSSH(
        target: String,
        command: String,
        timeout: TimeInterval,
        credentialID: UUID? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                let authentication = authenticationConfiguration(for: credentialID)
                defer { authentication.discardAuthorization() }
                proc.arguments = authentication.arguments + [
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=8",
                    sshDestination(target),
                    command,
                ]
                proc.environment = ProcessInfo.processInfo.environment.merging(authentication.environment) { _, new in new }
                let out = Pipe()
                let errorOutput = Pipe()
                proc.standardOutput = out
                proc.standardError = errorOutput
                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: HerdrError.tunnelFailed("ssh spawn: \(error.localizedDescription)"))
                    return
                }
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if proc.isRunning { proc.terminate() }
                }
                proc.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(throwing: HerdrError.tunnelFailed(
                        failureReason(status: proc.terminationStatus, stderr: errorData)
                    ))
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    static func authenticationConfiguration(
        for credentialID: UUID?
    ) -> SSHAuthenticationConfiguration {
        guard let credentialID, let executablePath = Bundle.main.executablePath,
              let authorizationID = try? SSHCredentialStore.createAuthorization(for: credentialID)
        else {
            return SSHAuthenticationConfiguration(
                arguments: ["-o", "BatchMode=yes"],
                environment: [:],
                authorizationID: nil
            )
        }
        return SSHAuthenticationConfiguration(
            arguments: ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"],
            environment: [
                "SSH_ASKPASS": executablePath,
                "SSH_ASKPASS_REQUIRE": "force",
                SSHCredentialStore.askPassModeEnvironmentKey: "1",
                SSHCredentialStore.authorizationIDEnvironmentKey: authorizationID.uuidString,
            ],
            authorizationID: authorizationID
        )
    }

    private static func failureReason(status: Int32, stderr: Data) -> String {
        failureReason(status: status, stderr: String(data: stderr, encoding: .utf8) ?? "")
    }

    private static func failureReason(status: Int32, stderr: String) -> String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return "ssh exited \(status)" }
        return String(detail.suffix(2_000))
    }
}
