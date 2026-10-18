import HerdrKit
import XCTest
@testable import herdrm

/// The coordinator that keeps every grazr device on one ACCOUNTS order and
/// one active account. Reports are put into the model's sessions directly
/// and the command channel is a recorder, so no test reaches a device.
@MainActor
final class GrazrSyncCoordinatorTests: XCTestCase {
    private let suiteName = "GrazrSyncCoordinatorTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private let work = GrazrAccount(id: "id-work", name: "work")
    private let home = GrazrAccount(id: "id-home", name: "home")

    private func report(active: String, order: [String], changedAt: Double, blocked: [String: GrazrBlock] = [:]) -> GrazrReport {
        GrazrReport(active: active, accounts: [work, home], order: order, blocked: blocked, changedAt: changedAt)
    }

    func testEnableProducesAPreviewAndPushesNothing() async throws {
        let model = AppModel()
        let older = Device(name: "studio", kind: .ssh(target: "me@studio"))
        let newer = Device(name: "laptop", kind: .ssh(target: "me@laptop"))
        model.devices = [older, newer]
        var olderState = DeviceSessionState()
        olderState.usesGrazr = true
        olderState.grazrReport = report(active: work.id, order: ["work", "home"], changedAt: 1_000)
        var newerState = DeviceSessionState()
        newerState.usesGrazr = true
        newerState.grazrReport = report(active: home.id, order: ["home", "work"], changedAt: 2_000)
        model.sessions = [older.id: olderState, newer.id: newerState]

        let sync = GrazrSyncCoordinator(model: model, defaults: defaults)
        var loaded: [UUID] = []
        var commands: [String] = []
        sync.reportLoader = { loaded.append($0) }
        sync.commandRunner = { _, command in
            commands.append(command)
            return Data()
        }

        sync.setEnabled(true)
        await sync.pendingRound?.value

        XCTAssertTrue(defaults.bool(forKey: AppModel.syncAccountsKey))
        XCTAssertEqual(Set(loaded), [older.id, newer.id])
        guard case .preview(let lines, let pushes) = model.grazrSyncStatus else {
            return XCTFail("expected a preview, got \(model.grazrSyncStatus)")
        }
        XCTAssertEqual(pushes, [GrazrSyncPush(device: older.id, orderNames: ["home", "work"], switchTo: home.id, problem: nil)])
        XCTAssertTrue(lines.contains { $0.text == "studio will move to home and take laptop's order" }, "\(lines.map(\.text))")
        XCTAssertEqual(commands, [], "a preview pushes nothing")
        XCTAssertNil(sync.planner.target, "a preview commits nothing to the planner")

        sync.setEnabled(false)
        XCTAssertEqual(model.grazrSyncStatus, .off)
        XCTAssertFalse(defaults.bool(forKey: AppModel.syncAccountsKey))
    }

    func testRefusalMapping() {
        func problem(_ ok: Bool, _ output: String) -> GrazrSyncProblem? {
            GrazrSyncCoordinator.problem(from: GrazrSwitchResult(ok: ok, output: output), accountID: "id-home")
        }
        XCTAssertNil(problem(true, "Rotated work -> home"))
        XCTAssertEqual(problem(false, "grazr: ACCOUNTS \(Grazr.needsUpdateMarker)"), .needsUpdate)
        XCTAssertEqual(problem(false, "grazr: home is pinned to an agent"), .pinned(accountID: "id-home"))
        XCTAssertEqual(
            problem(false, "refreshing\ngrazr: home failed with 401 Unauthorized"),
            .blocked(accountID: "id-home", reason: "grazr: home failed with 401 Unauthorized")
        )
        XCTAssertEqual(
            problem(false, "grazr: Busy rotating already, try again"),
            .refused("grazr: Busy rotating already, try again")
        )
    }

    func testLinesDescribeInSyncProblemsAndPause() {
        let laptop = UUID(), studio = UUID(), server = UUID()
        let now = 10_000.0
        let devices = [
            GrazrSyncDevice(id: laptop, name: "laptop", report: report(active: home.id, order: ["home", "work"], changedAt: now - 180)),
            GrazrSyncDevice(id: studio, name: "studio", report: report(active: home.id, order: ["home", "work"], changedAt: now - 100)),
            GrazrSyncDevice(id: server, name: "server", report: report(
                active: work.id, order: ["work", "home"], changedAt: now - 3_000,
                blocked: [home.id: GrazrBlock(reason: "401 Unauthorized")]
            )),
        ]
        let serverDevice = Device(id: server, name: "server", kind: .ssh(target: "me@server"))

        // Nothing observed yet.
        XCTAssertEqual(
            GrazrSyncCoordinator.lines(planner: GrazrSyncPlanner(), pushes: [], results: [:], devices: devices, now: now).map(\.text),
            ["All devices in sync"]
        )

        // laptop changed last; studio follows it, server cannot.
        var planner = GrazrSyncPlanner()
        _ = planner.observe(devices.map { device in
            device.id == studio
                ? GrazrSyncDevice(id: studio, name: "studio", report: report(active: home.id, order: ["home", "work"], changedAt: now - 3_000))
                : device
        }, now: now)
        XCTAssertEqual(planner.target?.source, laptop)
        let lines = GrazrSyncCoordinator.lines(
            planner: planner, pushes: [],
            results: [server: .blocked(accountID: home.id, reason: "401 Unauthorized")],
            devices: devices, now: now,
            device: { $0 == server ? serverDevice : nil }
        )
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let threeMinutesAgo = formatter.localizedString(for: Date(timeIntervalSince1970: now - 180), relativeTo: Date(timeIntervalSince1970: now))
        XCTAssertEqual(lines.map(\.text), [
            "studio follow laptop (changed \(threeMinutesAgo))",
            "server: home is blocked (401 Unauthorized), still on work",
        ])
        XCTAssertEqual(lines.map(\.tone), [.ok, .warning])
        XCTAssertEqual(lines[1].blockedAccount, home)
        XCTAssertEqual(lines[1].device, serverDevice)
        XCTAssertNil(lines[0].blockedAccount)

        // An older grazr.
        XCTAssertEqual(
            GrazrSyncCoordinator.lines(planner: planner, pushes: [], results: [server: .needsUpdate], devices: devices, now: now).last?.text,
            "grazr on server needs 0.4.7+senad.4 or later"
        )

        // Two bounces pause the sync: grazr on each undoes what was pushed to it.
        let a = UUID(), b = UUID()
        func pair(_ aActive: String, _ aAt: Double, _ bActive: String, _ bAt: Double) -> [GrazrSyncDevice] {
            [GrazrSyncDevice(id: a, name: "alpha", report: report(active: aActive, order: ["work", "home"], changedAt: aAt)),
             GrazrSyncDevice(id: b, name: "beta", report: report(active: bActive, order: ["work", "home"], changedAt: bAt))]
        }
        var bouncing = GrazrSyncPlanner()
        _ = bouncing.observe(pair(work.id, 1_000, home.id, 2_000), now: 0)
        bouncing.recordResult(device: a, problem: nil, now: 0)
        bouncing.settle(pair(home.id, 2_010, home.id, 2_000)[0])
        _ = bouncing.observe(pair(work.id, 2_100, home.id, 2_000), now: 60)
        bouncing.recordResult(device: b, problem: nil, now: 60)
        bouncing.settle(pair(work.id, 2_100, work.id, 2_110)[1])
        _ = bouncing.observe(pair(work.id, 2_100, home.id, 2_200), now: 120)
        XCTAssertEqual(bouncing.bouncing, GrazrSyncBounce(source: a, follower: b))
        XCTAssertEqual(
            GrazrSyncCoordinator.lines(planner: bouncing, pushes: [], results: [:], devices: pair(work.id, 2_100, home.id, 2_200), now: 120).first,
            GrazrSyncLine(
                id: "paused",
                text: "Sync paused: alpha and beta keep undoing each other. Check that their thresholds match.",
                tone: .warning, device: nil, blockedAccount: nil
            )
        )
    }
}
