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

    /// The history cache and in-flight share: one device's merged history,
    /// namespaced apart from the per-provider reading keys.
    private static func historyKey(on device: Device) -> Key {
        "history:\(device.id)"
    }

    private let runner: @Sendable (String, Device) async throws -> Data
    private let now: @Sendable () -> Date

    /// Fresh readings by key, stamped with when they were fetched.
    private var cache: [Key: (at: Date, result: UsageParseResult)] = [:]
    /// Reads under way by key, whose result concurrent readers share.
    private var inFlight: [Key: Task<UsageParseResult, Error>] = [:]
    /// Fresh histories by key, stamped with when they were generated.
    private var historyCache: [Key: (at: Date, result: UsageHistory)] = [:]
    /// History reads under way by key, shared like the reading ones.
    private var historyInFlight: [Key: Task<UsageHistory, Error>] = [:]

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
    /// shared run otherwise. `force` re-runs the command even when fresh
    /// (the sheet's refresh button).
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
            commands = [UsageSource.claudeUsageCommand]
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

    // MARK: - History

    /// `device`'s 30-day usage history: every provider that keeps
    /// transcripts runs its own aggregation command (gemini has none) and
    /// the parsed histories merge — days by date, per-model totals side by
    /// side. Cached for the same five minutes and shared while under way
    /// like a reading; there is no forced variant, plain TTL semantics
    /// only. Throws when every command failed; a partial failure caches
    /// what succeeded.
    public func history(on device: Device) async throws -> UsageHistory {
        let key = Self.historyKey(on: device)
        if let entry = historyCache[key], now().timeIntervalSince(entry.at) < Self.ttl {
            return entry.result
        }
        if let running = historyInFlight[key] {
            return try await running.value
        }
        let task = Task<UsageHistory, Error> {
            try await self.readFreshHistory(on: device, key: key)
        }
        historyInFlight[key] = task
        return try await task.value
    }

    /// Runs every provider's history command now, in parallel, and merges
    /// the parses into one history under the key.
    private func readFreshHistory(on device: Device, key: Key) async throws -> UsageHistory {
        defer { historyInFlight[key] = nil }
        let stamp = now()
        let members = await withTaskGroup(of: Member.self) { group in
            for provider in UsageProvider.allCases {
                // Gemini keeps no transcripts; there is no command to run.
                guard let command = UsageHistorySource.command(for: provider) else { continue }
                group.addTask {
                    do {
                        let stdout = try await self.runner(command, device)
                        return Member(
                            provider: provider,
                            outcome: .success(UsageHistorySource.parse(provider, stdout: stdout, fetchedAt: stamp)))
                    } catch {
                        return Member(provider: provider, outcome: .failure(Failure(reason: error.localizedDescription)))
                    }
                }
            }
            var out: [Member] = []
            for await member in group { out.append(member) }
            return out
        }

        var dayTokens: [Date: [UsageProvider: UsageTokens]] = [:]
        var modelTotals: [UsageProvider: [String: UsageTokens]] = [:]
        var failures: [String] = []
        var ran = false
        for member in members {
            switch member.outcome {
            case .failure(let failure):
                failures.append(failure.reason)
            case .success(let history?):
                ran = true
                for day in history.days {
                    dayTokens[day.date, default: [:]].merge(day.tokens) { _, new in new }
                }
                modelTotals[member.provider] = history.modelTotals[member.provider] ?? [:]
            case .success(nil):
                // The command ran but printed nothing usable (an absent
                // CLI's envelope, say): a valid empty contribution.
                ran = true
            }
        }
        guard ran || failures.isEmpty else {
            historyCache[key] = nil
            throw HerdrError.malformedResponse("no history source on \(device.name) succeeded: \(failures.joined(separator: "; "))")
        }
        var sessions: [UsageSession] = []
        for member in members {
            guard case .success(let history?) = member.outcome else { continue }
            sessions.append(contentsOf: history.sessions)
        }
        sessions.sort { $0.created > $1.created }
        let history = UsageHistory(
            days: dayTokens
                .map { UsageDay(date: $0.key, tokens: $0.value) }
                .sorted { $0.date < $1.date },
            modelTotals: modelTotals,
            sessions: Array(sessions.prefix(400)),
            generatedAt: stamp)
        historyCache[key] = (stamp, history)
        return history
    }

    /// One provider's contribution to a merged history: a parse (nil when
    /// the output was nothing usable) or the reason its command failed.
    private struct Member: Sendable {
        let provider: UsageProvider
        let outcome: Result<UsageHistory?, Failure>
    }

    /// Why one provider's history command failed — Sendable, so the
    /// parallel aggregation can carry it out of the task group.
    private struct Failure: Error, Sendable {
        let reason: String
    }
}
#endif
