import HerdrKit
import SwiftUI

/// Per-device provider usage states behind the usage sheet (Task 5) and the
/// sidebar hint (Task 6). One refresh fans a device's four provider reads
/// out over a task group; a failed run — device offline, timeout, tailcat
/// refusal — becomes that provider's `.failed` state, so one stuck agent
/// never takes the sheet down. `.failed` only ever comes from a thrown
/// error: a successful run that decodes to nothing lands as `.unknown`.
@MainActor
final class UsageModel: ObservableObject {
    /// Where each provider's last reading on each device stands.
    @Published private(set) var states: [UUID: [UsageProvider: UsageProviderState]] = [:]

    /// The last history chart per device, nil until its first read lands
    /// (and after a first read that failed outright).
    @Published private(set) var histories: [UUID: UsageHistory] = [:]

    /// The process-wide store: its five-minute cache and single-flight runs
    /// survive sheet reopenings, so re-presenting a device inside the window
    /// re-runs nothing.
    private let store = UsageStore.shared

    /// Reads every provider on `device`, in parallel. `force` re-runs the
    /// commands even when the store's cache is fresh (the sheet's refresh
    /// button). Never throws: a failed run becomes that provider's `.failed`
    /// state.
    func refresh(_ device: Device, force: Bool = false) async {
        // A refresh keeps the last readings standing — only never-read
        // providers show loading. Wiping what's known for a spinner is the
        // thing the sheet must never do: the data stays, freshness rides on
        // the per-card age line and the footer's corner spinner.
        let previous = states[device.id] ?? [:]
        states[device.id] = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map { provider in
                (provider, previous[provider] ?? UsageProviderState.loading)
            }
        )
        let store = store
        await withTaskGroup(of: (UsageProvider, UsageProviderState).self) { group in
            for provider in UsageProvider.allCases {
                group.addTask {
                    do {
                        let result = try await store.reading(provider, on: device, force: force)
                        let state = UsageProviderState(
                            parse: result,
                            fetchedAt: result.readings.first?.fetchedAt ?? Date())
                        return (provider, state)
                    } catch is CancellationError {
                        // A cancelled read means the sheet closed or the run was
                        // superseded — nothing went wrong with the provider, so
                        // no failure is written; the state stands as seeded.
                        return (provider, .loading)
                    } catch {
                        let reason = String(
                            localized: "Couldn't check \(provider.rawValue) usage: \(error.localizedDescription)")
                        return (provider, UsageProviderState.failed(reason))
                    }
                }
            }
            for await (provider, state) in group {
                states[device.id]?[provider] = state
            }
        }
    }

    /// Test seam for the sheet's UIUX tests: preloads one device's states the
    /// way a finished refresh would leave them, without running the store.
    /// Production code never calls this — states otherwise change only
    /// through `refresh`.
    func preload(_ device: Device, _ states: [UsageProvider: UsageProviderState]) {
        self.states[device.id] = states
    }

    /// Reads `device`'s merged 30-day history through the store's
    /// `"history:{device}"` key (five-minute TTL, single-flight, no forced
    /// variant). Never throws: a failed run — device offline, every command
    /// short — leaves the last history standing, stale but honest about its
    /// age.
    func refreshHistory(_ device: Device) async {
        guard let history = try? await store.history(on: device) else { return }
        histories[device.id] = history
    }

    /// Test seam for the sheet's history UIUX tests, mirroring `preload`:
    /// parks a history as a finished `refreshHistory` would leave it.
    /// Production code never calls this.
    func preloadHistory(_ device: Device, _ history: UsageHistory) {
        histories[device.id] = history
    }
}

extension UsageStore {
    /// One store for the app's lifetime. The model builds one per sheet
    /// presentation, but the cache and in-flight fold they share live here.
    static let shared = UsageStore()
}

/// The compact token form everywhere usage shows a number: `943`, `12k`,
/// `1.2M`, `3.4G`, `5.6T`, `7.8P` — never scientific notation, trailing
/// `.0` trimmed, lowercase `k` per the user's convention.
enum UsageFormat {
    private static let tiers: [(Double, String)] = [
        (1_000_000_000_000_000, "P"),
        (1_000_000_000_000, "T"),
        (1_000_000_000, "G"),
        (1_000_000, "M"),
        (1_000, "k"),
    ]

    static func compact(_ n: Int) -> String {
        let value = Double(n)
        for (factor, suffix) in tiers where value >= factor {
            let scaled = value / factor
            var text = String(format: scaled >= 100 ? "%.0f" : "%.1f", scaled)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + suffix
        }
        return "\(n)"
    }
}

extension UsageProviderState {
    /// The line the sheet shows for every state besides readings; `nil`
    /// when there are readings to render instead. A `.failed` state already
    /// carries its localized reason.
    var statusText: String? {
        switch self {
        case .loading:
            return String(localized: "Checking usage…")
        case .notInstalled:
            return String(localized: "Not installed")
        case .unknown:
            return String(localized: "No usage yet")
        case .failed(let message):
            return message
        case .readings:
            return nil
        }
    }
}
