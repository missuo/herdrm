import HerdrKit
import XCTest
@testable import herdrm

/// The coordinator that keeps every grazr device on one ACCOUNTS order and
/// one active account. A `SyncWorld` stands in for the devices: it serves
/// their reports, answers grazr's commands and records what was sent and
/// notified, so no test reaches a device.
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
    private let now = Date().timeIntervalSince1970

    private func report(active: String, order: [String], changedAt: Double, blocked: [String: GrazrBlock] = [:]) -> GrazrReport {
        GrazrReport(active: active, accounts: [work, home], order: order, blocked: blocked, changedAt: changedAt)
    }

    // MARK: - Preview

    func testEnableProducesAPreviewAndPushesNothing() async throws {
        let world = SyncWorld(defaults: defaults, [
            ("studio", report(active: work.id, order: ["work", "home"], changedAt: 1_000)),
            ("laptop", report(active: home.id, order: ["home", "work"], changedAt: 2_000)),
        ])
        world.sync.setEnabled(true)
        await world.sync.pendingRound?.value

        XCTAssertTrue(defaults.bool(forKey: AppModel.syncAccountsKey))
        XCTAssertEqual(Set(world.loads), [world.id("studio"), world.id("laptop")])
        guard case .preview(let lines, let pushes) = world.model.grazrSyncStatus else {
            return XCTFail("expected a preview, got \(world.model.grazrSyncStatus)")
        }
        XCTAssertEqual(pushes, [GrazrSyncPush(device: world.id("studio"), orderNames: ["home", "work"], switchTo: home.id, problem: nil)])
        XCTAssertTrue(lines.contains { $0.text == "studio will move to home and take laptop's order" }, "\(lines.map(\.text))")
        XCTAssertEqual(world.sent, [], "a preview pushes nothing")
        XCTAssertNil(world.sync.planner.target, "a preview commits nothing to the planner")

        world.sync.setEnabled(false)
        XCTAssertEqual(world.model.grazrSyncStatus, .off)
        XCTAssertFalse(defaults.bool(forKey: AppModel.syncAccountsKey))
    }

    // MARK: - Pushes

    func testApplyWritesTheOrderThenSwitchesAndNotifiesOnce() async throws {
        let world = SyncWorld(defaults: defaults, [
            ("laptop", report(active: home.id, order: ["home", "work"], changedAt: now - 60)),
            ("studio", report(active: work.id, order: ["work", "home"], changedAt: now - 600)),
        ])
        await world.enableAndApply()

        XCTAssertEqual(world.sent, ["studio order home,work", "studio switch home"], "order first, nothing to the source")
        XCTAssertEqual(world.notes, [["grazr: studio now on home", "following laptop", "studio"]])
        XCTAssertEqual(
            world.sync.planner.lastSeen[world.id("studio")], GrazrSyncState(report: world.reports[world.id("studio")]!),
            "the landed push is settled, not a change of studio's own"
        )
        XCTAssertTrue(world.lineTexts.first?.hasPrefix("studio follow laptop (changed ") == true, "\(world.lineTexts)")

        // In step now: the next round sends nothing and posts nothing.
        await world.kick()
        XCTAssertEqual(world.sent.count, 2)
        XCTAssertEqual(world.notes.count, 1)
        XCTAssertNil(world.sync.planner.bouncing)

        // Turning it on again while it runs is a no-op, not a new preview.
        world.sync.setEnabled(true)
        await world.sync.pendingRound?.value
        guard case .lines = world.model.grazrSyncStatus else { return XCTFail("\(world.model.grazrSyncStatus)") }
        XCTAssertNotNil(world.sync.planner.target)
        world.sync.setEnabled(false)
    }

    func testDevicesThatAgreeReadAllInSync() async throws {
        let world = SyncWorld(defaults: defaults, [
            ("laptop", report(active: home.id, order: ["home", "work"], changedAt: now - 60)),
            ("studio", report(active: home.id, order: ["home", "work"], changedAt: now - 600)),
        ])
        await world.enableAndApply()
        XCTAssertEqual(world.sent, [])
        XCTAssertEqual(world.lineTexts, ["All devices in sync"])
        world.sync.setEnabled(false)
    }

    func testAnOrderRefusalStillSwitchesAndIsReported() async throws {
        let world = SyncWorld(defaults: defaults, [
            ("laptop", report(active: home.id, order: ["home", "work"], changedAt: now - 60)),
            ("studio", report(active: work.id, order: ["work", "home"], changedAt: now - 600)),
        ])
        world.answers["studio order home,work"] = GrazrSwitchResult(ok: false, output: "grazr: ACCOUNTS \(Grazr.needsUpdateMarker)")
        await world.enableAndApply()

        XCTAssertEqual(world.sent, ["studio order home,work", "studio switch home"])
        XCTAssertEqual(world.notes.count, 1, "the switch landed")
        XCTAssertTrue(world.lineTexts.contains("grazr on studio needs 0.4.7+senad.4 or later"), "\(world.lineTexts)")
        world.sync.setEnabled(false)
    }

    func testARefusedSwitchPostsNothingAndOnlyBusyIsRetriedAtOnce() async throws {
        let world = SyncWorld(defaults: defaults, [
            ("laptop", report(active: home.id, order: ["home", "work"], changedAt: now - 60)),
            ("studio", report(active: work.id, order: ["home", "work"], changedAt: now - 600)),
        ])
        world.answers["studio switch home"] = GrazrSwitchResult(ok: false, output: "grazr: Busy rotating already")
        await world.enableAndApply()
        XCTAssertEqual(world.sent, ["studio switch home"])
        XCTAssertEqual(world.notes, [])
        XCTAssertTrue(world.lineTexts.contains("studio: grazr: Busy rotating already"), "\(world.lineTexts)")

        // Busy is passing: recorded as such, the next round asks again.
        world.answers["studio switch home"] = GrazrSwitchResult(ok: false, output: "refreshing\ngrazr: home failed with 401")
        await world.kick()
        XCTAssertEqual(world.sent.count, 2)
        XCTAssertTrue(world.lineTexts.contains("studio: home is blocked (grazr: home failed with 401), still on work"), "\(world.lineTexts)")
        guard case .lines(let lines) = world.model.grazrSyncStatus else { return XCTFail("\(world.model.grazrSyncStatus)") }
        XCTAssertEqual(lines.last?.blockedAccount, home)
        XCTAssertEqual(lines.last?.device, world.device("studio"))

        // Any other refusal waits for studio to change.
        await world.kick()
        XCTAssertEqual(world.sent.count, 2)
        XCTAssertEqual(world.notes, [])
        world.sync.setEnabled(false)
    }

    func testAnUnreadableDeviceSitsOutAndKeepsItsProblem() async throws {
        let world = SyncWorld(defaults: defaults, [
            ("laptop", report(active: home.id, order: ["home", "work"], changedAt: now - 60)),
            ("studio", report(active: work.id, order: ["work", "home"], changedAt: now - 600)),
            // The last report read, newest of all, but the device cannot be read now.
            ("server", report(active: work.id, order: ["work", "home"], changedAt: now - 10)),
        ])
        world.unreadable = [world.id("server")]
        await world.enableAndApply()
        XCTAssertEqual(world.sent, ["studio order home,work", "studio switch home"], "server's old report is not a change to spread")
        XCTAssertEqual(world.sync.planner.target?.source, world.id("laptop"))

        // Readable again, behind laptop, and its grazr refuses.
        world.unreadable = []
        world.reports[world.id("server")] = report(active: work.id, order: ["home", "work"], changedAt: now - 900)
        world.answers["server switch home"] = GrazrSwitchResult(ok: false, output: "grazr: home failed with 401")
        await world.kick()
        XCTAssertEqual(world.sent.last, "server switch home")
        let blocked = "server: home is blocked (grazr: home failed with 401), still on work"
        XCTAssertTrue(world.lineTexts.contains(blocked), "\(world.lineTexts)")

        // Unreadable once more: skipped, and its problem stays on show.
        world.unreadable = [world.id("server")]
        let sent = world.sent.count
        await world.kick()
        XCTAssertEqual(world.sent.count, sent)
        XCTAssertTrue(world.lineTexts.contains(blocked), "\(world.lineTexts)")
        world.sync.setEnabled(false)
    }

    func testALandedPushWhoseRereadFailsIsNotSettledFromTheOldReport() async throws {
        let world = SyncWorld(defaults: defaults, [
            ("laptop", report(active: home.id, order: ["home", "work"], changedAt: now - 60)),
            ("studio", report(active: work.id, order: ["home", "work"], changedAt: now - 600)),
            ("server", report(active: work.id, order: ["home", "work"], changedAt: now - 900)),
        ])
        // Both switches land, then neither device can be read.
        world.onCommand = { name, _ in world.unreadable.insert(world.id(name)) }
        await world.enableAndApply()
        XCTAssertEqual(world.sent, ["studio switch home", "server switch home"])
        XCTAssertEqual(world.notes.count, 2)

        // Their old "work" reports must not read as two bounces, which would pause the sync.
        await world.kick()
        XCTAssertEqual(world.sent.count, 2)
        XCTAssertNil(world.sync.planner.bouncing)
        XCTAssertNil(world.sync.planner.pausedUntil)
        XCTAssertEqual(world.sync.planner.lastSeen[world.id("studio")]?.activeID, work.id, "never settled from the old report")

        // Readable again: both are where the pushes put them, nothing to do.
        world.unreadable = []
        await world.kick()
        XCTAssertEqual(world.sent.count, 2)
        XCTAssertNil(world.sync.planner.bouncing)
        XCTAssertEqual(world.sync.planner.lastSeen[world.id("studio")]?.activeID, home.id)
        world.sync.setEnabled(false)
    }

    func testTurningOffMidPushStopsTheRound() async throws {
        let world = SyncWorld(defaults: defaults, [
            ("laptop", report(active: home.id, order: ["home", "work"], changedAt: now - 60)),
            ("studio", report(active: work.id, order: ["work", "home"], changedAt: now - 600)),
        ])
        world.onCommand = { _, label in if label.hasPrefix("order") { world.sync.setEnabled(false) } }
        await world.enableAndApply()

        XCTAssertEqual(world.sent, ["studio order home,work"], "no switch after off")
        XCTAssertEqual(world.notes, [])
        XCTAssertEqual(world.model.grazrSyncStatus, .off)
        XCTAssertNil(world.sync.planner.target)
        XCTAssertTrue(world.sync.planner.lastSeen.isEmpty, "the reset planner is left alone")
    }

    func testAKickDuringARoundRunsItOnceMore() async throws {
        let world = SyncWorld(defaults: defaults, [
            ("laptop", report(active: home.id, order: ["home", "work"], changedAt: now - 60)),
            ("studio", report(active: home.id, order: ["home", "work"], changedAt: now - 600)),
        ])
        world.sync.setEnabled(true)
        await world.sync.pendingRound?.value
        world.loads = []
        var kicked = false
        world.onLoad = { _ in
            guard !kicked else { return }
            kicked = true
            world.sync.kick()
            for _ in 0..<5 { await Task.yield() }
        }
        world.sync.apply()
        let first = world.sync.pendingRound
        await first?.value
        XCTAssertEqual(world.loads.filter { $0 == world.id("laptop") }.count, 2, "one round, then one more for the kick")
        world.sync.setEnabled(false)
    }

    // MARK: - Pure

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
            GrazrSyncCoordinator.lines(
                planner: GrazrSyncPlanner(), pushes: [], results: [:], pushedAnything: false, devices: devices, now: now
            ).map(\.text),
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

        // A target, but nothing was ever pushed and nothing is wrong: in sync.
        XCTAssertEqual(
            GrazrSyncCoordinator.lines(planner: planner, pushes: [], results: [:], pushedAnything: false, devices: devices, now: now)
                .map(\.text),
            ["All devices in sync"]
        )

        let lines = GrazrSyncCoordinator.lines(
            planner: planner, pushes: [],
            results: [server: .blocked(accountID: home.id, reason: "401 Unauthorized")], pushedAnything: true,
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
            GrazrSyncCoordinator.lines(
                planner: planner, pushes: [], results: [server: .needsUpdate], pushedAnything: true, devices: devices, now: now
            ).last?.text,
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
            GrazrSyncCoordinator.lines(
                planner: bouncing, pushes: [], results: [:], pushedAnything: true,
                devices: pair(work.id, 2_100, home.id, 2_200), now: 120
            ).first,
            GrazrSyncLine(
                id: "paused",
                text: "Sync paused: alpha and beta keep undoing each other. Check that their thresholds match.",
                tone: .warning, device: nil, blockedAccount: nil
            )
        )
    }
}

/// Devices for the coordinator: reports it reads, grazr's answers to its
/// commands (ok unless `answers` says otherwise; an ok one changes the report
/// the way grazr would), and a record of what it sent and notified.
@MainActor
private final class SyncWorld {
    let model = AppModel()
    let sync: GrazrSyncCoordinator
    var reports: [UUID: GrazrReport] = [:]
    var unreadable: Set<UUID> = []
    /// Keyed "<device> <label>", as in `sent`.
    var answers: [String: GrazrSwitchResult] = [:]
    var onLoad: ((UUID) async -> Void)?
    var onCommand: ((String, String) -> Void)?
    var loads: [UUID] = []
    /// "<device> order a,b" or "<device> switch <account name>".
    var sent: [String] = []
    var notes: [[String]] = []

    init(defaults: UserDefaults, _ devices: [(String, GrazrReport)]) {
        sync = GrazrSyncCoordinator(model: model, defaults: defaults)
        model.devices = devices.map { Device(name: $0.0, kind: .ssh(target: "me@\($0.0)")) }
        for (device, (_, report)) in zip(model.devices, devices) {
            var state = DeviceSessionState()
            state.usesGrazr = true
            state.grazrReport = report
            model.sessions[device.id] = state
            reports[device.id] = report
        }
        sync.reportLoader = { [unowned self] id in
            self.loads.append(id)
            await self.onLoad?(id)
            guard !self.unreadable.contains(id), let report = self.reports[id] else { return false }
            self.model.sessions[id]?.grazrReport = report
            return true
        }
        sync.commandRunner = { [unowned self] device, command in
            let label = Self.label(command)
            self.sent.append("\(device.name) \(label)")
            self.onCommand?(device.name, label)
            let result = self.answers["\(device.name) \(label)"] ?? GrazrSwitchResult(ok: true, output: "done")
            if result.ok { self.land(label, on: device.id) }
            return try JSONSerialization.data(withJSONObject: ["ok": result.ok, "output": result.output])
        }
        sync.notifier = { [unowned self] title, body, device in self.notes.append([title, body, device]) }
    }

    func id(_ name: String) -> UUID { device(name).id }
    func device(_ name: String) -> Device { model.devices.first { $0.name == name }! }

    var lineTexts: [String] {
        if case .lines(let lines) = model.grazrSyncStatus { return lines.map(\.text) }
        return []
    }

    func enableAndApply() async {
        sync.setEnabled(true)
        await sync.pendingRound?.value
        sync.apply()
        await sync.pendingRound?.value
    }

    func kick() async {
        sync.kick()
        await sync.pendingRound?.value
    }

    private static let accounts = [GrazrAccount(id: "id-work", name: "work"), GrazrAccount(id: "id-home", name: "home")]

    private static func label(_ command: String) -> String {
        for account in accounts where command == Grazr.switchCommand(to: account.id) { return "switch \(account.name)" }
        for names in [["home", "work"], ["work", "home"]] where command == Grazr.setAccountsCommand(names: names) {
            return "order \(names.joined(separator: ","))"
        }
        return "other"
    }

    private func land(_ label: String, on id: UUID) {
        guard let old = reports[id] else { return }
        let parts = label.split(separator: " ", maxSplits: 1).map(String.init)
        let active = parts[0] == "switch" ? Self.accounts.first { $0.name == parts[1] }?.id : old.active
        let order = parts[0] == "order" ? parts[1].split(separator: ",").map(String.init) : old.order
        reports[id] = GrazrReport(
            active: active, accounts: old.accounts, order: order, blocked: old.blocked,
            changedAt: Date().timeIntervalSince1970
        )
    }
}
