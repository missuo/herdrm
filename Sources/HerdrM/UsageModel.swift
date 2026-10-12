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

    /// The process-wide store: its five-minute cache and single-flight runs
    /// survive sheet reopenings, so re-presenting a device inside the window
    /// re-runs nothing.
    private let store = UsageStore.shared

    /// Reads every provider on `device`, in parallel. `force` re-runs the
    /// commands even when the store's cache is fresh (the sheet's refresh
    /// button, which on Claude also has grazr re-read its accounts). Never
    /// throws: a failed run becomes that provider's `.failed` state.
    func refresh(_ device: Device, force: Bool = false) async {
        states[device.id] = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map { ($0, UsageProviderState.loading) }
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
}

extension UsageStore {
    /// One store for the app's lifetime. The model builds one per sheet
    /// presentation, but the cache and in-flight fold they share live here.
    static let shared = UsageStore()
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
