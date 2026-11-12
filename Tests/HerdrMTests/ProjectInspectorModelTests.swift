import HerdrKit
import XCTest
@testable import herdrm

@MainActor
final class ProjectInspectorModelTests: XCTestCase {
    private let devbox = Device(name: "devbox", kind: .ssh(target: "dev@devbox"))
    private let cwd = "/home/dev/acme-app/frontend"
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectInspectorModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    // MARK: - Fixtures

    private static let ssLines = [
        #"LISTEN 0      511                      127.0.0.1:3100  0.0.0.0:* users:(("next-server (v1",pid=3678507,fd=22))"#,
        #"LISTEN 0      2048                     127.0.0.1:8100  0.0.0.0:* users:(("python3",pid=3995699,fd=3),("python3",pid=3672770,fd=3))"#,
    ]

    private static let pidLines = [
        "3678507\t3678404\tnext-server (v1\t/home/dev/acme-app/frontend\tacme-dev-fe.service\t/tmp/acme-frontend-3100.log\tnext-server (v14.2.35)",
        "3995699\t982\tpython3\t/home/dev/acme-app/packages/api\tacme-dev-api.service\t/tmp/acme-api-8100.log\tpython3 -m uvicorn acme_api.main_simple:app --host 127.0.0.1 --port 8100 --reload --reload-dir acme_api",
        "3672770\t3995699\tpython3\t/home/dev/acme-app/packages/api\tacme-dev-api.service\t/tmp/acme-api-8100.log\tpython3 -c from multiprocessing.spawn import spawn_main; spawn_main",
    ]

    private static let devboxFrame = (
        ["@@pp-begin 1", "@@roots", "/home/dev/acme-app/frontend\t/home/dev/acme-app\t/home/dev/acme-app/.git", "@@listeners ss"]
            + ssLines + ["@@pids"] + pidLines + ["@@pp-end"]
    ).joined(separator: "\n")

    private static let emptyFrame = ["@@pp-begin 1", "@@roots", "@@pp-end"].joined(separator: "\n")

    private static let hostFrame = [
        "@@pp-begin 1", "@@host", "os Darwin", "hostname laptop", "ncpu 8", "@@pp-end",
    ].joined(separator: "\n")

    private struct FakeError: Error {}

    private final class FakeRunner: ProjectProbeRunning, @unchecked Sendable {
        struct Call: Equatable { var device: Device; var sections: [String]; var cwds: [String] }
        private let lock = NSLock()
        private var _calls: [Call] = []
        private var heldContinuations: [CheckedContinuation<Void, Never>] = []
        private var frames: [UUID: String] = [:]
        private var failing = false
        private var holdFirst = 0
        private var heldDeviceID: UUID?
        private var completedDevices: Set<UUID> = []
        private var started = 0

        func setFrame(_ frame: String, for id: UUID) { lock.lock(); frames[id] = frame; lock.unlock() }
        func setFailing(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
        /// How many leading calls wait for `releaseHeld()`.
        func setHoldFirst(_ count: Int) { lock.lock(); holdFirst = count; lock.unlock() }
        func hold(deviceID: UUID) { lock.lock(); heldDeviceID = deviceID; lock.unlock() }
        func completed(deviceID: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return completedDevices.contains(deviceID) }

        var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

        func run(device: Device, sections: [String], cwds: [String]) async throws -> String {
            let (hold, failing, frame): (Bool, Bool, String) = {
                lock.lock(); defer { lock.unlock() }
                _calls.append(Call(device: device, sections: sections, cwds: cwds))
                started += 1
                return (started <= holdFirst || heldDeviceID == device.id, self.failing, frames[device.id] ?? ProjectInspectorModelTests.emptyFrame)
            }()
            if hold {
                await withCheckedContinuation { continuation in
                    lock.lock(); heldContinuations.append(continuation); lock.unlock()
                }
            }
            if Task.isCancelled { throw CancellationError() }
            if failing { throw FakeError() }
            markCompleted(device.id)
            return frame
        }

        private func markCompleted(_ deviceID: UUID) {
            lock.lock(); defer { lock.unlock() }
            completedDevices.insert(deviceID)
        }

        func releaseHeld() {
            lock.lock()
            let pending = heldContinuations
            heldContinuations = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        var heldCount: Int { lock.lock(); defer { lock.unlock() }; return heldContinuations.count }
    }

    private func makeModel(_ runner: FakeRunner, localDevice: Device = .local) -> ProjectInspectorModel {
        ProjectInspectorModel(
            runner: runner, store: ProjectStore(directory: storeDirectory), localDevice: localDevice,
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private func context(_ device: Device? = nil) -> ProjectContext {
        ProjectContext(device: device ?? devbox, workspaceLabel: "acme", cwds: [cwd], focusedCwd: cwd)
    }

    private func space(_ device: Device? = nil) -> SpaceRef {
        SpaceRef(deviceID: (device ?? devbox).id, workspaceID: "w1")
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: - Tests

    func testProbeResolvesRootThenClassifies() async {
        let runner = FakeRunner()
        runner.setFrame(Self.devboxFrame, for: devbox.id)
        let model = makeModel(runner)
        await model.probe(space: space(), context: context())

        let entry = model.entry(for: space())
        XCTAssertEqual(entry?.state, .live)
        XCTAssertEqual(entry?.snapshot?.devServers.count, 2)
        XCTAssertEqual(model.identity(for: space())?.root, "/home/dev/acme-app")
        XCTAssertEqual(model.keyBySpace[space()], "\(devbox.id.uuidString):/home/dev/acme-app")
        XCTAssertEqual(entry?.lastProbe, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testRemoteSpaceAlsoProbesLocalVMs() async {
        let runner = FakeRunner()
        runner.setFrame(Self.devboxFrame, for: devbox.id)
        runner.setFrame(Self.hostFrame, for: Device.local.id)
        let model = makeModel(runner)
        await model.probe(space: space(), context: context())

        let calls = runner.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.contains { $0.device.id == devbox.id && !$0.sections.contains("vms") && $0.cwds == [cwd] })
        XCTAssertTrue(calls.contains { $0.device.isLocal && $0.sections == ["host", "vms"] })
        XCTAssertNotNil(model.entry(for: space())?.localVMs)
    }

    func testLocalSpaceProbesOnceIncludingVMs() async {
        let runner = FakeRunner()
        runner.setFrame(Self.devboxFrame, for: Device.local.id)
        let model = makeModel(runner)
        let local = Device.local
        await model.probe(space: space(local), context: context(local))

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertTrue(runner.calls[0].sections.contains("vms"))
        XCTAssertNotNil(model.entry(for: space(local))?.localVMs)
    }

    func testLateResultForAnotherKeyIsIgnored() async {
        let runner = FakeRunner()
        runner.setFrame(Self.devboxFrame, for: devbox.id)
        runner.setHoldFirst(1)
        let model = makeModel(runner)
        let first = Task { await model.probe(space: space(), context: context()) }
        await waitUntil { runner.heldCount == 1 }

        let reprobe = model.setRoot(space: space(), context: context(), root: "/other")
        XCTAssertEqual(model.keyBySpace[space()], "\(devbox.id.uuidString):/other")
        // The re-probe returns an empty frame; only the held devbox frame has dev servers.
        runner.setFrame(Self.emptyFrame, for: devbox.id)
        runner.releaseHeld()
        _ = await first.value
        await reprobe?.value

        let other = model.entries["\(devbox.id.uuidString):/other"]
        XCTAssertEqual(other?.snapshot?.devServers.count ?? 0, 0)
        XCTAssertNil(model.entries["\(devbox.id.uuidString):/home/dev/acme-app"])
        XCTAssertEqual(model.keyBySpace[space()], "\(devbox.id.uuidString):/other")
    }

    func testFailureKeepsLastSnapshotAndMarksFailed() async {
        let runner = FakeRunner()
        runner.setFrame(Self.devboxFrame, for: devbox.id)
        let model = makeModel(runner)
        await model.probe(space: space(), context: context())
        let good = model.entry(for: space())

        runner.setFailing(true)
        await model.probe(space: space(), context: context())
        let after = model.entry(for: space())
        guard case .failed = after?.state else { return XCTFail("expected failed, got \(String(describing: after?.state))") }
        XCTAssertEqual(after?.snapshot, good?.snapshot)
        XCTAssertNotNil(after?.snapshot)
        XCTAssertEqual(after?.lastProbe, good?.lastProbe)
    }

    func testOverrideMutationReclassifiesWithoutProbe() async throws {
        let runner = FakeRunner()
        runner.setFrame(Self.devboxFrame, for: devbox.id)
        let model = makeModel(runner)
        await model.probe(space: space(), context: context())
        let callCount = runner.calls.count
        let server = try XCTUnwrap(model.entry(for: space())?.snapshot?.devServers.first)

        model.setURLOverride(space: space(), signature: server.signature, url: "https://app.example.test")
        await model.settleMutations()

        XCTAssertEqual(runner.calls.count, callCount)
        let updated = model.entry(for: space())?.snapshot?.devServers.first { $0.signature == server.signature }
        XCTAssertEqual(updated?.urls.first?.source, .override)
        XCTAssertEqual(updated?.urls.first?.url, "https://app.example.test")
    }

    func testAttachThenDetachContainerAndLinkedDevices() async throws {
        let runner = FakeRunner()
        runner.setFrame(Self.devboxFrame, for: devbox.id)
        let model = makeModel(runner)
        await model.probe(space: space(), context: context())
        let key = try XCTUnwrap(model.keyBySpace[space()])
        let store = ProjectStore(directory: storeDirectory)

        model.attachContainer(space: space(), name: "acme-db-1")
        XCTAssertEqual(store.overrides(for: key).attachedContainers, ["acme-db-1"])
        model.detachContainer(space: space(), name: "acme-db-1")
        await model.settleMutations()
        XCTAssertEqual(store.overrides(for: key).attachedContainers, [])

        let other = Device(name: "buildbox", kind: .ssh(target: "dev@buildbox"))
        model.linkDevice(space: space(), device: other, root: "/srv/acme")
        XCTAssertEqual(model.linkedDevices(for: space()).map(\.deviceID), [other.id])
        model.unlinkDevice(space: space(), deviceID: other.id)
        await model.settleMutations()
        XCTAssertEqual(model.linkedDevices(for: space()), [])
    }

    func testUnsupportedDeviceNeverProbes() async {
        let runner = FakeRunner()
        let tailcat = Device(name: "cat", kind: .tailcat)
        let model = makeModel(runner)
        await model.probe(space: space(tailcat), context: context(tailcat))

        XCTAssertTrue(runner.calls.isEmpty)
        guard case .failed(let message) = model.entry(for: space(tailcat))?.state else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("need a shell"))
    }

    func testBackoffDoublesFromTwoToSixtySeconds() {
        XCTAssertEqual(ProjectInspectorModel.pollDelay(failures: 0), 15)
        XCTAssertEqual(ProjectInspectorModel.pollDelay(failures: 1), 2)
        XCTAssertEqual(ProjectInspectorModel.pollDelay(failures: 2), 4)
        XCTAssertEqual(ProjectInspectorModel.pollDelay(failures: 5), 32)
        XCTAssertEqual(ProjectInspectorModel.pollDelay(failures: 6), 60)
        XCTAssertEqual(ProjectInspectorModel.pollDelay(failures: 40), 60)
    }

    func testSavedRootOverrideAppliesTheFirstProbe() async {
        let runner = FakeRunner()
        runner.setFrame(Self.devboxFrame, for: devbox.id)
        let model = makeModel(runner)
        ProjectStore(directory: storeDirectory).setSpaceRoot(deviceID: devbox.id, workspaceLabel: "acme", root: "/home/dev/acme-app")
        await model.probe(space: space(), context: context())

        XCTAssertEqual(model.entry(for: space())?.state, .live)
        XCTAssertNotNil(model.entry(for: space())?.snapshot)
        XCTAssertTrue(runner.calls.first?.cwds.contains("/home/dev/acme-app") ?? false)
    }

    func testCancellingAProbeDoesNotMarkItFailed() async {
        let runner = FakeRunner()
        runner.setHoldFirst(1)
        let model = makeModel(runner)
        let task = Task { await model.probe(space: space(), context: context()) }
        await waitUntil { runner.heldCount == 1 }
        task.cancel()
        runner.releaseHeld()
        _ = await task.value

        if case .failed = model.entry(for: space())?.state { XCTFail("cancellation must not fail the entry") }
    }

    func testCancellingOnlyTheLocalVMProbeDropsTheCompletedMainResult() async {
        let runner = FakeRunner()
        runner.hold(deviceID: Device.local.id)
        let model = makeModel(runner)
        let task = Task { await model.probe(space: space(), context: context()) }
        await waitUntil { runner.heldCount == 1 && runner.completed(deviceID: devbox.id) }
        XCTAssertEqual(runner.heldCount, 1)
        XCTAssertTrue(runner.completed(deviceID: devbox.id), "The main probe must finish before cancellation")

        task.cancel()
        runner.releaseHeld()
        let outcome = await task.value

        XCTAssertEqual(outcome, .dropped, "The optional VM probe swallowing cancellation must not apply the main result")
        XCTAssertEqual(model.entry(for: space())?.state, .idle)
        XCTAssertNil(model.entry(for: space())?.snapshot)
    }

    func testEmptyCwdListNeverCallsTheRunner() async {
        let runner = FakeRunner()
        let model = makeModel(runner)
        var empty = context()
        empty.cwds = []
        let outcome = await model.probe(space: space(), context: empty)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(runner.calls.isEmpty)
        guard case .failed(let message) = model.entry(for: space())?.state else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("No project directory"))
    }

    func testDroppedLateResultNeitherAppliesNorCountsAsFailure() async {
        let runner = FakeRunner()
        runner.setHoldFirst(1)
        let model = makeModel(runner)
        let first = Task { await model.probe(space: space(), context: context()) }
        await waitUntil { runner.heldCount == 1 }
        let reprobe = model.setRoot(space: space(), context: context(), root: "/other")
        runner.releaseHeld()
        let outcome = await first.value
        await reprobe?.value
        XCTAssertEqual(outcome, .dropped)
    }

    func testFrameCutBeforeEndIsLiveAndPartial() async {
        let runner = FakeRunner()
        // The ssh run died before `@@pp-end`; the runner still hands over what arrived.
        runner.setFrame(String(Self.devboxFrame.dropLast("@@pp-end".count)), for: devbox.id)
        let model = makeModel(runner)
        let outcome = await model.probe(space: space(), context: context())

        XCTAssertEqual(outcome, .applied)
        let entry = model.entry(for: space())
        XCTAssertEqual(entry?.state, .live)
        XCTAssertEqual(entry?.snapshot?.partial, true)
        XCTAssertEqual(entry?.snapshot?.devServers.count, 2)
    }

    func testRemoteCwdsThatAreAllUnsafeAreSkippedWithoutBackoff() async {
        let runner = FakeRunner()
        let model = makeModel(runner)
        var unsafe = context()
        unsafe.cwds = ["/home/dev/back\\slash"]
        let outcome = await model.probe(space: space(), context: unsafe)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(runner.calls.isEmpty)
        guard case .failed(let message) = model.entry(for: space())?.state else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("No project directory"))

        // An apostrophe is fine for a remote shell and is probed.
        var quoted = context()
        quoted.cwds = ["/home/dev/it's here"]
        _ = await model.probe(space: space(), context: quoted)
        XCTAssertEqual(runner.calls.first?.cwds, ["/home/dev/it's here"])
    }

    func testDetachingAnAttachedComposeGroupOnlyRemovesTheAttachment() async throws {
        let runner = FakeRunner()
        let frame = Self.devboxFrame.replacingOccurrences(
            of: "@@pp-end",
            with: "@@compose\n[{\"Name\":\"billing\",\"Status\":\"running(1)\",\"ConfigFiles\":\"/srv/billing/compose.yml\"}]\n@@pp-end")
        runner.setFrame(frame, for: devbox.id)
        let model = makeModel(runner)
        await model.probe(space: space(), context: context())
        let key = try XCTUnwrap(model.keyBySpace[space()])
        let store = ProjectStore(directory: storeDirectory)

        model.attachCompose(space: space(), name: "billing")
        await model.settleMutations()
        XCTAssertEqual(model.entry(for: space())?.snapshot?.compose.map(\.match), [.attached])

        model.detachCompose(space: space(), name: "billing")
        await model.settleMutations()
        XCTAssertEqual(store.overrides(for: key).attachedCompose, [])
        XCTAssertEqual(store.overrides(for: key).detachedCompose, [])
        XCTAssertEqual(model.entry(for: space())?.snapshot?.otherCompose.map(\.name), ["billing"])
    }

    func testFinishedReclassifyTasksAreNotRetained() async {
        let runner = FakeRunner()
        runner.setFrame(Self.devboxFrame, for: devbox.id)
        let model = makeModel(runner)
        await model.probe(space: space(), context: context())
        for index in 0..<20 { model.setHidden(space: space(), signature: "x@\(index)", hidden: true) }
        await model.settleMutations()
        XCTAssertEqual(model.pendingReclassifyCount, 0)
    }
}
