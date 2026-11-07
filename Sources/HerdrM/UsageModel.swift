import HerdrKit
import SwiftUI

/// Per-device provider usage states behind the sidebar's usage row. One
/// refresh fans the picked providers' reads on one device out over a task
/// group; a failed run — device offline, timeout, tailcat refusal — becomes
/// that provider's `.failed` state, so one stuck agent never blanks the
/// others. `.failed` only ever comes from a thrown error: a successful run
/// that decodes to nothing lands as `.unknown`.
@MainActor
final class UsageModel: ObservableObject {
    /// How often the row re-reads while it is on screen: the store's cache
    /// lifetime, so every tick runs the commands once and never faster.
    nonisolated static let refreshInterval: TimeInterval = 300

    /// Readings older than this are not shown: two missed refreshes (the
    /// window was hidden, the device went away) and the numbers are stale.
    nonisolated static let staleAfter: TimeInterval = 2 * refreshInterval

    /// Where each provider's last reading on each device stands.
    @Published private(set) var states: [UUID: [UsageProvider: UsageProviderState]] = [:]

    /// The store's five-minute cache and single-flight runs bound what a
    /// refresh costs. Tests pass a store with a fake runner, so no provider
    /// command runs on the test machine.
    private let store: UsageStore

    init(store: UsageStore = .shared) {
        self.store = store
    }

    /// Reads `providers` on `device` now, then again every `interval`
    /// until the calling task is cancelled (the row's `.task(id:)`: the row
    /// left the screen, the window was hidden, the device or the pick
    /// changed).
    func watch(_ device: Device, providers: [UsageProvider], every interval: TimeInterval = refreshInterval) async {
        while !Task.isCancelled {
            await refresh(device, providers: providers)
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
        }
    }

    /// Reads `providers` on `device`, in parallel. Never throws: a failed
    /// run becomes that provider's `.failed` state.
    func refresh(_ device: Device, providers: [UsageProvider]) async {
        // The last readings stay standing while the next one runs; only
        // never-read providers show loading.
        var seeded = states[device.id] ?? [:]
        for provider in providers where seeded[provider] == nil {
            seeded[provider] = .loading
        }
        states[device.id] = seeded
        let store = store
        await withTaskGroup(of: (UsageProvider, UsageProviderState?).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let result = try await store.reading(provider, on: device)
                        let state = UsageProviderState(
                            parse: result,
                            fetchedAt: result.readings.first?.fetchedAt ?? Date())
                        return (provider, state)
                    } catch is CancellationError {
                        // The row went away mid-read: nothing went wrong with
                        // the provider, so the last state stands.
                        return (provider, nil)
                    } catch {
                        return (provider, .failed(error.localizedDescription))
                    }
                }
            }
            for await (provider, state) in group {
                if let state { states[device.id]?[provider] = state }
            }
        }
    }

    /// Test seam: preloads one device's states the way a finished refresh
    /// would leave them, without running the store.
    func preload(_ device: Device, _ states: [UsageProvider: UsageProviderState]) {
        self.states[device.id] = states
    }
}

extension UsageStore {
    /// One store for the app's lifetime, so its cache and in-flight fold
    /// outlive the row's appearances.
    static let shared = UsageStore()
}

/// The usage row's settings: on/off (View ▸ Show Agent Usage) and which
/// agents it shows (View ▸ Agents in Usage Row).
enum UsageDefaults {
    static let showKey = "sidebar.showUsageStats"
    static let agentsKey = "usage.sidebarAgents"
    /// The window-bearing pair plus OpenCode's token total.
    static let defaultAgents = "claude,codex,opencode"

    /// The picked agents in canonical order; junk entries drop, and a list
    /// with nothing valid in it falls back to the default pick.
    static func providers(from raw: String) -> [UsageProvider] {
        let picked = Set(raw.split(separator: ",").map(String.init))
        let providers = UsageProvider.allCases.filter { picked.contains($0.rawValue) }
        return providers.isEmpty ? [.claude, .codex, .opencode] : providers
    }

    /// `raw` with `provider` toggled in or out, in canonical order.
    static func toggling(_ provider: UsageProvider, in raw: String) -> String {
        var picked = Set(providers(from: raw))
        if picked.contains(provider) { picked.remove(provider) } else { picked.insert(provider) }
        return UsageProvider.allCases.filter(picked.contains).map(\.rawValue).joined(separator: ",")
    }

    /// The agent's display name.
    static func name(_ provider: UsageProvider) -> String {
        switch provider {
        case .claude: return String(localized: "Claude")
        case .codex: return String(localized: "Codex")
        case .opencode: return String(localized: "OpenCode")
        case .gemini: return String(localized: "Gemini")
        }
    }
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
