import HerdrKit
import XCTest
@testable import herdrm

/// The history control belongs to the card being activated, independent of
/// the currently selected terminal and of the row's drag/select surface.
@MainActor
final class SidebarAgentHistoryUIUXTests: XCTestCase {
    func testPointerOpensClosesAndReopensHistoryForAnUnselectedClaudeCard() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        sidebar.selectFirstAgent()
        sidebar.scroll(.offset(520))
        let target = try XCTUnwrap(sidebar.model.visibleAgents.first { $0.agent.paneID == "pane-1" })
        XCTAssertNotEqual(sidebar.model.selectedPane, target.ref)
        let originalOffset = sidebar.scrollOffset
        let originalRow = try sidebar.paneRowFrame(target.title)

        try sidebar.clickAgentHistoryButton(for: target)
        XCTAssertEqual(sidebar.scrollOffset, originalOffset, accuracy: 1,
                       "Opening history from a sidebar card must not recenter the space")
        XCTAssertEqual(try sidebar.paneRowFrame(target.title).minY, originalRow.minY, accuracy: 1,
                       "The card's history button must remain under the pointer")

        XCTAssertEqual(sidebar.model.selectedPane, target.ref)
        XCTAssertTrue(sidebar.model.conversationHistory.isPresented, "the native row drag host must not intercept the history button")
        XCTAssertEqual(sidebar.model.conversationHistory.state, .unavailable("no_binding"))

        try sidebar.clickAgentHistoryButton(for: target)

        XCTAssertEqual(sidebar.model.selectedPane, target.ref)
        XCTAssertFalse(sidebar.model.conversationHistory.isPresented, "clicking the same card again closes its history")
        XCTAssertEqual(sidebar.model.conversationHistory.state, .unavailable("no_binding"))

        try sidebar.clickAgentHistoryButton(for: target)

        XCTAssertEqual(sidebar.model.selectedPane, target.ref)
        XCTAssertTrue(sidebar.model.conversationHistory.isPresented, "the same control can reopen its history")
        XCTAssertEqual(sidebar.model.conversationHistory.state, .unavailable("no_binding"))
    }

    func testPointerSwitchesAnOpenDrawerToAnotherClaudeCard() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        sidebar.selectFirstAgent()
        sidebar.scroll(.offset(520))
        let first = try XCTUnwrap(sidebar.model.visibleAgents.first { $0.agent.paneID == "pane-1" })
        let second = try XCTUnwrap(sidebar.model.visibleAgents.first { $0.agent.paneID == "pane-2" })

        try sidebar.clickAgentHistoryButton(for: first)
        XCTAssertEqual(sidebar.model.selectedPane, first.ref)
        XCTAssertTrue(sidebar.model.conversationHistory.isPresented)

        // The first click above proves a real pointer reaches the button past the
        // row's drag host. Switching the open drawer to another card is a
        // selection behavior; drive it through the button's AX action so the
        // assertion doesn't hinge on headless-CI pointer coordinates landing on a
        // card whose button sits beside an already-open drawer.
        try sidebar.pressAgentHistoryButton(for: second)

        XCTAssertEqual(sidebar.model.selectedPane, second.ref)
        XCTAssertTrue(sidebar.model.conversationHistory.isPresented, "another card opens its own history rather than closing the old drawer")
        XCTAssertEqual(sidebar.model.conversationHistory.state, .unavailable("no_binding"))
    }

    func testVoiceOverOpensTheExactClaudeCodeCardWithoutABinding() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, agentKinds: ["claude", "claude-code", "codex"])
        sidebar.selectFirstAgent()
        let target = try XCTUnwrap(sidebar.model.visibleAgents.first { $0.agent.paneID == "pane-1" })
        let ids = sidebar.agentHistoryButtons.compactMap(\.identifier)
        XCTAssertEqual(Set(ids).count, ids.count, "each agent's history control has a unique identifier")
        XCTAssertTrue(sidebar.agentHistoryButtons.allSatisfy { $0.name == String(localized: "Read full conversation") })

        try sidebar.pressAgentHistoryButton(for: target)

        XCTAssertEqual(sidebar.model.selectedPane, target.ref)
        XCTAssertTrue(sidebar.model.conversationHistory.isPresented)
        XCTAssertEqual(sidebar.model.conversationHistory.state, .unavailable("no_binding"))

        try sidebar.pressAgentHistoryButton(for: target)

        XCTAssertEqual(sidebar.model.selectedPane, target.ref)
        XCTAssertFalse(sidebar.model.conversationHistory.isPresented, "VoiceOver repeats the same toggle action as a pointer click")
    }

    func testOtherAgentsHaveNoHistoryControlAndCannotOpenHistory() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, terminals: 2, agentKinds: ["claude", "codex", "shell"])
        sidebar.selectFirstAgent()
        let selected = sidebar.model.selectedPane
        let other = try XCTUnwrap(sidebar.model.visibleAgents.first { $0.agent.paneID == "pane-1" })
        let shell = try XCTUnwrap(sidebar.model.visibleAgents.first { $0.agent.paneID == "pane-2" })
        let ids = Set(sidebar.agentHistoryButtons.compactMap(\.identifier))
        XCTAssertFalse(ids.contains("sidebar.agent.history.\(other.id)"))
        XCTAssertFalse(ids.contains("sidebar.agent.history.\(shell.id)"))

        sidebar.model.toggleConversationHistory(for: other.ref)
        XCTAssertEqual(sidebar.model.selectedPane, selected)
        XCTAssertFalse(sidebar.model.conversationHistory.isPresented)
        let stale = PaneRef(deviceID: other.device.id, paneID: "removed-pane")
        sidebar.model.toggleConversationHistory(for: stale)
        XCTAssertEqual(sidebar.model.selectedPane, selected)
        XCTAssertFalse(sidebar.model.conversationHistory.isPresented)

        sidebar.model.toggleConversationHistory(for: try XCTUnwrap(selected))
        XCTAssertTrue(sidebar.model.conversationHistory.isPresented)
        sidebar.model.toggleConversationHistory(for: other.ref)
        sidebar.model.toggleConversationHistory(for: stale)
        XCTAssertEqual(sidebar.model.selectedPane, selected)
        XCTAssertTrue(sidebar.model.conversationHistory.isPresented, "invalid targets must not close another agent's open history")
    }

    func testHistoryControlPreservesTaggedAndUntaggedCardHeights() throws {
        let variants: [[String: String]?] = [nil, ["claude_usage": "5h 7% 3h21m · 7d 2% 6d18h"]]
        for tokens in variants {
            let claude = try SidebarHarness(spaces: 14, agents: 20, agentTokens: tokens)
            let other = try SidebarHarness(spaces: 14, agents: 20, agentTokens: tokens, agentKinds: Array(repeating: "codex", count: 20))
            XCTAssertEqual(claude.listHeight, other.listHeight, accuracy: 1, "a footer overlay must not add a row")
            XCTAssertEqual(claude.listWidth, other.listWidth, accuracy: 1)
        }
    }
}
