import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

@MainActor
final class AgentUnreadUIUXTests: XCTestCase {
    func testRecoveryStatusesRenderTheExistingUnreadDot() throws {
        func bluePixels(_ status: AgentStatus, unread: Bool) throws -> Int {
            let renderer = ImageRenderer(content: AgentStatusGlyph(status: status, unreadDone: unread)
                .frame(width: 24, height: 24).background(Color.black))
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.blueComponent > color.redComponent + 0.2 { count += 1 }
                }
            }
            return count
        }
        let done = try bluePixels(.done, unread: true)
        XCTAssertGreaterThan(done, 0, "A real completed result supplies the visible-dot baseline")
        for status in [AgentStatus.idle, .unknown] {
            XCTAssertEqual(try bluePixels(status, unread: true), done)
            XCTAssertEqual(try bluePixels(status, unread: false), 0)
        }
    }

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

    func testRecoveryStatusEventsKeepUnreadVisibleAndPersistedUntilOpened() throws {
        let suite = "AgentUnreadUIUXTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false,
                                         attentionDefaults: defaults)
        let model = sidebar.model
        let entry = try XCTUnwrap(model.visibleAgents.first)
        let space = try XCTUnwrap(model.visibleSpaces.first)
        let deviceID = entry.device.id
        let working = entry.agent.updatingStatus(.working)
        model.sessions[deviceID]?.agents = [working]
        model.updateSnapshotAttention(agents: [working], deviceID: deviceID)
        var done = working.updatingStatus(.done)
        done.completionSeq = 41
        model.sessions[deviceID]?.agents = [done]
        XCTAssertEqual(model.updateSnapshotAttention(agents: [done], deviceID: deviceID), [done.paneID])

        // Manifest reloads/reconnects send status events before the authoritative
        // snapshot. An idle event has no sequence and cannot acknowledge 41.
        for status in ["idle", "unknown"] {
            let event = HerdrEvent(kind: HerdrEvent.agentStatusChangedKind, payload: .object([
                "data": .object(["pane_id": .string(done.paneID), "agent_status": .string(status)])
            ]))
            XCTAssertTrue(model.applyAgentStatusEvent(event, deviceID: deviceID))
            XCTAssertNil(model.session(deviceID).agents.first?.completionSeq)
            XCTAssertTrue(model.isUnread(entry), "A sequence-less status event did not read the result")
            XCTAssertTrue(AppModel(attentionDefaults: defaults).isUnread(entry),
                          "A relaunch during recovery must retain the result")
            XCTAssertEqual(model.attention(in: space), .unreadDone)
            sidebar.settleSidebar()
            XCTAssertTrue(sidebar.actionRowNames().contains("Agent 1, Unread"),
                          "The recovering Agent still exposes its unread badge")
        }
        let screenshot = FileManager.default.temporaryDirectory.appendingPathComponent("unread-recovery-demo.png")
        try sidebar.writeSnapshot(to: screenshot)
        let attachment = XCTAttachment(contentsOfFile: screenshot)
        attachment.name = "Unread result during recovery (fake Agent 1 and Space 1)"
        attachment.lifetime = .keepAlways
        add(attachment)

        var recovering = done.updatingStatus(.idle)
        recovering.completionSeq = nil
        model.sessions[deviceID]?.agents = [recovering]
        XCTAssertTrue(model.updateSnapshotAttention(agents: [recovering], deviceID: deviceID).isEmpty)
        XCTAssertTrue(model.isUnread(entry))
        model.sessions[deviceID]?.agents = [done]
        XCTAssertTrue(model.updateSnapshotAttention(agents: [done], deviceID: deviceID).isEmpty,
                      "Restoring the same result must not produce another notification")
        sidebar.settleSidebar()
        try sidebar.clickAgentTitleWithoutSettling("Agent 1")
        XCTAssertFalse(model.isUnread(entry))
        XCTAssertFalse(AppModel(attentionDefaults: defaults).isUnread(entry))
        sidebar.settleSidebar()
        XCTAssertFalse(sidebar.actionRowNames().contains("Agent 1, Unread"))

        done.completionSeq = 42
        model.sessions[deviceID]?.agents = [done]
        XCTAssertEqual(model.updateSnapshotAttention(agents: [done], deviceID: deviceID), [done.paneID])
        XCTAssertTrue(model.isUnread(entry))
        let serverRead = done.updatingStatus(.idle)
        model.sessions[deviceID]?.agents = [serverRead]
        model.updateSnapshotAttention(agents: [serverRead], deviceID: deviceID)
        XCTAssertFalse(model.isUnread(entry), "An actual idle snapshot with a sequence still acknowledges it")
        XCTAssertEqual(model.attention(in: space), .none)
        XCTAssertFalse(AppModel(attentionDefaults: defaults).isUnread(entry))
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

    func testRelaunchRestoresOnlyUnreadResultsAndClicksPersistAcknowledgement() throws {
        let suite = "AgentUnreadUIUXTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var first: SidebarHarness? = try SidebarHarness(spaces: 1, agents: 2, pinnedHeaders: false,
                                                       attentionDefaults: defaults)
        let firstModel = try XCTUnwrap(first?.model)
        let entries = firstModel.visibleAgents
        let deviceID = try XCTUnwrap(entries.first).device.id
        let working = entries.map { $0.agent.updatingStatus(.working) }
        firstModel.sessions[deviceID]?.agents = working
        firstModel.updateSnapshotAttention(agents: working, deviceID: deviceID)
        let done = working.map { original in
            var agent = original.updatingStatus(.done)
            agent.completionSeq = 41
            return agent
        }
        firstModel.sessions[deviceID]?.agents = done
        XCTAssertEqual(firstModel.updateSnapshotAttention(agents: done, deviceID: deviceID), Set(done.map(\.paneID)))
        try first?.clickAgentTitleWithoutSettling("Agent 1")
        XCTAssertFalse(firstModel.isUnread(entries[0]))
        XCTAssertTrue(firstModel.isUnread(entries[1]))
        first = nil

        // A new real AppModel loads the same persisted state through the harness.
        let reopened = try SidebarHarness(spaces: 1, agents: 2, pinnedHeaders: false, attentionDefaults: defaults)
        let model = reopened.model
        model.sessions[deviceID]?.agents = done
        XCTAssertFalse(model.isUnread(entries[0]), "Reading A before quitting remains acknowledged")
        XCTAssertTrue(model.isUnread(entries[1]), "Unopened B must still show its blue dot")
        XCTAssertTrue(model.updateSnapshotAttention(agents: done, deviceID: deviceID).isEmpty,
                      "Restoring B's dot must not replay its completion notification")
        let recovering = done.map { original in
            var agent = original.updatingStatus(.idle)
            agent.completionSeq = nil
            return agent
        }
        model.updateSnapshotAttention(agents: recovering, deviceID: deviceID)
        XCTAssertTrue(model.isUnread(entries[1]), "A reconnect classification gap does not read B")
        XCTAssertTrue(model.updateSnapshotAttention(agents: done, deviceID: deviceID).isEmpty)
        reopened.settleSidebar()
        try reopened.clickAgentTitleWithoutSettling("Agent 2")
        XCTAssertFalse(model.isUnread(entries[1]))

        let afterReading = AppModel(attentionDefaults: defaults)
        XCTAssertTrue(afterReading.unreadAgents.isEmpty, "Reading B also survives the next launch")
        XCTAssertTrue(afterReading.updateSnapshotAttention(agents: done, deviceID: deviceID).isEmpty)
        var offlineResult = done
        offlineResult[1].completionSeq = 42
        XCTAssertEqual(afterReading.updateSnapshotAttention(agents: offlineResult, deviceID: deviceID), [done[1].paneID])
        XCTAssertTrue(afterReading.isUnread(entries[1]), "A genuinely newer result completed while closed is unread")
        XCTAssertTrue(afterReading.updateSnapshotAttention(agents: offlineResult, deviceID: deviceID).isEmpty)
    }

    func testRestoredUnreadDoesNotTransferToAReplacementTerminal() throws {
        let suite = "AgentUnreadUIUXTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false, attentionDefaults: defaults)
        let model = sidebar.model
        let entry = try XCTUnwrap(model.visibleAgents.first)
        let deviceID = entry.device.id
        let working = entry.agent.updatingStatus(.working)
        model.updateSnapshotAttention(agents: [working], deviceID: deviceID)
        var done = working.updatingStatus(.done)
        done.completionSeq = 41
        model.updateSnapshotAttention(agents: [done], deviceID: deviceID)
        XCTAssertTrue(model.isUnread(entry))

        let relaunched = AppModel(attentionDefaults: defaults)
        XCTAssertTrue(relaunched.isUnread(entry))
        let replacement = try JSONDecoder().decode(AgentInfo.self, from: JSONSerialization.data(withJSONObject: [
            "pane_id": done.paneID, "workspace_id": done.workspaceID, "tab_id": done.tabID,
            "terminal_id": "replacement", "agent": "codex",
            "agent_status": "done", "completion_seq": 41
        ]))
        XCTAssertTrue(relaunched.updateSnapshotAttention(agents: [replacement], deviceID: deviceID).isEmpty)
        XCTAssertFalse(relaunched.isUnread(entry), "A replacement terminal cannot inherit the former result's dot")
        XCTAssertTrue(AppModel(attentionDefaults: defaults).unreadAgents.isEmpty)
    }

    func testLegacyServerIdleStatusAfterReadingInTheTUIClearsTheDot() throws {
        let suite = "AgentUnreadUIUXTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false, attentionDefaults: defaults)
        let model = sidebar.model
        let entry = try XCTUnwrap(model.visibleAgents.first)
        let deviceID = entry.device.id
        // Protocol 17-21 servers never send completion_seq.
        for status in [AgentStatus.working, .done] {
            let agent = entry.agent.updatingStatus(status)
            model.sessions[deviceID]?.agents = [agent]
            model.updateSnapshotAttention(agents: [agent], deviceID: deviceID)
        }
        XCTAssertTrue(model.isUnread(entry))
        // The user reads the result in the herdr TUI; the server reports idle.
        let event = HerdrEvent(kind: HerdrEvent.agentStatusChangedKind, payload: .object([
            "data": .object(["pane_id": .string(entry.agent.paneID), "agent_status": .string("idle")])
        ]))
        XCTAssertTrue(model.applyAgentStatusEvent(event, deviceID: deviceID))
        XCTAssertFalse(model.isUnread(entry), "Idle is the legacy server's read state")
        XCTAssertFalse(AppModel(attentionDefaults: defaults).isUnread(entry),
                       "The cleared dot is not restored on the next launch")
        sidebar.settleSidebar()
        XCTAssertFalse(sidebar.actionRowNames().contains("Agent 1, Unread"))
    }

    func testOpeningASpaceLandsOnAnUnreadResultDuringRecovery() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 2, pinnedHeaders: false)
        let model = sidebar.model
        let entries = model.visibleAgents
        XCTAssertEqual(entries.count, 2)
        let deviceID = entries[0].device.id
        let working = entries.map { $0.agent.updatingStatus(.working) }
        model.sessions[deviceID]?.agents = working
        model.updateSnapshotAttention(agents: working, deviceID: deviceID)
        var done = working[1].updatingStatus(.done)
        done.completionSeq = 41
        model.updateSnapshotAttention(agents: [working[0], done], deviceID: deviceID)
        var recovering = done.updatingStatus(.idle)
        recovering.completionSeq = nil
        let agents = [working[0], recovering]
        model.sessions[deviceID]?.agents = agents
        model.updateSnapshotAttention(agents: agents, deviceID: deviceID)
        XCTAssertTrue(model.isUnread(entries[1]))

        model.selectedPane = nil
        sidebar.settleSidebar()
        try sidebar.clickSpaceTitle("Space 1")
        XCTAssertEqual(model.selectedPane, entries[1].ref,
                       "An unread result showing its dot while idle outranks a working agent")
    }

    func testRemovingADeviceForgetsItsSavedAttention() throws {
        let fixture = try AttentionFixture()
        let remote = Device(name: "test1", kind: .ssh(target: "test1@test.invalid"))
        let model = fixture.model()
        model.devices = [.local, remote]
        try seedUnread(model, deviceID: remote.id)
        XCTAssertEqual(AgentAttentionState.load(from: fixture.defaults).unread.map(\.deviceID), [remote.id])

        model.removeDevice(remote)
        XCTAssertTrue(model.unreadAgents.isEmpty)
        XCTAssertEqual(AgentAttentionState.load(from: fixture.defaults), AgentAttentionState(),
                       "A removed device leaves no badge or completion history behind")
    }

    func testChangingAConnectionTargetForgetsSavedAttention() throws {
        let fixture = try AttentionFixture()
        let remote = Device(name: "test1", kind: .ssh(target: "test1@test.invalid"))
        let model = fixture.model()
        model.devices = [.local, remote]
        defer { model.removeDevice(remote) }
        try seedUnread(model, deviceID: remote.id)

        model.updateDevice(remote.id, name: "test1", sshTarget: "test1@test.invalid")
        XCTAssertEqual(model.unreadAgents.map(\.deviceID), [remote.id], "A rename keeps the device's results")
        model.updateDevice(remote.id, name: "test1", sshTarget: "test2@test.invalid")
        XCTAssertTrue(model.unreadAgents.isEmpty)
        XCTAssertEqual(AgentAttentionState.load(from: fixture.defaults), AgentAttentionState(),
                       "Another host's panes cannot inherit the old host's results")
    }

    func testChangingTheRemoteSessionForgetsSavedAttentionAndPersists() throws {
        let fixture = try AttentionFixture()
        let remote = Device(name: "test1", kind: .ssh(target: "test1@test.invalid"))
        let model = fixture.model()
        model.devices = [.local, remote]
        defer { model.removeDevice(remote) }
        try seedUnread(model, deviceID: remote.id)

        model.updateDevice(remote.id, name: "renamed", sshTarget: "test1@test.invalid", sessionName: "default")
        XCTAssertEqual(model.unreadAgents.map(\.deviceID), [remote.id],
                       "\"default\" is the session the device already talks to")
        model.updateDevice(remote.id, name: "renamed", sshTarget: "test1@test.invalid", sessionName: " work ")
        XCTAssertTrue(model.unreadAgents.isEmpty, "Another session's panes cannot inherit these results")
        XCTAssertEqual(model.device(remote.id)?.sessionName, "work")
        XCTAssertEqual(model.device(remote.id)?.sshTarget, "test1@test.invalid")
        let saved = DeviceStore(directory: fixture.directory).load().first { $0.id == remote.id }
        XCTAssertEqual(saved?.sessionName, "work", "The session survives relaunch")
    }

    func testUnchangedSnapshotsDoNotWritePreferencesAgain() throws {
        let fixture = try AttentionFixture(counting: true)
        let defaults = try XCTUnwrap(fixture.defaults as? CountingDefaults)
        let model = fixture.model()
        let done = try seedUnread(model, deviceID: Device.local.id)
        let writes = defaults.attentionWrites
        XCTAssertGreaterThan(writes, 0)
        for _ in 0..<3 {
            XCTAssertTrue(model.updateSnapshotAttention(agents: [done], deviceID: Device.local.id).isEmpty)
        }
        XCTAssertEqual(defaults.attentionWrites, writes, "Polling the same snapshot must not rewrite preferences")
        model.updateSnapshotAttention(agents: [done.updatingStatus(.working)], deviceID: Device.local.id)
        XCTAssertEqual(defaults.attentionWrites, writes + 1, "A real change is still saved")
    }

    func testDiscoveryPrunesAttentionOfDevicesThatNoLongerExist() throws {
        let fixture = try AttentionFixture()
        let config = fixture.directory.appendingPathComponent("config", isDirectory: true)
        let sessionDir = config.appendingPathComponent("sessions/test1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let socket = sessionDir.appendingPathComponent("herdr.sock")
        XCTAssertTrue(FileManager.default.createFile(atPath: socket.path, contents: nil))
        let named = try XCTUnwrap(HerdrSessionDiscovery.namedSessions(configDirectory: config)
            .map(HerdrSessionDiscovery.device(for:)).first)
        let removed = UUID()
        let keys = [Device.local.id, named.id, removed].map { AgentUnreadKey(deviceID: $0, paneID: "w1:p1") }
        AgentAttentionState(unread: Set(keys), trackers: Dictionary(uniqueKeysWithValues: keys.map {
            ($0.deviceID, AgentCompletionTracker())
        })).save(to: fixture.defaults)

        let model = fixture.model()
        XCTAssertEqual(model.unreadAgents, Set(keys),
                       "Named sessions are not known at launch, so nothing is pruned before discovery")
        model.refreshNamedSessions(configDirectory: config)
        let kept = Set(keys.prefix(2))
        XCTAssertEqual(model.unreadAgents, kept, "Discovery drops devices that no longer exist")
        XCTAssertEqual(AgentAttentionState.load(from: fixture.defaults).unread, kept)
        XCTAssertEqual(Set(AgentAttentionState.load(from: fixture.defaults).trackers.keys), Set(kept.map(\.deviceID)))

        try FileManager.default.removeItem(at: socket)
        model.refreshNamedSessions(configDirectory: config)
        XCTAssertEqual(model.unreadAgents, [keys[0]], "A session that went away takes its results with it")
    }

    @discardableResult
    private func seedUnread(_ model: AppModel, deviceID: UUID) throws -> AgentInfo {
        let working = try JSONDecoder().decode(AgentInfo.self, from: JSONSerialization.data(withJSONObject: [
            "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "terminal_id": "t1",
            "agent": "codex", "agent_status": "working"
        ]))
        model.updateSnapshotAttention(agents: [working], deviceID: deviceID)
        var done = working.updatingStatus(.done)
        done.completionSeq = 41
        XCTAssertEqual(model.updateSnapshotAttention(agents: [done], deviceID: deviceID), [done.paneID])
        XCTAssertEqual(model.unreadAgents, [AgentUnreadKey(deviceID: deviceID, paneID: done.paneID)])
        return done
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

/// Isolated preferences and device list, so attention tests never touch the
/// user's real `devices.json` or defaults.
@MainActor
private final class AttentionFixture {
    let directory: URL
    let defaults: UserDefaults
    private let suite = "AgentUnreadUIUXTests.\(UUID().uuidString)"

    init(counting: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentUnreadUIUXTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(counting ? CountingDefaults(suiteName: suite) : UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func model() -> AppModel {
        AppModel(attentionDefaults: defaults, deviceStore: DeviceStore(directory: directory))
    }
}

private final class CountingDefaults: UserDefaults {
    private(set) var attentionWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == AgentAttentionState.defaultsKey { attentionWrites += 1 }
        super.set(value, forKey: defaultName)
    }
}
