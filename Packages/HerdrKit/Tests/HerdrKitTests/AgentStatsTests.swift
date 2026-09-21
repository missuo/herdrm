import Foundation
import XCTest
@testable import HerdrKit

/// Sidebar stats lines derived from the pane `tokens` map that plugins such as
/// grazr (`grazr`, `claude_*`) and herdr-agent-quota (`quota_*`) publish.
final class AgentStatsTests: XCTestCase {
    func testTokensDecodeFromAgentList() throws {
        let agent = try decode("""
            {
              "terminal_id": "t", "agent": "claude", "agent_status": "idle",
              "workspace_id": "wC", "tab_id": "wC:t1", "pane_id": "wC:p1",
              "focused": true, "revision": 4, "cwd": "/home/deepdark/dev/imperum-v2",
              "tokens": {
                "grazr": "senad@example.com",
                "claude_model": "Fable 5.1 (1M context)",
                "claude_ctx": "context 47% · cache 99.8%",
                "claude_usage": "5h 7% 3h21m · 7d 2% 6d18h",
                "gap": "\\u200b"
              }
            }
            """)
        XCTAssertEqual(agent.tokens?["grazr"], "senad@example.com")
        XCTAssertEqual(agent.tokens?.count, 5)
    }

    func testMissingTokensDecodesAsNilAndYieldsNoLines() throws {
        let agent = try decode("""
            {
              "terminal_id": "t", "agent": "claude", "agent_status": "idle",
              "workspace_id": "w", "tab_id": "w:t", "pane_id": "w:p",
              "focused": false, "revision": 0
            }
            """)
        XCTAssertNil(agent.tokens)
        XCTAssertEqual(agent.statsLines, [])
    }

    func testGrazrTokensProduceAllFourLinesInOrder() {
        let lines = AgentStatsLine.lines(from: [
            "grazr": "senad@example.com",
            "claude_model": "Fable 5.1 (1M context)",
            "claude_ctx": "context 47% · cache 99.8%",
            "claude_usage": "5h 7% 3h21m · 7d 2% 6d18h",
            "gap": "\u{200b}",
        ])
        XCTAssertEqual(lines, [
            AgentStatsLine(kind: .account, text: "senad@example.com"),
            AgentStatsLine(kind: .model, text: "Fable 5.1 (1M context)"),
            AgentStatsLine(kind: .context, text: "context 47% · cache 99.8%"),
            AgentStatsLine(kind: .usage, text: "5h 7% 3h21m · 7d 2% 6d18h"),
        ])
    }

    func testAgentQuotaTokensAreTheFallbackForModelContextAndUsage() {
        let lines = AgentStatsLine.lines(from: [
            "grazr": "senad@example.com",
            "quota_model": "Fable 5.1",
            "quota_context": "context 42%",
            "quota_cache": "cache 99.1%",
            "quota_5h_warning": "5h 50% 3h57m",
            "quota_week_danger": "7d 89% 2d8h",
        ])
        XCTAssertEqual(lines, [
            AgentStatsLine(kind: .account, text: "senad@example.com"),
            AgentStatsLine(kind: .model, text: "Fable 5.1"),
            AgentStatsLine(kind: .context, text: "context 42% · cache 99.1%"),
            AgentStatsLine(kind: .usage, text: "5h 50% 3h57m · 7d 89% 2d8h"),
        ])
    }

    func testGrazrKeysWinOverQuotaKeysWhenBothPresent() {
        let lines = AgentStatsLine.lines(from: [
            "claude_model": "Fable 5.1 (1M context)",
            "quota_model": "Fable 5.1",
            "quota_5h_normal": "5h 99% 4h46m",
        ])
        XCTAssertEqual(lines, [
            AgentStatsLine(kind: .model, text: "Fable 5.1 (1M context)"),
            AgentStatsLine(kind: .usage, text: "5h 99% 4h46m"),
        ])
    }

    func testBlankAndWhitespaceValuesAreSkipped() {
        let lines = AgentStatsLine.lines(from: [
            "grazr": "   ",
            "claude_model": "",
            "quota_context": "context 10%",
            "quota_cache": " ",
        ])
        XCTAssertEqual(lines, [AgentStatsLine(kind: .context, text: "context 10%")])
    }

    private func decode(_ json: String) throws -> AgentInfo {
        try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
    }
}
