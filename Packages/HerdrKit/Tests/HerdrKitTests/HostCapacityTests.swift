import XCTest
@testable import HerdrKit

/// The levels `cloud-dev-load` computes on the dev boxes, so HerdrM and the agents
/// there agree on when a host is too full for another agent.
final class HostCapacityTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    private func snapshot(
        os: String = "Linux",
        available: UInt64,
        total: UInt64 = 62 << 30,
        swapUsed: UInt64 = 0,
        swapTotal: UInt64 = 16 << 30,
        agents: (UInt64, UInt64)? = nil,
        load: Double = 1,
        cpus: Int = 8
    ) -> MachineSnapshot {
        MachineSnapshot(
            os: os, host: "cloud-dev2", cpuCount: cpus, uptime: nil, load: [load, load, load],
            cpuPercent: nil, memUsedBytes: total - available, memTotalBytes: total,
            swapUsedBytes: swapUsed, swapTotalBytes: swapTotal,
            agentsMemBytes: agents?.0, agentsMemLimitBytes: agents?.1,
            disks: [], groups: [], mcpServers: [],
            other: ProcessUsage(id: "other", name: "other", cpuPercent: 0, rssBytes: 0, processCount: 0),
            topOther: []
        )
    }

    /// A small host is not "full" just for being small: on a 4 GB box, 1.5 GB free is fine.
    func testSmallHostScalesTheMemoryLines() throws {
        let fine = try XCTUnwrap(snapshot(available: 1536 << 20, total: 4 * gib, swapTotal: 0).capacity)
        XCTAssertEqual(fine.level, .ok)
        let tight = try XCTUnwrap(snapshot(available: 300 << 20, total: 4 * gib, swapTotal: 0).capacity)
        XCTAssertEqual(tight.level, .critical)
        XCTAssertEqual(tight.reasons, [.lowMemory(available: 300 << 20)])
    }

    /// Big hosts keep the fixed 6 / 10 GiB lines.
    func testBigHostKeepsTheFixedMemoryLines() throws {
        XCTAssertEqual(try XCTUnwrap(snapshot(available: 5 * gib).capacity).level, .critical)
        XCTAssertEqual(try XCTUnwrap(snapshot(available: 8 * gib).capacity).level, .busy)
    }

    func testIdleHostIsOK() throws {
        let capacity = try XCTUnwrap(snapshot(available: 40 * gib, agents: (4 * gib, 32 * gib)).capacity)
        XCTAssertEqual(capacity.level, .ok)
        XCTAssertEqual(capacity.reasons, [])
    }

    /// The 2026-10-18 case: herdr's panes at 31 of 32 GB, plenty of RAM left box-wide.
    func testAgentsNearTheirCapIsCritical() throws {
        let capacity = try XCTUnwrap(snapshot(available: 25 * gib, agents: (31 * gib, 32 * gib)).capacity)
        XCTAssertEqual(capacity.level, .critical)
        XCTAssertEqual(capacity.reasons, [.agentsMemory(used: 31 * gib, limit: 32 * gib)])
    }

    func testAgentsPastSeventyPercentIsBusy() throws {
        XCTAssertEqual(snapshot(available: 40 * gib, agents: (24 * gib, 32 * gib)).capacity?.level, .busy)
    }

    func testLowMemoryLevels() {
        XCTAssertEqual(snapshot(available: 5 * gib).capacity?.level, .critical)
        XCTAssertEqual(snapshot(available: 8 * gib).capacity?.level, .busy)
    }

    /// cloud-dev's usual state: swap two-thirds full, 23 GB free — busy, not critical.
    func testSwapIsCriticalOnlyWhileRAMIsShort() {
        let swapped = snapshot(available: 23 * gib, swapUsed: 10 * gib, swapTotal: 15 * gib)
        XCTAssertEqual(swapped.capacity?.level, .busy)
        let short = snapshot(available: 8 * gib, swapUsed: 10 * gib, swapTotal: 15 * gib)
        XCTAssertEqual(short.capacity?.level, .critical)
    }

    func testLoadAloneNeverMakesAHostCritical() {
        XCTAssertEqual(snapshot(available: 40 * gib, load: 40).capacity?.level, .busy)
    }

    func testCriticalReasonsComeFirst() throws {
        let capacity = try XCTUnwrap(snapshot(available: 8 * gib, agents: (31 * gib, 32 * gib)).capacity)
        XCTAssertEqual(capacity.reasons.first, .agentsMemory(used: 31 * gib, limit: 32 * gib))
        XCTAssertEqual(capacity.reasons.last, .lowMemory(available: 8 * gib))
    }

    func testNotComputedOffLinux() {
        XCTAssertNil(snapshot(os: "Darwin", available: 1 * gib).capacity)
    }
}
