import Foundation

/// Per-device facade over herdr's socket API. For SSH devices it owns the tunnel.
public actor HerdrService {
    public let device: Device
    private var tunnel: SSHTunnel?
    private var rpc: SocketRPC?
    /// nil for remote devices and when auto-start is off; remotes are the user's to run.
    private let localServer: LocalHerdrServer?
    /// Auto-start is for a server that was never there, not for one that went away: see
    /// `ping(_:socketPath:)`.
    private var everConnected = false

    public static let minimumProtocolVersion = 17

    public init(device: Device, autoStartLocalServer: Bool = true) {
        self.init(
            device: device,
            localServer: device.isLocal && autoStartLocalServer ? LocalHerdrServer() : nil
        )
    }

    /// Seam for tests: injects the auto-start collaborator, nil turning it off.
    init(device: Device, localServer: LocalHerdrServer?) {
        self.device = device
        if let target = device.sshTarget {
            self.tunnel = SSHTunnel(target: target, credentialID: device.id)
        }
        self.localServer = localServer
    }

    // MARK: - Connection

    public func connect() async throws -> PingResult {
        let socketPath: String
        switch device.kind {
        case .local:
            socketPath = device.socketPath
                ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/herdr/herdr.sock")
        case .ssh:
            guard let tunnel else { throw HerdrError.tunnelFailed("missing tunnel") }
            socketPath = try await tunnel.ensureUp()
        }
        let client = SocketRPC(socketPath: socketPath)
        let pong: PingResult
        do {
            pong = try await ping(client, socketPath: socketPath)
        } catch {
            // Two diagnosis routes compose here. The probe is definitive (it asks the
            // remote whether the socket exists) but only fits the silent-forward shape;
            // ssh's captured stderr is the generic fallback — often just
            // "connect failed: open failed", and blind when ControlMaster muxes the
            // host, which is exactly what the probe covers.
            if let tunnel {
                if let herdrError = error as? HerdrError, Self.isSilentForward(herdrError),
                   let diagnosis = await tunnel.diagnoseSilentForward() {
                    await tunnel.tearDown()
                    throw diagnosis
                }
                if let forwardingFailure = await tunnel.forwardingFailure() {
                    await tunnel.tearDown()
                    throw HerdrError.tunnelFailed(forwardingFailure)
                }
            }
            throw error
        }
        guard pong.protocolVersion >= Self.minimumProtocolVersion else {
            throw HerdrError.incompatibleProtocol(pong.protocolVersion)
        }
        rpc = client
        everConnected = true
        return pong
    }

    /// Test seam: whether this service would start a local server at all.
    var autoStartsLocalServer: Bool { localServer != nil }

    /// Pings; when the local server was never reachable in this session, starts it and pings
    /// again, so the app boots without the user opening a terminal to run `herdr`.
    ///
    /// A server that already answered here and is gone now was stopped deliberately — by
    /// `herdr server stop`, or by the restart in the middle of `herdr update` — and bringing
    /// it back would both undo the user's decision and let herdrm win the bind race that
    /// `herdr update` needs. The guard is per service instance rather than per process on
    /// purpose: Reconnect and the backoff loop must still be able to start a server for
    /// someone who installed or repaired herdr after opening the app.
    private func ping(_ client: SocketRPC, socketPath: String) async throws -> PingResult {
        do {
            return try await client.request(method: "ping", params: .object([:]), as: PingResult.self)
        } catch let error as HerdrError where Self.isServerDown(error) {
            guard let localServer, !everConnected else { throw error }
            try await localServer.ensureRunning(socketPath: socketPath)
            return try await client.request(method: "ping", params: .object([:]), as: PingResult.self)
        }
    }

    /// The two shapes a missing server takes: no socket file at all, or a file whose
    /// `connect()` is refused because nobody is listening.
    ///
    /// Nothing else qualifies, and the strictness is the point: `SocketRPC` reports a failed
    /// `read()` (the 15 s timeout — a hung but live server), `write()` or `socket()` through
    /// the same `connectionFailed` case, and every one of those proves somebody was on the
    /// other end. Treating them as "no server" would start a second daemon on top of a live
    /// one. Matched on the text `SocketRPC.connect` builds — `"connect(): \(strerror)"` — the
    /// way `AppModel.isSSHAuthenticationFailure` already matches OpenSSH's wording.
    static func isServerDown(_ error: HerdrError) -> Bool {
        switch error {
        case .socketUnavailable: return true
        case .connectionFailed(let reason):
            return reason.contains("connect():") && reason.contains("Connection refused")
        default: return false
        }
    }

    /// The shape a dead SSH forward takes: the tunnel is up, ssh accepts the local
    /// connection, fails to open the remote side, and closes it — the first read hits
    /// EOF and the reply comes back empty. Matched on the text
    /// `SocketRPC.decodeResponse` builds, the way `isServerDown` matches `connect()`'s
    /// wording. Everything else proves somebody replied (or the local socket itself
    /// failed) and must surface unchanged.
    static func isSilentForward(_ error: HerdrError) -> Bool {
        if case .malformedResponse("empty reply") = error { return true }
        return false
    }

    public func disconnect() async {
        rpc = nil
        if let tunnel { await tunnel.tearDown() }
    }

    private func client() throws -> SocketRPC {
        guard let rpc else { throw HerdrError.connectionFailed("not connected") }
        return rpc
    }

    // MARK: - Reads

    public func snapshot() async throws -> SessionSnapshot {
        struct Envelope: Codable { let snapshot: SessionSnapshot }
        return try await client().request(method: "session.snapshot", as: Envelope.self).snapshot
    }

    public func agents() async throws -> [AgentInfo] {
        struct Envelope: Codable { let agents: [AgentInfo] }
        return try await client().request(method: "agent.list", as: Envelope.self).agents
    }

    public func workspaces() async throws -> [WorkspaceInfo] {
        struct Envelope: Codable { let workspaces: [WorkspaceInfo] }
        return try await client().request(method: "workspace.list", as: Envelope.self).workspaces
    }

    /// Agent kinds this herdr server knows how to detect/start ("claude", "codex", …).
    public func agentKinds() async throws -> [String] {
        let result = try await client().request(method: "server.agent_manifests")
        guard let list = result["manifests"]?.arrayValue else { return [] }
        return list.compactMap { $0["agent"]?.stringValue }
    }

    /// The CLI binary a kind installs as (usually the kind itself).
    public static func binaryName(for kind: String) -> String {
        kind == "cursor" ? "cursor-agent" : kind
    }

    /// Flags that put a kind's CLI into bypass/yolo mode. Only kinds with a verified
    /// flag (vendor docs or `--help` output) are listed; nil = the agent has no known
    /// bypass mode and the UI hides the toggle entirely.
    public static func bypassFlags(for kind: String) -> [String]? {
        switch kind {
        case "claude": return ["--dangerously-skip-permissions"]
        case "codex": return ["--dangerously-bypass-approvals-and-sandbox"]
        case "grok": return ["--always-approve"]
        case "gemini": return ["--yolo"]
        case "opencode": return ["--auto"]
        case "cursor": return ["--force"]
        case "copilot": return ["--allow-all-tools"]
        default: return nil
        }
    }

    /// Sniffs which of the given kinds are actually installed on this device
    /// (`command -v` locally or over SSH), preserving order.
    public func installedAgentKinds(from kinds: [String]) async throws -> [String] {
        guard !kinds.isEmpty else { return [] }
        let binaries = kinds.map(Self.binaryName)
        let script = "\(SSHTunnel.remotePathExport); for b in \(binaries.joined(separator: " ")); do command -v \"$b\" >/dev/null 2>&1 && echo \"$b\"; done"
        let output: String
        switch device.kind {
        case .local:
            output = try await Self.runLocalShell(script)
        case .ssh(let target):
            output = try await SSHTunnel.runSSH(
                target: target,
                command: script,
                timeout: 15,
                credentialID: device.id
            )
        }
        let found = Set(output.split(separator: "\n").map(String.init))
        return kinds.filter { found.contains(Self.binaryName(for: $0)) }
    }

    static func runLocalShell(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                proc.arguments = ["-c", command]
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: HerdrError.connectionFailed(error.localizedDescription))
                    return
                }
                proc.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    // MARK: - Writes

    public func prompt(target: String, text: String) async throws {
        _ = try await client().request(
            method: "agent.prompt",
            params: .object(["target": .string(target), "text": .string(text)])
        )
    }

    /// The home directory on this device (local $HOME, or the probed remote one).
    public func homeDirectory() async throws -> String {
        switch device.kind {
        case .local:
            return NSHomeDirectory()
        case .ssh:
            guard let tunnel else { throw HerdrError.tunnelFailed("missing tunnel") }
            return try await tunnel.probeRemoteHome()
        }
    }

    /// "~" and "~/…" resolve against this device's home; anything else passes through.
    public func absolutePath(_ path: String) async throws -> String {
        if path == "~" { return try await homeDirectory() }
        if path.hasPrefix("~/") { return try await homeDirectory() + "/" + path.dropFirst(2) }
        return path
    }

    /// The visible subdirectories of a directory on this device ("~"-relative paths
    /// allowed), sorted the way Finder sorts. Feeds the New Space directory browser.
    /// Throws when the directory can't be read — callers decide how quiet to be.
    public func listDirectories(at path: String) async throws -> [String] {
        let absolute = try await absolutePath(path)
        let names: [String]
        switch device.kind {
        case .local:
            let manager = FileManager.default
            names = try manager.contentsOfDirectory(atPath: absolute).filter { name in
                guard !name.hasPrefix(".") else { return false }
                var isDirectory: ObjCBool = false
                // fileExists follows symlinks, so a linked project directory still lists.
                return manager.fileExists(atPath: "\(absolute)/\(name)", isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        case .ssh(let target):
            let output = try await SSHTunnel.runSSH(
                target: target,
                command: "cd \(Self.shellQuoted(absolute)) && LC_ALL=C ls -1p",
                timeout: 15,
                credentialID: device.id
            )
            names = output.split(separator: "\n").compactMap { line in
                line.hasSuffix("/") ? String(line.dropLast()) : nil
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Wraps a path for the remote shell. Single quotes so nothing inside expands;
    /// the quote dance survives sh, zsh, and fish login shells alike.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Creates a workspace (herdr "space") rooted at a directory.
    /// Returns its id and the root pane (a bare shell terminal).
    public func createWorkspace(label: String?, cwd: String?) async throws -> (workspaceID: String, rootPaneID: String?) {
        var params: [String: JSONValue] = ["focus": .bool(false)]
        if let label { params["label"] = .string(label) }
        if let cwd { params["cwd"] = .string(cwd) }
        let result = try await client().request(method: "workspace.create", params: .object(params))
        guard let id = result["workspace"]?["workspace_id"]?.stringValue
                ?? result["workspace_id"]?.stringValue
        else { throw HerdrError.malformedResponse("workspace.create returned no workspace_id") }
        return (id, result["root_pane"]?["pane_id"]?.stringValue)
    }

    public func renameWorkspace(workspaceID: String, label: String) async throws {
        _ = try await client().request(
            method: "workspace.rename",
            params: .object([
                "workspace_id": .string(workspaceID),
                "label": .string(label),
            ])
        )
    }

    /// Creates a tab (optionally in a workspace/cwd) and returns the new pane id.
    public func createTab(workspaceID: String?, cwd: String?, label: String?) async throws -> String {
        var params: [String: JSONValue] = ["focus": .bool(false)]
        if let workspaceID { params["workspace_id"] = .string(workspaceID) }
        if let cwd { params["cwd"] = .string(cwd) }
        if let label { params["label"] = .string(label) }
        let result = try await client().request(method: "tab.create", params: .object(params))
        guard let paneID = result["root_pane"]?["pane_id"]?.stringValue
        else { throw HerdrError.malformedResponse("tab.create returned no root_pane.pane_id") }
        return paneID
    }

    public func startAgent(
        name: String,
        kind: String,
        paneID: String,
        args: [String] = [],
        waitForShell: Bool = false
    ) async throws {
        var pinnedTerminalID: String?
        if waitForShell {
            pinnedTerminalID = try? await paneTerminalID(paneID)
        }
        let clock = ContinuousClock()
        let retryDeadline = clock.now.advanced(by: Self.paneShellReadinessTimeout)

        while true {
            do {
                _ = try await client().request(
                    method: "agent.start",
                    params: .object([
                        "name": .string(name),
                        "kind": .string(kind),
                        "pane_id": .string(paneID),
                        "args": .array(args.map { .string($0) }),
                    ])
                )
                return
            } catch let error as HerdrError {
                // Probe failures must not replace the server's original error.
                guard waitForShell,
                      Self.isPaneBusy(error),
                      clock.now < retryDeadline,
                      let pinnedTerminalID,
                      await paneShellStillInitializing(paneID, pinnedTerminalID: pinnedTerminalID)
                else { throw error }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    static let paneShellReadinessTimeout: Duration = .seconds(2)

    static func isPaneBusy(_ error: HerdrError) -> Bool {
        guard case .rpc(let code, _) = error else { return false }
        return code == "agent_pane_busy"
    }

    private func paneShellStillInitializing(_ paneID: String, pinnedTerminalID: String) async -> Bool {
        guard let terminalID = try? await paneTerminalID(paneID),
              terminalID == pinnedTerminalID,
              let initializing = try? await paneShellIsInitializing(paneID)
        else { return false }
        return initializing
    }

    private func paneTerminalID(_ paneID: String) async throws -> String? {
        let result = try await client().request(
            method: "pane.get",
            params: .object(["pane_id": .string(paneID)])
        )
        return result["pane"]?["terminal_id"]?.stringValue
    }

    private func paneShellIsInitializing(_ paneID: String) async throws -> Bool {
        let result = try await client().request(
            method: "pane.process_info",
            params: .object(["pane_id": .string(paneID)])
        )
        guard let processInfo = result["process_info"] else { return false }
        return Self.processInfoShowsShellInitialization(processInfo)
    }

    static func processInfoShowsShellInitialization(_ processInfo: JSONValue) -> Bool {
        guard let shellPID = integer(processInfo["shell_pid"]),
              integer(processInfo["foreground_process_group_id"]) == shellPID
        else { return false }
        return processInfo["foreground_processes"]?.arrayValue?.contains { process in
            guard integer(process["pid"]) == shellPID else { return false }
            let name = process["name"]?.stringValue
            let argv0 = process["argv"]?.arrayValue?.first?.stringValue
            return name.map(isPaneShellProcessName) == true
                || argv0.map(isPaneShellProcessName) == true
        } == true
    }

    private static func integer(_ value: JSONValue?) -> UInt64? {
        guard case .number(let number)? = value else { return nil }
        return UInt64(exactly: number)
    }

    private static func isPaneShellProcessName(_ value: String) -> Bool {
        var name = value
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? value
        while name.hasPrefix("-") { name.removeFirst() }
        name = name.lowercased()
        if name.hasSuffix(".exe") { name.removeLast(4) }
        return [
            "sh", "bash", "dash", "zsh", "fish", "ksh", "mksh", "csh", "tcsh",
            "elvish", "xonsh", "nu", "pwsh", "powershell", "cmd",
        ].contains(name)
    }

    /// Reads the pane's visible screen with ANSI intact. Returns nil text when unchanged
    /// since `ifChangedFrom` (compared via the pane revision).
    public func readPane(paneID: String) async throws -> (text: String, revision: Int) {
        let result = try await client().request(
            method: "pane.read",
            params: .object([
                "pane_id": .string(paneID),
                "source": .string("visible"),
                "format": .string("ansi"),
            ])
        )
        guard let text = result["read"]?["text"]?.stringValue else {
            throw HerdrError.malformedResponse("pane.read returned no text")
        }
        let revision: Int
        if case .number(let value)? = result["read"]?["revision"] {
            revision = Int(value)
        } else {
            revision = -1
        }
        return (text, revision)
    }

    /// Sends literal text (herdr wraps it in bracketed paste when the app enables it —
    /// right for pastes, wrong for keystrokes; use sendKeys for those).
    public func sendInput(paneID: String, text: String) async throws {
        _ = try await client().request(
            method: "pane.send_input",
            params: .object(["pane_id": .string(paneID), "text": .string(text)])
        )
    }

    /// Sends named keys ("a", "enter", "backspace", "ctrl+c", …) encoded as real
    /// terminal key presses by herdr.
    public func sendKeys(paneID: String, keys: [String]) async throws {
        _ = try await client().request(
            method: "pane.send_input",
            params: .object(["pane_id": .string(paneID), "keys": .array(keys.map { .string($0) })])
        )
    }

    public func closePane(paneID: String) async throws {
        _ = try await client().request(method: "pane.close", params: .object(["pane_id": .string(paneID)]))
    }

    public func closeWorkspace(workspaceID: String) async throws {
        _ = try await client().request(
            method: "workspace.close",
            params: .object(["workspace_id": .string(workspaceID)])
        )
    }

    /// Makes a local file readable by this device and returns the device-local path.
    /// Remote files are streamed over SSH into the user's private cache.
    public func stageAttachment(from localURL: URL) async throws -> String {
        switch device.kind {
        case .local:
            return localURL.path
        case .ssh:
            guard let tunnel else { throw HerdrError.tunnelFailed("missing tunnel") }
            return try await tunnel.uploadFile(from: localURL)
        }
    }

    // MARK: - Events

    public func events() throws -> AsyncThrowingStream<HerdrEvent, Error> {
        try client().events()
    }

    // MARK: - Terminal attach

    /// Shell fragment that picks the herdr binary to attach with. herdr's attach
    /// stream requires the CLI and server protocol versions to match exactly, so
    /// when several herdr binaries share the PATH (a stale copy in ~/.local/bin
    /// next to an updated /usr/local/bin install), blindly taking the first one
    /// yields `protocol_mismatch`. When the server version is known, every PATH
    /// candidate is tried for an exact `--version` match first; the first-found
    /// binary stays the fallback either way.
    static func attachBinarySelection(serverVersion: String?) -> String {
        guard let serverVersion, !serverVersion.isEmpty,
              serverVersion.allSatisfy({ $0.isNumber || $0 == "." })
        else { return "hb=herdr" }
        // A manual PATH walk: `command -v -a` isn't POSIX and silently returns
        // only the first match under macOS /bin/sh.
        return "hb=''; oldifs=$IFS; IFS=:; for d in $PATH; do c=\"$d/herdr\"; [ -x \"$c\" ] || continue; "
            + "[ \"$(\"$c\" --version 2>/dev/null | awk '{print $NF}')\" = '\(serverVersion)' ] && { hb=\"$c\"; break; }; "
            + "done; IFS=$oldifs; [ -n \"$hb\" ] || hb=herdr"
    }

    /// The command the embedded terminal should spawn to attach to a pane.
    /// `serverVersion` (from the device's last successful ping) lets the attach
    /// pick a herdr binary whose protocol matches the server's — see
    /// `attachBinarySelection`.
    public nonisolated func attachCommand(paneID: String, serverVersion: String? = nil) -> AttachCommand {
        // GUI apps launched from Finder don't inherit a login-shell PATH, and
        // sshd exec is not a login shell either — hence the PATH export.
        let script = "\(SSHTunnel.remotePathExport); \(Self.attachBinarySelection(serverVersion: serverVersion)); "
            + "exec \"$hb\" agent attach '\(paneID)' --takeover"
        switch device.kind {
        case .local:
            return AttachCommand(executable: "/bin/sh", args: ["-c", script], environment: [:], authorizationID: nil)
        case .ssh(let target):
            // Wrapped in sh explicitly: the ssh remote command runs in the user's
            // login shell, and the script's sh syntax must not depend on it.
            let remote = "exec /bin/sh -c \(Self.shellQuoted(script))"
            let authentication = SSHTunnel.authenticationConfiguration(for: device.id)
            return AttachCommand(
                executable: "/usr/bin/ssh",
                args: ["-tt"] + authentication.arguments + [
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=10",
                    SSHTunnel.sshDestination(target), remote,
                ],
                environment: authentication.environment,
                authorizationID: authentication.authorizationID
            )
        }
    }
}

public struct AttachCommand: Sendable {
    public let executable: String
    public let args: [String]
    public let environment: [String: String]
    /// Single-use askpass grant; the caller must discard it once the process exits.
    public let authorizationID: UUID?
}
