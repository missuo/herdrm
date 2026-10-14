import Foundation
import XCTest
@testable import HerdrKit

/// The device-side history aggregators `UsageHistorySource.command(for:)`
/// builds: each streams its transcript store into the normalized day/model
/// document `parse` decodes, reading only fixture trees pointed at through
/// `$HOME`, with the device timezone pinned through `$TZ`.
final class UsageHistoryTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)

    /// Warsaw is UTC+2 on these October dates (DST ends Oct 25) — the fixed
    /// zone the local-day tests pin through `$TZ`.
    private static let testZone = "Europe/Warsaw"

    // MARK: - Claude

    /// The same `message.id + requestId` recorded in two session files
    /// counts once; a distinct record in one of them still counts.
    func testClaudeAggregatorDedupesMessageIds() async throws {
        guard hasTool("python3") else { throw XCTSkip("python3 is not installed") }
        let home = try makeTempHome("history-claude-dedupe")
        defer { try? FileManager.default.removeItem(at: home) }
        let duplicate = Self.claudeLine(
            id: "msg_01", requestId: "req_01", timestamp: "2026-10-12T10:00:00.000Z",
            input: 10, output: 4, cacheRead: 100, cacheWrite: 50)
        try Self.write(
            duplicate + "\n"
                + Self.claudeLine(
                    id: "msg_02", requestId: "req_02", timestamp: "2026-10-12T10:05:00.000Z",
                    input: 7, output: 2),
            to: home.appendingPathComponent(".claude/projects/alpha/session-a.jsonl"))
        try Self.write(
            duplicate,
            to: home.appendingPathComponent(".claude/projects/beta/nested/session-b.jsonl"))

        let history = try await parseHistory(.claude, home: home)
        XCTAssertEqual(history?.days.count, 1)
        let tokens = try XCTUnwrap(history?.days.first?.tokens[.claude])
        XCTAssertEqual(tokens.input, 17)
        XCTAssertEqual(tokens.output, 6)
        XCTAssertEqual(tokens.cacheRead, 100)
        XCTAssertEqual(tokens.cacheWrite, 50)
        XCTAssertEqual(history?.modelTotals[.claude]?.count, 1)
    }

    /// Records either side of local midnight land on their own local day:
    /// 23:30 and 00:30 Warsaw (= UTC+2) are the 12th and the 13th, though
    /// both transcripts carry October 12 UTC stamps.
    func testClaudeAggregatorSumsByLocalDay() async throws {
        guard hasTool("python3") else { throw XCTSkip("python3 is not installed") }
        let home = try makeTempHome("history-claude-days")
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.write(
            Self.claudeLine(
                id: "msg_a", requestId: "req_a", timestamp: "2026-10-12T21:30:00.000Z",
                input: 100, output: 10, cacheRead: 1_000, cacheWrite: 100) + "\n"
                + Self.claudeLine(
                    id: "msg_b", requestId: "req_b", timestamp: "2026-10-12T22:30:00.000Z",
                    input: 200, output: 20, cacheRead: 2_000, cacheWrite: 200),
            to: home.appendingPathComponent(".claude/projects/alpha/session.jsonl"))

        let history = try await parseHistory(.claude, home: home, timeZone: Self.testZone)
        XCTAssertEqual(history?.days.count, 2)
        XCTAssertEqual(try XCTUnwrap(history?.days.first?.date), Self.utcDay(2026, 10, 12))
        XCTAssertEqual(history?.days.first?.tokens[.claude]?.input, 100)
        XCTAssertEqual(history?.days.first?.tokens[.claude]?.cacheRead, 1_000)
        XCTAssertEqual(try XCTUnwrap(history?.days.last?.date), Self.utcDay(2026, 10, 13))
        XCTAssertEqual(history?.days.last?.tokens[.claude]?.input, 200)
        XCTAssertEqual(history?.days.last?.tokens[.claude]?.cacheWrite, 200)
        XCTAssertEqual(history?.modelTotals[.claude]?["claude-opus-5-5"]?.input, 300)
    }

    /// `user` lines and `assistant` lines without `message.usage` are
    /// skipped; only usage-carrying assistant records count.
    func testClaudeAggregatorSkipsNonAssistantAndUsageless() async throws {
        guard hasTool("python3") else { throw XCTSkip("python3 is not installed") }
        let home = try makeTempHome("history-claude-skip")
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.write(
            #"{"timestamp":"2026-10-12T10:00:00.000Z","type":"user","message":{"role":"user","content":"hello"}}"#
                + "\n"
                + #"{"timestamp":"2026-10-12T10:01:00.000Z","type":"assistant","message":{"id":"msg_88","model":"claude-opus-5-5"}}"#
                + "\n"
                + Self.claudeLine(
                    id: "msg_89", requestId: "req_89", timestamp: "2026-10-12T10:02:00.000Z",
                    input: 42, output: 8),
            to: home.appendingPathComponent(".claude/projects/alpha/session.jsonl"))

        let history = try await parseHistory(.claude, home: home)
        XCTAssertEqual(history?.days.count, 1)
        XCTAssertEqual(history?.days.first?.tokens[.claude]?.input, 42)
        XCTAssertEqual(history?.days.first?.tokens[.claude]?.output, 8)
    }

    // MARK: - Codex

    /// One session file with three growing `total_token_usage` events counts
    /// only the last one's totals, once — the series is cumulative, never
    /// summed across events. A later non-`token_count` line does not win.
    func testCodexSessionTotalsNotDoubleSummed() async throws {
        guard hasTool("python3") else { throw XCTSkip("python3 is not installed") }
        let home = try makeTempHome("history-codex-cumulative")
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.write(
            [
                Self.codexLine(timestamp: "2026-10-12T09:00:00.000Z", input: 100, output: 10),
                Self.codexLine(timestamp: "2026-10-12T09:02:00.000Z", input: 200, output: 20),
                Self.codexLine(
                    timestamp: "2026-10-12T09:04:00.000Z", input: 300, output: 30,
                    reasoning: 15, cacheRead: 70, cacheWrite: 3, model: "gpt-5-codex"),
                #"{"timestamp":"2026-10-12T09:05:00.000Z","type":"event_msg","payload":{"type":"agent_reasoning_delta"}}"#,
            ].joined(separator: "\n"),
            to: home.appendingPathComponent(".codex/sessions/2026/10/12/rollout-1.jsonl"))

        let history = try await parseHistory(.codex, home: home)
        XCTAssertEqual(history?.days.count, 1)
        let tokens = try XCTUnwrap(history?.days.first?.tokens[.codex])
        XCTAssertEqual(tokens.input, 300)
        XCTAssertEqual(tokens.output, 30)
        XCTAssertEqual(tokens.reasoning, 15)
        XCTAssertEqual(tokens.cacheRead, 70)
        XCTAssertEqual(tokens.cacheWrite, 3)
        XCTAssertEqual(history?.modelTotals[.codex]?.count, 1)
        XCTAssertEqual(history?.modelTotals[.codex]?["gpt-5-codex"]?.input, 300)
    }

    // MARK: - OpenCode

    /// opencode's history comes from its local sqlite db (`message` rows,
    /// `data` JSON with role/tokens/time.created): assistant messages
    /// bucket by the device's local day and by `modelID`, the SQL cutoff
    /// drops anything older than 30 days, user rows never count, and a
    /// missing db yields an empty history. Built against a real sqlite
    /// fixture under a temp HOME with a pinned timezone.
    func testOpencodeHistoryWalksItsDatabase() async throws {
        try XCTSkipUnless(hasTool("python3"), "python3 is not installed")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-opencode-\(UUID().uuidString)").path
        let dbDir = "\(home)/.local/share/opencode"
        try FileManager.default.createDirectory(
            atPath: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        func message(role: String, model: String, createdMs: Double, input: Int, output: Int, cacheRead: Int = 0) -> String {
            let data: [String: Any] = [
                "role": role,
                "time": ["created": createdMs],
                "modelID": model,
                "tokens": ["input": input, "output": output, "reasoning": 0,
                           "cache": ["read": cacheRead, "write": 0]],
            ]
            let json = try! JSONSerialization.data(withJSONObject: data)
            return String(data: json, encoding: .utf8)!
        }
        // 2026-10-14 10:00 UTC = 12:00 Warsaw: one day's usage across two
        // models; one row predating the 30-day cutoff; one user row that
        // must never count.
        let recent = 1_791_000_000_000.0
        let old = recent - 31.5 * 86400 * 1000
        let rows = [
            message(role: "assistant", model: "glm-5.3", createdMs: recent, input: 1_000, output: 100, cacheRead: 5_000),
            message(role: "assistant", model: "gemini-3-flash", createdMs: recent + 3_600_000, input: 200, output: 50),
            message(role: "assistant", model: "glm-5.3", createdMs: old, input: 999_999, output: 999_999),
            message(role: "user", model: "glm-5.3", createdMs: recent, input: 777, output: 777),
        ]
        let seed = """
        import json, sqlite3, sys
        conn = sqlite3.connect(sys.argv[1])
        conn.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
        for index, row in enumerate(json.load(open(sys.argv[2]))):
            conn.execute("INSERT INTO message VALUES (?, ?, ?, ?, ?)", (str(index), "s", int(json.loads(row)['time']['created']), 0, row))
        conn.commit()
        """
        let seedURL = URL(fileURLWithPath: dbDir).appendingPathComponent("seed.py")
        let rowsURL = URL(fileURLWithPath: dbDir).appendingPathComponent("rows.json")
        try seed.write(to: seedURL, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: rows).write(to: rowsURL)
        let seedProcess = Process()
        seedProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        seedProcess.arguments = ["python3", seedURL.path, "\(dbDir)/opencode.db", rowsURL.path]
        try seedProcess.run()
        seedProcess.waitUntilExit()
        XCTAssertEqual(seedProcess.terminationStatus, 0, "fixture seed failed")

        let command = try XCTUnwrap(UsageHistorySource.command(for: .opencode))
        let output = try await DeviceFileService(device: .local).run(
            "HOME='\(home)'; export HOME; TZ='Europe/Warsaw'; export TZ; " + command)
        let history = try XCTUnwrap(
            UsageHistorySource.parse(.opencode, stdout: output, fetchedAt: fetchedAt))

        XCTAssertEqual(history.days.count, 1, "both recent rows share the Warsaw day: \(history.days)")
        XCTAssertEqual(
            history.days.first?.tokens[.opencode],
            UsageTokens(input: 1_200, output: 150, reasoning: 0, cacheRead: 5_000, cacheWrite: 0))
        XCTAssertEqual(history.modelTotals[.opencode]?.count, 2)
        XCTAssertEqual(history.modelTotals[.opencode]?["glm-5.3"]?.input, 1_000)
        XCTAssertEqual(history.modelTotals[.opencode]?["gemini-3-flash"]?.input, 200)

        // A missing db is a valid, empty history — the daemon's absence
        // reads as "no data", not a failure.
        let emptyHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-opencode-empty-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: emptyHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: emptyHome) }
        let emptyOutput = try await DeviceFileService(device: .local).run(
            "HOME='\(emptyHome)'; export HOME; " + command)
        let empty = try XCTUnwrap(
            UsageHistorySource.parse(.opencode, stdout: emptyOutput, fetchedAt: fetchedAt))
        XCTAssertEqual(empty.days, [])
        XCTAssertTrue(empty.modelTotals[.opencode]?.isEmpty ?? false)

        // With opencode installed and used, the real db yields real days.
        guard hasTool("opencode"), FileManager.default.fileExists(
            atPath: NSString(string: "~/.local/share/opencode/opencode.db").expandingTildeInPath)
        else { return }
        let liveOutput = try await DeviceFileService(device: .local).run(command)
        let live = try XCTUnwrap(
            UsageHistorySource.parse(.opencode, stdout: liveOutput, fetchedAt: fetchedAt))
        XCTAssertFalse(live.days.isEmpty, "the real opencode db has recent usage")
        XCTAssertTrue((live.modelTotals[.opencode]?["glm-5.3"]?.input ?? 0) > 0)
    }

    // MARK: - Parse

    /// The normalized document the heredocs print decodes to a `UsageHistory`
    /// with the day label pinned to midnight UTC and totals keyed by
    /// `provider`; anything that is not the history shape at all is nil.
    func testParseMapsNormalizedSchema() throws {
        let document = #"{"days": [{"date": "2026-10-12", "input": 100, "output": 40, "reasoning": 0, "cache_read": 500, "cache_write": 20}], "models": {"claude-opus-5-5": {"input": 60, "output": 25, "reasoning": 0, "cache_read": 300, "cache_write": 20}}}"#
        let history = try XCTUnwrap(
            UsageHistorySource.parse(.claude, stdout: Data(document.utf8), fetchedAt: fetchedAt))
        XCTAssertEqual(history.generatedAt, fetchedAt)
        XCTAssertEqual(history.days.count, 1)
        XCTAssertEqual(history.days.first?.date, Self.utcDay(2026, 10, 12))
        XCTAssertEqual(
            history.days.first?.tokens,
            [.claude: UsageTokens(input: 100, output: 40, reasoning: 0, cacheRead: 500, cacheWrite: 20)])
        XCTAssertEqual(
            history.modelTotals,
            [.claude: ["claude-opus-5-5": UsageTokens(input: 60, output: 25, reasoning: 0, cacheRead: 300, cacheWrite: 20)]])

        // Not the history shape at all: nil, never a thrown failure.
        XCTAssertNil(
            UsageHistorySource.parse(.claude, stdout: Data("Current session: 15% used".utf8), fetchedAt: fetchedAt))
        XCTAssertNil(UsageHistorySource.parse(.codex, stdout: Data(), fetchedAt: fetchedAt))

        // An empty document is a valid, empty history.
        let empty = try XCTUnwrap(
            UsageHistorySource.parse(.codex, stdout: Data(#"{"days": [], "models": {}}"#.utf8), fetchedAt: fetchedAt))
        XCTAssertEqual(empty.days, [])
        XCTAssertTrue(empty.modelTotals[.codex]?.isEmpty ?? false)
    }

    // MARK: - Commands

    /// Claude and codex stream heredocs with the 30-day mtime filter ahead
    /// of any file open; opencode runs its guarded stats call; gemini (no
    /// transcripts) has none.
    func testHistoryCommandsExistForClaudeCodexAndOpencode() throws {
        for provider in [UsageProvider.claude, .codex] {
            let command = try XCTUnwrap(UsageHistorySource.command(for: provider))
            XCTAssertTrue(command.hasPrefix(SSHTunnel.remotePathExport))
            XCTAssertTrue(command.contains("<<'USAGE_EOF'"))
            XCTAssertTrue(command.contains("getmtime"))
            XCTAssertTrue(command.contains("for line in handle"))
            XCTAssertFalse(command.contains(".read("))
            let mtime = try XCTUnwrap(command.range(of: "getmtime"))
            let open = try XCTUnwrap(command.range(of: "open(path"))
            XCTAssertTrue(mtime.lowerBound < open.lowerBound)
        }
        XCTAssertTrue(try XCTUnwrap(UsageHistorySource.command(for: .claude)).contains(".claude"))
        XCTAssertTrue(try XCTUnwrap(UsageHistorySource.command(for: .claude)).contains("projects"))
        XCTAssertTrue(try XCTUnwrap(UsageHistorySource.command(for: .codex)).contains(".codex"))
        XCTAssertTrue(try XCTUnwrap(UsageHistorySource.command(for: .codex)).contains("sessions"))
        let opencode = try XCTUnwrap(UsageHistorySource.command(for: .opencode))
        XCTAssertTrue(opencode.hasPrefix(SSHTunnel.remotePathExport))
        XCTAssertTrue(opencode.contains("python3 - <<'USAGE_EOF'"), "the sqlite walk is a heredoc")
        XCTAssertTrue(opencode.contains("opencode.db"), "it reads opencode's own database")
        XCTAssertTrue(opencode.contains("mode=ro"), "read-only, so the daemon's WAL never blocks")
        XCTAssertTrue(opencode.contains("WHERE time_created >="), "the 30-day window is an indexed SQL cutoff")
        XCTAssertTrue(opencode.contains("assistant"), "assistant messages are the rows that count")
        XCTAssertNil(UsageHistorySource.command(for: .gemini))
    }

    /// An empty home (no `~/.claude`, no `~/.codex`) yields a valid empty
    /// history from both commands rather than a crash or nil.
    func testCommandsOnEmptyHomeYieldEmptyHistory() async throws {
        guard hasTool("python3") else { throw XCTSkip("python3 is not installed") }
        let home = try makeTempHome("history-empty")
        defer { try? FileManager.default.removeItem(at: home) }
        for provider in [UsageProvider.claude, .codex] {
            let history = try await parseHistory(provider, home: home)
            XCTAssertEqual(history?.days, [])
            XCTAssertEqual(history?.modelTotals[provider], [:])
        }
    }

    /// Transcript files untouched for over 30 days are skipped by the mtime
    /// filter before any parsing, whatever their records say.
    func testFilesOlderThanThirtyDaysAreSkipped() async throws {
        guard hasTool("python3") else { throw XCTSkip("python3 is not installed") }
        let home = try makeTempHome("history-stale")
        defer { try? FileManager.default.removeItem(at: home) }
        let oldDate = Date(timeIntervalSinceNow: -40 * 86400)
        let claudeFile = home.appendingPathComponent(".claude/projects/alpha/old.jsonl")
        try Self.write(
            Self.claudeLine(
                id: "msg_old", requestId: "req_old", timestamp: "2026-10-12T10:00:00.000Z",
                input: 999),
            to: claudeFile)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: claudeFile.path)
        let codexFile = home.appendingPathComponent(".codex/sessions/2026/09/old.jsonl")
        try Self.write(
            Self.codexLine(timestamp: "2026-10-12T09:00:00.000Z", input: 999, output: 1),
            to: codexFile)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: codexFile.path)

        for provider in [UsageProvider.claude, .codex] {
            let history = try await parseHistory(provider, home: home)
            XCTAssertEqual(history?.days, [], "\(provider.rawValue) counted a 40-day-old file")
        }
    }

    // MARK: - Helpers

    /// Runs `provider`'s command with `$HOME` (and optionally `$TZ`) pointed
    /// at the fixture tree, returning its parsed history.
    private func parseHistory(
        _ provider: UsageProvider, home: URL, timeZone: String? = nil
    ) async throws -> UsageHistory? {
        let command = try XCTUnwrap(UsageHistorySource.command(for: provider))
        var prefix = timeZone.map { "TZ='\($0)'; export TZ; " } ?? ""
        prefix += "HOME='\(home.path)'; export HOME; "
        let output = try await DeviceFileService(device: .local).run(prefix + command)
        return UsageHistorySource.parse(provider, stdout: output, fetchedAt: fetchedAt)
    }

    /// An empty fixture home the commands can read through `$HOME`.
    private func makeTempHome(_ name: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-history-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// One assistant transcript record, the shape pinned by the 2026-10-13
    /// probe: `timestamp`, `requestId`, `message.id/model/usage` with
    /// `cache_creation` (write) and `cache_read` input tokens.
    private static func claudeLine(
        id: String, requestId: String, timestamp: String,
        input: Int, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0,
        model: String = "claude-opus-5-5"
    ) -> String {
        #"{"timestamp": "\#(timestamp)", "requestId": "\#(requestId)", "type": "assistant", "message": {"id": "\#(id)", "model": "\#(model)", "usage": {"input_tokens": \#(input), "cache_creation_input_tokens": \#(cacheWrite), "cache_read_input_tokens": \#(cacheRead), "output_tokens": \#(output)}}}"#
    }

    /// One codex `token_count` event: `total_token_usage` is the session's
    /// cumulative total, `model` rides `payload.info` when present.
    private static func codexLine(
        timestamp: String, input: Int, output: Int, reasoning: Int = 0,
        cacheRead: Int = 0, cacheWrite: Int = 0, model: String? = nil
    ) -> String {
        let modelField = model.map { #", "model": "\#($0)""# } ?? ""
        return #"{"timestamp": "\#(timestamp)", "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": \#(input), "cached_input_tokens": \#(cacheRead), "cache_write_input_tokens": \#(cacheWrite), "output_tokens": \#(output), "reasoning_output_tokens": \#(reasoning)}\#(modelField)}}}"#
    }

    /// Midnight UTC of a day label, the Date `parse` pins labels to.
    private static func utcDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// Whether `tool` answers `command -v`, the same probe the device does.
    private func hasTool(_ tool: String) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        probe.arguments = [tool]
        probe.standardOutput = Pipe()
        probe.standardError = Pipe()
        do { try probe.run() } catch { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }
}
