import Foundation
import XCTest
@testable import HerdrKit

/// The device-side commands `UsageSource.command(for:)` builds: each prints
/// the normalized JSON its `UsageSource.parse` reads, reading only fixture
/// trees pointed at through `$HOME`.
final class UsageSourcesTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Codex

    /// The command scans `$HOME/.codex/sessions` for the newest `token_count`
    /// record and prints it normalized: one reading, the spike's monthly
    /// window and token totals.
    func testCodexCommandReadsFixtureHome() async throws {
        guard hasTool("python3") else { throw XCTSkip("python3 is not installed") }
        let home = try makeTempHome("codex")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try spikeRecordLine.write(
            to: sessions.appendingPathComponent("rollout-x.jsonl"), atomically: true, encoding: .utf8)

        let command = try XCTUnwrap(UsageSource.command(for: .codex))
        let output = try await DeviceFileService(device: .local).run(withHome(home, command))
        let result = try XCTUnwrap(UsageSource.parse(.codex, stdout: output, fetchedAt: fetchedAt))
        XCTAssertEqual(result.installed, true)
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.readings.first?.windows.count, 1)
        XCTAssertEqual(result.readings.first?.windows.first?.group, "30d")
        XCTAssertEqual(result.readings.first?.windows.first?.remaining, 98)
        XCTAssertEqual(result.readings.first?.tokens?.input, 4_612_440)
        XCTAssertEqual(result.readings.first?.tokens?.cacheRead, 4_441_088)
    }

    /// An empty home has no `~/.codex`: not installed, nothing to show.
    func testCodexCommandOnEmptyHomeIsInstalledFalseWithNoWindows() async throws {
        guard hasTool("python3") else { throw XCTSkip("python3 is not installed") }
        let home = try makeTempHome("codex-empty")
        defer { try? FileManager.default.removeItem(at: home) }

        let command = try XCTUnwrap(UsageSource.command(for: .codex))
        let output = try await DeviceFileService(device: .local).run(withHome(home, command))
        let result = try XCTUnwrap(UsageSource.parse(.codex, stdout: output, fetchedAt: fetchedAt))
        XCTAssertEqual(result.installed, false)
        XCTAssertEqual(result.readings, [])
    }

    // MARK: - Gemini

    /// The command sums the week's `usage.json` files under
    /// `$HOME/.gemini/tmp` into one normalized token total, and a file that
    /// fails to parse is skipped rather than fatal.
    func testGeminiCommandAggregatesFixtureUsageFiles() async throws {
        guard hasTool("python3") else { throw XCTSkip("python3 is not installed") }
        let home = try makeTempHome("gemini")
        defer { try? FileManager.default.removeItem(at: home) }
        let usage = #"{"total": {"tokens": {"input": 2, "output": 1, "cached": 3}}}"#
        for hash in ["aaaaaaaa", "bbbbbbbb"] {
            try write(usage, to: home.appendingPathComponent(".gemini/tmp/\(hash)/usage.json"))
        }

        let command = try XCTUnwrap(UsageSource.command(for: .gemini))
        let output = try await DeviceFileService(device: .local).run(withHome(home, command))
        let result = try XCTUnwrap(UsageSource.parse(.gemini, stdout: output, fetchedAt: fetchedAt))
        XCTAssertEqual(result.installed, true)
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.readings.first?.tokens?.input, 4)
        XCTAssertEqual(result.readings.first?.tokens?.output, 2)
        XCTAssertEqual(result.readings.first?.tokens?.cacheRead, 6)
        XCTAssertEqual(result.readings.first?.tokens?.reasoning, 0)
        XCTAssertEqual(result.readings.first?.tokens?.cacheWrite, 0)

        // Two files whose second is invalid JSON: still sums the valid one.
        try write("not json", to: home.appendingPathComponent(".gemini/tmp/bbbbbbbb/usage.json"))
        let retried = try await DeviceFileService(device: .local).run(withHome(home, command))
        let after = try XCTUnwrap(UsageSource.parse(.gemini, stdout: retried, fetchedAt: fetchedAt))
        XCTAssertEqual(after.readings.first?.tokens?.input, 2)
        XCTAssertEqual(after.readings.first?.tokens?.cacheRead, 3)
    }

    // MARK: - OpenCode

    /// The command runs `opencode stats` with the auth list after the
    /// `---AUTH---` marker the parser splits on, and where opencode is
    /// installed its real stats parse to nonzero token counts.
    func testOpencodeCommandRunsWhereInstalled() async throws {
        let command = try XCTUnwrap(UsageSource.command(for: .opencode))
        XCTAssertTrue(command.hasPrefix(SSHTunnel.remotePathExport))
        XCTAssertTrue(command.contains("echo ---AUTH---"))
        guard let marker = command.range(of: "---AUTH---") else {
            return XCTFail("command has no ---AUTH--- marker")
        }
        XCTAssertTrue(command[marker.upperBound...].contains("auth list"))
        guard hasTool("opencode") else { throw XCTSkip("opencode is not installed") }

        let output = try await DeviceFileService(device: .local).run(command)
        let result = try XCTUnwrap(UsageSource.parse(.opencode, stdout: output, fetchedAt: fetchedAt))
        XCTAssertEqual(result.installed, true)
        XCTAssertGreaterThan(try XCTUnwrap(result.readings.first?.tokens?.input), 0)
    }

    // MARK: - Helpers

    /// The newest `token_count` record of the 2026-10-08 spike, as codex
    /// wrote it to its session rollout (trimmed to what the scanner reads).
    private let spikeRecordLine = """
        {"timestamp":"2026-10-08T17:32:27.332Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4612440,"output_tokens":9838,"reasoning_output_tokens":5146,"cached_input_tokens":4441088,"cache_write_input_tokens":0}},"rate_limits":{"primary":{"used_percent":2.0,"window_minutes":43200,"resets_at":1794069902}}}}
        """

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

    /// `HOME` pointed at the fixture tree for the whole command. The command
    /// opens with a `for` loop (`SSHTunnel.remotePathExport`), which a bare
    /// `HOME=…` prefix cannot precede in `/bin/sh`, so the assignment is
    /// exported on its own instead.
    private func withHome(_ home: URL, _ command: String) -> String {
        "HOME='\(home.path)'; export HOME; " + command
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
