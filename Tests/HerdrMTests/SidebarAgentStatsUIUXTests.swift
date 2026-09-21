import Foundation
import XCTest
@testable import herdrm

/// Agent rows grow to show the plugin stats lines (grazr account, model,
/// context, usage) when the pane carries those tokens, and stay at their
/// original height when it does not.
@MainActor
final class SidebarAgentStatsUIUXTests: XCTestCase {
    private static let grazrTokens = [
        "grazr": "senad@example.com",
        "claude_model": "Fable 5.1 (1M context)",
        "claude_ctx": "context 47% · cache 99.8%",
        "claude_usage": "5h 7% 3h21m · 7d 2% 6d18h",
    ]

    func testTaggedAgentRowsAreTallerThanUntaggedOnes() throws {
        let plain = try SidebarHarness(spaces: 14, agents: 20)
        let tagged = try SidebarHarness(spaces: 14, agents: 20, agentTokens: Self.grazrTokens)
        let growth = tagged.listHeight - plain.listHeight
        // Four 11pt lines plus the 4pt VStack spacing each: roughly 15pt a line.
        XCTAssertGreaterThan(growth, 20 * 4 * 12, "twenty rows × four lines should add height")
        XCTAssertLessThan(growth, 20 * 4 * 20)

        if let dir = ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"] {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            // Past the 14 space rows so the Agents section is what's on screen.
            tagged.scroll(.offset(520))
            plain.scroll(.offset(520))
            try tagged.writeSnapshot(to: base.appendingPathComponent("sidebar-tagged.png"))
            try plain.writeSnapshot(to: base.appendingPathComponent("sidebar-plain.png"))
        }
    }

    func testAccountOnlyTokensAddASingleLine() throws {
        let plain = try SidebarHarness(spaces: 14, agents: 20)
        let tagged = try SidebarHarness(spaces: 14, agents: 20, agentTokens: ["grazr": "senad@example.com"])
        let growth = tagged.listHeight - plain.listHeight
        XCTAssertGreaterThan(growth, 20 * 12)
        XCTAssertLessThan(growth, 20 * 20)
    }
}
