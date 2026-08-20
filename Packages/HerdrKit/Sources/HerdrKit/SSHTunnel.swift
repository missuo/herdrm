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
            target,
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
                    target,
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
