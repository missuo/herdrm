import Foundation
import HerdrKit

enum GrazrSyncTone: Equatable { case ok, warning }

/// One line of the Accounts window's sync status.
struct GrazrSyncLine: Equatable, Identifiable {
    let id: String
    let text: String
    let tone: GrazrSyncTone
    let device: Device?
    /// Non-nil: the window offers Re-authenticate… for this account on `device`.
    let blockedAccount: GrazrAccount?
}

enum GrazrSyncStatus: Equatable {
    case off
    /// Fewer than two devices run grazr; `name` is the one that does.
    case fewDevices(name: String?)
    /// Just turned on: what the first round would do, run on Apply.
    case preview(lines: [GrazrSyncLine], pushes: [GrazrSyncPush])
    case lines([GrazrSyncLine])
}

/// Keeps every device's grazr (this Mac's too) on one ACCOUNTS order and one
/// active account: a round each minute, and one after any grazr action
/// HerdrM performs. The device that changed last wins; `GrazrSyncPlanner`
/// decides, this runs its pushes over each device's command channel.
@MainActor
final class GrazrSyncCoordinator {
    static let interval: TimeInterval = 60

    private unowned let model: AppModel
    private let defaults: UserDefaults
    private(set) var planner = GrazrSyncPlanner()
    /// The latest round started by `setEnabled`, `apply` or `kick`, so a
    /// caller can wait for it.
    private(set) var pendingRound: Task<Void, Never>?
    /// Rereads a device's grazr into its session. Tests replace it.
    var reportLoader: @MainActor (UUID) async -> Void
    /// Runs a shell command on a device. Tests replace it.
    var commandRunner: (Device, String) async throws -> Data = { device, command in
        try await DeviceFileService(device: device).run(command)
    }

    private var loop: Task<Void, Never>?
    private var running = false
    private var runAgain = false
    /// Bumped by every on/off, so a round from before stops pushing.
    private var generation = 0
    /// What each device last could not do, kept until it follows or a push
    /// says otherwise: the planner does not ask an unchanged device again.
    private var problems: [UUID: GrazrSyncProblem] = [:]

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        reportLoader = { [unowned model] in await model.loadGrazrReport(deviceID: $0) }
    }

    var enabled: Bool { defaults.bool(forKey: AppModel.syncAccountsKey) }

    /// On shows what the first round would do and pushes nothing until
    /// `apply`; off stops the loop and forgets everything seen.
    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: AppModel.syncAccountsKey)
        generation += 1
        loop?.cancel()
        loop = nil
        planner.reset()
        problems = [:]
        if on {
            pendingRound = Task { await round(preview: true) }
        } else {
            pendingRound = nil
            model.grazrSyncStatus = .off
        }
    }

    /// Runs the preview's pushes, then keeps the devices in step. The round
    /// reads every device again first, so a change made since the preview
    /// still wins.
    func apply() {
        guard enabled else { return }
        startLoop()
    }

    /// At launch: with the option on, the first round pushes without a preview.
    func startIfEnabled() {
        guard enabled, loop == nil else { return }
        startLoop()
    }

    /// One round now. Before Apply it only refreshes the preview.
    func kick() {
        guard enabled else { return }
        if loop != nil {
            pendingRound = Task { await round(preview: false) }
        } else if model.grazrSyncStatus != .off {
            pendingRound = Task { await round(preview: true) }
        }
    }

    private func startLoop() {
        loop?.cancel()
        let generation = generation
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == generation else { return }
                await self.round(preview: false)
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    // MARK: - Round

    /// A round already running is not entered again; it runs once more after.
    private func round(preview: Bool) async {
        guard !running else {
            runAgain = true
            return
        }
        running = true
        defer { running = false }
        var preview = preview
        repeat {
            runAgain = false
            await runRound(preview: preview, generation: generation)
            preview = loop == nil
        } while runAgain && enabled
    }

    private func runRound(preview: Bool, generation: Int) async {
        let group = model.devices.filter { model.sessions[$0.id]?.usesGrazr == true }
        for device in group { await reportLoader(device.id) }
        guard generation == self.generation else { return }
        let members = syncDevices(group)
        guard members.count >= 2 else {
            model.grazrSyncStatus = .fewDevices(name: members.first?.name)
            return
        }
        let now = Date().timeIntervalSince1970

        if preview {
            var copy = planner
            let pushes = copy.observe(members, now: now)
            let found = Dictionary(pushes.compactMap { push in push.problem.map { (push.device, $0) } }) { $1 }
            model.grazrSyncStatus = .preview(
                lines: Self.lines(planner: copy, pushes: pushes, results: found, devices: members, now: now, device: model.device),
                pushes: pushes
            )
            return
        }

        let pushes = planner.observe(members, now: now)
        let sourceName = planner.target.flatMap { target in members.first { $0.id == target.source }?.name } ?? ""
        for push in pushes where push.device != planner.target?.source {
            guard generation == self.generation, let device = model.device(push.device) else { continue }
            let problem = await execute(push, on: device, sourceName: sourceName, generation: generation)
            if generation == self.generation { problems[push.device] = problem }
        }
        guard generation == self.generation else { return }

        let fresh = syncDevices(group)
        if let target = planner.target {
            let wanted = GrazrSyncState(orderIDs: target.orderIDs, activeID: target.activeID, changedAt: nil)
            let present = Set(fresh.map(\.id))
            problems = problems.filter { id, _ in
                present.contains(id)
                    && !(fresh.first { $0.id == id }.map { GrazrSyncPlanner.equal(GrazrSyncState(report: $0.report), wanted) } ?? false)
            }
        }
        model.grazrSyncStatus = .lines(
            Self.lines(planner: planner, pushes: [], results: problems, devices: fresh, now: now, device: model.device)
        )
    }

    /// Order first, then the switch. Returns what got in the way, if anything.
    /// A push that outlives an on/off leaves the new planner alone.
    private func execute(
        _ push: GrazrSyncPush, on device: Device, sourceName: String, generation: Int
    ) async -> GrazrSyncProblem? {
        var orderProblem: GrazrSyncProblem?
        var switchProblem = push.problem
        var ran = false
        if let names = push.orderNames {
            ran = true
            switch await command(Grazr.setAccountsCommand(names: names), on: device) {
            case .answered(let result) where !result.ok:
                orderProblem = result.output.contains(Grazr.needsUpdateMarker)
                    ? .needsUpdate : .refused(result.summary ?? "")
            case .failed(let problem): orderProblem = problem
            default: break
            }
        }
        if let account = push.switchTo, generation == self.generation {
            ran = true
            switch await command(Grazr.switchCommand(to: account), on: device) {
            case .answered(let result) where result.ok:
                let name = model.session(device.id).grazrReport?.accounts.first { $0.id == account }?.name ?? account
                NotificationManager.shared.postPluginResult(
                    title: String(localized: "grazr: \(device.name) now on \(name)"),
                    body: String(localized: "following \(sourceName)"),
                    deviceName: device.name
                )
            case .answered(let result): switchProblem = Self.problem(from: result, accountID: account)
            case .failed(let problem): switchProblem = problem
            }
        }
        let problem = switchProblem ?? orderProblem
        if ran { await reportLoader(device.id) }
        guard generation == self.generation else { return problem }
        if ran, let report = model.session(device.id).grazrReport {
            planner.settle(GrazrSyncDevice(id: device.id, name: device.name, report: report))
        }
        planner.recordResult(device: device.id, problem: problem, now: Date().timeIntervalSince1970)
        return problem
    }

    private enum Outcome {
        case answered(GrazrSwitchResult)
        /// The command did not run, or printed no result.
        case failed(GrazrSyncProblem)
    }

    private func command(_ text: String, on device: Device) async -> Outcome {
        do {
            return .answered(try JSONDecoder().decode(GrazrSwitchResult.self, from: await commandRunner(device, text)))
        } catch {
            return .failed(.refused(error.localizedDescription))
        }
    }

    /// The group: devices that run grazr and whose report says it is installed.
    private func syncDevices(_ group: [Device]) -> [GrazrSyncDevice] {
        group.compactMap { device in
            guard let report = model.sessions[device.id]?.grazrReport, report.installed else { return nil }
            return GrazrSyncDevice(id: device.id, name: device.name, report: report)
        }
    }

    // MARK: - Pure

    /// Why grazr refused a switch to `accountID`. "Busy rotating" stays a
    /// refusal; the planner treats it as passing.
    static func problem(from result: GrazrSwitchResult, accountID: String) -> GrazrSyncProblem? {
        guard !result.ok else { return nil }
        let summary = result.summary ?? ""
        if result.output.contains(Grazr.needsUpdateMarker) { return .needsUpdate }
        if result.output.contains("pinned to an agent") { return .pinned(accountID: accountID) }
        if result.output.contains("failed with") { return .blocked(accountID: accountID, reason: summary) }
        return .refused(summary)
    }

    /// The window's lines: a pause, who follows whom, what a preview would
    /// do, and each device's problem. `device` resolves an id for the lines
    /// that act on one.
    static func lines(
        planner: GrazrSyncPlanner, pushes: [GrazrSyncPush], results: [UUID: GrazrSyncProblem],
        devices: [GrazrSyncDevice], now: Double, device resolve: (UUID) -> Device? = { _ in nil }
    ) -> [GrazrSyncLine] {
        func name(_ id: UUID) -> String { devices.first { $0.id == id }?.name ?? "" }
        let source = planner.target.flatMap { target in devices.first { $0.id == target.source } }
        /// An account as `id`'s device calls it, else as the source does.
        func account(_ accountID: String?, on id: UUID) -> String {
            guard let accountID else { return String(localized: "no account") }
            let own = devices.first { $0.id == id }?.report.accounts.first { $0.id == accountID }
            return (own ?? source?.report.accounts.first { $0.id == accountID })?.name ?? accountID
        }

        var lines: [GrazrSyncLine] = []
        if let bounce = planner.bouncing {
            let a = name(bounce.source), b = name(bounce.follower)
            lines.append(GrazrSyncLine(
                id: "paused",
                text: String(localized: "Sync paused: \(a) and \(b) keep undoing each other. Check that their thresholds match."),
                tone: .warning, device: nil, blockedAccount: nil
            ))
        }
        if let target = planner.target {
            let wanted = GrazrSyncState(orderIDs: target.orderIDs, activeID: target.activeID, changedAt: nil)
            let followers = devices
                .filter { $0.id != target.source && GrazrSyncPlanner.equal(GrazrSyncState(report: $0.report), wanted) }
                .map(\.name).joined(separator: ", ")
            let from = name(target.source)
            if !followers.isEmpty {
                let text = target.at > 0
                    ? String(localized: "\(followers) follow \(from) (changed \(relative(target.at, now: now)))")
                    : String(localized: "\(followers) follow \(from)")
                lines.append(GrazrSyncLine(id: "in-sync", text: text, tone: .ok, device: nil, blockedAccount: nil))
            }
            for push in pushes where push.switchTo != nil || push.orderNames != nil {
                let who = name(push.device)
                let text = push.switchTo.map {
                    String(localized: "\(who) will move to \(account($0, on: push.device)) and take \(from)'s order")
                } ?? String(localized: "\(who) will take \(from)'s order")
                lines.append(GrazrSyncLine(
                    id: "push-\(push.device)", text: text, tone: .ok, device: resolve(push.device), blockedAccount: nil
                ))
            }
        } else {
            lines.append(GrazrSyncLine(
                id: "in-sync", text: String(localized: "All devices in sync"), tone: .ok, device: nil, blockedAccount: nil
            ))
        }

        for member in devices {
            guard let problem = results[member.id] else { continue }
            let who = member.name
            var blocked: GrazrAccount?
            let text: String
            switch problem {
            case .blocked(let id, let reason):
                blocked = member.report.accounts.first { $0.id == id }
                let active = account(member.report.active, on: member.id)
                text = String(localized: "\(who): \(account(id, on: member.id)) is blocked (\(reason)), still on \(active)")
            case .notEnrolled(let id):
                text = String(localized: "\(who): \(account(id, on: member.id)) is not enrolled")
            case .pinned(let id):
                text = String(localized: "\(who): \(account(id, on: member.id)) is pinned to an agent")
            case .needsUpdate:
                text = String(localized: "grazr on \(who) needs 0.4.7+senad.4 or later")
            case .refused(let words):
                text = String(localized: "\(who): \(words)")
            }
            lines.append(GrazrSyncLine(
                id: "problem-\(member.id)", text: text, tone: .warning,
                device: resolve(member.id), blockedAccount: blocked
            ))
        }
        return lines
    }

    private static func relative(_ at: Double, now: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: at), relativeTo: Date(timeIntervalSince1970: now))
    }
}
