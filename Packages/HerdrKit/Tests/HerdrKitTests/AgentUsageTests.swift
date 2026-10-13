import Foundation
import XCTest
@testable import HerdrKit

/// Provider usage parsing: the Claude CLI's `/usage` text and the
/// normalized codex, opencode and gemini command output into
/// `AgentUsageReading`s.
final class AgentUsageTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)

    /// The CLI's report is one reading (its own session's account), the
    /// session and weekly windows with `remaining` = 100 − used.
    func testClaudeUsageTextYieldsOneReading() throws {
        let result = try XCTUnwrap(parse(.claude, """
            Current session: 15% used · resets Oct 13 at 3:09pm (Europe/Warsaw)
            Current week (all models): 13% used · resets Oct 17 at 3:59pm (Europe/Warsaw)
            """))
        XCTAssertEqual(result.installed, true)
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.readings.first?.provider, .claude)
        XCTAssertEqual(result.readings.first?.windows.count, 2)
        XCTAssertEqual(result.readings.first?.windows.first?.group, "session")
        XCTAssertEqual(result.readings.first?.windows.first?.remaining, 85)
        XCTAssertEqual(UsageProviderState(parse: result, fetchedAt: fetchedAt), .readings(result.readings))
    }

    /// A missing CLI prints the installed-false envelope: `.notInstalled`,
    /// the plain state every provider shares.
    func testClaudeMissingCLIMeansNotInstalled() throws {
        let result = try XCTUnwrap(parse(.claude, #"{"installed": false}"#))
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

    // MARK: - Sidebar selection

    /// The sidebar's USAGE column watches a model: that scope's window wins,
    /// and a watched model with no window falls back to the all-models one
    /// so the column never blanks.
    func testWatchedModelFallsBackToAllModelsWindow() throws {
        let now = Date()
        let studio = Device(id: UUID(), name: "Studio", kind: .ssh(target: "studio.example"))
        let allModels = GrazrWindow(kind: "quota", group: "weekly", remaining: 40, resetsAt: now.addingTimeInterval(3 * 86400))
        let fable = GrazrWindow(
            kind: "quota", scope: "Fable", group: "weekly",
            remaining: 25, resetsAt: now.addingTimeInterval(3 * 86400))
        let states: [UUID: [UsageProvider: UsageProviderState]] = [
            Device.local.id: [
                .claude: .readings([AgentUsageReading(id: "claude", provider: .claude, windows: [allModels], fetchedAt: now)])
            ],
            studio.id: [
                .claude: .readings([AgentUsageReading(id: "claude-studio", provider: .claude, windows: [fable], fetchedAt: now)])
            ],
        ]
        let devices = [Device.local, studio]

        // The watched model's own window wins, wherever it runs.
        let watched = UsageSelection.tightestWindow(states: states, devices: devices, scope: "Fable", now: now)
        XCTAssertEqual(watched?.device, studio, "the Fable window is on Studio")
        XCTAssertEqual(watched?.window, fable)

        // A watched model yielding no window falls back to the all-models one.
        let missing = UsageSelection.tightestWindow(states: states, devices: devices, scope: "Missing", now: now)
        XCTAssertEqual(missing?.device, Device.local)
        XCTAssertEqual(missing?.window, allModels)

        // "All models" watches the scope-nil windows only — a tighter scoped
        // window never intrudes on it.
        let all = UsageSelection.tightestWindow(states: states, devices: devices, scope: nil, now: now)
        XCTAssertEqual(all?.window, allModels, "scope nil never picks the tighter Fable window")
    }

    /// Only open windows over listed devices with readings can win — a closed
    /// window has refilled, a failed provider is not a fresh reading, and an
    /// unlisted device could not be opened on.
    func testTightestWindowSkipsClosedUnknownDevicesAndNonReadings() throws {
        let now = Date()
        let studio = Device(id: UUID(), name: "Studio", kind: .ssh(target: "studio.example"))
        let ghost = Device(id: UUID(), name: "Ghost", kind: .ssh(target: "ghost.example"))
        let tightest = GrazrWindow(kind: "quota", group: "session", remaining: 3, resetsAt: now.addingTimeInterval(60))
        let closed = GrazrWindow(kind: "quota", group: "30d", remaining: 5, resetsAt: now.addingTimeInterval(-60))
        let scoped = GrazrWindow(
            kind: "quota", scope: "Fable", group: "weekly",
            remaining: 1, resetsAt: now.addingTimeInterval(60))
        let states: [UUID: [UsageProvider: UsageProviderState]] = [
            Device.local.id: [
                .claude: .failed("offline"), // not a fresh reading
                .codex: .readings([AgentUsageReading(id: "codex", provider: .codex, windows: [closed], fetchedAt: now)]), // closed: refilled
                .gemini: .readings([AgentUsageReading(id: "gemini", provider: .gemini, windows: [tightest], fetchedAt: now)]),
            ],
            studio.id: [
                .opencode: .readings([AgentUsageReading(id: "opencode", provider: .opencode, windows: [], fetchedAt: now)]), // tokens only
            ],
            ghost.id: [
                .gemini: .readings([AgentUsageReading(id: "gemini-ghost", provider: .gemini, windows: [scoped], fetchedAt: now)]),
            ],
        ]

        let pick = UsageSelection.tightestWindow(states: states, devices: [Device.local, studio], scope: nil, now: now)
        XCTAssertEqual(pick?.device, Device.local, "the ghost device cannot be opened on, so it is skipped")
        XCTAssertEqual(pick?.window, tightest, "the open scope-nil window with the least left wins")

        // The scoped window counts once its scope is watched — even from a
        // device the nil-scope pass skipped only for lack of a match.
        let scopedPick = UsageSelection.tightestWindow(states: states, devices: [Device.local, ghost], scope: "Fable", now: now)
        XCTAssertEqual(scopedPick?.window, scoped)
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
