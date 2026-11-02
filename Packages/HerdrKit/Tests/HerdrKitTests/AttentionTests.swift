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
