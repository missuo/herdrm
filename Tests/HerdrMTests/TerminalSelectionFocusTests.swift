import AppKit
import XCTest
@testable import herdrm

@MainActor
final class TerminalSelectionFocusTests: XCTestCase {
    private var harness: SidebarHarness!
    private var ids: [String] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        harness = try SidebarHarness(spaces: 1, agents: 3, pinnedHeaders: false)
        ids = harness.model.visibleAgents.map { AppModel.AttachedEntry.agent($0).id }
    }

    override func tearDown() {
        ids.forEach { AttachViewRegistry.unregister($0) }
        harness = nil
        super.tearDown()
    }

    private func openFirstAgent() -> LineBreakTerminalView {
        harness.selectFirstAgent()
        let old = LineBreakTerminalView(frame: .zero)
        AttachViewRegistry.register(old, for: ids[0])
        harness.mountTerminal(old, focus: true)
        return old
    }

    func testFirstOpenReleasesPreviousTerminalDuringTheSidebarClick() throws {
        let old = openFirstAgent()
        XCTAssertTrue(harness.terminalFirstResponder === old)
        try harness.clickAgentTitleWithoutSettling("Agent 2")
        XCTAssertEqual(harness.model.selectedAttachedEntry?.id, ids[1])
        XCTAssertFalse(harness.terminalFirstResponder === old,
                       "Typing while the new view mounts must not reach the previous agent")
    }

    func testFirstOpenFocusesTheSelectedViewWhenItRegisters() async throws {
        _ = openFirstAgent()
        try harness.clickAgentTitleWithoutSettling("Agent 2")
        let next = LineBreakTerminalView(frame: .zero)
        AttachViewRegistry.register(next, for: ids[1])
        harness.mountTerminal(next)
        await harness.settleTerminalFocus()
        XCTAssertTrue(harness.terminalFirstResponder === next)
    }

    func testLateUnselectedViewCannotTakeFocus() async throws {
        _ = openFirstAgent()
        try harness.clickAgentTitleWithoutSettling("Agent 2")
        try harness.clickAgentTitleWithoutSettling("Agent 3")
        let selected = LineBreakTerminalView(frame: .zero)
        AttachViewRegistry.register(selected, for: ids[2])
        harness.mountTerminal(selected)
        let late = LineBreakTerminalView(frame: .zero)
        AttachViewRegistry.register(late, for: ids[1])
        harness.mountTerminal(late)
        await harness.settleTerminalFocus()
        XCTAssertTrue(harness.terminalFirstResponder === selected)
    }
}
