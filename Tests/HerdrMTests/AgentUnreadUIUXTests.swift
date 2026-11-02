import AppKit
import HerdrKit
import XCTest
@testable import herdrm

@MainActor
final class AgentUnreadUIUXTests: XCTestCase {
    func testOpenedCompletionStaysReadAfterReconnectRebuildsItsObservation() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let model = sidebar.model
        let entry = try XCTUnwrap(model.visibleAgents.first)
        let deviceID = entry.device.id
        let working = entry.agent.updatingStatus(.working)
        model.sessions[deviceID]?.agents = [working]
        model.updateSnapshotAttention(agents: [working], deviceID: deviceID)
        var done = working.updatingStatus(.done)
        done.completionSeq = 41
        model.sessions[deviceID]?.agents = [done]
        XCTAssertEqual(model.updateSnapshotAttention(agents: [done], deviceID: deviceID), [done.paneID])
        XCTAssertTrue(model.isUnread(entry))

        try sidebar.clickAgentTitleWithoutSettling(entry.title)
        XCTAssertFalse(model.isUnread(entry))

        model.updateSnapshotAttention(agents: [], deviceID: deviceID)
        var recovering = done.updatingStatus(.unknown)
        recovering.completionSeq = nil
        model.updateSnapshotAttention(agents: [recovering], deviceID: deviceID)
        XCTAssertTrue(model.updateSnapshotAttention(agents: [done], deviceID: deviceID).isEmpty)
        XCTAssertFalse(model.isUnread(entry), "Rebuilt observations must retain the user's acknowledgement")

        done.completionSeq = 42
        XCTAssertEqual(model.updateSnapshotAttention(agents: [done], deviceID: deviceID), [done.paneID])
        XCTAssertTrue(model.isUnread(entry), "A new result still needs to be read")
        XCTAssertTrue(model.updateSnapshotAttention(agents: [done], deviceID: deviceID).isEmpty)
    }

    func testVisibleCompletionAcknowledgesTheIncomingSnapshotBeforeSessionAssignment() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let model = sidebar.model
        let entry = try XCTUnwrap(model.visibleAgents.first)
        let deviceID = entry.device.id
        var working = entry.agent.updatingStatus(.working)
        working.completionSeq = 40
        model.sessions[deviceID]?.agents = [working]
        model.updateSnapshotAttention(agents: [working], deviceID: deviceID)
        model.selectAgent(entry.ref)
        let id = AppModel.AttachedEntry.agent(entry).id
        let terminal = LineBreakTerminalView(frame: .zero)
        AttachViewRegistry.register(terminal, for: id)
        defer { AttachViewRegistry.unregister(id) }
        sidebar.mountTerminal(terminal, focus: true)
        sidebar.activateWindow()
        XCTAssertTrue(NSApp.isActive && terminal.window?.isKeyWindow == true)

        var done = working.updatingStatus(.done)
        done.completionSeq = 41
        // refresh confirms attention before replacing sessions[deviceID].agents.
        XCTAssertEqual(model.updateSnapshotAttention(agents: [done], deviceID: deviceID), [done.paneID])
        XCTAssertEqual(model.session(deviceID).agents.first?.completionSeq, 40)
        XCTAssertFalse(model.isUnread(entry), "The visible result is immediately acknowledged")
        model.sessions[deviceID]?.agents = [done]

        model.detailMode = .files
        model.updateSnapshotAttention(agents: [], deviceID: deviceID)
        var recovering = done.updatingStatus(.unknown)
        recovering.completionSeq = nil
        model.updateSnapshotAttention(agents: [recovering], deviceID: deviceID)
        XCTAssertTrue(model.updateSnapshotAttention(agents: [done], deviceID: deviceID).isEmpty,
                      "Automatic acknowledgement records sequence 41, not the stale session's 40")
        XCTAssertFalse(model.isUnread(entry))

        done.completionSeq = 42
        XCTAssertEqual(model.updateSnapshotAttention(agents: [done], deviceID: deviceID), [done.paneID])
        XCTAssertTrue(model.isUnread(entry), "A newer result covered by Files remains unread")
    }

    func testReconnectDoesNotReplayOldCompletionsButKeepsAnOfflineCompletion() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 24, pinnedHeaders: false)
        let model = sidebar.model
        let deviceID = try XCTUnwrap(model.visibleAgents.first).device.id
        let completed = model.session(deviceID).agents.enumerated().map { index, original in
            var agent = original.updatingStatus(.done)
            agent.completionSeq = UInt64(100 + index)
            return agent
        }
        model.sessions[deviceID]?.agents = completed
        XCTAssertTrue(model.updateSnapshotAttention(agents: completed, deviceID: deviceID).isEmpty)

        let recovering = completed.enumerated().map { index, original in
            var agent = original.updatingStatus(index.isMultiple(of: 2) ? .idle : .unknown)
            agent.completionSeq = nil
            return agent
        }
        model.updateSnapshotAttention(agents: recovering, deviceID: deviceID)
        XCTAssertTrue(model.updateSnapshotAttention(agents: completed, deviceID: deviceID).isEmpty)
        XCTAssertTrue(model.visibleAgents.allSatisfy { !model.isUnread($0) })

        // A turn that starts AND finishes while disconnected must still notify,
        // even when the displayed status is done on both sides of the gap.
        var offlineResult = completed
        offlineResult[0].completionSeq = 200
        model.sessions[deviceID]?.agents = offlineResult
        XCTAssertEqual(model.updateSnapshotAttention(agents: offlineResult, deviceID: deviceID),
                       [offlineResult[0].paneID])
        let entry = try XCTUnwrap(model.visibleAgents.first { $0.agent.paneID == offlineResult[0].paneID })
        XCTAssertTrue(model.isUnread(entry))
        try sidebar.clickAgentTitleWithoutSettling(entry.title)
        XCTAssertEqual(model.selectedPane, entry.ref)
        XCTAssertFalse(model.isUnread(entry))
        XCTAssertTrue(model.updateSnapshotAttention(agents: offlineResult, deviceID: deviceID).isEmpty)
        XCTAssertFalse(model.isUnread(entry), "Replaying the acknowledged completion must not restore the dot")
    }

    func testStatusEventWaitsForCompletionSnapshotAndDoesNotConsumeIt() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let model = sidebar.model
        let entry = try XCTUnwrap(model.visibleAgents.first)
        let deviceID = entry.device.id
        let working = entry.agent.updatingStatus(.working)
        model.sessions[deviceID]?.agents = [working]
        model.updateSnapshotAttention(agents: [working], deviceID: deviceID)
        let event = HerdrEvent(kind: HerdrEvent.agentStatusChangedKind, payload: .object([
            "data": .object(["pane_id": .string(working.paneID), "agent_status": .string("done")])
        ]))
        XCTAssertTrue(model.applyAgentStatusEvent(event, deviceID: deviceID))
        XCTAssertFalse(model.isUnread(entry), "Status events do not carry a completion sequence")
        var done = working.updatingStatus(.done)
        done.completionSeq = 1
        model.sessions[deviceID]?.agents = [done]
        XCTAssertEqual(model.updateSnapshotAttention(agents: [done], deviceID: deviceID), [done.paneID])
        XCTAssertTrue(model.isUnread(entry))
        XCTAssertTrue(model.updateSnapshotAttention(agents: [done], deviceID: deviceID).isEmpty)
    }

    func testLegacyActivityEventsStillProduceOneSnapshotCompletion() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let model = sidebar.model
        let entry = try XCTUnwrap(model.visibleAgents.first)
        let deviceID = entry.device.id
        let idle = entry.agent.updatingStatus(.idle)
        model.sessions[deviceID]?.agents = [idle]
        model.updateSnapshotAttention(agents: [idle], deviceID: deviceID)
        for status in ["working", "done"] {
            let event = HerdrEvent(kind: HerdrEvent.agentStatusChangedKind, payload: .object([
                "data": .object(["pane_id": .string(idle.paneID), "agent_status": .string(status)])
            ]))
            XCTAssertTrue(model.applyAgentStatusEvent(event, deviceID: deviceID))
        }
        XCTAssertFalse(model.isUnread(entry))
        let done = idle.updatingStatus(.done)
        XCTAssertEqual(model.updateSnapshotAttention(agents: [done], deviceID: deviceID), [done.paneID])
        XCTAssertTrue(model.isUnread(entry))
        XCTAssertTrue(model.updateSnapshotAttention(agents: [done], deviceID: deviceID).isEmpty)
    }

    func testLegacyCompletionAfterUnknownShowsDotUntilOpened() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let model = sidebar.model
        let entry = try XCTUnwrap(model.visibleAgents.first)
        let deviceID = entry.device.id
        for status in [AgentStatus.working, .unknown, .done] {
            let agent = entry.agent.updatingStatus(status)
            model.sessions[deviceID]?.agents = [agent]
            model.updateSnapshotAttention(agents: [agent], deviceID: deviceID)
        }
        XCTAssertTrue(model.isUnread(entry), "Background completion must survive an unknown snapshot")
        try sidebar.clickAgentTitleWithoutSettling(entry.title)
        XCTAssertFalse(model.isUnread(entry))
        for status in [AgentStatus.unknown, .done] {
            let agent = entry.agent.updatingStatus(status)
            model.sessions[deviceID]?.agents = [agent]
            model.updateSnapshotAttention(agents: [agent], deviceID: deviceID)
        }
        XCTAssertFalse(model.isUnread(entry), "Reading the result must survive status recovery")
    }

    func testOpeningAnotherAgentFromFilesDoesNotReadTheCoveredAgent() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 2, pinnedHeaders: false)
        let entries = sidebar.model.visibleAgents
        sidebar.model.selectAgent(entries[0].ref)
        let id = AppModel.AttachedEntry.agent(entries[0]).id
        let terminal = LineBreakTerminalView(frame: .zero)
        AttachViewRegistry.register(terminal, for: id)
        defer { AttachViewRegistry.unregister(id) }
        sidebar.mountTerminal(terminal, focus: true)
        sidebar.activateWindow()
        sidebar.model.detailMode = .files
        finish(entries[0], in: sidebar.model)
        finish(entries[1], in: sidebar.model)

        try sidebar.clickAgentTitleWithoutSettling("Agent 2")

        XCTAssertTrue(sidebar.model.isUnread(entries[0]), "The covered result was never opened")
        XCTAssertFalse(sidebar.model.isUnread(entries[1]))

        // Returning to a standalone shell must not briefly read the covered agent either.
        sidebar.model.detailMode = .files
        sidebar.model.selectedPane = entries[0].ref
        sidebar.model.newShellSession(on: entries[0].device)
        XCTAssertTrue(sidebar.model.isUnread(entries[0]))
    }

    func testAutomaticSelectionWhileFilesCoverTerminalKeepsResultUnread() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 2, pinnedHeaders: false)
        let entries = sidebar.model.visibleAgents
        sidebar.model.selectAgent(entries[0].ref)
        sidebar.model.detailMode = .files
        finish(entries[1], in: sidebar.model)

        // A refresh can replace a pane closed in another client while Files is open.
        sidebar.model.selectedPane = entries[1].ref

        XCTAssertTrue(sidebar.model.isUnread(entries[1]), "Automatic selection did not reveal the result")
        try sidebar.clickAgentTitleWithoutSettling("Agent 2")
        XCTAssertFalse(sidebar.model.isUnread(entries[1]), "Opening the result still acknowledges it")
    }

    func testOpeningUnreadAgentClearsOnlyItsDot() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 2, pinnedHeaders: false)
        let entries = sidebar.model.visibleAgents
        finish(entries[0], in: sidebar.model)
        finish(entries[1], in: sidebar.model)
        XCTAssertTrue(sidebar.model.isUnread(entries[0]))
        XCTAssertTrue(sidebar.model.isUnread(entries[1]))
        try sidebar.clickAgentTitleWithoutSettling("Agent 1")
        XCTAssertFalse(sidebar.model.isUnread(entries[0]))
        XCTAssertTrue(sidebar.model.isUnread(entries[1]), "Opening one agent must not read the other")
    }

    func testClickingAlreadySelectedAgentAcknowledgesItsResult() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let entry = try XCTUnwrap(sidebar.model.visibleAgents.first)
        sidebar.model.selectAgent(entry.ref)
        finish(entry, in: sidebar.model)
        XCTAssertTrue(sidebar.model.isUnread(entry))
        try sidebar.clickAgentTitleWithoutSettling("Agent 1")
        XCTAssertFalse(sidebar.model.isUnread(entry))
    }

    func testClickingCurrentSpaceAcknowledgesShownAgent() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let entry = try XCTUnwrap(sidebar.model.visibleAgents.first)
        sidebar.model.selectAgent(entry.ref)
        finish(entry, in: sidebar.model)
        XCTAssertTrue(sidebar.model.isUnread(entry))
        try sidebar.clickSpaceTitle("Space 1")
        XCTAssertFalse(sidebar.model.isUnread(entry))
        XCTAssertEqual(sidebar.model.attention(in: try XCTUnwrap(sidebar.model.visibleSpaces.first)), .none)
    }

    func testVisibleCompletionIsReadButCoveredCompletionStaysUnread() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let entry = try XCTUnwrap(sidebar.model.visibleAgents.first)
        sidebar.model.selectAgent(entry.ref)
        let id = AppModel.AttachedEntry.agent(entry).id
        let terminal = LineBreakTerminalView(frame: .zero)
        AttachViewRegistry.register(terminal, for: id)
        defer { AttachViewRegistry.unregister(id) }
        sidebar.mountTerminal(terminal, focus: true)
        sidebar.activateWindow()
        XCTAssertTrue(NSApp.isActive && terminal.window?.isKeyWindow == true,
                      "Active app: \(NSApp.isActive), key terminal: \(terminal.window?.isKeyWindow.description ?? "no window")")
        finish(entry, in: sidebar.model)
        XCTAssertFalse(sidebar.model.isUnread(entry))
        sidebar.model.detailMode = .files
        finish(entry, in: sidebar.model)
        XCTAssertTrue(sidebar.model.isUnread(entry), "A file view covers the result")
        sidebar.model.detailMode = .terminal
        XCTAssertFalse(sidebar.model.isUnread(entry))
    }

    private func finish(_ entry: AppModel.AgentEntry, in model: AppModel) {
        let deviceID = entry.device.id
        let agents = model.session(deviceID).agents
        var previous = Dictionary(uniqueKeysWithValues: agents.map { ($0.paneID, $0.status) })
        previous[entry.agent.paneID] = .working
        let next = agents.map { $0.paneID == entry.agent.paneID ? $0.updatingStatus(.done) : $0 }
        model.sessions[deviceID]?.agents = next
        model.updateUnreadAgents(previous: previous, agents: next, deviceID: deviceID)
    }
}
