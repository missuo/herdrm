import XCTest
@testable import HerdrKit

final class GrazrSyncTests: XCTestCase {
    private let A = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let B = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let C = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private static let standard: [(id: String, name: String)] = [("g", "gmail"), ("i", "icloud"), ("w", "work")]

    private func device(
        _ name: String, id: UUID, order: [String], active: String,
        accounts: [(id: String, name: String)] = standard,
        blocked: [String: String] = [:], blockedUntil: Double? = nil, pins: [String: String] = [:],
        windows: [String: [GrazrWindow]] = [:], changedAt: Double?
    ) -> GrazrSyncDevice {
        let report = GrazrReport(
            active: active,
            accounts: accounts.map { GrazrAccount(id: $0.id, name: $0.name, windows: windows[$0.id] ?? []) },
            order: order,
            blocked: blocked.mapValues { GrazrBlock(reason: $0, until: blockedUntil) },
            pins: pins.mapValues { GrazrPin(account: $0) },
            changedAt: changedAt
        )
        return GrazrSyncDevice(id: id, name: name, report: report)
    }

    private func push(_ device: UUID, order: [String]? = nil, to account: String? = nil, problem: GrazrSyncProblem? = nil) -> GrazrSyncPush {
        GrazrSyncPush(device: device, orderNames: order, switchTo: account, problem: problem)
    }

    private let gi = ["gmail", "icloud"]
    private let giw = ["gmail", "icloud", "work"]

    func testFirstRoundPicksTheNewestDeviceAndPushesToTheOthers() {
        var planner = GrazrSyncPlanner()
        let pushes = planner.observe([
            device("a", id: A, order: gi, active: "g", changedAt: 1000),
            device("b", id: B, order: ["icloud", "gmail"], active: "i", changedAt: 2000),
            device("c", id: C, order: gi, active: "g", changedAt: 500),
        ], now: 0)

        XCTAssertEqual(planner.target?.source, B)
        XCTAssertEqual(pushes, [
            push(A, order: ["icloud", "gmail"], to: "i"),
            push(C, order: ["icloud", "gmail"], to: "i"),
        ])
    }

    func testALoneRotationOnOneDevicePropagates() {
        var planner = GrazrSyncPlanner()
        XCTAssertEqual(planner.observe([
            device("a", id: A, order: gi, active: "g", changedAt: 1000),
            device("b", id: B, order: gi, active: "g", changedAt: 1000),
            device("c", id: C, order: gi, active: "g", changedAt: 1000),
        ], now: 0), [])

        let pushes = planner.observe([
            device("a", id: A, order: gi, active: "g", changedAt: 1000),
            device("b", id: B, order: gi, active: "i", changedAt: 2000),
            device("c", id: C, order: gi, active: "g", changedAt: 1000),
        ], now: 10)

        XCTAssertEqual(planner.target?.source, B)
        XCTAssertEqual(pushes, [push(A, to: "i"), push(C, to: "i")])
    }

    func testTwoDevicesChangingInOneRoundSettleByChangedAt() {
        var planner = GrazrSyncPlanner()
        _ = planner.observe([
            device("a", id: A, order: giw, active: "g", changedAt: 1000),
            device("b", id: B, order: giw, active: "g", changedAt: 1000),
            device("c", id: C, order: giw, active: "g", changedAt: 1000),
        ], now: 0)

        let pushes = planner.observe([
            device("a", id: A, order: giw, active: "i", changedAt: 3000),
            device("b", id: B, order: giw, active: "w", changedAt: 3100),
            device("c", id: C, order: giw, active: "g", changedAt: 1000),
        ], now: 10)

        XCTAssertEqual(planner.target?.source, B)
        XCTAssertEqual(planner.target?.activeID, "w")
        XCTAssertEqual(pushes, [push(A, to: "w"), push(C, to: "w")])
    }

    func testATieSettlesByDeviceName() {
        var planner = GrazrSyncPlanner()
        _ = planner.observe([
            device("alpha", id: A, order: giw, active: "g", changedAt: 1000),
            device("beta", id: B, order: giw, active: "g", changedAt: 1000),
        ], now: 0)

        let pushes = planner.observe([
            device("alpha", id: A, order: giw, active: "i", changedAt: 3000),
            device("beta", id: B, order: giw, active: "w", changedAt: 3010),
        ], now: 10)

        XCTAssertEqual(planner.target?.source, A)
        XCTAssertEqual(pushes, [push(B, to: "i")])
    }

    func testADeviceWithoutChangedAtNeverWins() {
        var planner = GrazrSyncPlanner()
        // "alpha" would win a tie by name; a missing changedAt does not tie.
        let pushes = planner.observe([
            device("alpha", id: A, order: gi, active: "g", changedAt: nil),
            device("beta", id: B, order: gi, active: "i", changedAt: 1),
        ], now: 0)

        XCTAssertEqual(planner.target?.source, B)
        XCTAssertEqual(pushes, [push(A, to: "i")])

        // Later drift on the undated device is pushed back, not followed.
        let again = planner.observe([
            device("alpha", id: A, order: gi, active: "w", changedAt: nil),
            device("beta", id: B, order: gi, active: "i", changedAt: 1),
        ], now: 10)
        XCTAssertEqual(planner.target?.source, B)
        XCTAssertEqual(again, [push(A, to: "i")])
    }

    func testExtraAccountsOnOneDeviceDoNotDiffer() {
        var planner = GrazrSyncPlanner()
        let a = device("a", id: A, order: giw, active: "g", changedAt: 1000)
        let b = device("b", id: B, order: gi, active: "g", accounts: [("g", "gmail"), ("i", "icloud")], changedAt: 2000)
        XCTAssertEqual(planner.observe([a, b], now: 0), [])
        XCTAssertEqual(planner.observe([a, b], now: 10), [])
        let touched = device("a", id: A, order: giw, active: "g", changedAt: 5000)
        XCTAssertEqual(planner.observe([touched, b], now: 20), [])
    }

    func testAPartialFollowerDoesNotBecomeTheSource() {
        var planner = GrazrSyncPlanner()
        let a = device("a", id: A, order: gi, active: "g", blocked: ["i": "rate limited"], changedAt: 1000)
        let b = device("b", id: B, order: gi, active: "i", changedAt: 2000)
        let blocked = GrazrSyncProblem.blocked(accountID: "i", reason: "rate limited")

        XCTAssertEqual(planner.observe([a, b], now: 0), [push(A, problem: blocked)])
        planner.recordResult(device: A, problem: blocked, now: 0)

        XCTAssertEqual(planner.observe([a, b], now: 300), [])
        XCTAssertEqual(planner.target?.source, B)
        XCTAssertEqual(planner.observe([a, b], now: 601), [push(A, problem: blocked)])
        XCTAssertEqual(planner.target?.source, B)
    }

    func testAFollowerIsRetriedWhenItsBlockLifts() {
        var planner = GrazrSyncPlanner()
        let b = device("b", id: B, order: gi, active: "i", changedAt: 2000)
        let blocked = GrazrSyncProblem.blocked(accountID: "i", reason: "rate limited")
        let pushes = planner.observe([
            device("a", id: A, order: gi, active: "g", blocked: ["i": "rate limited"], changedAt: 1000), b,
        ], now: 0)
        XCTAssertEqual(pushes, [push(A, problem: blocked)])
        planner.recordResult(device: A, problem: blocked, now: 0)

        let retried = planner.observe([device("a", id: A, order: gi, active: "g", changedAt: 1000), b], now: 30)
        XCTAssertEqual(retried, [push(A, to: "i")])
    }

    func testAnExpiredBlockIsNotABlock() {
        let now = 1_000_000.0
        let b = device("b", id: B, order: gi, active: "i", changedAt: 2000)

        var expired = GrazrSyncPlanner()
        let lapsed = device("a", id: A, order: gi, active: "g", blocked: ["i": "rate limited"], blockedUntil: now - 10, changedAt: 1000)
        XCTAssertEqual(expired.observe([lapsed, b], now: now), [push(A, to: "i")])

        var current = GrazrSyncPlanner()
        let held = device("a", id: A, order: gi, active: "g", blocked: ["i": "rate limited"], blockedUntil: now + 10, changedAt: 1000)
        XCTAssertEqual(current.observe([held, b], now: now), [push(A, problem: .blocked(accountID: "i", reason: "rate limited"))])
    }

    func testAPinnedAccountIsNeverPushed() {
        var planner = GrazrSyncPlanner()
        let pushes = planner.observe([
            device("a", id: A, order: giw, active: "w", changedAt: 2000),
            device("b", id: B, order: giw, active: "g", pins: ["p1": "w"], changedAt: 1000),
        ], now: 0)

        XCTAssertEqual(pushes, [push(B, problem: .pinned(accountID: "w"))])
        XCTAssertNil(pushes.first?.switchTo)
    }

    func testNotEnrolledIsReportedNotPushed() {
        var planner = GrazrSyncPlanner()
        let pushes = planner.observe([
            device("a", id: A, order: giw, active: "w", changedAt: 2000),
            device("b", id: B, order: gi, active: "g", accounts: [("g", "gmail"), ("i", "icloud")], changedAt: 1000),
        ], now: 0)

        XCTAssertEqual(pushes, [push(B, problem: .notEnrolled(accountID: "w"))])
    }

    func testOrderIsWrittenAsTheFollowersNames() {
        var planner = GrazrSyncPlanner()
        let pushes = planner.observe([
            device("a", id: A, order: ["icloud", "gmail"], active: "i", accounts: [("g", "gmail"), ("i", "icloud")], changedAt: 2000),
            device(
                "b", id: B, order: ["personal", "spare", "apple"], active: "i",
                accounts: [("g", "personal"), ("i", "apple"), ("x", "spare")], changedAt: 1000
            ),
        ], now: 0)

        XCTAssertEqual(pushes, [push(B, order: ["apple", "personal", "spare"])])
    }

    func testTwoBouncesPauseTheSync() {
        var planner = GrazrSyncPlanner()
        XCTAssertEqual(planner.observe([
            device("a", id: A, order: gi, active: "g", changedAt: 1000),
            device("b", id: B, order: gi, active: "i", changedAt: 2000),
        ], now: 0), [push(A, to: "i")])
        planner.recordResult(device: A, problem: nil, now: 0)
        planner.settle(device("a", id: A, order: gi, active: "i", changedAt: 2010))

        // grazr on A rotates away from i, which had headroom there.
        XCTAssertEqual(planner.observe([
            device("a", id: A, order: gi, active: "g", changedAt: 2100),
            device("b", id: B, order: gi, active: "i", changedAt: 2000),
        ], now: 60), [push(B, to: "g")])
        XCTAssertNil(planner.pausedUntil)
        planner.recordResult(device: B, problem: nil, now: 60)
        planner.settle(device("b", id: B, order: gi, active: "g", changedAt: 2110))

        // And grazr on B undoes that in turn: the second bounce pauses.
        let rounds = [
            device("a", id: A, order: gi, active: "g", changedAt: 2100),
            device("b", id: B, order: gi, active: "i", changedAt: 2200),
        ]
        XCTAssertEqual(planner.observe(rounds, now: 120), [])
        XCTAssertEqual(planner.pausedUntil, 120 + 1800)
        XCTAssertEqual(planner.bouncing, GrazrSyncBounce(source: A, follower: B))
        XCTAssertEqual(planner.observe(rounds, now: 600), [])

        // Once the pause ends the newest state is pushed again.
        XCTAssertEqual(planner.observe(rounds, now: 1921), [push(A, to: "i")])
        XCTAssertNil(planner.pausedUntil)
        XCTAssertNil(planner.bouncing)
    }

    func testARotationAwayFromALowAccountIsNotABounce() {
        var planner = GrazrSyncPlanner()
        let low = ["i": [GrazrWindow(kind: "five_hour", group: "session", remaining: 5, resetsAt: Date(timeIntervalSince1970: 10_000_000_000))]]
        XCTAssertEqual(planner.observe([
            device("a", id: A, order: gi, active: "g", windows: low, changedAt: 1000),
            device("b", id: B, order: gi, active: "i", changedAt: 2000),
        ], now: 0), [push(A, to: "i")])
        planner.recordResult(device: A, problem: nil, now: 0)
        planner.settle(device("a", id: A, order: gi, active: "i", windows: low, changedAt: 2010))

        XCTAssertEqual(planner.observe([
            device("a", id: A, order: gi, active: "g", windows: low, changedAt: 2100),
            device("b", id: B, order: gi, active: "i", changedAt: 2000),
        ], now: 60), [push(B, to: "g")])
        planner.recordResult(device: B, problem: nil, now: 60)
        planner.settle(device("b", id: B, order: gi, active: "g", changedAt: 2110))

        // B rotating away from g (with headroom) is one bounce, not two.
        XCTAssertEqual(planner.observe([
            device("a", id: A, order: gi, active: "g", windows: low, changedAt: 2100),
            device("b", id: B, order: gi, active: "i", changedAt: 2200),
        ], now: 120), [push(A, to: "i")])
        XCTAssertNil(planner.pausedUntil)
        XCTAssertNil(planner.bouncing)
    }

    func testALateJoinerWithOlderChangeFollowsAndWithNewerWins() {
        let a = device("a", id: A, order: gi, active: "g", changedAt: 1000)
        let b = device("b", id: B, order: gi, active: "g", changedAt: 1100)

        var older = GrazrSyncPlanner()
        XCTAssertEqual(older.observe([a, b], now: 0), [])
        let follows = older.observe([a, b, device("c", id: C, order: gi, active: "i", changedAt: 500)], now: 10)
        XCTAssertEqual(older.target?.source, B)
        XCTAssertEqual(follows, [push(C, to: "g")])

        var newer = GrazrSyncPlanner()
        XCTAssertEqual(newer.observe([a, b], now: 0), [])
        let wins = newer.observe([a, b, device("c", id: C, order: ["icloud", "gmail"], active: "i", changedAt: 5000)], now: 10)
        XCTAssertEqual(newer.target?.source, C)
        XCTAssertEqual(wins, [
            push(A, order: ["icloud", "gmail"], to: "i"),
            push(B, order: ["icloud", "gmail"], to: "i"),
        ])
    }

    func testSettleDoesNotMakeADeviceAChangeSource() {
        let first = [
            device("a", id: A, order: gi, active: "g", changedAt: 1000),
            device("b", id: B, order: gi, active: "i", changedAt: 2000),
        ]
        let landed = device("a", id: A, order: gi, active: "i", changedAt: 5000)
        let second = [landed, first[1]]

        var settled = GrazrSyncPlanner()
        XCTAssertEqual(settled.observe(first, now: 0), [push(A, to: "i")])
        settled.recordResult(device: A, problem: nil, now: 0)
        settled.settle(landed)
        XCTAssertEqual(settled.lastSeen[A], GrazrSyncState(orderIDs: ["g", "i"], activeID: "i", changedAt: 5000))
        XCTAssertEqual(settled.observe(second, now: 30), [])
        XCTAssertEqual(settled.target?.source, B)

        // Without settle, the landed push would read as A's own change.
        var unsettled = GrazrSyncPlanner()
        _ = unsettled.observe(first, now: 0)
        _ = unsettled.observe(second, now: 30)
        XCTAssertEqual(unsettled.target?.source, A)
    }

    func testBusyRotatingIsRetriedNextRound() {
        var planner = GrazrSyncPlanner()
        let round = [
            device("a", id: A, order: gi, active: "g", changedAt: 1000),
            device("b", id: B, order: gi, active: "i", changedAt: 2000),
        ]
        XCTAssertEqual(planner.observe(round, now: 0), [push(A, to: "i")])
        planner.recordResult(device: A, problem: .refused("grazr: Busy rotating already, try again shortly"), now: 0)
        XCTAssertEqual(planner.observe(round, now: 10), [push(A, to: "i")])

        // Any other refusal waits for a change or retryAfter.
        planner.recordResult(device: A, problem: .refused("Already on that account"), now: 10)
        XCTAssertEqual(planner.observe(round, now: 20), [])
    }

    /// After a restart the order HerdrM pushed to a blocked follower bumps its
    /// changed_at past the source's. A planner restored from its snapshot
    /// knows that state and keeps the source; a fresh one would crown the
    /// follower and move everyone to its account.
    func testARestoredSnapshotKeepsAPushedFollowerFromWinning() throws {
        var planner = GrazrSyncPlanner()
        let ig = ["icloud", "gmail"]
        let blocked = GrazrSyncProblem.blocked(accountID: "i", reason: "rate limited")
        let a = device("a", id: A, order: ig, active: "i", changedAt: 2000)
        let c = device("c", id: C, order: ig, active: "i", changedAt: 1500)
        let b = device("b", id: B, order: gi, active: "g", blocked: ["i": "rate limited"], changedAt: 1000)
        XCTAssertEqual(planner.observe([a, b, c], now: 0), [push(B, order: ig, problem: blocked)])
        // The order lands, the switch cannot: b is on gmail, stamped newest.
        let pushed = device("b", id: B, order: ig, active: "g", blocked: ["i": "rate limited"], changedAt: 3000)
        planner.settle(pushed)
        planner.recordResult(device: B, problem: blocked, now: 0)

        let saved = try JSONEncoder().encode(planner.snapshot())
        var restored = GrazrSyncPlanner(snapshot: try JSONDecoder().decode(GrazrSyncPlanner.Snapshot.self, from: saved))
        XCTAssertEqual(restored.snapshot(), planner.snapshot())
        XCTAssertEqual(restored.observe([a, pushed, c], now: 60), [push(B, problem: blocked)])
        XCTAssertEqual(restored.target?.source, A)

        var fresh = GrazrSyncPlanner()
        XCTAssertEqual(fresh.observe([a, pushed, c], now: 60), [push(A, to: "g"), push(C, to: "g")], "what a restart did before")
    }

    func testForgettingTheSourceLetsTheNewestRemainingLead() {
        let work = GrazrAccount(id: "id-work", name: "work"), home = GrazrAccount(id: "id-home", name: "home")
        func device(_ name: String, active: String, order: [String], at: Double) -> GrazrSyncDevice {
            GrazrSyncDevice(id: UUID(), name: name, report: GrazrReport(
                active: active, accounts: [work, home], order: order, blocked: [:], changedAt: at
            ))
        }
        let studio = device("studio", active: work.id, order: ["work", "home"], at: 3_000)
        let laptop = device("laptop", active: home.id, order: ["home", "work"], at: 2_000)
        let desk = device("desk", active: work.id, order: ["home", "work"], at: 1_000)
        var planner = GrazrSyncPlanner()
        let first = planner.observe([studio, laptop, desk], now: 3_000)
        XCTAssertEqual(planner.target?.source, studio.id)
        XCTAssertEqual(Set(first.map(\.device)), [laptop.id, desk.id])

        // studio leaves before anyone followed: no lead, and nothing moves
        // until a device changes of its own.
        planner.forget(studio.id)
        XCTAssertNil(planner.target)
        XCTAssertEqual(planner.observe([laptop, desk], now: 3_100), [])
        let moved = GrazrSyncDevice(id: laptop.id, name: "laptop", report: GrazrReport(
            active: home.id, accounts: [work, home], order: ["work", "home"], blocked: [:], changedAt: 3_100
        ))
        let next = planner.observe([moved, desk], now: 3_100)
        XCTAssertEqual(planner.target?.source, laptop.id)
        XCTAssertEqual(next.map(\.device), [desk.id])
        XCTAssertEqual(next.first?.orderNames, ["work", "home"])
        XCTAssertEqual(next.first?.switchTo, home.id)

        // A follower leaving is forgotten: back, it is asked again.
        planner.forget(desk.id)
        XCTAssertEqual(planner.target?.source, laptop.id)
        XCTAssertEqual(planner.observe([moved, desk], now: 3_200).map(\.device), [desk.id])
    }

    func testForgettingTheSourceHandsTheLeadToADeviceAlreadyInStep() {
        var planner = GrazrSyncPlanner()
        let ig = ["icloud", "gmail"]
        let blocked = GrazrSyncProblem.blocked(accountID: "i", reason: "rate limited")
        let a = device("a", id: A, order: ig, active: "i", changedAt: 2000)
        let c = device("c", id: C, order: ig, active: "i", changedAt: 1500)
        let b = device("b", id: B, order: gi, active: "g", blocked: ["i": "rate limited"], changedAt: 1000)
        XCTAssertEqual(planner.observe([a, b, c], now: 0), [push(B, order: ig, problem: blocked)])
        let pushed = device("b", id: B, order: ig, active: "g", blocked: ["i": "rate limited"], changedAt: 3000)
        planner.settle(pushed)
        planner.recordResult(device: B, problem: blocked, now: 0)

        // a leaves: c is on the target and leads; b, stamped newest by the
        // order push, does not drag c to gmail.
        planner.forget(A)
        XCTAssertEqual(planner.target?.source, C)
        let pushes = planner.observe([pushed, c], now: 120)
        XCTAssertFalse(pushes.contains { $0.device == C }, "\(pushes)")
        XCTAssertEqual(planner.target?.activeID, "i")
    }

    func testStateMapsOrderNamesToIDsAndEqualityIgnoresUnsharedAccounts() {
        let listed = GrazrSyncState(report: GrazrReport(
            active: "i", accounts: [GrazrAccount(id: "g", name: "gmail"), GrazrAccount(id: "i", name: "icloud")],
            order: ["icloud", "gone", "gmail"], changedAt: 7
        ))
        XCTAssertEqual(listed, GrazrSyncState(orderIDs: ["i", "g"], activeID: "i", changedAt: 7))
        let unlisted = GrazrSyncState(report: GrazrReport(
            accounts: [GrazrAccount(id: "w", name: "work"), GrazrAccount(id: "g", name: "gmail")]
        ))
        XCTAssertEqual(unlisted.orderIDs, ["g", "w"])

        XCTAssertTrue(GrazrSyncPlanner.equal(
            GrazrSyncState(orderIDs: ["i", "x", "g"], activeID: "i", changedAt: 1),
            GrazrSyncState(orderIDs: ["i", "g"], activeID: "i", changedAt: 2)
        ))
        XCTAssertFalse(GrazrSyncPlanner.equal(
            GrazrSyncState(orderIDs: ["g", "i"], activeID: "i", changedAt: nil),
            GrazrSyncState(orderIDs: ["i", "g"], activeID: "i", changedAt: nil)
        ))
    }
}
