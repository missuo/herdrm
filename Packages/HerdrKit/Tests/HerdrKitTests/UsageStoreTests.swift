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
        let codexCommand = UsageSource.command(for: .codex)

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
        XCTAssertEqual(runner.commands, [UsageSource.command(for: .claude)])
        XCTAssertEqual(forced.readings.first?.windows.first?.remaining, 85)

        runner.reset()
        clock.advance(301)
        let plain = try await store.reading(.claude, on: .local)
        XCTAssertEqual(runner.commands, [UsageSource.command(for: .claude)])
        XCTAssertEqual(plain.readings.first?.windows.first?.remaining, 85)
    }

    /// Each run gets its provider's own bounded timeout.
    func testRunnerGetsProviderTimeout() async throws {
        let runner = StubRunner(stdout: Data(Self.claudeUsage.utf8))
        let store = UsageStore(runner: runner.run, now: { self.fetchedAt })

        _ = try await store.reading(.claude, on: .local)
        XCTAssertEqual(runner.timeouts, [UsageSource.timeout(for: .claude)])
    }

    // MARK: - Force

    /// A forced read while fresh re-runs; a forced read arriving while a
    /// read is under way joins it instead of starting a second run, and the
    /// shared result stays cached for the next plain read.
    func testForcedReadJoinsInFlightRunAndKeepsCache() async throws {
        let clock = MutableClock(fetchedAt)
        let runner = StubRunner(stdout: Data(Self.codexRecord.utf8), pause: 0.2)
        let store = UsageStore(runner: runner.run, now: { clock.date })

        async let plain = store.reading(.codex, on: .local)
        try await Task.sleep(nanoseconds: 50_000_000)
        async let forced = store.reading(.codex, on: .local, force: true)
        let (a, b) = try await (plain, forced)
        XCTAssertEqual(a, b)
        XCTAssertEqual(runner.callCount, 1, "the forced read joins the run under way")

        _ = try await store.reading(.codex, on: .local)
        XCTAssertEqual(runner.callCount, 1, "the joined result is cached")

        _ = try await store.reading(.codex, on: .local, force: true)
        XCTAssertEqual(runner.callCount, 2, "force re-runs over a fresh cache")
    }

    // MARK: - Deadline

    /// A run that never returns (a read blocked on a held pipe) cannot
    /// wedge the provider: the read fails at the store's deadline, and the
    /// next read starts a new run instead of waiting on the stuck one.
    func testStuckRunHitsDeadlineAndNextReadRetries() async throws {
        let runner = StubRunner(stdout: Data(Self.codexRecord.utf8))
        runner.hangFirst(1, for: 10)
        let store = UsageStore(runner: runner.run, now: { self.fetchedAt }, deadline: 0.3)

        let started = Date()
        do {
            _ = try await store.reading(.codex, on: .local)
            XCTFail("a stuck run must fail at the deadline")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        let retried = try await store.reading(.codex, on: .local)
        XCTAssertEqual(runner.callCount, 2)
        XCTAssertEqual(retried.readings.first?.windows.first?.remaining, 80)
    }

    /// Concurrent readers of a stuck run are released at the deadline too.
    func testWaitersOnStuckRunAreReleasedAtDeadline() async throws {
        let runner = StubRunner(stdout: Data(Self.codexRecord.utf8))
        runner.hangFirst(1, for: 10)
        let store = UsageStore(runner: runner.run, now: { self.fetchedAt }, deadline: 0.3)

        let started = Date()
        async let first: UsageParseResult? = try? store.reading(.codex, on: .local)
        async let second: UsageParseResult? = try? store.reading(.codex, on: .local)
        let (a, b) = await (first, second)
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(runner.callCount, 1)
    }

    // MARK: - Device runner

    /// The real runner returns at its timeout even when the command's child
    /// outlives the shell and holds stdout open — the case that used to
    /// leave `readDataToEndOfFile` (and the provider) waiting forever.
    func testDeviceRunnerReturnsWhenChildHoldsPipe() async throws {
        try await assertTimesOut("sleep 30 & wait")
    }

    /// The same with a shell and child that both ignore SIGTERM.
    func testDeviceRunnerReturnsWhenChildIgnoresTerm() async throws {
        try await assertTimesOut("trap '' TERM; sleep 30 & wait")
    }

    /// `DeviceFileService.run` itself no longer hangs on a held pipe: the
    /// timeout signals the command's whole process group.
    func testPlainRunReturnsWhenChildIgnoresTerm() async throws {
        let started = Date()
        do {
            _ = try await DeviceFileService(device: .local).run("trap '' TERM; sleep 30 & wait", timeout: 1)
            XCTFail("the run must time out")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 9)
    }

    private func assertTimesOut(_ command: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let started = Date()
        do {
            _ = try await UsageStore.runOnDevice(command, on: .local, timeout: 1)
            XCTFail("the run must time out", file: file, line: line)
        } catch {
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)", file: file, line: line)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 9, file: file, line: line)
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
    private var given: [TimeInterval] = []
    private var hangs = 0
    private var hangSeconds: TimeInterval = 0
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

    var timeouts: [TimeInterval] {
        lock.withLock { given }
    }

    /// The first `count` runs hang for `seconds` and ignore cancellation,
    /// the way a run blocked reading a held pipe did.
    func hangFirst(_ count: Int, for seconds: TimeInterval) {
        lock.withLock {
            hangs = count
            hangSeconds = seconds
        }
    }

    func run(_ command: String, device: Device, timeout: TimeInterval) async throws -> Data {
        let (failure, hang): (Error?, TimeInterval?) = lock.withLock {
            ran.append(command)
            given.append(timeout)
            let failure = failures.isEmpty ? nil : failures.removeFirst()
            guard hangs > 0 else { return (failure, nil) }
            hangs -= 1
            return (failure, hangSeconds)
        }
        if let failure { throw failure }
        if let hang {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + hang) { continuation.resume() }
            }
        }
        if pause > 0 {
            try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
        }
        return stdout
    }
}
