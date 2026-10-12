#if os(macOS)
import Foundation

/// Caches each provider's parsed usage per device for five minutes and
/// folds concurrent reads of the same provider into one command run, so the
/// sidebar can refresh freely without hammering the device. Parsing stays
/// in `UsageSource`; the store owns only caching and concurrency.
public actor UsageStore {
    /// How long a reading stays fresh.
    private static let ttl: TimeInterval = 300

    /// The identity cache and in-flight share: one device, one provider.
    private typealias Key = String

    private static func key(_ provider: UsageProvider, on device: Device) -> Key {
        "\(device.id):\(provider.rawValue)"
    }

    private let runner: @Sendable (String, Device) async throws -> Data
    private let now: @Sendable () -> Date

    /// Fresh readings by key, stamped with when they were fetched.
    private var cache: [Key: (at: Date, result: UsageParseResult)] = [:]
    /// Reads under way by key, whose result concurrent readers share.
    private var inFlight: [Key: Task<UsageParseResult, Error>] = [:]

    public init(
        runner: @escaping (String, Device) async throws -> Data = {
            try await DeviceFileService(device: $1).run($0)
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.runner = runner
        self.now = now
    }

    /// `provider`'s readings on `device`: from the cache while fresh, one
    /// shared run otherwise. `force` re-runs even when fresh, and on Claude
    /// has grazr re-read its accounts before the reader runs.
    public func reading(
        _ provider: UsageProvider, on device: Device, force: Bool = false
    ) async throws -> UsageParseResult {
        let key = Self.key(provider, on: device)
        if !force, let entry = cache[key], now().timeIntervalSince(entry.at) < Self.ttl {
            return entry.result
        }
        if !force, let running = inFlight[key] {
            return try await running.value
        }
        let task = Task<UsageParseResult, Error> {
            try await self.readFresh(provider, on: device, key: key, force: force)
        }
        inFlight[key] = task
        return try await task.value
    }

    /// Runs the command(s) now and replaces the key's cache on success. A
    /// failed run clears the key, so the next read retries.
    private func readFresh(
        _ provider: UsageProvider, on device: Device, key: Key, force: Bool
    ) async throws -> UsageParseResult {
        defer { inFlight[key] = nil }
        let commands: [String]
        switch provider {
        case .claude:
            commands = force ? [Grazr.refreshCommand, Grazr.readerCommand] : [Grazr.readerCommand]
        default:
            guard let command = UsageSource.command(for: provider) else {
                throw HerdrError.malformedResponse("\(provider.rawValue) has no usage command")
            }
            commands = [command]
        }
        do {
            var stdout = Data()
            for command in commands {
                stdout = try await runner(command, device)
            }
            let fetchedAt = now()
            guard let result = UsageSource.parse(provider, stdout: stdout, fetchedAt: fetchedAt) else {
                throw HerdrError.malformedResponse("\(provider.rawValue) printed no usable usage")
            }
            cache[key] = (fetchedAt, result)
            return result
        } catch {
            cache[key] = nil
            throw error
        }
    }
}
#endif
