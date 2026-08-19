import XCTest
@testable import HerdrKit

/// Integration tests against the real local herdr server.
/// Skipped when no local herdr socket exists.
final class LocalSocketTests: XCTestCase {
    private var socketPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/herdr/herdr.sock")
    }

    private func requireLocalHerdr() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: socketPath),
            "no local herdr server running"
        )
    }

    func testPingReportsCompatibleProtocol() async throws {
        try requireLocalHerdr()
        let rpc = SocketRPC(socketPath: socketPath)
        let pong = try await rpc.request(method: "ping", params: .object([:]), as: PingResult.self)
        XCTAssertGreaterThanOrEqual(pong.protocolVersion, HerdrService.minimumProtocolVersion)
        XCTAssertFalse(pong.version.isEmpty)
    }

    func testServiceConnectSnapshotAndLists() async throws {
        try requireLocalHerdr()
        let service = HerdrService(device: .local, autoStartLocalServer: false)
        _ = try await service.connect()

        let snapshot = try await service.snapshot()
        let agents = try await service.agents()
        let workspaces = try await service.workspaces()

        // snapshot and dedicated list endpoints must agree
        XCTAssertEqual(Set(snapshot.agents.map(\.paneID)), Set(agents.map(\.paneID)))
        XCTAssertEqual(Set(snapshot.workspaces.map(\.workspaceID)), Set(workspaces.map(\.workspaceID)))
        // every agent belongs to a listed workspace
        let workspaceIDs = Set(workspaces.map(\.workspaceID))
        for agent in agents {
            XCTAssertTrue(workspaceIDs.contains(agent.workspaceID), "agent \(agent.paneID) has unknown workspace")
        }
    }

    func testUnknownMethodSurfacesRPCError() async throws {
        try requireLocalHerdr()
        let rpc = SocketRPC(socketPath: socketPath)
        do {
            _ = try await rpc.request(method: "definitely.not.a.method")
            XCTFail("expected an RPC error")
        } catch let HerdrError.rpc(code, _) {
            XCTAssertFalse(code.isEmpty)
        }
    }

    func testStatusSortBuckets() {
        XCTAssertLessThan(AgentStatus.blocked.sortBucket, AgentStatus.done.sortBucket)
        XCTAssertLessThan(AgentStatus.done.sortBucket, AgentStatus.working.sortBucket)
        XCTAssertLessThan(AgentStatus.working.sortBucket, AgentStatus.idle.sortBucket)
        XCTAssertEqual(AgentStatus(wire: "nonsense"), .unknown)
        XCTAssertEqual(AgentStatus(wire: nil), .unknown)
    }

    func testOnlyPaneBusyErrorsAreRetryable() {
        XCTAssertTrue(HerdrService.isPaneBusy(.rpc(code: "agent_pane_busy", message: "busy")))
        XCTAssertFalse(HerdrService.isPaneBusy(.rpc(code: "agent_name_taken", message: "taken")))
        XCTAssertFalse(HerdrService.isPaneBusy(.rpc(code: "agent_pane_unavailable", message: "gone")))
        XCTAssertFalse(HerdrService.isPaneBusy(.connectionFailed("dropped")))
    }

    func testShellInitializationProcessInfoRequiresThePaneShellInForeground() {
        let initializing: JSONValue = .object([
            "shell_pid": .number(42),
            "foreground_process_group_id": .number(42),
            "foreground_processes": .array([
                .object([
                    "pid": .number(42),
                    "name": .string("-zsh"),
                    "argv": .array([.string("/bin/zsh")]),
                ]),
            ]),
        ])
        XCTAssertTrue(HerdrService.processInfoShowsShellInitialization(initializing))

        let busy: JSONValue = .object([
            "shell_pid": .number(42),
            "foreground_process_group_id": .number(99),
            "foreground_processes": .array([
                .object(["pid": .number(99), "name": .string("vim")]),
            ]),
        ])
        XCTAssertFalse(HerdrService.processInfoShowsShellInitialization(busy))

        let replacedShell: JSONValue = .object([
            "shell_pid": .number(42),
            "foreground_process_group_id": .number(42),
            "foreground_processes": .array([
                .object(["pid": .number(42), "name": .string("opencode")]),
            ]),
        ])
        XCTAssertFalse(HerdrService.processInfoShowsShellInitialization(replacedShell))
    }

    func testEventStreamDeliversTabLifecycle() async throws {
        try requireLocalHerdr()
        let service = HerdrService(device: .local, autoStartLocalServer: false)
        _ = try await service.connect()
        let stream = try await service.events()

        // Create and close a tab; expect at least one pane/tab event to arrive.
        let collector = Task { () -> [String] in
            var kinds: [String] = []
            for try await event in stream {
                kinds.append(event.kind)
                if kinds.count >= 2 { break }
            }
            return kinds
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let paneID = try await service.createTab(workspaceID: nil, cwd: nil, label: "herdrm-test")
        try await Task.sleep(nanoseconds: 300_000_000)
        try await service.closePane(paneID: paneID)

        let result = try await withTimeout(seconds: 10) { try await collector.value }
        XCTAssertFalse(result.isEmpty, "no events received for tab lifecycle")
    }
}

func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw HerdrError.connectionFailed("timed out after \(seconds)s")
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
