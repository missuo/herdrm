import Foundation

/// How much room a host has for another agent. The levels and thresholds are the
/// ones the dev boxes' own `cloud-dev-load` computes for the agents running there
/// (imperum-v2 `.claude/hooks/cloud-dev-load`), so HerdrM and those agents agree on
/// when a box is too full. Linux only: it reads `MemAvailable` and herdr's cgroup.
///
/// The case it exists for: parallel test runs inside herdr panes on a dev VM filled
/// herdr's 32 GB cap and the kernel killed them (cloud-dev2, 2026-10-18).
public struct HostCapacity: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        case ok, busy, critical

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Why a host is not `ok`.
    public enum Reason: Sendable, Equatable {
        /// herdr's panes against herdr's memory cap.
        case agentsMemory(used: UInt64, limit: UInt64)
        case lowMemory(available: UInt64)
        case swap(used: UInt64, total: UInt64)
        /// The 1-minute load per CPU.
        case load(perCPU: Double)
    }

    public var level: Level
    /// The critical reasons first, then the busy ones.
    public var reasons: [Reason]

    static let criticalAvailableBytes: UInt64 = 6 << 30
    static let busyAvailableBytes: UInt64 = 10 << 30
    /// The fixed lines suit big dev VMs; on a small host (a 4 GB VPS, a Pi) free
    /// memory is always under 6 GiB, so the lines also scale down with total RAM.
    static let criticalAvailableFraction = 0.10
    static let busyAvailableFraction = 0.16

    static func availableThresholds(total: UInt64) -> (critical: UInt64, busy: UInt64) {
        (min(criticalAvailableBytes, UInt64(Double(total) * criticalAvailableFraction)),
         min(busyAvailableBytes, UInt64(Double(total) * busyAvailableFraction)))
    }
    /// Swap counts as critical only while RAM is also short: idle pages parked in
    /// swap are not pressure on their own.
    static let criticalSwap = 0.50
    static let busySwap = 0.25
    static let criticalAgents = 0.85
    static let busyAgents = 0.70
    /// Load alone never makes a host critical.
    static let busyLoadPerCPU = 1.5

    public init(level: Level, reasons: [Reason]) {
        self.level = level
        self.reasons = reasons
    }

    public init?(snapshot: MachineSnapshot) {
        guard snapshot.os == "Linux", snapshot.memTotalBytes > 0 else { return nil }
        var critical: [Reason] = []
        var busy: [Reason] = []

        if let used = snapshot.agentsMemBytes, let limit = snapshot.agentsMemLimitBytes, limit > 0 {
            let fraction = Double(used) / Double(limit)
            if fraction > Self.criticalAgents {
                critical.append(.agentsMemory(used: used, limit: limit))
            } else if fraction > Self.busyAgents {
                busy.append(.agentsMemory(used: used, limit: limit))
            }
        }

        let available = snapshot.memTotalBytes - min(snapshot.memTotalBytes, snapshot.memUsedBytes)
        let lines = Self.availableThresholds(total: snapshot.memTotalBytes)
        if available < lines.critical {
            critical.append(.lowMemory(available: available))
        } else if available < lines.busy {
            busy.append(.lowMemory(available: available))
        }

        if snapshot.swapTotalBytes > 0 {
            let swap = Double(snapshot.swapUsedBytes) / Double(snapshot.swapTotalBytes)
            let reason = Reason.swap(used: snapshot.swapUsedBytes, total: snapshot.swapTotalBytes)
            if swap > Self.criticalSwap, available < lines.busy {
                critical.append(reason)
            } else if swap > Self.busySwap {
                busy.append(reason)
            }
        }

        if let load = snapshot.load.first, snapshot.cpuCount > 0 {
            let perCPU = load / Double(snapshot.cpuCount)
            if perCPU > Self.busyLoadPerCPU { busy.append(.load(perCPU: perCPU)) }
        }

        level = !critical.isEmpty ? .critical : (!busy.isEmpty ? .busy : .ok)
        reasons = critical + busy
    }
}
