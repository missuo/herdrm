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

/// Tracks completed results from snapshots for one device. Retain this value
/// across a connection gap so turns completed while disconnected are counted.
public struct AgentCompletionTracker: Sendable {
    private struct Observation: Sendable {
        let terminalID: String?
        let completionSeq: UInt64?
        let status: AgentStatus
    }

    private struct AcknowledgedCompletion: Sendable {
        let terminalID: String?
        let completionSeq: UInt64
    }

    private var observations: [String: Observation] = [:]
    private var acknowledgedCompletions: [String: AcknowledgedCompletion] = [:]

    public init() {}

    /// Remember the result the user read independently of snapshot baselines.
    /// A reconnect can briefly omit the pane or its completion sequence.
    public mutating func acknowledge(paneID: String) {
        guard let observed = observations[paneID],
              let sequence = observed.completionSeq else { return }
        acknowledgedCompletions[paneID] = AcknowledgedCompletion(
            terminalID: observed.terminalID, completionSeq: sequence
        )
    }

    /// Events can expose a short-lived active state between snapshots on
    /// older servers. Only a later snapshot may confirm its completion.
    public mutating func observeActivity(paneID: String, status: AgentStatus) {
        guard status == .working || status == .blocked,
              let previous = observations[paneID] else { return }
        observations[paneID] = Observation(
            terminalID: previous.terminalID, completionSeq: previous.completionSeq,
            status: status
        )
    }

    public mutating func update(agents: [AgentInfo]) -> Set<String> {
        let liveIDs = Set(agents.map(\.paneID))
        observations = observations.filter { liveIDs.contains($0.key) }
        var completed: Set<String> = []

        for agent in agents {
            guard let previous = observations[agent.paneID],
                  previous.terminalID == agent.terminalID else {
                // First sight of a pane (or its replacement terminal) seeds a
                // baseline; already-finished results are not new notifications.
                observations[agent.paneID] = Observation(
                    terminalID: agent.terminalID, completionSeq: agent.completionSeq,
                    status: agent.status
                )
                continue
            }

            if let sequence = agent.completionSeq {
                let isNew = previous.completionSeq.map { sequence > $0 } ?? true
                if isNew, agent.status == .done { completed.insert(agent.paneID) }
                // A smaller sequence means the backend restarted its counter.
                // A sequence on idle is already read by the server; consume it
                // without notifying so a later done status cannot revive it.
            } else if previous.completionSeq == nil,
                      isLegacyCompletion(from: previous.status, to: agent.status) {
                completed.insert(agent.paneID)
            }

            if let read = acknowledgedCompletions[agent.paneID],
               read.terminalID == agent.terminalID,
               read.completionSeq == agent.completionSeq {
                completed.remove(agent.paneID)
            }

            observations[agent.paneID] = Observation(
                terminalID: agent.terminalID,
                completionSeq: agent.completionSeq ?? previous.completionSeq,
                // Unknown is a temporary classification gap, not the end of
                // observed work. Preserve that evidence for legacy servers;
                // idle, done and terminal replacement still reset it.
                status: agent.status == .unknown ? previous.status : agent.status
            )
        }
        return completed
    }
}

private func isLegacyCompletion(from previous: AgentStatus?, to status: AgentStatus) -> Bool {
    status == .done && (previous == .working || previous == .blocked)
}

public enum AgentUnread: Sendable {
    /// Apply completion decisions from the snapshot tracker. Without an
    /// explicit set, older callers use observed working/blocked-to-done
    /// transitions; an empty initial status baseline never creates flags.
    ///
    /// Completion first marks the pane unread. The GUI acknowledges it when
    /// opened, or immediately when its terminal is visible in the active window.
    public static func applying(
        previous: [String: AgentStatus],
        agents: [AgentInfo],
        unread: Set<AgentUnreadKey>,
        deviceID: UUID,
        completedPaneIDs: Set<String>? = nil
    ) -> Set<AgentUnreadKey> {
        var next = unread
        let liveIDs = Set(agents.map(\.paneID))
        next = next.filter { key in
            key.deviceID != deviceID || liveIDs.contains(key.paneID)
        }

        guard completedPaneIDs != nil || !previous.isEmpty else { return next }

        for agent in agents {
            let key = AgentUnreadKey(deviceID: deviceID, paneID: agent.paneID)
            if agent.status != .done {
                // Unknown is a temporary loss of classification, not an
                // acknowledgement. Retain unread until the known state returns.
                if agent.status != .unknown { next.remove(key) }
                continue
            }
            let completed = completedPaneIDs?.contains(agent.paneID)
                ?? isLegacyCompletion(from: previous[agent.paneID], to: agent.status)
            guard completed else { continue }
            next.insert(key)
        }
        return next
    }
}
