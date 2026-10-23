import AppKit
import HerdrKit
import XCTest
@testable import herdrm

@MainActor
final class AgentUnreadUIUXTests: XCTestCase {
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
