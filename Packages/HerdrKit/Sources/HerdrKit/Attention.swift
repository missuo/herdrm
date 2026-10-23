import Foundation

/// One glyph for a Space, using the same marks as an agent row.
/// Strongest state inside the space wins: needs input → unread → working.
public enum SpaceAttention: Equatable, Sendable {
    case blocked
    case unreadDone
    case working
    case none

    public static func rollup<S: Sequence>(_ agents: S) -> SpaceAttention
    where S.Element == (status: AgentStatus, unreadDone: Bool) {
        var sawUnreadDone = false
        var sawWorking = false
        for agent in agents {
            if agent.status == .blocked { return .blocked }
            if agent.status == .done, agent.unreadDone { sawUnreadDone = true }
            else if agent.status == .working { sawWorking = true }
        }
        if sawUnreadDone { return .unreadDone }
        if sawWorking { return .working }
        return .none
    }
}

/// Keys a "finished while you weren't looking" flag. herdr has no viewed
/// state; this lives entirely in the GUI.
public struct AgentUnreadKey: Hashable, Sendable {
    public let deviceID: UUID
    public let paneID: String

    public init(deviceID: UUID, paneID: String) {
        self.deviceID = deviceID
        self.paneID = paneID
    }
}

public enum AgentUnread: Sendable {
    /// Apply a live status transition. Initial snapshots pass an empty
    /// `previous` map and must not create unread flags.
    ///
    /// Completion first marks the pane unread. The GUI acknowledges it when
    /// opened, or immediately when its terminal is visible in the active window.
    public static func applying(
        previous: [String: AgentStatus],
        agents: [AgentInfo],
        unread: Set<AgentUnreadKey>,
        deviceID: UUID
    ) -> Set<AgentUnreadKey> {
        var next = unread
        let liveIDs = Set(agents.map(\.paneID))
        next = next.filter { key in
            key.deviceID != deviceID || liveIDs.contains(key.paneID)
        }

        guard !previous.isEmpty else { return next }

        for agent in agents {
            let key = AgentUnreadKey(deviceID: deviceID, paneID: agent.paneID)
            if agent.status != .done {
                next.remove(key)
                continue
            }
            let old = previous[agent.paneID]
            guard old != nil, old != agent.status else { continue }
            next.insert(key)
        }
        return next
    }
}
