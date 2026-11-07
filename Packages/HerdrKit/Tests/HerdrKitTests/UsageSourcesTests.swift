import Foundation
import XCTest
@testable import HerdrKit

/// The device-side commands `UsageSource.command(for:)` builds: each prints
/// the normalized JSON its `UsageSource.parse` reads, reading only fixture
/// trees pointed at through `$HOME`. Nothing here needs python3, and the
/// real `claude` CLI never runs: a stub on the fixture PATH stands in.
final class UsageSourcesTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Shape

    /// Every command is a static string: one `/bin/sh -c` script (the
    /// login shell may be fish or zsh), no python, and no backslash a fish
    /// login shell would read as an escape inside the single quotes.
    func testCommandsAreStaticPOSIXScripts() {
        for provider in UsageProvider.allCases {
            let command = UsageSource.command(for: provider)
            let script = UsageSource.script(for: provider)
            XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"), "\(provider)")
            XCTAssertTrue(command.hasSuffix("' herdrm-usage"), "\(provider)")
            XCTAssertFalse(command.contains("python"), "\(provider) must not need python3")
            XCTAssertFalse(script.contains("\\"), "\(provider)'s script must carry no backslash")
            XCTAssertTrue(script.contains("PATH=\"$HOME/.local/bin:"), "\(provider) resolves tools over SSH")
            XCTAssertTrue(script.contains(":/opt/homebrew/bin:/usr/local/bin:$PATH\"; export PATH"), "\(provider)")
        }
    }

    /// Each provider's own command timeout bounds the run; claude's is the
    /// longest (a cold CLI start) but still bounded.
    func testCommandTimeoutsAreBounded() {
        for provider in UsageProvider.allCases {
            XCTAssertGreaterThan(UsageSource.timeout(for: provider), 0)
            XCTAssertLessThanOrEqual(UsageSource.timeout(for: provider), 90)
        }
        XCTAssertGreaterThan(UsageSource.timeout(for: .claude), UsageSource.timeout(for: .codex))
    }

    // MARK: - Codex

    /// The command scans `$HOME/.codex/sessions` for the newest `token_count`
    /// record and prints it normalized: one reading, the spike's monthly
    /// window and token totals.
    func testCodexCommandReadsFixtureHome() async throws {
        let home = try makeTempHome("codex")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(spikeRecordLine, to: home.appendingPathComponent(".codex/sessions/2026/10/08/rollout-x.jsonl"))

        let result = try await runParsed(.codex, home: home)
        XCTAssertEqual(result.installed, true)
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.readings.first?.windows.count, 1)
        XCTAssertEqual(result.readings.first?.windows.first?.group, "30d")
        XCTAssertEqual(result.readings.first?.windows.first?.remaining, 98)
        XCTAssertEqual(result.readings.first?.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_794_069_902))
        XCTAssertEqual(result.readings.first?.tokens?.input, 4_612_440)
        XCTAssertEqual(result.readings.first?.tokens?.output, 9_838)
        XCTAssertEqual(result.readings.first?.tokens?.reasoning, 5_146)
        XCTAssertEqual(result.readings.first?.tokens?.cacheRead, 4_441_088)
    }

    /// A `token_count` record with `"info":null` (codex writes one before
    /// the first turn) is skipped: the newest record that has info wins,
    /// rather than all-null tokens failing the whole read.
    func testCodexCommandSkipsRecordsWithNullInfo() async throws {
        let home = try makeTempHome("codex-null-info")
        defer { try? FileManager.default.removeItem(at: home) }
        let nullInfo = #"{"timestamp":"2026-10-08T17:40:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":9.0,"window_minutes":300,"resets_at":1794069999},"secondary":null}}}"#
        try write(spikeRecordLine + "\n" + nullInfo + "\n",
                  to: home.appendingPathComponent(".codex/sessions/2026/10/08/rollout-x.jsonl"))

        let result = try await runParsed(.codex, home: home)
        let reading = try XCTUnwrap(result.readings.first)
        XCTAssertEqual(reading.tokens?.input, 4_612_440, "the record with info is the one read")
        XCTAssertEqual(reading.windows.first?.group, "30d")
    }

    /// Older codex builds write no `cache_write_input_tokens`, and a real
    /// record carries `"secondary":null` beside `last_token_usage`; both
    /// still parse, the missing count as zero.
    func testCodexCommandParsesOlderRecordWithoutCacheWrite() async throws {
        let home = try makeTempHome("codex-old")
        defer { try? FileManager.default.removeItem(at: home) }
        let old = #"{"timestamp":"2026-10-08T17:32:27.332Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":80,"output_tokens":7,"reasoning_output_tokens":2,"total_tokens":127},"last_token_usage":{"input_tokens":1,"cached_input_tokens":1,"output_tokens":1,"reasoning_output_tokens":1,"total_tokens":2}},"rate_limits":{"primary":{"used_percent":57.0,"window_minutes":10080,"resets_at":1794482062},"secondary":null}}}"#
        try write(old, to: home.appendingPathComponent(".codex/sessions/2026/10/08/rollout-old.jsonl"))

        let result = try await runParsed(.codex, home: home)
        let reading = try XCTUnwrap(result.readings.first)
        XCTAssertEqual(
            reading.tokens, UsageTokens(input: 120, output: 7, reasoning: 2, cacheRead: 80, cacheWrite: 0),
            "total_token_usage, never last_token_usage; a missing cache-write count is zero")
        XCTAssertEqual(reading.windows.map(\.group), ["weekly"])
        XCTAssertEqual(reading.windows.first?.remaining, 43)
    }

    /// The newest day directory's rollout is read; an older day's record
    /// does not win.
    func testCodexCommandReadsNewestRollout() async throws {
        let home = try makeTempHome("codex-newest")
        defer { try? FileManager.default.removeItem(at: home) }
        let older = spikeRecordLine.replacingOccurrences(of: #""used_percent":2.0"#, with: #""used_percent":70.0"#)
        try write(older, to: home.appendingPathComponent(".codex/sessions/2026/09/30/rollout-a.jsonl"))
        try write(spikeRecordLine, to: home.appendingPathComponent(".codex/sessions/2026/10/08/rollout-b.jsonl"))

        let result = try await runParsed(.codex, home: home)
        XCTAssertEqual(result.readings.first?.windows.first?.remaining, 98)
    }

    /// The scans are plain POSIX sh: they read the same under dash (Linux's
    /// `/bin/sh`), and the quoted command survives a zsh login shell.
    func testScansRunUnderDashAndThroughZsh() throws {
        let home = try makeTempHome("codex-shells")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(spikeRecordLine, to: home.appendingPathComponent(".codex/sessions/2026/10/08/rollout-x.jsonl"))
        try write(#"{"total": {"tokens": {"input": 2, "output": 1, "cached": 3}}}"#,
                  to: home.appendingPathComponent(".gemini/tmp/aaaaaaaa/usage.json"))

        for (shell, arguments) in [
            ("/bin/dash", { (p: UsageProvider) in ["-c", UsageSource.script(for: p), "herdrm-usage"] }),
            ("/bin/zsh", { (p: UsageProvider) in ["-c", UsageSource.command(for: p)] }),
        ] {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            let codex = try XCTUnwrap(UsageSource.parse(
                .codex, stdout: try runShell(shell, arguments(.codex), home: home), fetchedAt: fetchedAt), shell)
            XCTAssertEqual(codex.readings.first?.windows.first?.remaining, 98, shell)
            XCTAssertEqual(codex.readings.first?.tokens?.input, 4_612_440, shell)
            let gemini = try XCTUnwrap(UsageSource.parse(
                .gemini, stdout: try runShell(shell, arguments(.gemini), home: home), fetchedAt: fetchedAt), shell)
            XCTAssertEqual(gemini.readings.first?.tokens?.cacheRead, 3, shell)
        }
    }

    /// An empty home has no `~/.codex`: not installed, nothing to show.
    func testCodexCommandOnEmptyHomeIsInstalledFalseWithNoWindows() async throws {
        let home = try makeTempHome("codex-empty")
        defer { try? FileManager.default.removeItem(at: home) }

        let result = try await runParsed(.codex, home: home)
        XCTAssertEqual(result.installed, false)
        XCTAssertEqual(result.readings, [])
    }

    /// Sessions without any `token_count` record yet: installed, unknown.
    func testCodexCommandWithoutRecordsIsInstalledUnknown() async throws {
        let home = try makeTempHome("codex-none")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"type":"session_meta","payload":{}}"#,
                  to: home.appendingPathComponent(".codex/sessions/2026/10/08/rollout-x.jsonl"))

        let result = try await runParsed(.codex, home: home)
        XCTAssertEqual(result, UsageParseResult(installed: true, readings: []))
    }

    // MARK: - Gemini

    /// The command sums the week's `usage.json` files under
    /// `$HOME/.gemini/tmp` into one normalized token total, and a file that
    /// fails to parse is skipped rather than fatal.
    func testGeminiCommandAggregatesFixtureUsageFiles() async throws {
        let home = try makeTempHome("gemini")
        defer { try? FileManager.default.removeItem(at: home) }
        let usage = #"{"total": {"tokens": {"input": 2, "output": 1, "cached": 3}}}"#
        for hash in ["aaaaaaaa", "bbbbbbbb"] {
            try write(usage, to: home.appendingPathComponent(".gemini/tmp/\(hash)/usage.json"))
        }

        let result = try await runParsed(.gemini, home: home)
        XCTAssertEqual(result.installed, true)
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.readings.first?.tokens?.input, 4)
        XCTAssertEqual(result.readings.first?.tokens?.output, 2)
        XCTAssertEqual(result.readings.first?.tokens?.cacheRead, 6)
        XCTAssertEqual(result.readings.first?.tokens?.reasoning, 0)
        XCTAssertEqual(result.readings.first?.tokens?.cacheWrite, 0)

        // Two files whose second is invalid JSON: still sums the valid one.
        try write("not json", to: home.appendingPathComponent(".gemini/tmp/bbbbbbbb/usage.json"))
        let after = try await runParsed(.gemini, home: home)
        XCTAssertEqual(after.readings.first?.tokens?.input, 2)
        XCTAssertEqual(after.readings.first?.tokens?.cacheRead, 3)
    }

    /// Pretty-printed usage files (multi-line, other keys beside `total`)
    /// sum the same, and a file older than a week is left out.
    func testGeminiCommandReadsPrettyJSONAndSkipsStaleFiles() async throws {
        let home = try makeTempHome("gemini-pretty")
        defer { try? FileManager.default.removeItem(at: home) }
        let pretty = """
            {
              "models": {"gemini-pro": {"tokens": {"input": 999}}},
              "total": {
            \t"tokens": {
                  "input": 10,
                  "output": 5,
                  "cached": 1,
                  "total": 16
                }
              }
            }
            """
        try write(pretty, to: home.appendingPathComponent(".gemini/tmp/cccccccc/usage.json"))
        let stale = home.appendingPathComponent(".gemini/tmp/dddddddd/usage.json")
        try write(pretty, to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: stale.path)

        let result = try await runParsed(.gemini, home: home)
        XCTAssertEqual(result.readings.first?.tokens?.input, 10)
        XCTAssertEqual(result.readings.first?.tokens?.output, 5)
        XCTAssertEqual(result.readings.first?.tokens?.cacheRead, 1)
    }

    /// No `~/.gemini`: not installed.
    func testGeminiCommandOnEmptyHomeIsNotInstalled() async throws {
        let home = try makeTempHome("gemini-empty")
        defer { try? FileManager.default.removeItem(at: home) }

        let result = try await runParsed(.gemini, home: home)
        XCTAssertEqual(result, UsageParseResult(installed: false, readings: []))
    }

    // MARK: - OpenCode

    /// The command runs `opencode stats` where opencode is installed, and
    /// its real stats parse to nonzero token counts.
    func testOpencodeCommandRunsWhereInstalled() async throws {
        XCTAssertTrue(UsageSource.script(for: .opencode).contains("opencode stats --json --days 7"))
        guard hasTool("opencode") else { throw XCTSkip("opencode is not installed") }

        let output = try await DeviceFileService(device: .local).run(UsageSource.command(for: .opencode))
        let result = try XCTUnwrap(UsageSource.parse(.opencode, stdout: output, fetchedAt: fetchedAt))
        XCTAssertEqual(result.installed, true)
        XCTAssertGreaterThan(try XCTUnwrap(result.readings.first?.tokens?.input), 0)
    }

    // MARK: - Claude

    /// The command wraps `claude -p /usage` with a `command -v` guard: a
    /// missing CLI prints the installed-false envelope the parser reads.
    /// The real CLI is never run here — `claude -p` touches `~/.claude` and
    /// talks to the provider; the stub tests below stand in for it.
    func testClaudeUsageCommandWrapsCLI() {
        let script = UsageSource.script(for: .claude)
        XCTAssertTrue(script.contains(#"have() { command -v "$1" >/dev/null 2>&1; }"#))
        XCTAssertTrue(script.contains(#"if ! have claude; then echo '{"installed": false}'; exit 0; fi"#))
        XCTAssertTrue(script.contains("/usage </dev/null"), "stdin is closed so -p never waits on it")
        XCTAssertFalse(script.contains("--bare"), "--bare skips OAuth and keychain auth")
    }

    /// A current CLI (its `--help` lists the flags) runs `/usage` without
    /// writing a session transcript, without MCP servers and with hooks
    /// disabled; the stub echoes the argv it was given.
    func testClaudeCommandPassesIsolationFlagsWhenSupported() async throws {
        let home = try makeTempHome("claude-new")
        defer { try? FileManager.default.removeItem(at: home) }
        try installClaudeStub(in: home, help: Self.currentHelp)

        let output = try await DeviceFileService(device: .local)
            .run(withHome(home, UsageSource.command(for: .claude)))
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertEqual(stubArguments(text), [
            "-p", "--no-session-persistence", "--strict-mcp-config",
            "--settings", #"{"disableAllHooks":true}"#, "/usage",
        ])
        XCTAssertFalse(text.contains("STDIN"), "stdin must be empty")
        let result = try XCTUnwrap(UsageSource.parse(.claude, stdout: output, fetchedAt: Self.fetchedOct13))
        XCTAssertEqual(result.readings.first?.windows.first?.remaining, 85)
    }

    /// An older CLI whose `--help` lacks the flags gets the plain form, so
    /// it never fails on an unknown option.
    func testClaudeCommandFallsBackToPlainFormOnOlderCLI() async throws {
        let home = try makeTempHome("claude-old")
        defer { try? FileManager.default.removeItem(at: home) }
        try installClaudeStub(in: home, help: """
            Usage: claude [options] [prompt]
              -p, --print   Print response and exit
              --mcp-config <configs...>
            """)

        let output = try await DeviceFileService(device: .local)
            .run(withHome(home, UsageSource.command(for: .claude)))
        XCTAssertEqual(stubArguments(String(decoding: output, as: UTF8.self)), ["-p", "/usage"])
    }

    /// The spike's `claude -p /usage` stdout parses to one reading with
    /// three windows: the 5-hour session, the all-models week (scope nil)
    /// and the per-model week, each `remaining` = 100 − used with the
    /// en-US-formatter-parsed reset time.
    func testClaudeUsageTextParsesWindows() throws {
        let result = try XCTUnwrap(
            UsageSource.parseClaudeUsage(Self.claudeSpikeOutput, fetchedAt: Self.fetchedOct13))
        XCTAssertEqual(result.installed, true)
        XCTAssertEqual(result.readings.count, 1)
        let windows = try XCTUnwrap(result.readings.first?.windows)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].group, "session")
        XCTAssertEqual(windows[0].remaining, 85)
        XCTAssertEqual(
            windows[0].resetsAt,
            Self.resetDate("Oct 13 at 3:09pm (Europe/Warsaw)", fetchedAt: Self.fetchedOct13))
        XCTAssertEqual(windows[1].group, "weekly")
        XCTAssertNil(windows[1].scope)
        XCTAssertEqual(windows[1].remaining, 87)
        XCTAssertEqual(
            windows[1].resetsAt,
            Self.resetDate("Oct 17 at 3:59pm (Europe/Warsaw)", fetchedAt: Self.fetchedOct13))
        XCTAssertEqual(windows[2].scope, "Fable")
        XCTAssertEqual(windows[2].remaining, 87)
    }

    /// Output that is neither the not-installed envelope nor `Current …`
    /// lines is an installed CLI with nothing usable: unknown, never a
    /// thrown failure — codex's shape.
    func testUnrecognizedUsageOutputYieldsUnknown() throws {
        let result = try XCTUnwrap(
            UsageSource.parseClaudeUsage("error: something", fetchedAt: fetchedAt))
        XCTAssertEqual(result, UsageParseResult(installed: true, readings: []))
    }

    /// The CLI prints no year: a January window read on New Year's Eve is
    /// next year's reset, not a year-stale one.
    func testResetDateRollesOverYearBoundary() throws {
        let result = try XCTUnwrap(UsageSource.parseClaudeUsage(
            "Current session: 59% used · resets Jan 3 at 1:00pm (Europe/Warsaw)",
            fetchedAt: Self.date(2026, 12, 31)))
        let resetsAt = try XCTUnwrap(result.readings.first?.windows.first?.resetsAt)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: resetsAt), 2027)
    }

    // MARK: - Helpers

    /// The newest `token_count` record of the 2026-10-08 spike, as codex
    /// wrote it to its session rollout (trimmed to what the scanner reads).
    private let spikeRecordLine = """
        {"timestamp":"2026-10-08T17:32:27.332Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4612440,"output_tokens":9838,"reasoning_output_tokens":5146,"cached_input_tokens":4441088,"cache_write_input_tokens":0}},"rate_limits":{"primary":{"used_percent":2.0,"window_minutes":43200,"resets_at":1794069902}}}}
        """

    /// Runs `provider`'s command against the fixture `home` and parses it.
    private func runParsed(_ provider: UsageProvider, home: URL) async throws -> UsageParseResult {
        let output = try await DeviceFileService(device: .local)
            .run(withHome(home, UsageSource.command(for: provider)))
        return try XCTUnwrap(
            UsageSource.parse(provider, stdout: output, fetchedAt: fetchedAt),
            String(decoding: output, as: UTF8.self))
    }

    /// Runs `shell` with `arguments` and `HOME` at the fixture, returning stdout.
    private func runShell(_ shell: String, _ arguments: [String], home: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    /// An empty fixture home the commands can read through `$HOME`.
    private func makeTempHome(_ name: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `HOME` pointed at the fixture tree for the whole command, which the
    /// `/bin/sh -c` script inherits.
    private func withHome(_ home: URL, _ command: String) -> String {
        "HOME='\(home.path)'; export HOME; " + command
    }

    // MARK: - Claude helpers

    /// `claude --help` text of a CLI that supports every isolation flag.
    private static let currentHelp = """
        Usage: claude [options] [prompt]
          --no-session-persistence     Disable session persistence
          --setting-sources <sources>  Comma-separated list of setting sources
          --settings <file-or-json>    Load additional settings
          --strict-mcp-config          Only use MCP servers from --mcp-config
        """

    /// A fake `claude` at `$HOME/.local/bin`, first on the command's PATH,
    /// so the real CLI never runs: `--help` prints `help`; anything else
    /// echoes its argv as `ARG <arg>` lines, reports a non-empty stdin, and
    /// prints the spike's usage text.
    private func installClaudeStub(in home: URL, help: String) throws {
        let stub = home.appendingPathComponent(".local/bin/claude")
        try write("""
            #!/bin/sh
            if [ "$1" = "--help" ]; then
            cat <<'HELP_EOF'
            \(help)
            HELP_EOF
            exit 0
            fi
            for a in "$@"; do printf 'ARG %s\\n' "$a"; done
            if IFS= read -r line; then echo STDIN; fi
            cat <<'USAGE_EOF'
            \(Self.claudeSpikeOutput)
            USAGE_EOF

            """, to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: stub.path), "the stub must shadow the real CLI")
    }

    private func stubArguments(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            line.hasPrefix("ARG ") ? String(line.dropFirst(4)) : nil
        }
    }

    /// The 2026-10-13 spike's `claude -p /usage` stdout, verbatim.
    private static let claudeSpikeOutput = """
        Current session: 15% used · resets Oct 13 at 3:09pm (Europe/Warsaw)
        Current week (all models): 13% used · resets Oct 17 at 3:59pm (Europe/Warsaw)
        Current week (Fable): 13% used · resets Oct 17 at 3:59pm (Europe/Warsaw)
        """

    /// Noon in Warsaw on the day the spike ran.
    private static let fetchedOct13 = date(2026, 10, 13)

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        components.timeZone = TimeZone(identifier: "Europe/Warsaw")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// The reset text as the parser reads it: the en-US formatter's parse
    /// of the CLI's `MMM d 'at' h:mma (zone)` stamp, pinned to `fetchedAt`'s
    /// year and rolled +1 when that lands nearly a year before the fetch.
    private static func resetDate(_ text: String, fetchedAt: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d 'at' h:mma (VV)"
        guard let parsed = formatter.date(from: text) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let shifted = calendar.date(
            byAdding: .year,
            value: calendar.component(.year, from: fetchedAt) - calendar.component(.year, from: parsed),
            to: parsed)!
        return shifted.timeIntervalSince(fetchedAt) < -330 * 86400
            ? calendar.date(byAdding: .year, value: 1, to: shifted)
            : shifted
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
