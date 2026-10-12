import Foundation
import XCTest
@testable import HerdrKit

/// Provider usage parsing: grazr's report for Claude and the normalized
/// codex, opencode and gemini command output into `AgentUsageReading`s.
final class AgentUsageTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)

    func testGrazrReportYieldsOneReadingPerAccount() throws {
        let result = try XCTUnwrap(parse(.claude, """
            {
              "installed": true, "active": "a1", "accounts": [
                {"id": "a1", "name": "senad@example.com", "windows": [
                  {"kind": "usage", "scope": null, "group": "session", "remaining": 12, "resets_at": null}]},
                {"id": "a2", "name": "work@example.com", "windows": [
                  {"kind": "usage", "scope": null, "group": "weekly", "remaining": 64, "resets_at": 1794000000}]}
              ],
              "order": [], "settings": {}, "blocked": {}
            }
            """))
        XCTAssertEqual(result.installed, true)
        XCTAssertEqual(result.readings.count, 2)
        XCTAssertEqual(result.readings.first?.account, "senad@example.com")
        XCTAssertEqual(result.readings.first?.windows.first?.group, "session")
        XCTAssertEqual(result.readings.first?.windows.first?.remaining, 12)
    }

    func testGrazrAbsentMeansNotInstalled() throws {
        let result = try XCTUnwrap(parse(.claude, """
            {
              "installed": false, "active": null, "accounts": [],
              "order": [], "settings": {}, "blocked": {}
            }
            """))
        XCTAssertEqual(result.installed, false)
        XCTAssertEqual(result.readings, [])
        XCTAssertEqual(UsageProviderState(parse: result, fetchedAt: fetchedAt), .notInstalled)
    }

    func testCodexRecordParsesWindowsAndTokens() throws {
        let result = try XCTUnwrap(parse(.codex, """
            {"installed": true, "updated": "2026-10-08T17:32:27.332Z",
             "windows": [{"used_percent": 2.0, "window_minutes": 43200, "resets_at": 1794069902}],
             "tokens": {"input": 4612440, "output": 9838, "reasoning": 5146,
                        "cache_read": 4441088, "cache_write": 0}}
            """))
        XCTAssertEqual(result.readings.count, 1)
        let window = try XCTUnwrap(result.readings.first?.windows.first)
        XCTAssertEqual(window.group, "30d")
        XCTAssertEqual(window.remaining, 98)
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1_794_069_902))
        XCTAssertEqual(result.readings.first?.tokens?.input, 4_612_440)
    }

    func testCodexMonthlyWindowLabelAndRemaining() throws {
        let monthly = try XCTUnwrap(parse(.codex, codexFixture(windowMinutes: 43200)))
        XCTAssertEqual(try XCTUnwrap(monthly.readings.first?.windows.first).label, "30d")
        XCTAssertEqual(try XCTUnwrap(monthly.readings.first?.windows.first).remaining, 59)

        let session = try XCTUnwrap(parse(.codex, codexFixture(windowMinutes: 300)))
        XCTAssertEqual(try XCTUnwrap(session.readings.first?.windows.first).group, "session")

        let weekly = try XCTUnwrap(parse(.codex, codexFixture(windowMinutes: 10080)))
        XCTAssertEqual(try XCTUnwrap(weekly.readings.first?.windows.first).group, "weekly")
    }

    func testCodexRecordWithoutRateLimitsYieldsUnknown() throws {
        let result = try XCTUnwrap(parse(.codex, """
            {"installed": true, "windows": [], "tokens": {"input": 10, "output": 20, "reasoning": 0,
                                                          "cache_read": 0, "cache_write": 0}}
            """))
        XCTAssertEqual(result.readings, [])
        XCTAssertEqual(UsageProviderState(parse: result, fetchedAt: fetchedAt), .unknown)
    }

    func testOpencodeStatsParsesTokens() throws {
        let result = try XCTUnwrap(parse(.opencode, """
            {
              "range": {"from": 1767225600000, "to": 1767830399000},
              "tokens": {"input": 1892345, "output": 43210, "reasoning": 6789,
                         "cache": {"read": 8765432, "write": 123456}},
              "sessions": 9, "messages": 214
            }
            """))
        XCTAssertEqual(result.installed, true)
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.readings.first?.tokens?.cacheRead, 8_765_432)
        XCTAssertEqual(result.readings.first?.tokens?.periodStart, Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(result.readings.first?.tokens?.periodEnd, Date(timeIntervalSince1970: 1_767_830_399))
    }

    /// An installed opencode with an empty stats payload has nothing to show
    /// yet — codex's shape: the card reads `.unknown`, never the store's
    /// thrown "no usable usage" failure.
    func testOpencodeEmptyStatsYieldsUnknown() throws {
        let result = try XCTUnwrap(parse(.opencode, """
            {"range": null, "tokens": null, "sessions": 0, "messages": 0}
            """))
        XCTAssertEqual(result.installed, true)
        XCTAssertEqual(result.readings, [])
        XCTAssertEqual(UsageProviderState(parse: result, fetchedAt: fetchedAt), .unknown)
    }

    func testGeminiAggregateParsesTokens() throws {
        let result = try XCTUnwrap(parse(.gemini, """
            {"installed": true, "tokens": {"input": 1, "output": 2, "reasoning": 0,
                                           "cache_read": 3, "cache_write": 0}, "files": 2}
            """))
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.readings.first?.tokens?.input, 1)
        XCTAssertEqual(result.readings.first?.tokens?.output, 2)
        XCTAssertEqual(result.readings.first?.tokens?.cacheRead, 3)
    }

    func testUndecodableStdoutReturnsNil() {
        XCTAssertNil(parse(.codex, ""))
    }

    // MARK: - State mapping

    /// A read that never produced a result stays `unknown`: `.failed` is
    /// reserved for thrown errors, never for undecodable-but-successful
    /// output or a missing reading.
    func testNilParseMapsToUnknown() {
        XCTAssertEqual(UsageProviderState(parse: nil, fetchedAt: fetchedAt), .unknown)
    }

    /// A tailcat tunnel refuses command runs — `DeviceFileService.run`
    /// throws before executing anything — and the store surfaces that
    /// refusal as a thrown error, which the app's usage model maps to
    /// `.failed`. The sheet must show a failure, never hang.
    func testTailcatDeviceMapsToFailedState() async {
        let tailcat = Device(name: "relay", kind: .tailcat)
        let store = UsageStore(runner: { _, device in
            guard case .tailcat = device.kind else {
                XCTFail("nothing may run beyond the tunnel's refusal")
                throw HerdrError.fileOperationFailed(Self.tailcatRefusal)
            }
            throw HerdrError.fileOperationFailed(Self.tailcatRefusal)
        })

        do {
            _ = try await store.reading(.codex, on: tailcat)
            XCTFail("the refusal must surface as a thrown error, not a reading")
        } catch {
            XCTAssertEqual(
                (error as? HerdrError)?.errorDescription,
                "file operation failed: \(Self.tailcatRefusal)",
                "the refusal's message is what the sheet's failed state shows")
        }
    }

    private func parse(_ provider: UsageProvider, _ json: String) -> UsageParseResult? {
        UsageSource.parse(provider, stdout: Data(json.utf8), fetchedAt: fetchedAt)
    }

    /// The codex record shape with one rate-limit window of `windowMinutes`.
    private func codexFixture(windowMinutes: Int) -> String {
        """
        {"installed": true, "windows": [{"used_percent": 41.0, "window_minutes": \(windowMinutes),
          "resets_at": 1794069902}], "tokens": {"input": 1, "output": 2, "reasoning": 0,
          "cache_read": 0, "cache_write": 0}}
        """
    }

    /// What `DeviceFileService.run` throws for commands over a tailcat tunnel.
    private static let tailcatRefusal = "commands are not supported over a tailcat tunnel"
}
