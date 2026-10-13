import Foundation
import XCTest
@testable import HerdrKit

/// The store's caching and concurrency: one command run per device and
/// provider within the five-minute TTL, shared across concurrent readers,
/// with a failed run retried on the next read. Commands are stubbed and the
/// clock is injected, so nothing here waits out a real TTL; the only real
/// sleep is the one runner pause that lets a second reader arrive while the
/// first run is still under way.
final class UsageStoreTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Single flight

    /// Two readers arriving while the command is still running share one
    /// run and see the same result.
    func testSingleFlightDeduplicatesConcurrentLoads() async throws {
        let clock = MutableClock(fetchedAt)
        let runner = StubRunner(stdout: Data(Self.codexRecord.utf8), pause: 0.1)
        let store = UsageStore(runner: runner.run, now: { clock.date })

        async let first = store.reading(.codex, on: .local)
        async let second = store.reading(.codex, on: .local)
        let (a, b) = try await (first, second)

        XCTAssertEqual(runner.callCount, 1, "both readers must share one command run")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.readings.first?.windows.first?.remaining, 80)
    }

    // MARK: - TTL

    /// After the TTL lapses the next read runs the command again.
    func testExpiredCacheRerunsCommand() async throws {
        let clock = MutableClock(fetchedAt)
        let runner = StubRunner(stdout: Data(Self.codexRecord.utf8))
        let store = UsageStore(runner: runner.run, now: { clock.date })
        let codexCommand = try XCTUnwrap(UsageSource.command(for: .codex))

        _ = try await store.reading(.codex, on: .local)
        clock.advance(301)
        let second = try await store.reading(.codex, on: .local)

        XCTAssertEqual(runner.callCount, 2)
        XCTAssertEqual(runner.commands, [codexCommand, codexCommand])
        XCTAssertEqual(second.readings.first?.fetchedAt, clock.date, "the re-run stamps the injected clock's time")
    }

    /// A read within the TTL serves the cached reading without a run.
    func testFreshCacheServesWithoutRunning() async throws {
        let clock = MutableClock(fetchedAt)
        let runner = StubRunner(stdout: Data(Self.codexRecord.utf8))
        let store = UsageStore(runner: runner.run, now: { clock.date })

        let first = try await store.reading(.codex, on: .local)
        let second = try await store.reading(.codex, on: .local)

        XCTAssertEqual(runner.callCount, 1)
        XCTAssertEqual(first, second)
    }

    // MARK: - Retrying

    /// A run that throws leaves nothing cached or in flight: the next read
    /// runs again and succeeds.
    func testFailedRunIsRetryable() async throws {
        let clock = MutableClock(fetchedAt)
        let runner = StubRunner(
            stdout: Data(Self.codexRecord.utf8),
            failures: [HerdrError.malformedResponse("the command came up short")])
        let store = UsageStore(runner: runner.run, now: { clock.date })

        do {
            _ = try await store.reading(.codex, on: .local)
            XCTFail("the failed run must surface its error")
        } catch {}

        let retried = try await store.reading(.codex, on: .local)

        XCTAssertEqual(runner.callCount, 2, "the failure must not poison the key")
        XCTAssertEqual(retried.readings.first?.windows.first?.remaining, 80)
    }

    // MARK: - Claude's rerun

    /// `force` re-runs claude's single CLI command, and so does an expired
    /// cache entry: one command for both paths, where grazr needed a
    /// refresh before the reader.
    func testClaudeForceRerunsSingleCommand() async throws {
        let clock = MutableClock(fetchedAt)
        let runner = StubRunner(stdout: Data(Self.claudeUsage.utf8))
        let store = UsageStore(runner: runner.run, now: { clock.date })

        let forced = try await store.reading(.claude, on: .local, force: true)
        XCTAssertEqual(runner.commands, [UsageSource.claudeUsageCommand])
        XCTAssertEqual(forced.readings.first?.windows.first?.remaining, 85)

        runner.reset()
        clock.advance(301)
        let plain = try await store.reading(.claude, on: .local)
        XCTAssertEqual(runner.commands, [UsageSource.claudeUsageCommand])
        XCTAssertEqual(plain.readings.first?.windows.first?.remaining, 85)
    }

    // MARK: - Fixtures

    /// Codex's normalized record with one 5-hour window at 80% left.
    private static let codexRecord = #"""
    {"installed": true, "windows": [{"used_percent": 20, "window_minutes": 300}], "tokens": null}
    """#

    /// `claude -p /usage`'s stdout: the session window at 15% used.
    private static let claudeUsage = """
        Current session: 15% used · resets Oct 13 at 3:09pm (Europe/Warsaw)
        """
}

/// A mutable clock the store reads through, advanced by tests instead of
/// waiting real TTLs out.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var date: Date {
        lock.withLock { current }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Records every command the store runs, replaying queued failures and
/// pausing `pause` seconds per run so a second reader can arrive mid-run.
private final class StubRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var ran: [String] = []
    private var failures: [Error]
    private let stdout: Data
    private let pause: TimeInterval

    init(stdout: Data, pause: TimeInterval = 0, failures: [Error] = []) {
        self.stdout = stdout
        self.pause = pause
        self.failures = failures
    }

    var commands: [String] {
        lock.withLock { ran }
    }

    var callCount: Int {
        lock.withLock { ran.count }
    }

    func reset() {
        lock.withLock { ran = [] }
    }

    func run(_ command: String, device: Device) async throws -> Data {
        let failure: Error? = lock.withLock {
            ran.append(command)
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        if let failure { throw failure }
        if pause > 0 {
            try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
        }
        return stdout
    }
}
