#if os(macOS)
import Foundation

/// Caches each provider's parsed usage per device for five minutes and
/// folds concurrent reads of the same provider into one command run, so
/// callers can refresh freely without hammering the device. Parsing stays
/// in `UsageSource`; the store owns only caching, concurrency and the
/// deadline that keeps one stuck run from wedging a provider.
public actor UsageStore {
    /// How long a reading stays fresh.
    private static let ttl: TimeInterval = 300

    /// How far past its command timeout a run may go before the store gives
    /// up on it: the runner's own kill and output grace come first.
    private static let deadlineSlack: TimeInterval = 15

    /// The identity cache and in-flight share: one device, one provider.
    private typealias Key = String

    private static func key(_ provider: UsageProvider, on device: Device) -> Key {
        "\(device.id):\(provider.rawValue)"
    }

    /// One run under way. `id` lets only the read that started it clear it.
    private struct Flight {
        let id: UUID
        let task: Task<(at: Date, result: UsageParseResult), Error>
    }

    private let runner: @Sendable (String, Device, TimeInterval) async throws -> Data
    private let now: @Sendable () -> Date
    private let deadline: TimeInterval?

    /// Fresh readings by key, stamped with when they were fetched.
    private var cache: [Key: (at: Date, result: UsageParseResult)] = [:]
    /// Reads under way by key, whose result concurrent readers share.
    private var inFlight: [Key: Flight] = [:]

    /// `runner` runs a command on a device within the given timeout;
    /// `deadline` overrides the store's own bound on one run (the
    /// provider's command timeout plus slack), for tests.
    public init(
        runner: @escaping @Sendable (String, Device, TimeInterval) async throws -> Data = {
            try await UsageStore.runOnDevice($0, on: $1, timeout: $2)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        deadline: TimeInterval? = nil
    ) {
        self.runner = runner
        self.now = now
        self.deadline = deadline
    }

    /// `provider`'s readings on `device`: from the cache while fresh, one
    /// shared run otherwise. `force` skips the cache (the refresh button);
    /// a run already under way is joined either way, its result is fresh.
    public func reading(
        _ provider: UsageProvider, on device: Device, force: Bool = false
    ) async throws -> UsageParseResult {
        let key = Self.key(provider, on: device)
        if !force, let entry = cache[key], now().timeIntervalSince(entry.at) < Self.ttl {
            return entry.result
        }
        if let running = inFlight[key] {
            return try await running.task.value.result
        }
        let flight = Flight(id: UUID(), task: Task { [runner, now] in
            try await Self.withDeadline(self.deadline ?? UsageSource.timeout(for: provider) + Self.deadlineSlack) {
                try await Self.fetch(provider, on: device, runner: runner, now: now)
            }
        })
        inFlight[key] = flight
        defer {
            if inFlight[key]?.id == flight.id { inFlight[key] = nil }
        }
        do {
            let fetched = try await flight.task.value
            cache[key] = fetched
            return fetched.result
        } catch {
            cache[key] = nil
            throw error
        }
    }

    /// Runs `provider`'s command once and parses it; touches no store state,
    /// so a run abandoned at the deadline can finish harmlessly.
    private static func fetch(
        _ provider: UsageProvider, on device: Device,
        runner: @Sendable (String, Device, TimeInterval) async throws -> Data,
        now: @Sendable () -> Date
    ) async throws -> (at: Date, result: UsageParseResult) {
        let stdout = try await runner(UsageSource.command(for: provider), device, UsageSource.timeout(for: provider))
        let fetchedAt = now()
        guard let result = UsageSource.parse(provider, stdout: stdout, fetchedAt: fetchedAt) else {
            throw HerdrError.malformedResponse("\(provider.rawValue) printed no usable usage")
        }
        return (fetchedAt, result)
    }

    /// The default runner: `runCollecting`, whose output read is bounded,
    /// so a child that outlives the killed shell and keeps stdout open
    /// cannot hold the read past the timeout.
    public static func runOnDevice(_ command: String, on device: Device, timeout: TimeInterval) async throws -> Data {
        let output = try await DeviceFileService(device: device).runCollecting(command, timeout: timeout)
        if output.timedOut {
            throw HerdrError.fileOperationFailed("usage command timed out after \(Int(timeout)) s")
        }
        if let status = output.exitStatus, status != 0 {
            let detail = String(decoding: output.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrError.fileOperationFailed(
                detail.isEmpty ? "usage command exited \(status)" : String(detail.suffix(300)))
        }
        return output.stdout
    }

    /// `operation`'s result, or a timeout error once `seconds` pass —
    /// whichever comes first. Unlike a task group this never waits for an
    /// operation that ignores cancellation; it is cancelled and left behind.
    private static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = DeadlineGate<T>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.arm(continuation)
            let work = Task {
                do { gate.finish(.success(try await operation())) } catch { gate.finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                let message = "usage read gave no answer within \(Int(seconds.rounded())) s"
                if gate.finish(.failure(HerdrError.fileOperationFailed(message))) { work.cancel() }
            }
        }
    }
}

/// Resumes a continuation exactly once, from whichever side gets there first.
private final class DeadlineGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func arm(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
        return pending != nil
    }
}
#endif
