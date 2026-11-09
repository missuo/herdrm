#if os(macOS)
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

/// Reaches a remote herdr socket so remote devices reuse SocketRPC as-is.
///
/// Unix hosts use the system OpenSSH client
/// (`ssh -N -L local.sock:remote.sock target`). Windows hosts cannot: the
/// `%APPDATA%\herdr\herdr.sock` path has a drive-letter colon that breaks
/// OpenSSH's `-L` parser, and Win32-OpenSSH does not reliably open AF_UNIX
/// forwards. Those sessions instead proxy each local connection over SSH to
/// `herdr remote-api-bridge` (the same channel the official CLI uses).
///
/// Auth uses OpenSSH config/agent/Tailscale SSH, with Keychain-backed askpass as a fallback.
public actor SSHTunnel {
    static let maximumUploadBytes = 50 * 1024 * 1024
    /// Folders ride one tar stream; the caps keep a stray drop of a whole
    /// project (node_modules and all) from tying up the link for minutes.
    static let maximumDirectoryUploadBytes = 200 * 1024 * 1024
    static let maximumDirectoryUploadEntries = 20_000

    /// Remote endpoint shape used to pick stream-local forward vs API bridge.
    public enum RemotePlatform: Sendable, Equatable {
        case unix(home: String)
        case windows(home: String, herdrExecutable: String)
    }

    public let target: String
    /// The remote herdr named session (issue #190); nil is the default session.
    public let sessionName: String?
    public private(set) var localSocketPath: String?
    /// Cached after the first successful probe; drives attach and diagnose paths.
    public private(set) var remotePlatform: RemotePlatform?
    private let credentialID: UUID?
    private var process: Process?
    private var errorOutput: Pipe?
    private var errorBuffer: SSHErrorBuffer?
    private var remoteHome: String?
    private var apiBridge: SSHRemoteAPIBridge?

    /// PATH prepended on the remote side; sshd exec is not a login shell (mirrors Heeler).
    public static let remotePathExport =
        "for d in \"$HOME\"/.nvm/versions/node/*/bin; do [ -d \"$d\" ] && PATH=\"$d:$PATH\"; done; "
        + "export PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\""

    public init(target: String, credentialID: UUID? = nil, sessionName: String? = nil) {
        self.target = target
        self.credentialID = credentialID
        self.sessionName = Device.normalizedSessionName(sessionName)
    }

    deinit {
        process?.terminate()
        apiBridge?.stop()
    }

    // MARK: - Probing

    /// Resolves the remote home once; also proves SSH reachability and detects Windows.
    public func probeRemoteHome() async throws -> String {
        if let remoteHome { return remoteHome }
        let platform = try await probeRemotePlatform()
        switch platform {
        case .unix(let home), .windows(let home, _):
            remoteHome = home
            return home
        }
    }

    /// Detects Unix vs Windows and caches the result for tunnel + attach.
    public func probeRemotePlatform() async throws -> RemotePlatform {
        if let remotePlatform { return remotePlatform }
        let platform = try await Self.detectRemotePlatform(
            target: target,
            credentialID: credentialID
        )
        remotePlatform = platform
        switch platform {
        case .unix(let home), .windows(let home, _):
            remoteHome = home
        }
        return platform
    }

    public func remoteSocketPath() async throws -> String {
        Self.remoteSocketPath(platform: try await probeRemotePlatform(), sessionName: sessionName)
    }

    /// herdr's socket for a session: `~/.config/herdr/herdr.sock` for the default one,
    /// `~/.config/herdr/sessions/<name>/herdr.sock` for a named one (herdr's
    /// `data_dir_for`, the layout `HerdrSessionDiscovery` scans locally).
    static func remoteSocketPath(platform: RemotePlatform, sessionName: String?) -> String {
        switch platform {
        case .unix(let home):
            if let sessionName {
                return "\(home)/.config/herdr/sessions/\(sessionName)/herdr.sock"
            }
            return "\(home)/.config/herdr/herdr.sock"
        case .windows(let home, _):
            // Display / diagnose only — OpenSSH cannot forward this path.
            let base = "\(home)\\AppData\\Roaming\\herdr"
            if let sessionName { return "\(base)\\sessions\\\(sessionName)\\herdr.sock" }
            return "\(base)\\herdr.sock"
        }
    }

    /// Deterministic local bridge/forward socket for a target and session (also used
    /// by attach). Two devices on one host but different sessions must not share it:
    /// the second forward would unlink the first one's socket.
    public static func localSocketPath(for target: String, sessionName: String? = nil) -> String {
        let dir = URL(fileURLWithPath: tunnelDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = Device.normalizedSessionName(sessionName).map { "\(target)#\($0)" } ?? target
        // Keep the path short: sockaddr_un caps at 104 bytes.
        return dir.appendingPathComponent("\(abs(key.hashValue) % 100_000).sock").path
    }

    static var tunnelDirectory: String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-tunnels", isDirectory: true).path
    }

    // MARK: - Orphaned forwards

    /// An `ssh -N -L` forward whose HerdrM is gone. A quit tears the tunnels down,
    /// but a kill (SIGKILL, a crash) gives the app no chance to, and `ssh -N` never
    /// reads stdin, so it does not notice: it stays up with PPID 1, holding its own
    /// connection to the host and a socket in `herdrm-tunnels/`.
    struct OrphanedForward: Equatable {
        let pid: pid_t
        let localSocketPath: String
    }

    /// Picks orphaned forwards out of `ps -axww -o pid=,ppid=,command=` output. Only
    /// re-parented (PPID 1) `/usr/bin/ssh -N` processes forwarding from the tunnel
    /// directory qualify, so the live tunnels of another running HerdrM (a debug build
    /// next to the installed app) are never touched.
    static func orphanedForwards(inProcessList list: String, tunnelDirectory: String) -> [OrphanedForward] {
        let forward = "-L \(tunnelDirectory)/"
        return list.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, let pid = pid_t(fields[0]), fields[1] == "1" else { return nil }
            let command = fields[2]
            guard command.hasPrefix("/usr/bin/ssh -N "),
                  let range = command.range(of: " \(forward)") else { return nil }
            let spec = command[command.index(after: range.lowerBound)...].dropFirst(3)
            guard let colon = spec.firstIndex(of: ":") else { return nil }
            // The reaper deletes this path, so accept only the names localSocketPath
            // generates (`<digits>.sock`): no `..`, no subdirectory, nothing outside.
            let name = spec[..<colon].dropFirst(tunnelDirectory.count + 1)
            guard name.hasSuffix(".sock"), name.count > 5,
                  name.dropLast(5).allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            return OrphanedForward(pid: pid, localSocketPath: String(spec[..<colon]))
        }
    }

    /// Stops the forwards a killed HerdrM left behind and removes their sockets.
    /// Called once at launch, before any tunnel of this process is up.
    @discardableResult
    public static func reapOrphanedForwards() -> Int {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        let output = Pipe()
        ps.standardOutput = output
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return 0 }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let orphans = orphanedForwards(
            inProcessList: String(decoding: data, as: UTF8.self),
            tunnelDirectory: tunnelDirectory
        )
        for orphan in orphans {
            kill(orphan.pid, SIGTERM)
            try? FileManager.default.removeItem(atPath: orphan.localSocketPath)
        }
        return orphans.count
    }

    /// True when this tunnel serves Windows via `remote-api-bridge` rather than `-L`.
    public var usesRemoteAPIBridge: Bool {
        if case .windows = remotePlatform { return true }
        return false
    }

    // MARK: - Tunnel lifecycle

    /// Ensures the forward (or Windows API bridge) is up and returns the local socket path.
    public func ensureUp() async throws -> String {
        if let localSocketPath {
            if let process, process.isRunning { return localSocketPath }
            if let apiBridge, apiBridge.isRunning { return localSocketPath }
        }
        process?.terminate()
        process = nil
        apiBridge?.stop()
        apiBridge = nil
        resetErrorCapture()

        let platform = try await probeRemotePlatform()
        let localSock = Self.localSocketPath(for: target, sessionName: sessionName)
        try? FileManager.default.removeItem(atPath: localSock)

        switch platform {
        case .windows(_, let herdrExecutable):
            return try startWindowsAPIBridge(
                localSock: localSock,
                herdrExecutable: herdrExecutable
            )
        case .unix:
            return try await startUnixSocketForward(
                localSock: localSock,
                remoteSock: try await remoteSocketPath()
            )
        }
    }

    private func startWindowsAPIBridge(
        localSock: String,
        herdrExecutable: String
    ) throws -> String {
        try Task.checkCancellation()
        let bridge = SSHRemoteAPIBridge(
            localSocketPath: localSock,
            target: target,
            herdrExecutable: herdrExecutable,
            credentialID: credentialID,
            sessionName: sessionName ?? "default"
        )
        do {
            try bridge.start()
        } catch {
            bridge.stop()
            throw error
        }
        apiBridge = bridge
        localSocketPath = localSock
        return localSock
    }

    private func startUnixSocketForward(
        localSock: String,
        remoteSock: String
    ) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let authentication = Self.authenticationConfiguration(for: credentialID)
        defer { authentication.discardAuthorization() }
        proc.arguments = Self.forwardArguments(
            localSock: localSock,
            remoteSock: remoteSock,
            target: target,
            authenticationArguments: authentication.arguments
        )
        proc.environment = ProcessInfo.processInfo.environment.merging(authentication.environment) { _, new in new }
        let errorOutput = Pipe()
        let errorBuffer = SSHErrorBuffer()
        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // EOF (ssh exited) stays readable forever; without this the handler
            // spins a core on empty reads until the tunnel is next rebuilt.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            errorBuffer.append(data)
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

    /// The `ssh -N -L` argv for the stream-local forward. It always opens its own
    /// connection: with `ControlMaster auto` in the user's ssh config, a forward
    /// requested through an existing master (another HerdrM session, Mutagen, a
    /// terminal) is set up inside that master's process and our ssh exits 0 at once.
    /// The tunnel then reads as failed ("ssh exited 0"), and `tearDown()` could not
    /// close a forward living in someone else's process anyway.
    static func forwardArguments(
        localSock: String,
        remoteSock: String,
        target: String,
        authenticationArguments: [String]
    ) -> [String] {
        ["-N"] + authenticationArguments + [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-L", "\(localSock):\(remoteSock)",
            sshDestination(target),
        ]
    }

    public func tearDown() {
        process?.terminate()
        process = nil
        apiBridge?.stop()
        apiBridge = nil
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

    // MARK: - Named sessions

    /// The remote's live herdr named sessions (issue #190), sorted, without
    /// `default`: every `~/.config/herdr/sessions/<name>/` holding a socket, the
    /// same rule `HerdrSessionDiscovery` applies to this Mac. Plain sh, so it
    /// works whatever the remote herdr version; Windows hosts aren't scanned.
    public func remoteNamedSessions() async throws -> [String] {
        guard case .unix = try await probeRemotePlatform() else { return [] }
        let output = try await Self.runSSH(
            target: target,
            command: Self.namedSessionScanCommand,
            timeout: 10,
            credentialID: credentialID
        )
        return Self.namedSessions(inScanOutput: output)
    }

    static let namedSessionScanCommand =
        "for s in \"$HOME\"/.config/herdr/sessions/*/herdr.sock; do "
        + "[ -S \"$s\" ] && basename \"$(dirname \"$s\")\"; done; true"

    /// Session names from the scan's output: one per line, unknown shapes and
    /// `default` dropped, so a stray directory can't smuggle in a bad name.
    static func namedSessions(inScanOutput output: String) -> [String] {
        let names = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && Device.isValidSessionName($0) && Device.normalizedSessionName($0) != nil }
        return Array(Set(names)).sorted()
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
        // Windows sessions never use stream-local forwards; a mute local socket
        // means the remote-api-bridge exec failed, not a missing Unix socket file.
        if case .windows = try? await probeRemotePlatform() {
            return .tunnelFailed(
                "Windows remote-api-bridge on \(target) accepted no reply"
                    + " — is herdr running, and is OpenSSH able to exec it?"
            )
        }
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

    /// Sniffs the remote OS: "macos", "windows", an os-release ID like "ubuntu"/"debian",
    /// or a uname fallback.
    public static func probeOS(target: String, credentialID: UUID? = nil) async throws -> String {
        // Prefer an explicit Windows probe: DefaultShell is often CMD, where the
        // POSIX `uname` script below never runs.
        if let windows = try? await runSSH(
            target: target,
            command: powershellEncodedCommand(windowsOSProbeScript),
            timeout: 10,
            credentialID: credentialID
        ) {
            let token = windows.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("herdr-windows:") || token == "windows" {
                return "windows"
            }
        }
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

    /// PowerShell that prints `herdr-windows:<arch>` on Windows hosts.
    static let windowsOSProbeScript = """
    $ProgressPreference = 'SilentlyContinue'
    if ($env:OS -ne 'Windows_NT') { exit 1 }
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    Write-Output ('herdr-windows:' + $arch)
    """

    /// Resolves home + herdr.exe on Windows, or `$HOME` on Unix.
    static func detectRemotePlatform(
        target: String,
        credentialID: UUID?
    ) async throws -> RemotePlatform {
        if let windows = try? await detectWindowsPlatform(
            target: target,
            credentialID: credentialID
        ) {
            return windows
        }
        let output = try await runSSH(
            target: target,
            command: "echo \"$HOME\"",
            timeout: 12,
            credentialID: credentialID
        )
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUnixHome(home) else {
            throw HerdrError.tunnelFailed("could not resolve remote home (got: \(output))")
        }
        return .unix(home: home)
    }

    static func detectWindowsPlatform(
        target: String,
        credentialID: UUID?
    ) async throws -> RemotePlatform {
        let output = try await runSSH(
            target: target,
            command: powershellEncodedCommand(windowsEnvironmentProbeScript),
            timeout: 15,
            credentialID: credentialID
        )
        guard let parsed = parseWindowsEnvironmentProbe(output) else {
            throw HerdrError.tunnelFailed("could not resolve Windows herdr environment")
        }
        return .windows(home: parsed.home, herdrExecutable: parsed.herdrExecutable)
    }

    /// Emits base64 home + herdr.exe paths (exits 1 off Windows, 2 if herdr is missing).
    static let windowsEnvironmentProbeScript = """
    $ProgressPreference = 'SilentlyContinue'
    if ($env:OS -ne 'Windows_NT') { exit 1 }
    function Emit([string]$Label, [string]$Value) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
        Write-Output ($Label + $encoded)
    }
    Emit 'herdr-windows-home:1:' $env:USERPROFILE
    $pathCommand = Get-Command herdr.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pathCommand) { Emit 'herdr-windows-herdr:1:' $pathCommand.Source; exit 0 }
    $herdrHome = if ([string]::IsNullOrWhiteSpace($env:HERDR_HOME)) {
        Join-Path $env:USERPROFILE '.herdr'
    } else {
        $env:HERDR_HOME
    }
    $active = Get-Item -LiteralPath (Join-Path $herdrHome 'packages\\standalone\\current') -Force -ErrorAction SilentlyContinue
    if ($null -ne $active -and -not [string]::IsNullOrWhiteSpace([string]$active.Target)) {
        Emit 'herdr-windows-herdr:1:' (Join-Path ([string]$active.Target) 'herdr.exe')
        exit 0
    }
    exit 2
    """

    /// UTF-16LE base64 for `powershell.exe -EncodedCommand` (avoids shell quoting).
    static func powershellEncodedCommand(_ script: String) -> String {
        let data = Data(script.utf16.flatMap { value -> [UInt8] in
            [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
        })
        return "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand \(data.base64EncodedString())"
    }

    static func parseWindowsEnvironmentProbe(_ output: String) -> (home: String, herdrExecutable: String)? {
        var home: String?
        var herdr: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = decodeWindowsProbeLine(line, prefix: "herdr-windows-home:1:") {
                home = value
            } else if let value = decodeWindowsProbeLine(line, prefix: "herdr-windows-herdr:1:") {
                herdr = value
            }
        }
        guard let home, let herdr, isWindowsHome(home), !herdr.isEmpty else { return nil }
        return (home, herdr)
    }

    static func decodeWindowsProbeLine(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let encoded = String(line.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: encoded),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func isUnixHome(_ home: String) -> Bool {
        home.hasPrefix("/")
    }

    /// `C:\Users\…` or `C:/Users/…` (CMD / PowerShell USERPROFILE forms).
    static func isWindowsHome(_ home: String) -> Bool {
        let utf8 = Array(home.utf8)
        guard utf8.count >= 3 else { return false }
        let drive = utf8[0]
        let isLetter = (drive >= 65 && drive <= 90) || (drive >= 97 && drive <= 122)
        guard isLetter, utf8[1] == UInt8(ascii: ":") else { return false }
        let sep = utf8[2]
        return sep == UInt8(ascii: "\\") || sep == UInt8(ascii: "/")
    }

    // MARK: - File transfer

    /// Streams one regular file to a private cache on the remote host and returns
    /// its absolute remote path. The generated name preserves only a safe extension.
    public func uploadFile(from localURL: URL) async throws -> String {
        let fileSize = try Self.validateUploadCandidate(localURL)
        return try await Self.uploadFile(
            target: target,
            localURL: localURL,
            remoteFilename: Self.uploadFilename(for: localURL),
            credentialID: credentialID,
            timeout: Self.uploadTimeout(fileSizeBytes: fileSize)
        )
    }

    /// Streams a folder to a private cache directory on the remote host and
    /// returns the absolute remote path of the folder, which keeps its name.
    public func uploadDirectory(from localURL: URL) async throws -> String {
        let totalSize = try Self.validateDirectoryUploadCandidate(localURL)
        return try await Self.uploadDirectory(
            target: target,
            localURL: localURL,
            remoteDirectoryName: UUID().uuidString.lowercased(),
            credentialID: credentialID,
            timeout: Self.uploadTimeout(fileSizeBytes: totalSize)
        )
    }

    /// Rejects folders the tar stream should not carry, and returns the total
    /// size of the regular files inside in bytes. Symlinks travel as links.
    @discardableResult
    static func validateDirectoryUploadCandidate(_ localURL: URL) throws -> Int {
        guard localURL.isFileURL else {
            throw HerdrError.fileTransferFailed("a local folder is required")
        }
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw HerdrError.fileTransferFailed("only folders can be transferred as folders")
        }
        // The name reaches the remote side only inside the tar stream, but a
        // newline would split the path the remote script prints back.
        guard !localURL.lastPathComponent.contains(where: \.isNewline) else {
            throw HerdrError.fileTransferFailed("the folder name contains a line break")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: localURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw HerdrError.fileTransferFailed("the folder could not be read")
        }
        var totalSize = 0
        var entries = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= maximumDirectoryUploadEntries else {
                throw HerdrError.fileTransferFailed(
                    "the folder has more than \(maximumDirectoryUploadEntries) items"
                )
            }
            let item = try url.resourceValues(forKeys: Set(keys))
            if item.isRegularFile == true {
                totalSize += item.fileSize ?? 0
            }
            guard totalSize <= maximumDirectoryUploadBytes else {
                throw HerdrError.fileTransferFailed(
                    "the folder is larger than the \(maximumDirectoryUploadBytes / (1024 * 1024)) MB limit"
                )
            }
        }
        return totalSize
    }

    /// Rejects what the upload path cannot stream, and returns the size in bytes.
    @discardableResult
    static func validateUploadCandidate(_ localURL: URL) throws -> Int {
        guard localURL.isFileURL else {
            throw HerdrError.fileTransferFailed("a local file is required")
        }
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw HerdrError.fileTransferFailed("only regular files can be transferred")
        }
        let fileSize = values.fileSize ?? 0
        guard fileSize <= maximumUploadBytes else {
            throw HerdrError.fileTransferFailed(
                "the file is larger than the \(maximumUploadBytes / (1024 * 1024)) MB limit"
            )
        }
        return fileSize
    }

    /// A hard deadline generous enough for a slow link (~256 KB/s) — stalled
    /// sessions are caught much earlier by ServerAlive, not by this watchdog.
    static func uploadTimeout(fileSizeBytes: Int) -> TimeInterval {
        min(600, 30 + Double(fileSizeBytes) / 262_144)
    }

    static func uploadFile(
        target: String,
        localURL: URL,
        remoteFilename: String,
        credentialID: UUID?,
        timeout: TimeInterval = 60,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")
    ) async throws -> String {
        // The name lands inside a remote shell script, so nothing but the
        // generated form of uploadFilename(for:) may reach it.
        guard isSafeRemoteFilename(remoteFilename) else {
            throw HerdrError.fileTransferFailed("unsafe remote filename")
        }
        let command = """
        umask 077
        dir="${XDG_CACHE_HOME:-$HOME/.cache}/herdrm/attachments"
        mkdir -p "$dir" && chmod 700 "$dir"
        find "$dir" -type f -mtime +7 -delete 2>/dev/null || true
        tmp="$dir/.\(remoteFilename).part"
        dest="$dir/\(remoteFilename)"
        if cat > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dest"; then
            printf '%s\\n' "$dest"
        else
            rm -f "$tmp"
            exit 1
        fi
        """

        return try await runUpload(
            target: target,
            command: command,
            credentialID: credentialID,
            timeout: timeout,
            executableURL: executableURL,
            makeInput: { .file(try FileHandle(forReadingFrom: localURL)) }
        )
    }

    static func uploadDirectory(
        target: String,
        localURL: URL,
        remoteDirectoryName: String,
        credentialID: UUID?,
        timeout: TimeInterval = 60,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        tarURL: URL = URL(fileURLWithPath: "/usr/bin/tar")
    ) async throws -> String {
        guard isSafeRemoteFilename(remoteDirectoryName) else {
            throw HerdrError.fileTransferFailed("unsafe remote filename")
        }
        // `tar -m` stamps extracted files with the upload time, so the
        // seven-day sweep measures from the upload, not the file's own age.
        let command = """
        umask 077
        dir="${XDG_CACHE_HOME:-$HOME/.cache}/herdrm/attachments"
        mkdir -p "$dir" && chmod 700 "$dir"
        find "$dir" -type f -mtime +7 -delete 2>/dev/null || true
        find "$dir" -mindepth 1 -type d -empty -mmin +60 -delete 2>/dev/null || true
        tmp="$dir/.\(remoteDirectoryName).part"
        dest="$dir/\(remoteDirectoryName)"
        if mkdir "$tmp" && tar -xmf - -C "$tmp" && mv -f "$tmp" "$dest"; then
            find "$dest" -mindepth 1 -maxdepth 1
        else
            rm -rf "$tmp"
            exit 1
        fi
        """
        let parent = localURL.deletingLastPathComponent().path
        // "./name" keeps a leading dash from reading as a tar option.
        let member = "./" + localURL.lastPathComponent
        return try await runUpload(
            target: target,
            command: command,
            credentialID: credentialID,
            timeout: timeout,
            executableURL: executableURL,
            makeInput: {
                let tar = Process()
                tar.executableURL = tarURL
                tar.arguments = ["-c", "-f", "-", "--no-mac-metadata", "-C", parent, member]
                // No AppleDouble `._*` files or xattrs in the stream.
                tar.environment = ["COPYFILE_DISABLE": "1"]
                tar.standardError = FileHandle.nullDevice
                return .process(tar)
            }
        )
    }

    enum UploadInput {
        case file(FileHandle)
        /// A producer whose stdout becomes ssh's stdin.
        case process(Process)
    }

    /// Runs the upload script over one ssh session with `makeInput` on stdin
    /// and returns the last absolute path the script prints.
    private static func runUpload(
        target: String,
        command: String,
        credentialID: UUID?,
        timeout: TimeInterval,
        executableURL: URL,
        makeInput: @escaping @Sendable () throws -> UploadInput
    ) async throws -> String {
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
                    "-o", "ServerAliveCountMax=4",
                    sshDestination(target),
                    // Under sh explicitly: the login shell may be zsh (where a
                    // `path=` assignment would clobber PATH) or fish (no `var=`
                    // assignments at all).
                    "exec /bin/sh -c \(HerdrService.shellQuoted(command))",
                ]
                proc.environment = ProcessInfo.processInfo.environment.merging(authentication.environment) { _, new in new }
                let output = Pipe()
                let errorOutput = Pipe()
                proc.standardOutput = output
                proc.standardError = errorOutput
                var producer: Process?
                do {
                    switch try makeInput() {
                    case .file(let handle):
                        proc.standardInput = handle
                    case .process(let source):
                        let pipe = Pipe()
                        source.standardOutput = pipe
                        proc.standardInput = pipe
                        try source.run()
                        producer = source
                    }
                    try proc.run()
                } catch {
                    if let producer, producer.isRunning { producer.terminate() }
                    continuation.resume(throwing: HerdrError.fileTransferFailed("ssh spawn: \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if proc.isRunning { proc.terminate() }
                    if let producer, producer.isRunning { producer.terminate() }
                }
                proc.waitUntilExit()
                if let producer {
                    // ssh exiting early (auth failure) leaves tar blocked on a
                    // full pipe; it must not outlive the upload.
                    if producer.isRunning { producer.terminate() }
                    producer.waitUntilExit()
                    if producer.terminationStatus != 0, proc.terminationStatus == 0 {
                        continuation.resume(throwing: HerdrError.fileTransferFailed("the folder could not be archived"))
                        return
                    }
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else {
                    let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(throwing: HerdrError.fileTransferFailed(
                        failureReason(status: proc.terminationStatus, stderr: errorData)
                    ))
                    return
                }
                let lines = String(data: data, encoding: .utf8)?
                    .split(whereSeparator: \.isNewline)
                    .map(String.init) ?? []
                guard let remotePath = lines.last(where: { $0.hasPrefix("/") }) else {
                    continuation.resume(throwing: HerdrError.fileTransferFailed("the remote host returned no path"))
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

    static func isSafeRemoteFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64, !name.hasPrefix("."), !name.contains("..") else {
            return false
        }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 97...122, UInt8(ascii: "-"), UInt8(ascii: "."): return true
            default: return false
            }
        }
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
#endif  // os(macOS)
