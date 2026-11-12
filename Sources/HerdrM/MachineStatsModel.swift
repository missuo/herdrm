import Foundation
import HerdrKit

/// Live health of the host behind the selected pane, for the meters under the terminal.
/// Kept apart from `AppModel` so a sample every two seconds re-renders only
/// the meters and their panel, not the sidebar.
@MainActor
final class MachineStatsModel: ObservableObject {
    enum State: Equatable {
        case connecting
        case live
        case failed(String)
    }

    struct InstanceLabel: Equatable {
        let paneID: String
        let title: String
    }

    /// Two minutes of whole-machine CPU at the sampler's 2s tick.
    static let historyLength = 60

    @Published private(set) var deviceID: UUID?
    @Published private(set) var snapshot: MachineSnapshot?
    @Published private(set) var state: State = .connecting
    @Published private(set) var cpuHistory: [Double] = []
    /// Process ids of each agent pane on the watched device (`pane.process_info`).
    @Published private(set) var panePIDs: [String: Set<Int32>] = [:]

    #if DEBUG
    func _setSnapshotForTesting(_ snapshot: MachineSnapshot, device: Device) {
        deviceID = device.id
        apply(snapshot)
    }
    #endif

    /// Streams `device` until the calling task is cancelled (the indicator's
    /// `.task(id:)`), reconnecting with backoff when the sampler dies.
    func run(device: Device) async {
        if deviceID != device.id {
            deviceID = device.id
            snapshot = nil
            cpuHistory = []
            panePIDs = [:]
        }
        state = .connecting
        var backoff: Double = 1
        while !Task.isCancelled {
            do {
                for try await snapshot in MachineStatsStream.snapshots(device: device) {
                    apply(snapshot)
                    backoff = 1
                }
                // A clean exit is still the sampler going away; fall through to retry.
            } catch {
                if Task.isCancelled { break }
                state = .failed(error.localizedDescription)
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 30)
        }
    }

    private func apply(_ snapshot: MachineSnapshot) {
        self.snapshot = snapshot
        state = .live
        if let cpu = snapshot.cpuPercent {
            cpuHistory.append(cpu)
            if cpuHistory.count > Self.historyLength {
                cpuHistory.removeFirst(cpuHistory.count - Self.historyLength)
            }
        }
    }

    /// Asks herdr which processes belong to each agent pane, so instances can
    /// carry the sidebar's titles. Panes that fail to answer are skipped.
    func resolvePanes(service: HerdrService, deviceID: UUID, paneIDs: [String]) async {
        var resolved: [String: Set<Int32>] = [:]
        for paneID in paneIDs {
            if Task.isCancelled { return }
            if let pids = try? await service.paneProcessPIDs(paneID: paneID), !pids.isEmpty {
                resolved[paneID] = pids
            }
        }
        guard self.deviceID == deviceID else { return }
        panePIDs = resolved
    }

    /// The agent pane an instance runs in: the pane whose shell or foreground
    /// process sits on the instance's root or its parent chain.
    func paneID(for instance: AgentInstance) -> String? {
        let lineage = Set(instance.lineage)
        return panePIDs.first { !$0.value.isDisjoint(with: lineage) }?.key
    }
}

enum MachineStatsFormat {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? ""
    }
}
