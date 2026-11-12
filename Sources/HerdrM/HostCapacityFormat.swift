import Foundation
import HerdrKit

/// Words for `HostCapacity`: the sidebar's warning, the panel's line and the
/// New Agent confirmation all say the same thing.
enum HostCapacityFormat {
    static func reason(_ reason: HostCapacity.Reason) -> String {
        switch reason {
        case let .agentsMemory(used, limit):
            return String(localized: "agents use \(MachineStatsFormat.bytes(used)) of their \(MachineStatsFormat.bytes(limit)) cap")
        case let .lowMemory(available):
            return String(localized: "\(MachineStatsFormat.bytes(available)) of RAM free")
        case let .swap(used, total):
            return String(localized: "swap \(MachineStatsFormat.bytes(used)) of \(MachineStatsFormat.bytes(total))")
        case let .load(perCPU):
            return String(localized: "load \(String(format: "%.1f", perCPU)) per CPU")
        }
    }

    /// `Full: agents use 31 GB of their 32 GB cap · swap 10 GB of 15 GB`.
    static func reasons(_ capacity: HostCapacity) -> String {
        let list = capacity.reasons.map(reason).joined(separator: " · ")
        switch capacity.level {
        case .critical: return String(localized: "Full: \(list)")
        case .busy: return String(localized: "Busy: \(list)")
        case .ok: return list
        }
    }

    static func summary(_ capacity: HostCapacity, device: String) -> String {
        String(localized: "\(device) has no room for another agent: \(capacity.reasons.map(reason).joined(separator: ", ")).")
    }

    static func levelHelp(_ level: HostCapacity.Level) -> String {
        switch level {
        case .critical:
            return String(localized: "A new agent or test run here is likely to be killed for memory.")
        case .busy:
            return String(localized: "Room is getting short. Run one test suite at a time.")
        case .ok:
            return ""
        }
    }
}
