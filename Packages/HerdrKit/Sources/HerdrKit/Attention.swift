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
            if agent.status == .working { sawWorking = true }
            else if agent.unreadDone { sawUnreadDone = true }
        }
        if sawUnreadDone { return .unreadDone }
        if sawWorking { return .working }
        return .none
    }
}

/// Keys a "finished while you weren't looking" flag. herdr has no viewed
/// state; this lives entirely in the GUI.
public struct AgentUnreadKey: Codable, Hashable, Sendable {
    public let deviceID: UUID
    public let paneID: String

    public init(deviceID: UUID, paneID: String) {
        self.deviceID = deviceID
        self.paneID = paneID
    }
}

/// Tracks completed results from snapshots for one device. Retain this value
/// across a connection gap so turns completed while disconnected are counted.
public struct AgentCompletionTracker: Codable, Equatable, Sendable {
    private struct Observation: Codable, Equatable, Sendable {
        let terminalID: String?
        let completionSeq: UInt64?
        let status: AgentStatus
    }

    private struct AcknowledgedCompletion: Codable, Equatable, Sendable {
        let terminalID: String?
        let completionSeq: UInt64
        /// Acknowledgement order, so the cap drops the oldest first.
        let order: UInt64
    }

    /// Acknowledgements outlive a pane's temporary absence and are persisted,
    /// so a device keeps at most this many (the most recently read).
    public static let acknowledgementLimit = 256

    private var observations: [String: Observation] = [:]
    private var acknowledgedCompletions: [String: AcknowledgedCompletion] = [:]
    private var acknowledgementClock: UInt64 = 0

    public init() {}

    /// Panes whose current terminal has reported a completion sequence. Only
    /// these servers (protocol 22+) distinguish "read" (idle with a sequence)
    /// from a sequence-less recovery state; older ones never send one.
    public var sequencedPaneIDs: Set<String> {
        Set(observations.compactMap { $0.value.completionSeq == nil ? nil : $0.key })
    }

    var acknowledgedPaneIDs: Set<String> { Set(acknowledgedCompletions.keys) }

    /// A replacement terminal cannot inherit the former result's unread badge.
    /// Inspect before update replaces the observation. Sequence rollback on the
    /// same terminal can be a recovered old baseline, not a new result.
    public func replacedPaneIDs(in agents: [AgentInfo]) -> Set<String> {
        Set(agents.compactMap { agent in
            guard let previous = observations[agent.paneID] else { return nil }
            if previous.terminalID != agent.terminalID { return agent.paneID }
            return nil
        })
    }

    /// Remember the result the user read independently of snapshot baselines.
    /// A reconnect can briefly omit the pane or its completion sequence.
    public mutating func acknowledge(paneID: String) {
        guard let observed = observations[paneID],
              let sequence = observed.completionSeq else { return }
        acknowledgementClock &+= 1
        acknowledgedCompletions[paneID] = AcknowledgedCompletion(
            terminalID: observed.terminalID, completionSeq: sequence, order: acknowledgementClock
        )
        let excess = acknowledgedCompletions.count - Self.acknowledgementLimit
        if excess > 0 {
            for stale in acknowledgedCompletions.sorted(by: { $0.value.order < $1.value.order }).prefix(excess) {
                acknowledgedCompletions[stale.key] = nil
            }
        }
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
            // A new terminal in the pane can never match the old acknowledgement.
            if let read = acknowledgedCompletions[agent.paneID], read.terminalID != agent.terminalID {
                acknowledgedCompletions[agent.paneID] = nil
            }
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
    ///
    /// `sequencedPaneIDs` (`AgentCompletionTracker.sequencedPaneIDs`) names the
    /// panes whose server reports completion sequences. Only those keep their
    /// dot through a sequence-less idle/unknown recovery state; on older
    /// servers idle without a sequence is the ordinary read state.
    public static func applying(
        previous: [String: AgentStatus],
        agents: [AgentInfo],
        unread: Set<AgentUnreadKey>,
        deviceID: UUID,
        completedPaneIDs: Set<String>? = nil,
        sequencedPaneIDs: Set<String> = []
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
                // Reconnects can temporarily report idle/unknown without a
                // sequence. Neither means the user read the retained result.
                // Idle with a sequence is the server's explicit read state.
                // Servers without sequences keep the pre-sequence behaviour.
                let recovering = sequencedPaneIDs.contains(agent.paneID)
                    && (agent.status == .unknown
                        || (agent.status == .idle && agent.completionSeq == nil))
                if !recovering { next.remove(key) }
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

/// Client attention belongs to a result, not the lifetime of the GUI process.
/// Save the badge and its completion history together so restoring the badge
/// does not replay a sound or revive a result that was already read.
public struct AgentAttentionState: Codable, Equatable, Sendable {
    public static let defaultsKey = "agents.attention"
    /// Bump when the stored shape changes. Any other version (or none) loads
    /// as empty state: a lost dot is better than a misread one.
    public static let formatVersion = 1
    public var unread: Set<AgentUnreadKey>
    public var trackers: [UUID: AgentCompletionTracker]

    private enum CodingKeys: String, CodingKey { case version, unread, trackers }

    public init(unread: Set<AgentUnreadKey> = [], trackers: [UUID: AgentCompletionTracker] = [:]) {
        self.unread = unread
        self.trackers = trackers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container,
                debugDescription: "Unsupported attention format \(version)"
            )
        }
        unread = try container.decode(Set<AgentUnreadKey>.self, forKey: .unread)
        trackers = try container.decode([UUID: AgentCompletionTracker].self, forKey: .trackers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(unread, forKey: .unread)
        try container.encode(trackers, forKey: .trackers)
    }

    public static func load(from defaults: UserDefaults = .standard) -> AgentAttentionState {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(Self.self, from: data)
        else { return AgentAttentionState() }
        return state
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
