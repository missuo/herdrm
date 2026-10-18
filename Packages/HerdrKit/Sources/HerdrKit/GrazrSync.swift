import Foundation

/// One device's rotation as the sync compares it: ACCOUNTS as account ids,
/// and the account Claude is on. Ids, not names, because each device names
/// its accounts itself.
public struct GrazrSyncState: Sendable, Equatable, Hashable {
    public var orderIDs: [String]
    public var activeID: String?
    /// When the device's rotation last changed (epoch seconds).
    public var changedAt: Double?

    /// A name in ACCOUNTS that no enrolled account has drops out. Without
    /// ACCOUNTS grazr rotates through every account, here sorted by name.
    public init(report: GrazrReport) {
        var ids: [String: String] = [:]
        for account in report.accounts where ids[account.name] == nil { ids[account.name] = account.id }
        orderIDs = report.order.isEmpty
            ? report.accounts.sorted { $0.name < $1.name }.map(\.id).uniqued()
            : report.order.compactMap { ids[$0] }.uniqued()
        activeID = report.active
        changedAt = report.changedAt
    }

    public init(orderIDs: [String], activeID: String?, changedAt: Double?) {
        self.orderIDs = orderIDs
        self.activeID = activeID
        self.changedAt = changedAt
    }
}

/// A device taking part in the sync, with its latest grazr report.
public struct GrazrSyncDevice: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let report: GrazrReport

    public init(id: UUID, name: String, report: GrazrReport) {
        self.id = id
        self.name = name
        self.report = report
    }
}

/// The state every device is brought to: the newest change seen, and the
/// device it came from.
public struct GrazrSyncTarget: Sendable, Equatable {
    public var orderIDs: [String]
    public var activeID: String?
    public var at: Double
    public var source: UUID

    public init(orderIDs: [String], activeID: String?, at: Double, source: UUID) {
        self.orderIDs = orderIDs
        self.activeID = activeID
        self.at = at
        self.source = source
    }
}

/// Why a device cannot follow the target.
public enum GrazrSyncProblem: Sendable, Equatable {
    case notEnrolled(accountID: String)
    case blocked(accountID: String, reason: String)
    case pinned(accountID: String)
    /// The device's grazr cannot set ACCOUNTS this way.
    case needsUpdate
    /// grazr's own refusal, in its words.
    case refused(String)
}

/// What to do on one device: write its order (in its own names), switch its
/// active account, or say why it cannot.
public struct GrazrSyncPush: Sendable, Equatable {
    public let device: UUID
    /// Nil when the order already agrees.
    public let orderNames: [String]?
    public let switchTo: String?
    public let problem: GrazrSyncProblem?

    public init(device: UUID, orderNames: [String]?, switchTo: String?, problem: GrazrSyncProblem?) {
        self.device = device
        self.orderNames = orderNames
        self.switchTo = switchTo
        self.problem = problem
    }
}

/// Two devices whose grazrs kept undoing each other: `source`'s state was
/// pushed to `follower`, whose grazr rotated away again.
public struct GrazrSyncBounce: Sendable, Equatable {
    public let source: UUID
    public let follower: UUID

    public init(source: UUID, follower: UUID) {
        self.source = source
        self.follower = follower
    }
}

/// Keeps several devices' grazr on one ACCOUNTS order and one active account.
/// There is no leader: the device that changed most recently wins, and the
/// others are pushed to its state. Pure bookkeeping; a caller runs the pushes.
public struct GrazrSyncPlanner: Sendable, Equatable {
    /// Changes this close together are one moment; the lower name wins.
    public static let tieWindow: Double = 30
    /// A follower rotating away this soon after a push undid it.
    public static let bounceWindow: Double = 120
    /// Two bounces this close together pause the sync.
    public static let bounceSpan: Double = 600
    public static let pauseLength: Double = 1800
    /// A follower that could not follow is asked again after this long, or
    /// sooner when its report changes.
    public static let retryAfter: Double = 600

    public private(set) var lastSeen: [UUID: GrazrSyncState] = [:]
    public private(set) var target: GrazrSyncTarget?
    public private(set) var pausedUntil: Double?
    public private(set) var bouncing: GrazrSyncBounce?

    /// The device as a push found it, so an unchanged one is not asked again.
    private struct Fingerprint: Sendable, Hashable {
        var state: GrazrSyncState
        var blocked: [String]
        var enrolled: [String]
    }

    /// The last push to a device. `pushedAccount` is the switch it asked for,
    /// kept for the bounce check until it lands somewhere else or fails.
    private struct Attempt: Sendable, Equatable {
        var targetAt: Double
        var fingerprint: Fingerprint
        var at: Double
        var pushedAccount: String?
        var hadHeadroom: Bool
        var source: UUID
    }

    private var attempts: [UUID: Attempt] = [:]
    private var bounces: [Double] = []
    private var names: [UUID: String] = [:]

    public init() {}

    /// Same active account, and the orders agree on the accounts both list:
    /// an account only one device has is no difference.
    public static func equal(_ a: GrazrSyncState, _ b: GrazrSyncState) -> Bool {
        guard a.activeID == b.activeID else { return false }
        let common = Set(a.orderIDs).intersection(b.orderIDs)
        return a.orderIDs.filter(common.contains) == b.orderIDs.filter(common.contains)
    }

    /// One round of reports in, the pushes that bring the rest to the target out.
    public mutating func observe(_ devices: [GrazrSyncDevice], now: Double) -> [GrazrSyncPush] {
        let states = devices.map { GrazrSyncState(report: $0.report) }
        for device in devices { names[device.id] = device.name }
        let changed = zip(devices, states).filter { device, state in
            lastSeen[device.id].map { !Self.equal($0, state) } ?? true
        }
        adoptNewest(of: changed)
        for (device, state) in zip(devices, states) { lastSeen[device.id] = state }

        if let pausedUntil {
            guard now >= pausedUntil else { return [] }
            self.pausedUntil = nil
            bouncing = nil
        }
        if countBounces(devices: devices, states: states, now: now) { return [] }
        guard let target else { return [] }
        return zip(devices, states).compactMap { push(to: $0, state: $1, target: target, now: now) }
    }

    /// For a device HerdrM just pushed: its new state is the push landing,
    /// not a change of its own to spread.
    public mutating func settle(_ device: GrazrSyncDevice) {
        lastSeen[device.id] = GrazrSyncState(report: device.report)
    }

    /// After a push ran. grazr busy rotating is passing, so the next round
    /// tries again; any other problem waits for the device to change or for
    /// `retryAfter`.
    public mutating func recordResult(device: UUID, problem: GrazrSyncProblem?, now: Double) {
        guard attempts[device] != nil else { return }
        if case .refused(let text)? = problem, text.contains("Busy rotating") {
            attempts[device] = nil
            return
        }
        attempts[device]?.at = now
        // A switch that did not happen cannot be undone by the device's grazr.
        if problem != nil { attempts[device]?.pushedAccount = nil }
    }

    public mutating func reset() {
        self = GrazrSyncPlanner()
    }

    // MARK: - Steps

    /// The newest changed device becomes the target when it is newer than
    /// the target, or ties it and wins by name. A device without a changedAt
    /// wins only when none is dated and there is no target yet.
    private mutating func adoptNewest(of changed: [(GrazrSyncDevice, GrazrSyncState)]) {
        let dated = changed.filter { $0.1.changedAt != nil }
        let pool = dated.isEmpty ? changed : dated
        guard let newest = pool.map({ $0.1.changedAt ?? 0 }).max(),
              let (winner, state) = pool.filter({ ($0.1.changedAt ?? 0) >= newest - Self.tieWindow })
                  .min(by: { $0.0.name < $1.0.name })
        else { return }
        let at = state.changedAt ?? 0
        if let target {
            guard state.changedAt != nil else { return }
            let newer = at > target.at + Self.tieWindow
            let ties = abs(at - target.at) <= Self.tieWindow
                && (winner.id == target.source || winner.name < (names[target.source] ?? ""))
            guard newer || ties else { return }
        }
        target = GrazrSyncTarget(orderIDs: state.orderIDs, activeID: state.activeID, at: at, source: winner.id)
    }

    /// A follower whose grazr moved off a pushed account that still had
    /// headroom there, soon after the push. The second within `bounceSpan`
    /// pauses the sync; true then.
    private mutating func countBounces(devices: [GrazrSyncDevice], states: [GrazrSyncState], now: Double) -> Bool {
        for (device, state) in zip(devices, states) {
            guard let attempt = attempts[device.id], let account = attempt.pushedAccount,
                  attempt.hadHeadroom, now - attempt.at <= Self.bounceWindow, state.activeID != account
            else { continue }
            attempts[device.id]?.pushedAccount = nil
            bounces = bounces.filter { now - $0 <= Self.bounceSpan } + [now]
            if bounces.count >= 2 {
                pausedUntil = now + Self.pauseLength
                bouncing = GrazrSyncBounce(source: attempt.source, follower: device.id)
                bounces = []
                return true
            }
        }
        return false
    }

    /// The target in the device's own terms: its order rewritten in its
    /// names, extra accounts last, and a switch or the reason it cannot.
    /// Nil for the source, a device already there, or one asked already
    /// that has not changed since.
    private mutating func push(
        to device: GrazrSyncDevice, state: GrazrSyncState, target: GrazrSyncTarget, now: Double
    ) -> GrazrSyncPush? {
        guard device.id != target.source,
              !Self.equal(state, GrazrSyncState(orderIDs: target.orderIDs, activeID: target.activeID, changedAt: nil))
        else { return nil }
        let report = device.report
        let enrolled = Set(report.accounts.map(\.id))
        let fingerprint = Fingerprint(state: state, blocked: report.blocked.keys.sorted(), enrolled: enrolled.sorted())
        if let attempt = attempts[device.id], attempt.targetAt == target.at,
           attempt.fingerprint == fingerprint, now - attempt.at < Self.retryAfter {
            return nil
        }

        let wanted = Set(target.orderIDs)
        let order = (target.orderIDs.filter(enrolled.contains) + state.orderIDs.filter { !wanted.contains($0) }).uniqued()
        let orderNames = order == state.orderIDs
            ? nil
            : order.compactMap { id in report.accounts.first { $0.id == id }?.name }

        var switchTo: String?
        var problem: GrazrSyncProblem?
        if let account = target.activeID, account != state.activeID {
            if !enrolled.contains(account) {
                problem = .notEnrolled(accountID: account)
            } else if let block = report.blocked[account] {
                problem = .blocked(accountID: account, reason: block.reason)
            } else if report.heldAccountIDs.contains(account) {
                problem = .pinned(accountID: account)
            } else {
                switchTo = account
            }
        }
        guard orderNames != nil || switchTo != nil || problem != nil else { return nil }

        let hadHeadroom = switchTo
            .flatMap { id in report.accounts.first { $0.id == id } }
            .map { report.hasHeadroom($0, now: Date(timeIntervalSince1970: now)) } ?? false
        attempts[device.id] = Attempt(
            targetAt: target.at, fingerprint: fingerprint, at: now,
            pushedAccount: switchTo, hadHeadroom: hadHeadroom, source: target.source
        )
        return GrazrSyncPush(device: device.id, orderNames: orderNames, switchTo: switchTo, problem: problem)
    }
}

private extension Array where Element: Hashable {
    /// The first of each element, in order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
