import Darwin
import Foundation
import HerdrKit
import XCTest
@testable import herdrm

@MainActor
final class AgentRefreshRetryTests: XCTestCase {
    func testDoneEventRetriesOneFailedSnapshotWithoutAnotherEvent() async throws {
        try await withFixture(failures: 1) { model, device, server, entry in
            self.completeAndSchedule(model, device: device, entry: entry)
            try await self.waitUntil { server.snapshotTimes.count == 1 }
            XCTAssertFalse(model.isUnread(entry), "The event alone cannot confirm a new completion")
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(server.snapshotTimes.count, 1, "A failed snapshot must not retry at the normal 200 ms event cadence")

            try await self.waitUntil(timeout: 4) { model.isUnread(entry) }
            XCTAssertTrue(model.isUnread(entry), "A successful retry must recover the completion without another event")
            XCTAssertEqual(server.snapshotTimes.count, 2)

            model.selectAgent(entry.ref)
            model.scheduleRefresh(device.id)
            try await self.waitUntil { server.snapshotTimes.count == 3 }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(model.isUnread(entry), "Re-reading the same completion must not recreate its acknowledged dot")
        }
    }

    func testRepeatedSnapshotFailuresUseSlowRetries() async throws {
        try await withFixture(failures: .max) { model, device, server, entry in
            self.completeAndSchedule(model, device: device, entry: entry)
            try await self.waitUntil(timeout: 4) { server.snapshotTimes.count >= 2 }
            let times = server.snapshotTimes
            XCTAssertGreaterThanOrEqual(times.count, 2, "A connected event stream must not leave the snapshot permanently stale")
            if times.count >= 2 {
                XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(times[0]), 1.5,
                                            "Repeated failures must wait for the slow retry, not spin every 200 ms")
            }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(server.snapshotTimes.count, 2)
            XCTAssertFalse(model.isUnread(entry))
        }
    }

    func testShutdownCancelsScheduledSnapshotRetry() async throws {
        try await withFixture(failures: 1) { model, device, server, entry in
            self.completeAndSchedule(model, device: device, entry: entry)
            try await self.waitUntil { server.snapshotTimes.count == 1 }
            try await Task.sleep(for: .milliseconds(150))
            await model.shutdownAllSessions()
            try await Task.sleep(for: .milliseconds(2400))
            XCTAssertEqual(server.snapshotTimes.count, 1, "Shutdown must cancel the queued retry")
            XCTAssertFalse(model.isUnread(entry))
        }
    }

    private func completeAndSchedule(_ model: AppModel, device: Device, entry: AppModel.AgentEntry) {
        let event = HerdrEvent(kind: HerdrEvent.agentStatusChangedKind, payload: .object([
            "data": .object(["pane_id": .string(entry.agent.paneID), "agent_status": .string("done")])
        ]))
        XCTAssertTrue(model.applyAgentStatusEvent(event, deviceID: device.id))
        // This is the production event loop's normal coalesced-refresh path.
        model.scheduleRefresh(device.id)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(predicate(), "The synthetic snapshot request did not reach the expected state")
    }

    private func withFixture(
        failures: Int,
        _ body: (AppModel, Device, SnapshotRetrySocket, AppModel.AgentEntry) async throws -> Void
    ) async throws {
        let savedSound = UserDefaults.standard.object(forKey: "notifications.sound")
        let savedNotifications = UserDefaults.standard.object(forKey: "notifications.enabled")
        UserDefaults.standard.set(false, forKey: "notifications.sound")
        UserDefaults.standard.set(false, forKey: "notifications.enabled")
        defer {
            UserDefaults.standard.set(savedSound, forKey: "notifications.sound")
            UserDefaults.standard.set(savedNotifications, forKey: "notifications.enabled")
        }
        let server = try SnapshotRetrySocket(failures: failures)
        let device = Device(name: "Snapshot retry fixture", kind: .local, socketPath: server.path)
        let suite = "AgentRefreshRetryTests.attention.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(attentionDefaults: defaults)
        model.devices = [device]
        model.deviceFilter = nil
        let working = try JSONDecoder().decode(AgentInfo.self, from: JSONSerialization.data(withJSONObject: [
            "terminal_id": "fixture-terminal", "agent": "codex", "agent_status": "working",
            "workspace_id": "fixture-space", "tab_id": "fixture-tab", "pane_id": "fixture-pane"
        ]))
        var state = DeviceSessionState()
        state.connection = .connected(version: "fixture")
        state.agents = [working]
        model.sessions[device.id] = state
        model.updateSnapshotAttention(agents: [working], deviceID: device.id)
        let entry = model.agentEntry(device: device, agent: working)
        do {
            _ = try await model.service(for: device).connect()
            try await body(model, device, server, entry)
        } catch {
            await model.shutdownAllSessions()
            server.stop()
            throw error
        }
        await model.shutdownAllSessions()
        server.stop()
    }
}

/// Same private Unix-socket approach as HerdrKit's PaneFixtureSocket: the
/// real HerdrService/SocketRPC decode the replies; no user's daemon is opened.
private final class SnapshotRetrySocket: @unchecked Sendable {
    let path = "/tmp/hretry-\(UUID().uuidString.prefix(8)).sock"
    private let listener: Int32
    private let lock = NSLock()
    private var remainingFailures: Int
    private var times: [Date] = []
    private var stopped = false
    var snapshotTimes: [Date] { lock.lock(); defer { lock.unlock() }; return times }

    init(failures: Int) throws {
        remainingFailures = failures
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HerdrError.connectionFailed("fixture socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            close(listener)
            throw HerdrError.connectionFailed("fixture bind")
        }
        let listening = listener
        Thread.detachNewThread { [weak self] in
            while true {
                let connection = accept(listening, nil, nil)
                guard connection >= 0 else { return }
                defer { close(connection) }
                var noSignal: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !data.contains(10) {
                    let count = read(connection, &buffer, buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let self else { continue }
                var response = self.reply(to: request)
                response["id"] = request["id"] ?? "fixture"
                guard var reply = try? JSONSerialization.data(withJSONObject: response) else { continue }
                reply.append(10)
                reply.withUnsafeBytes { bytes in _ = write(connection, bytes.baseAddress!, bytes.count) }
            }
        }
    }

    private func reply(to request: [String: Any]) -> [String: Any] {
        switch request["method"] as? String {
        case "ping":
            return ["result": ["version": "fixture", "protocol": 22]]
        case "session.snapshot":
            lock.lock()
            times.append(Date())
            let fail = remainingFailures > 0
            if fail { remainingFailures -= 1 }
            lock.unlock()
            if fail {
                return ["error": ["code": "fixture_snapshot_failed", "message": "synthetic snapshot failure"]]
            }
            let agent: [String: Any] = [
                "terminal_id": "fixture-terminal", "agent": "codex", "agent_status": "done",
                "workspace_id": "fixture-space", "tab_id": "fixture-tab", "pane_id": "fixture-pane",
                "completion_seq": 1
            ]
            // No workspace names: snapshot processing must not seed Recent launches.
            return ["result": ["snapshot": ["agents": [agent], "workspaces": []]]]
        default:
            return ["error": ["code": "unsupported_fixture_method", "message": "not used by this fixture"]]
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    deinit { stop() }
}
