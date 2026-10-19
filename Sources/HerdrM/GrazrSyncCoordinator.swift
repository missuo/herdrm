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
    /// Turned on (or relaunched before Apply) with something to move: what
    /// the first round would do, run on Apply. Nothing to move skips it.
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
    /// Rereads a device's grazr into its session; false when it could not,
    /// which leaves the last report there. Tests replace it.
    var reportLoader: @MainActor (UUID) async -> Bool
    /// Runs a shell command on a device. Tests replace it.
    var commandRunner: @MainActor (Device, String) async throws -> Data = { device, command in
        try await DeviceFileService(device: device).run(command)
    }
    /// Posts a notification: title, body, device name. Tests replace it.
    var notifier: @MainActor (String, String, String) -> Void = { title, body, deviceName in
        NotificationManager.shared.postPluginResult(title: title, body: body, deviceName: deviceName)
    }

    private var loop: Task<Void, Never>?
    private var running = false
    private var runAgain = false
    /// Bumped by every on/off, so a round from before stops pushing.
    private var generation = 0
    /// What each device last could not do, kept until it follows or a push
    /// says otherwise: the planner does not ask an unchanged device again.
    private var problems: [UUID: GrazrSyncProblem] = [:]
    /// Any command ran since the option went on. Until then the devices
    /// agreed by themselves.
    private var pushedAnything = false
    /// Pushed devices whose reread failed: settled at their next read, so the
    /// state HerdrM wrote is not taken for a change of their own. Saved.
    private var unsettled: Set<UUID> = []
    /// Switches that answered ok on a device that could not be reread: the
    /// next read says whether they landed. Not saved.
    private var unconfirmed: [UUID: (account: String, summary: String?, sourceName: String)] = [:]
    /// A preview with moves was shown since the option went on (or before
    /// this launch): a lone device then no longer counts as nothing to approve.
    private var heldForApproval = false

    /// What `syncAccountsStateKey` holds.
    private struct Saved: Codable {
        var planner: GrazrSyncPlanner.Snapshot
        var unsettled: [UUID]
    }

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        reportLoader = { [unowned model] in await model.loadGrazrReport(deviceID: $0) }
    }

    var enabled: Bool { defaults.bool(forKey: AppModel.syncAccountsKey) }
    /// The user applied the first round, or it had nothing to approve.
    var applied: Bool { defaults.bool(forKey: AppModel.syncAccountsAppliedKey) }

    /// On shows what the first round would do and pushes nothing until
    /// `apply` (nothing to approve starts the sync at once); off stops the
    /// loop and forgets everything seen. On while already syncing changes
    /// nothing.
    func setEnabled(_ on: Bool) {
        if on, enabled, loop != nil { return }
        defaults.set(on, forKey: AppModel.syncAccountsKey)
        defaults.removeObject(forKey: AppModel.syncAccountsAppliedKey)
        defaults.removeObject(forKey: AppModel.syncAccountsStateKey)
        generation += 1
        loop?.cancel()
        loop = nil
        planner.reset()
        problems = [:]
        pushedAnything = false
        unsettled = []
        unconfirmed = [:]
        heldForApproval = false
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
        markApplied()
        startLoop()
    }

    /// At launch: applied, the sync carries on from the saved state without
    /// a preview; not yet applied, the preview is shown again.
    func startIfEnabled() {
        guard enabled, loop == nil else { return }
        if applied {
            restore()
            startLoop()
        } else {
            heldForApproval = true
            pendingRound = Task { await round(preview: true) }
        }
    }

    /// One round now. Before Apply it only refreshes the preview.
    func kick() {
        guard enabled else { return }
        if loop != nil {
            pendingRound = Task { await round(preview: false) }
        } else if !applied, model.grazrSyncStatus != .off {
            pendingRound = Task { await round(preview: true) }
        }
    }

    private func markApplied() {
        defaults.set(true, forKey: AppModel.syncAccountsAppliedKey)
        heldForApproval = false
    }

    private func save() {
        let saved = Saved(planner: planner.snapshot(), unsettled: unsettled.sorted { $0.uuidString < $1.uuidString })
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: AppModel.syncAccountsStateKey)
    }

    private func restore() {
        guard let data = defaults.data(forKey: AppModel.syncAccountsStateKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        planner = GrazrSyncPlanner(snapshot: saved.planner)
        unsettled = Set(saved.unsettled)
    }

    /// A round now (`pendingRound`) unless the caller is in one, then one
    /// each `interval`.
    private func startLoop(roundNow: Bool = true) {
        loop?.cancel()
        let generation = generation
        let first: Task<Void, Never>? = roundNow ? Task { await round(preview: false) } : nil
        if let first { pendingRound = first }
        loop = Task { [weak self] in
            await first?.value
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                await self.round(preview: false)
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
        // A device that cannot be read sits this round out with its last state.
        var unread: Set<UUID> = []
        for device in group where !(await reportLoader(device.id)) { unread.insert(device.id) }
        guard generation == self.generation else { return }
        let known = syncDevices(group)
        guard known.count >= 2 else {
            // One device at enable: nothing to approve, the sync waits for a
            // second. Not so once moves were shown, or for a launch that has
            // not met every device yet.
            if preview, !heldForApproval {
                markApplied()
                startLoop(roundNow: false)
            }
            model.grazrSyncStatus = .fewDevices(name: known.first?.name)
            return
        }
        let members = known.filter { !unread.contains($0.id) }
        guard members.count >= 2 else { return }
        let now = Date().timeIntervalSince1970

        if preview {
            var copy = planner
            let pushes = copy.observe(members, now: now)
            if pushes.contains(where: { $0.orderNames != nil || $0.switchTo != nil }) {
                heldForApproval = true
                let found = Dictionary(pushes.compactMap { push in push.problem.map { (push.device, $0) } }) { $1 }
                model.grazrSyncStatus = .preview(
                    lines: Self.lines(
                        planner: copy, pushes: pushes, results: found, pushedAnything: pushedAnything,
                        devices: members, now: now, device: model.device
                    ),
                    pushes: pushes
                )
                return
            }
            // Nothing would move. The first enable with nothing to move starts at
            // once; after a preview with moves (or a launch before Apply) the user
            // still confirms, even when only the devices that agree were read.
            if heldForApproval {
                model.grazrSyncStatus = .preview(
                    lines: Self.lines(planner: copy, pushes: [], results: [:], pushedAnything: pushedAnything,
                                      devices: members, now: now, device: model.device),
                    pushes: []
                )
                return
            }
            markApplied()
            startLoop(roundNow: false)
        }

        // Read again since a push whose reread failed: what it finds is that push.
        for member in members {
            if unsettled.remove(member.id) != nil { planner.settle(member) }
            if let pending = unconfirmed.removeValue(forKey: member.id), let device = model.device(member.id) {
                let problem = confirm(
                    pending.account, on: device, report: member.report, summary: pending.summary,
                    sourceName: pending.sourceName
                )
                if let problem {
                    planner.recordResult(device: member.id, problem: problem, now: now)
                    problems[member.id] = problem
                }
            }
        }
        let pushes = planner.observe(members, now: now)
        let sourceName = planner.target.flatMap { target in members.first { $0.id == target.source }?.name } ?? ""
        for push in pushes where push.device != planner.target?.source {
            guard generation == self.generation, let device = model.device(push.device) else { continue }
            let problem = await execute(push, on: device, sourceName: sourceName, generation: generation)
            if generation == self.generation { problems[push.device] = problem }
        }
        guard generation == self.generation else { return }

        let fresh = syncDevices(group.filter { !unread.contains($0.id) })
        let inGroup = Set(known.map(\.id))
        let wanted = planner.target.map { GrazrSyncState(orderIDs: $0.orderIDs, activeID: $0.activeID, changedAt: nil) }
        // An unread device keeps its problem; one that follows now loses it.
        problems = problems.filter { id, _ in
            guard inGroup.contains(id) else { return false }
            guard let wanted, let report = fresh.first(where: { $0.id == id })?.report else { return true }
            return !GrazrSyncPlanner.equal(GrazrSyncState(report: report), wanted)
        }
        model.grazrSyncStatus = .lines(Self.lines(
            planner: planner, pushes: [], results: problems, pushedAnything: pushedAnything,
            devices: known.map { device in fresh.first { $0.id == device.id } ?? device }, now: now, device: model.device
        ))
        save()
    }

    /// Order first, then the switch. Returns what got in the way, if anything.
    /// A push that outlives an on/off leaves the new planner alone.
    private func execute(
        _ push: GrazrSyncPush, on device: Device, sourceName: String, generation: Int
    ) async -> GrazrSyncProblem? {
        var orderProblem: GrazrSyncProblem?
        var switchProblem = push.problem
        var ran = false
        /// An ok answer: grazr's summary, until a reread shows it landed.
        var answered: (account: String, summary: String?)?
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
            case .answered(let result) where result.ok: answered = (account, result.summary)
            case .answered(let result): switchProblem = Self.problem(from: result, accountID: account)
            case .failed(let problem): switchProblem = problem
            }
        }
        // Unread after the push: its state stays unknown, not the old one.
        let reread = ran ? await reportLoader(device.id) : false
        guard generation == self.generation else { return switchProblem ?? orderProblem }
        if ran { pushedAnything = true }
        let report = reread ? model.session(device.id).grazrReport : nil
        if let report {
            unsettled.remove(device.id)
            planner.settle(GrazrSyncDevice(id: device.id, name: device.name, report: report))
            if let answered {
                switchProblem = confirm(
                    answered.account, on: device, report: report, summary: answered.summary, sourceName: sourceName
                )
            }
        } else if ran {
            unsettled.insert(device.id)
            if let answered { unconfirmed[device.id] = (answered.account, answered.summary, sourceName) }
        }
        let problem = switchProblem ?? orderProblem
        planner.recordResult(device: device.id, problem: problem, now: Date().timeIntervalSince1970)
        return problem
    }

    /// A switch grazr answered ok counts once the device's report is on the
    /// account: notified then. grazr with DRY_RUN=1 answers ok and stays put,
    /// which is a refusal in its words, so it is not pushed again at once.
    private func confirm(
        _ account: String, on device: Device, report: GrazrReport, summary: String?, sourceName: String
    ) -> GrazrSyncProblem? {
        guard report.active == account else {
            return .refused(summary ?? String(localized: "did not move"))
        }
        let name = report.accounts.first { $0.id == account }?.name ?? account
        notifier(
            String(localized: "grazr: \(device.name) now on \(name)"),
            String(localized: "following \(sourceName)"),
            device.name
        )
        return nil
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
    /// do, and each device's problem. Before anything was pushed, with
    /// nothing to do or report, it reads "All devices in sync". `device`
    /// resolves an id for the lines that act on one.
    static func lines(
        planner: GrazrSyncPlanner, pushes: [GrazrSyncPush], results: [UUID: GrazrSyncProblem], pushedAnything: Bool,
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
        // Nothing to do since the option went on: the devices agree by themselves.
        let agreed = !pushedAnything && results.isEmpty && pushes.isEmpty && planner.bouncing == nil
        if !agreed, let target = planner.target {
            let wanted = GrazrSyncState(orderIDs: target.orderIDs, activeID: target.activeID, changedAt: nil)
            let following = devices
                .filter { $0.id != target.source && GrazrSyncPlanner.equal(GrazrSyncState(report: $0.report), wanted) }
                .map(\.name)
            let followers = following.joined(separator: ", ")
            let from = name(target.source)
            if !following.isEmpty {
                let text: String
                switch (following.count, target.at > 0) {
                case (1, true): text = String(localized: "\(followers) follows \(from) (changed \(relative(target.at, now: now)))")
                case (1, false): text = String(localized: "\(followers) follows \(from)")
                case (_, true): text = String(localized: "\(followers) follow \(from) (changed \(relative(target.at, now: now)))")
                case (_, false): text = String(localized: "\(followers) follow \(from)")
                }
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
