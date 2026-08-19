import Foundation

/// Per-device facade over herdr's socket API. For SSH devices it owns the tunnel.
public actor HerdrService {
    public let device: Device
    private var tunnel: SSHTunnel?
    private var rpc: SocketRPC?

    public static let minimumProtocolVersion = 17

    public init(device: Device) {
        self.device = device
        if let target = device.sshTarget {
            self.tunnel = SSHTunnel(target: target)
        }
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
        let pong = try await client.request(method: "ping", params: .object([:]), as: PingResult.self)
        guard pong.protocolVersion >= Self.minimumProtocolVersion else {
            throw HerdrError.incompatibleProtocol(pong.protocolVersion)
        }
        rpc = client
        return pong
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
            output = try await SSHTunnel.runSSH(target: target, command: script, timeout: 15)
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

    public func startAgent(name: String, kind: String, paneID: String, args: [String] = []) async throws {
        _ = try await client().request(
            method: "agent.start",
            params: .object([
                "name": .string(name),
                "kind": .string(kind),
                "pane_id": .string(paneID),
                "args": .array(args.map { .string($0) }),
            ])
        )
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

    // MARK: - Events

    public func events() throws -> AsyncThrowingStream<HerdrEvent, Error> {
        try client().events()
    }

    // MARK: - Terminal attach

    /// The command the embedded terminal should spawn to attach to a pane.
    public nonisolated func attachCommand(paneID: String) -> (executable: String, args: [String]) {
        switch device.kind {
        case .local:
            // GUI apps launched from Finder don't inherit a login-shell PATH.
            let local = "\(SSHTunnel.remotePathExport); exec herdr agent attach '\(paneID)' --takeover"
            return ("/bin/sh", ["-c", local])
        case .ssh(let target):
            let remote = "\(SSHTunnel.remotePathExport); exec herdr agent attach '\(paneID)' --takeover"
            return ("/usr/bin/ssh", [
                "-tt",
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                target, remote,
            ])
        }
    }
}
