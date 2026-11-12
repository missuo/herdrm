import Foundation
import HerdrKit
@testable import herdrm

/// Stands in for the device in usage tests: answers each provider's
/// command with canned stdout and records which providers were asked, so
/// no `claude`, codex scan or `opencode` ever runs on the test machine.
final class FakeUsageRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [UsageProvider] = []
    private let outputs: [UsageProvider: String]
    private let failing: Set<UsageProvider>

    /// Claude at 34% of its session and 12% of its week, Codex not
    /// installed, OpenCode with 1.2M tokens, Gemini not installed.
    static let defaultOutputs: [UsageProvider: String] = [
        .claude: "Current session: 34% used\nCurrent week (all models): 12% used\n",
        .codex: #"{"installed":false}"#,
        .opencode: #"{"tokens":{"input":1000000,"output":200000,"reasoning":0,"cache":{"read":0,"write":0}}}"#,
        .gemini: #"{"installed":false}"#,
    ]

    init(outputs: [UsageProvider: String] = FakeUsageRunner.defaultOutputs, failing: Set<UsageProvider> = []) {
        self.outputs = outputs
        self.failing = failing
    }

    /// Providers asked so far, in call order.
    var asked: [UsageProvider] {
        lock.withLock { calls }
    }

    func run(_ command: String, _ device: Device, _ timeout: TimeInterval) async throws -> Data {
        guard let provider = UsageProvider.allCases.first(where: { UsageSource.command(for: $0) == command }) else {
            throw HerdrError.fileOperationFailed("unexpected command")
        }
        lock.withLock { calls.append(provider) }
        if failing.contains(provider) {
            throw HerdrError.fileOperationFailed("\(provider.rawValue) offline")
        }
        return Data((outputs[provider] ?? "").utf8)
    }

    /// A store over this runner. `uncached` advances the store's clock a
    /// whole cache lifetime on every look, so each read runs the command.
    func store(uncached: Bool = false) -> UsageStore {
        let clock = Clock()
        return UsageStore(
            runner: { try await self.run($0, $1, $2) },
            now: { uncached ? clock.tick() : Date() })
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date()

        func tick() -> Date {
            lock.withLock {
                now = now.addingTimeInterval(UsageModel.refreshInterval + 1)
                return now
            }
        }
    }
}
