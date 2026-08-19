import Foundation

/// Agent status buckets as reported by herdr (protocol 19).
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case working
    case blocked
    case done
    case unknown

    public init(wire: String?) {
        self = AgentStatus(rawValue: wire ?? "unknown") ?? .unknown
    }

    /// Console sort bucket, matching Heeler: Blocked > Done > Working > Idle > Unknown.
    public var sortBucket: Int {
        switch self {
        case .blocked: return 0
        case .done: return 1
        case .working: return 2
        case .idle: return 3
        case .unknown: return 4
        }
    }
}

public struct AgentInfo: Codable, Sendable, Identifiable, Equatable {
    public let terminalID: String?
    /// Missing while herdr is still detecting the agent in a freshly started pane.
    public let agentKindRaw: String?
    public let terminalTitle: String?
    public let terminalTitleStripped: String?
    public let agentStatusRaw: String?
    public let workspaceID: String
    public let tabID: String
    public let paneID: String
    public let focused: Bool?
    public let cwd: String?
    public let revision: Int?

    public var id: String { paneID }
    public var status: AgentStatus { AgentStatus(wire: agentStatusRaw) }
    public var agent: String { agentKindRaw ?? "agent" }
    public var title: String {
        let stripped = terminalTitleStripped ?? terminalTitle
        if let stripped, !stripped.isEmpty { return stripped }
        return agent
    }

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case agentKindRaw = "agent"
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case agentStatusRaw = "agent_status"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case focused
        case cwd
        case revision
    }
}

public struct WorkspaceInfo: Codable, Sendable, Identifiable, Equatable {
    public let workspaceID: String
    public let number: Int
    public let label: String
    public let focused: Bool?
    public let paneCount: Int?
    public let tabCount: Int?
    public let activeTabID: String?
    public let agentStatusRaw: String?

    public var id: String { workspaceID }
    public var status: AgentStatus { AgentStatus(wire: agentStatusRaw) }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number
        case label
        case focused
        case paneCount = "pane_count"
        case tabCount = "tab_count"
        case activeTabID = "active_tab_id"
        case agentStatusRaw = "agent_status"
    }
}

/// Any pane in the session, agent or bare shell.
public struct PaneInfo: Codable, Sendable, Identifiable, Equatable {
    public let paneID: String
    public let workspaceID: String
    public let tabID: String?
    public let agentKindRaw: String?
    public let agentStatusRaw: String?
    public let terminalTitle: String?
    public let cwd: String?
    public let revision: Int?

    public var id: String { paneID }
    public var hasAgent: Bool { agentKindRaw != nil }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agentKindRaw = "agent"
        case agentStatusRaw = "agent_status"
        case terminalTitle = "terminal_title"
        case cwd
        case revision
    }
}

public struct SessionSnapshot: Codable, Sendable, Equatable {
    public let agents: [AgentInfo]
    public let workspaces: [WorkspaceInfo]
    public let panes: [PaneInfo]?
    public let focusedPaneID: String?
    public let focusedWorkspaceID: String?
    public let version: String?
    public let protocolVersion: Int?

    enum CodingKeys: String, CodingKey {
        case agents
        case workspaces
        case panes
        case focusedPaneID = "focused_pane_id"
        case focusedWorkspaceID = "focused_workspace_id"
        case version
        case protocolVersion = "protocol"
    }
}

public struct PingResult: Codable, Sendable {
    public let version: String
    public let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
    }
}

public struct HerdrEvent: Sendable {
    public let kind: String
    public let payload: JSONValue

    /// All parameterless (globally subscribable) kinds in herdr protocol 19.
    /// pane.agent_status_changed / pane.scroll_changed / pane.output_matched are
    /// pane-scoped (require pane_id) and are deliberately absent; status changes
    /// surface globally via pane.updated.
    public static let allKinds: [String] = [
        "workspace.created", "workspace.updated", "workspace.metadata_updated", "workspace.renamed",
        "workspace.moved", "workspace.reordered", "workspace.focused", "workspace.closed",
        "worktree.created", "worktree.opened", "worktree.removed",
        "tab.created", "tab.renamed", "tab.moved", "tab.focused", "tab.closed",
        "pane.created", "pane.updated", "pane.moved", "pane.focused", "pane.closed", "pane.exited",
        "pane.agent_detected",
        "layout.updated",
    ]
}

public enum HerdrError: Error, LocalizedError, Sendable {
    case socketUnavailable(String)
    case connectionFailed(String)
    case herdrNotInstalled
    case rpc(code: String, message: String)
    case malformedResponse(String)
    case incompatibleProtocol(Int)
    case tunnelFailed(String)

    public var errorDescription: String? {
        switch self {
        case .socketUnavailable(let path): return "herdr socket not found at \(path)"
        case .connectionFailed(let reason): return "connection failed: \(reason)"
        case .herdrNotInstalled: return "herdr not found on herdrm's PATH — install it with \"brew install herdr\""
        case .rpc(let code, let message): return "herdr error \(code): \(message)"
        case .malformedResponse(let reason): return "malformed response: \(reason)"
        case .incompatibleProtocol(let version): return "herdr protocol \(version) is too old (need >= 17)"
        case .tunnelFailed(let reason): return "SSH tunnel failed: \(reason)"
        }
    }
}
