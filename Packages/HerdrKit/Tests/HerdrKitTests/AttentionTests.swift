import XCTest
@testable import HerdrKit

final class AttentionTests: XCTestCase {
    func testRollupPicksTheStrongestAgentState() {
        XCTAssertEqual(
            SpaceAttention.rollup([
                (status: .working, unreadDone: false),
                (status: .done, unreadDone: true),
                (status: .blocked, unreadDone: false),
            ]),
            .blocked
        )
        XCTAssertEqual(
            SpaceAttention.rollup([
                (status: .working, unreadDone: false),
                (status: .done, unreadDone: true),
                (status: .done, unreadDone: false),
            ]),
            .unreadDone
        )
        XCTAssertEqual(
            SpaceAttention.rollup([
                (status: .working, unreadDone: false),
                (status: .done, unreadDone: false),
            ]),
            .working
        )
        XCTAssertEqual(
            SpaceAttention.rollup([
                (status: .done, unreadDone: false),
                (status: .idle, unreadDone: false),
            ]),
            .none
        )
        XCTAssertEqual(
            SpaceAttention.rollup([
                (status: .idle, unreadDone: false),
            ]),
            .none
        )
    }

    func testRecoveringUnreadResultsRemainVisibleWithoutOverridingActiveState() {
        for status in [AgentStatus.idle, .unknown] {
            XCTAssertEqual(SpaceAttention.rollup([(status: status, unreadDone: true)]), .unreadDone)
            XCTAssertEqual(SpaceAttention.rollup([(status: status, unreadDone: false)]), .none)
            XCTAssertEqual(SpaceAttention.rollup([
                (status: status, unreadDone: true),
                (status: .working, unreadDone: false),
            ]), .unreadDone, "An unread result keeps the same space priority during recovery")
            XCTAssertEqual(SpaceAttention.rollup([
                (status: status, unreadDone: true),
                (status: .blocked, unreadDone: false),
            ]), .blocked)
        }
        XCTAssertEqual(SpaceAttention.rollup([(status: .working, unreadDone: true)]), .working)
        XCTAssertEqual(SpaceAttention.rollup([(status: .blocked, unreadDone: true)]), .blocked)
    }

    func testInitialSnapshotDoesNotMarkUnread() throws {
        let agent = try decodeDone(paneID: "w1:p1")
        let device = UUID()
        let unread = AgentUnread.applying(
            previous: [:],
            agents: [agent],
            unread: [],
            deviceID: device
        )
        XCTAssertTrue(unread.isEmpty)
    }

    func testTransitionToDoneMarksUnreadEvenIfSelected() throws {
        let agent = try decodeDone(paneID: "w1:p1")
        let device = UUID()
        let unread = AgentUnread.applying(
            previous: ["w1:p1": .working],
            agents: [agent],
            unread: [],
            deviceID: device
        )
        XCTAssertEqual(unread, [AgentUnreadKey(deviceID: device, paneID: "w1:p1")])
    }

    func testRestoredIdleOrUnknownResultsDoNotBecomeUnread() throws {
        let device = UUID()
        let agents = try ["idle", "unknown"].enumerated().map { index, _ in
            try decodeDone(paneID: "w\(index + 1):p1")
        }
        let unread = AgentUnread.applying(
            previous: ["w1:p1": .idle, "w2:p1": .unknown],
            agents: agents, unread: [], deviceID: device
        )
        XCTAssertTrue(unread.isEmpty, "Restoring old results is not a new completion")
    }

    func testLeavingDoneClearsUnreadAndGonePanesArePruned() throws {
        let device = UUID()
        let key = AgentUnreadKey(deviceID: device, paneID: "w1:p1")
        let other = AgentUnreadKey(deviceID: UUID(), paneID: "w2:p1")
        let working = try decodeAgent(paneID: "w1:p1", status: "working")
        let next = AgentUnread.applying(
            previous: ["w1:p1": .done],
            agents: [working],
            unread: [key, other],
            deviceID: device
        )
        XCTAssertEqual(next, [other])

        let pruned = AgentUnread.applying(
            previous: ["w1:p1": .done],
            agents: [],
            unread: [key, other],
            deviceID: device
        )
        XCTAssertEqual(pruned, [other])
    }

    func testReadResultDoesNotReappearAfterStatusRecovery() throws {
        var tracker = AgentCompletionTracker()
        let pane = "w1:p1"
        func snapshot(_ status: String, _ sequence: UInt64?) throws -> [AgentInfo] {
            [try decodeAgent(paneID: pane, status: status, completionSeq: sequence)]
        }
        XCTAssertEqual(tracker.update(agents: try snapshot("done", 41)), [])
        XCTAssertEqual(tracker.update(agents: try snapshot("idle", nil)), [])
        XCTAssertEqual(tracker.update(agents: try snapshot("unknown", nil)), [])
        XCTAssertEqual(tracker.update(agents: try snapshot("done", 41)), [],
                       "The same completion remains read after status recovery")
        XCTAssertEqual(tracker.update(agents: try snapshot("working", nil)), [])
        XCTAssertEqual(tracker.update(agents: try snapshot("done", nil)), [],
                       "A missing sequence must not erase a known completion baseline")
        XCTAssertEqual(tracker.update(agents: try snapshot("done", 41)), [])
    }

    func testCompletedTurnsDuringDisconnectionAreDetectedOnce() throws {
        var tracker = AgentCompletionTracker()
        let pane = "w1:p1"
        func snapshot(_ status: String, _ sequence: UInt64?) throws -> [AgentInfo] {
            [try decodeAgent(paneID: pane, status: status, completionSeq: sequence)]
        }
        XCTAssertEqual(tracker.update(agents: try snapshot("done", 10)), [])
        // A whole turn can start and finish while no snapshots arrive.
        XCTAssertEqual(tracker.update(agents: try snapshot("done", 11)), [pane])
        XCTAssertEqual(tracker.update(agents: try snapshot("done", 11)), [])
        XCTAssertEqual(tracker.update(agents: try snapshot("working", nil)), [])
        XCTAssertEqual(tracker.update(agents: try snapshot("done", 12)), [pane])
        XCTAssertEqual(tracker.update(agents: try snapshot("blocked", nil)), [])
        XCTAssertEqual(tracker.update(agents: try snapshot("done", 13)), [pane])
    }

    func testAcknowledgedCompletionSurvivesARebuiltObservation() throws {
        var tracker = AgentCompletionTracker()
        let pane = "w1:p1"
        let done = try decodeAgent(paneID: pane, status: "done", completionSeq: 41)
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "working")]), [])
        XCTAssertEqual(tracker.update(agents: [done]), [pane])
        tracker.acknowledge(paneID: pane)

        XCTAssertEqual(tracker.update(agents: []), [])
        tracker.acknowledge(paneID: pane)
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "unknown")]), [])
        tracker.acknowledge(paneID: pane)
        XCTAssertEqual(tracker.update(agents: [done]), [],
                       "A temporary absence and sequence-less snapshot must not revive a read result")

        let next = try decodeAgent(paneID: pane, status: "done", completionSeq: 42)
        XCTAssertEqual(tracker.update(agents: [next]), [pane], "A new offline result still notifies")
        XCTAssertEqual(tracker.update(agents: [next]), [])
    }

    func testAcknowledgedCompletionSurvivesALowerSequenceBaseline() throws {
        var tracker = AgentCompletionTracker()
        let pane = "w1:p1"
        let done = try decodeAgent(paneID: pane, status: "done", completionSeq: 41)
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "working")]), [])
        XCTAssertEqual(tracker.update(agents: [done]), [pane])
        tracker.acknowledge(paneID: pane)

        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 2)]), [])
        XCTAssertEqual(tracker.update(agents: [done]), [],
                       "Replaying a read result must not notify after the observation counter moves back")
        let next = try decodeAgent(paneID: pane, status: "done", completionSeq: 42)
        XCTAssertEqual(tracker.update(agents: [next]), [pane])
        XCTAssertEqual(tracker.update(agents: [next]), [])
    }

    func testAcknowledgementDoesNotSuppressAReplacementTerminalOrLegacyTurn() throws {
        var tracker = AgentCompletionTracker()
        let pane = "w1:p1"
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 41)]), [])
        tracker.acknowledge(paneID: pane)

        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "working", terminalID: "new")]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 41, terminalID: "new")]), [pane],
                       "A replacement terminal owns its own completion sequence")

        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "working", terminalID: "legacy")]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", terminalID: "legacy")]), [pane])
        tracker.acknowledge(paneID: pane)
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "working", terminalID: "legacy")]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", terminalID: "legacy")]), [pane],
                       "Servers without completion sequences retain activity-based notifications")
    }

    func testServerReadCompletionAdvancesBaselineWithoutReminder() throws {
        var tracker = AgentCompletionTracker()
        let pane = "w1:p1"
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 20)]), [])
        // Idle with a completion sequence means another client has read it.
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "idle", completionSeq: 21)]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 21)]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "unknown", completionSeq: 22)]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 22)]), [])
    }

    func testFirstTurnCanCompleteEntirelyWhileDisconnected() throws {
        for initial in ["idle", "unknown"] {
            var tracker = AgentCompletionTracker()
            let pane = "w1:p1"
            XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: initial)]), [])
            XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 1)]), [pane])
            XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 1)]), [])
        }
    }

    func testNewPanesAndRestartedTerminalsEstablishFreshBaselines() throws {
        var tracker = AgentCompletionTracker()
        let first = try decodeAgent(paneID: "w1:p1", status: "done", completionSeq: 50)
        let newPane = try decodeAgent(paneID: "w2:p1", status: "done", completionSeq: 80)
        XCTAssertEqual(tracker.update(agents: [first]), [])
        XCTAssertEqual(tracker.update(agents: [first, newPane]), [])
        XCTAssertEqual(tracker.update(agents: []), [])
        XCTAssertEqual(tracker.update(agents: [first]), [], "A reused pane ID is a fresh baseline")
        let replacement = try decodeAgent(paneID: "w1:p1", status: "done", completionSeq: 90, terminalID: "replacement")
        XCTAssertEqual(tracker.update(agents: [replacement]), [])
        let next = try decodeAgent(paneID: "w1:p1", status: "done", completionSeq: 91, terminalID: "replacement")
        XCTAssertEqual(tracker.update(agents: [next]), ["w1:p1"])
    }

    func testServerSequenceRestartDoesNotNotifyUntilAnotherCompletion() throws {
        var tracker = AgentCompletionTracker()
        let pane = "w1:p1"
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 40)]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 2)]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "working")]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 3)]), [pane])
    }

    func testLegacySnapshotsOnlyNotifyAfterObservedWorkOrBlock() throws {
        var tracker = AgentCompletionTracker()
        let pane = "w1:p1"
        func snapshot(_ status: String) throws -> [AgentInfo] {
            [try decodeAgent(paneID: pane, status: status)]
        }
        XCTAssertEqual(tracker.update(agents: try snapshot("done")), [])
        for restored in ["idle", "unknown"] {
            XCTAssertEqual(tracker.update(agents: try snapshot(restored)), [])
            XCTAssertEqual(tracker.update(agents: try snapshot("done")), [])
        }
        for active in ["working", "blocked"] {
            XCTAssertEqual(tracker.update(agents: try snapshot(active)), [])
            XCTAssertEqual(tracker.update(agents: try snapshot("done")), [pane])
            XCTAssertEqual(tracker.update(agents: try snapshot("done")), [])
        }
        // A first observed running task can complete before we ever saw a sequence.
        XCTAssertEqual(tracker.update(agents: try snapshot("working")), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 1)]), [pane])
    }

    func testLegacyCompletionSurvivesUnknownSnapshots() throws {
        let pane = "w1:p1"
        for active in ["working", "blocked"] {
            var tracker = AgentCompletionTracker()
            XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: active)]), [])
            for _ in 0..<2 {
                XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "unknown")]), [])
            }
            XCTAssertEqual(tracker.update(agents: [try decodeDone(paneID: pane)]), [pane],
                           "Temporary loss of classification must not erase observed activity")
            XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "unknown")]), [])
            XCTAssertEqual(tracker.update(agents: [try decodeDone(paneID: pane)]), [],
                           "Status recovery must not replay the same completion")
        }
    }

    func testLegacyUnknownDoesNotCarryActivityPastIdleOrTerminalReplacement() throws {
        let pane = "w1:p1"
        var tracker = AgentCompletionTracker()
        for status in ["working", "unknown", "idle", "unknown", "done"] {
            XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: status)]), [],
                           "Idle ends the previous activity")
        }
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "working")]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "unknown", terminalID: "new")]), [])
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", terminalID: "new")]), [],
                       "A replacement terminal cannot inherit the old task")
    }

    func testActivityEventsAllowLegacyCompletionToBeConfirmedBySnapshot() throws {
        let pane = "w1:p1"
        for active in [AgentStatus.working, .blocked] {
            var tracker = AgentCompletionTracker()
            XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "idle")]), [])
            // A short task can complete before the next snapshot is fetched.
            tracker.observeActivity(paneID: pane, status: active)
            tracker.observeActivity(paneID: pane, status: .done)
            XCTAssertEqual(tracker.update(agents: [try decodeDone(paneID: pane)]), [pane])
            XCTAssertEqual(tracker.update(agents: [try decodeDone(paneID: pane)]), [])
        }

        var tracker = AgentCompletionTracker()
        tracker.observeActivity(paneID: pane, status: .working)
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 7)]), [],
                       "Events for a previously unknown pane do not replace its initial baseline")
        tracker.observeActivity(paneID: pane, status: .working)
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 7)]), [],
                       "An activity event retains the known completion sequence")
        tracker.observeActivity(paneID: pane, status: .blocked)
        XCTAssertEqual(tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 8)]), [pane])
    }

    func testExplicitCompletionsControlUnreadEvenWhenStatusIsUnchanged() throws {
        let device = UUID()
        let pane = "w1:p1"
        let done = try decodeDone(paneID: pane)
        XCTAssertEqual(AgentUnread.applying(previous: [pane: .working], agents: [done], unread: [],
                                           deviceID: device, completedPaneIDs: []), [])
        XCTAssertEqual(AgentUnread.applying(previous: [pane: .done], agents: [done], unread: [],
                                           deviceID: device, completedPaneIDs: [pane]),
                       [AgentUnreadKey(deviceID: device, paneID: pane)])
        XCTAssertEqual(AgentUnread.applying(previous: [:], agents: [done], unread: [],
                                           deviceID: device, completedPaneIDs: [pane]),
                       [AgentUnreadKey(deviceID: device, paneID: pane)],
                       "A retained completion tracker survives a cleared status baseline")
    }

    func testUnknownDuringReconnectPreservesUnreadWithoutRevivingReadResults() throws {
        let device = UUID()
        let pane = "w1:p1"
        let key = AgentUnreadKey(deviceID: device, paneID: pane)
        var tracker = AgentCompletionTracker()
        var previous: [String: AgentStatus] = [:]
        var unread: Set<AgentUnreadKey> = []
        func receive(_ status: String, sequence: UInt64?) throws {
            let agent = try decodeAgent(paneID: pane, status: status, completionSeq: sequence)
            let completed = tracker.update(agents: [agent])
            unread = AgentUnread.applying(previous: previous, agents: [agent], unread: unread,
                                           deviceID: device, completedPaneIDs: completed)
            previous[pane] = agent.status
        }

        try receive("working", sequence: nil)
        try receive("done", sequence: 4)
        XCTAssertEqual(unread, [key])
        try receive("unknown", sequence: nil)
        XCTAssertEqual(unread, [key], "Unknown does not acknowledge an unread result")
        try receive("done", sequence: 4)
        XCTAssertEqual(unread, [key], "The original unread result returns with its status")

        unread = [] // The user opens and reads the result.
        try receive("unknown", sequence: nil)
        try receive("done", sequence: 4)
        XCTAssertEqual(unread, [], "A read completion must not be recreated")
    }

    func testCompletionSequenceDecodesAndSurvivesDisplayStatusUpdates() throws {
        let agent = try decodeAgent(paneID: "w1:p1", status: "done", completionSeq: UInt64.max)
        XCTAssertEqual(agent.completionSeq, UInt64.max)
        XCTAssertEqual(agent.updatingStatus(.working).completionSeq, UInt64.max)
        let legacy = try decodeDone(paneID: "w1:p1")
        XCTAssertNil(legacy.completionSeq)
    }

    func testTrackerAndUnreadSurviveEncodingWithoutRepeatingCompletion() throws {
        let device = UUID()
        let first = try decodeAgent(paneID: "read", status: "working")
        let second = try decodeAgent(paneID: "unread", status: "working")
        var tracker = AgentCompletionTracker()
        XCTAssertEqual(tracker.update(agents: [first, second]), [])
        let done = try ["read", "unread"].map {
            try decodeAgent(paneID: $0, status: "done", completionSeq: 41)
        }
        XCTAssertEqual(tracker.update(agents: done), ["read", "unread"])
        tracker.acknowledge(paneID: "read")
        let unread: Set<AgentUnreadKey> = [AgentUnreadKey(deviceID: device, paneID: "unread")]

        // The process disappears here. Only encoded state reaches its successor.
        var restored = try roundTrip(tracker)
        let restoredUnread = try roundTrip(unread)
        XCTAssertEqual(restoredUnread, unread)
        XCTAssertEqual(restored.update(agents: done), [], "Restoring a badge is not a new notification")
        let next = try [done[0], decodeAgent(paneID: "unread", status: "done", completionSeq: 42)]
        XCTAssertEqual(restored.update(agents: next), ["unread"], "A turn completed while closed still notifies")
        XCTAssertEqual(restored.update(agents: next), [])

        restored.acknowledge(paneID: "unread")
        var afterReading = try roundTrip(restored)
        XCTAssertEqual(afterReading.update(agents: []), [])
        XCTAssertEqual(afterReading.update(agents: try ["read", "unread"].map {
            try decodeAgent(paneID: $0, status: "unknown")
        }), [])
        XCTAssertEqual(afterReading.update(agents: next), [], "Read results stay read across relaunch and recovery")
    }

    func testIdleWithoutSequenceDoesNotDiscardAnUnreadCompletion() throws {
        let device = UUID()
        let key = AgentUnreadKey(deviceID: device, paneID: "w1:p1")
        for status in ["idle", "unknown"] {
            let recovering = try decodeAgent(paneID: key.paneID, status: status)
            XCTAssertEqual(AgentUnread.applying(previous: [key.paneID: .done], agents: [recovering],
                                               unread: [key], deviceID: device, completedPaneIDs: []), [key],
                           "A sequence-less reconnect snapshot is not evidence the user read the result")
        }
        let readByServer = try decodeAgent(paneID: key.paneID, status: "idle", completionSeq: 41)
        XCTAssertEqual(AgentUnread.applying(previous: [key.paneID: .done], agents: [readByServer],
                                           unread: [key], deviceID: device, completedPaneIDs: []), [])
    }

    func testSavedAttentionRestoresBadgesAndCompletionHistoryTogether() throws {
        let suite = "AttentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AgentAttentionState.load(from: defaults), AgentAttentionState())
        let device = UUID()
        let key = AgentUnreadKey(deviceID: device, paneID: "w1:p1")
        var tracker = AgentCompletionTracker()
        _ = tracker.update(agents: [try decodeAgent(paneID: key.paneID, status: "working")])
        let done = try decodeAgent(paneID: key.paneID, status: "done", completionSeq: 41)
        XCTAssertEqual(tracker.update(agents: [done]), [key.paneID])
        let state = AgentAttentionState(unread: [key], trackers: [device: tracker])
        state.save(to: defaults)
        var restored = AgentAttentionState.load(from: defaults)
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.trackers[device]?.update(agents: [done]), [])
        restored.unread.remove(key)
        restored.trackers[device]?.acknowledge(paneID: key.paneID)
        restored.save(to: defaults)
        let read = AgentAttentionState.load(from: defaults)
        XCTAssertEqual(read, restored)
        XCTAssertTrue(read.unread.isEmpty)
    }

    func testOnlyTerminalReplacementInvalidatesTheOldUnreadResult() throws {
        let pane = "w1:p1"
        var tracker = AgentCompletionTracker()
        _ = tracker.update(agents: [try decodeAgent(paneID: pane, status: "done", completionSeq: 40)])
        for status in ["idle", "unknown"] {
            XCTAssertEqual(tracker.replacedPaneIDs(in: [try decodeAgent(paneID: pane, status: status)]), [])
        }
        XCTAssertEqual(tracker.replacedPaneIDs(in: [try decodeAgent(paneID: pane, status: "done", completionSeq: 2)]), [])
        XCTAssertEqual(tracker.replacedPaneIDs(in: [try decodeAgent(paneID: pane, status: "done", completionSeq: 40,
                                                                terminalID: "replacement")]), [pane])
        XCTAssertEqual(tracker.replacedPaneIDs(in: [try decodeAgent(paneID: pane, status: "done", completionSeq: 41)]), [])
    }

    /// Runtime checks let this regression fail against the old non-persistable
    /// types rather than failing to compile before Codable is implemented.
    private func roundTrip<T>(_ value: T) throws -> T {
        let encodable = try XCTUnwrap(value as? any Encodable, "Attention must survive process exit")
        let type = try XCTUnwrap(T.self as? any Decodable.Type)
        let data = try JSONEncoder().encode(encodable)
        return try XCTUnwrap(JSONDecoder().decode(type, from: data) as? T)
    }

    private func decodeDone(paneID: String) throws -> AgentInfo {
        try decodeAgent(paneID: paneID, status: "done")
    }

    private func decodeAgent(paneID: String, status: String, completionSeq: UInt64? = nil,
                             terminalID: String = "t") throws -> AgentInfo {
        let completion = completionSeq.map { ", \"completion_seq\": \($0)" } ?? ""
        let data = Data("""
            {
              "terminal_id": "\(terminalID)", "agent": "codex", "name": "codex",
              "agent_status": "\(status)", "workspace_id": "w1", "tab_id": "w1:t1",
              "pane_id": "\(paneID)", "focused": false, "revision": 0\(completion)
            }
            """.utf8)
        return try JSONDecoder().decode(AgentInfo.self, from: data)
    }
}
