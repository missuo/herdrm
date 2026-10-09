import XCTest
@testable import HerdrKit

final class GrazrAccountsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_876_000) // 2026-10-01 17:33 UTC

    private func window(_ group: String, _ remaining: Int, scope: String? = nil, resetsIn hours: Double) -> GrazrWindow {
        GrazrWindow(
            kind: group, scope: scope, group: group, remaining: remaining,
            resetsAt: now.addingTimeInterval(hours * 3600)
        )
    }

    func testOrdersActiveFirstThenTheConfiguredOrder() {
        let report = GrazrReport(
            active: "c",
            accounts: [
                GrazrAccount(id: "a", name: "a@x"),
                GrazrAccount(id: "z", name: "unlisted@x"),
                GrazrAccount(id: "b", name: "b@x"),
                GrazrAccount(id: "c", name: "c@x"),
            ],
            order: ["b@x", "a@x", "c@x"]
        )

        XCTAssertEqual(report.sortedAccounts.map(\.id), ["c", "b", "a", "z"])
        XCTAssertFalse(report.isListed(report.accounts[1]))
    }

    func testAGapRunsUntilTheSoonestRefillWhenNothingHasHeadroom() {
        let accounts = [
            GrazrAccount(id: "a", name: "a", windows: [window("weekly", 1, resetsIn: 100)], updated: now.timeIntervalSince1970),
            GrazrAccount(id: "b", name: "b", windows: [window("session", 2, resetsIn: 3), window("weekly", 87, resetsIn: 140)]),
            GrazrAccount(id: "c", name: "c", windows: [window("weekly", 0, resetsIn: 60)]),
        ]
        let report = GrazrReport(active: "a", accounts: accounts, order: ["a", "b", "c"])
        XCTAssertNil(report.predictedNext(now: now))
        XCTAssertEqual(report.upcomingGap(now: now), GrazrGap(until: now.addingTimeInterval(3 * 3600), account: accounts[1]))

        // With an account to move into there is no gap.
        let covered = GrazrReport(active: "a", accounts: accounts + [GrazrAccount(id: "d", name: "d")], order: ["a", "b", "c", "d"])
        XCTAssertEqual(covered.predictedNext(now: now)?.id, "d")
        XCTAssertNil(covered.upcomingGap(now: now))
    }

    func testASwapEstimateIgnoresAWindowsFirstMinutes() {
        // 6% of a fresh 5-hour window gone in 2.4 minutes is Claude reloading
        // after a swap, not a pace: only the week (16% in 23.2 h) counts.
        let account = GrazrAccount(id: "a", name: "a", windows: [
            window("session", 94, resetsIn: 5 - 0.04), window("weekly", 84, resetsIn: 7 * 24 - 23.2),
        ], updated: now.timeIntervalSince1970)
        let report = GrazrReport(active: "a", accounts: [account], settings: ["REMAINING_SESSION": "15", "REMAINING_WEEKLY": "15"])

        let eta = report.swapEstimate(for: account, now: now)

        XCTAssertEqual(eta.map { $0.timeIntervalSince(now) / 3600 } ?? 0, 69 / (16 / 23.2), accuracy: 0.01)
    }

    func testModelScopesListEveryPerModelWeekOnce() {
        let report = GrazrReport(accounts: [
            GrazrAccount(id: "a", name: "a", windows: [
                window("session", 77, resetsIn: 2),
                window("weekly", 27, resetsIn: 100),
                window("weekly", 64, scope: "Fable", resetsIn: 100),
            ]),
            GrazrAccount(id: "b", name: "b", windows: [
                window("weekly", 62, scope: "Fable", resetsIn: 50),
                window("weekly", 90, scope: "Opus", resetsIn: 50),
            ]),
            GrazrAccount(id: "c", name: "c"),
        ])

        XCTAssertEqual(report.modelScopes, ["Fable", "Opus"])
        XCTAssertEqual(report.accounts[0].modelWindow("Fable")?.remaining, 64)
        XCTAssertNil(report.accounts[0].modelWindow("Opus"))
        XCTAssertEqual(report.accounts[0].window(.week)?.remaining, 27)
    }

    func testAWindowPastItsResetIsFullAgain() {
        let spent = window("session", 0, resetsIn: -1)
        XCTAssertFalse(spent.isOpen(now: now))
        XCTAssertEqual(spent.left(now: now), 100)

        let open = window("weekly", 14, resetsIn: 30)
        XCTAssertEqual(open.left(now: now), 14)
    }

    func testLeastLeftIgnoresWindowsThatHaveReset() {
        let account = GrazrAccount(id: "a", name: "a", windows: [
            window("session", 0, resetsIn: -2),
            window("weekly", 14, resetsIn: 30),
            window("weekly", 42, scope: "Fable", resetsIn: 30),
        ])
        XCTAssertEqual(account.leastLeft(now: now), 14)
        XCTAssertEqual(account.sortedWindows.map(\.label), ["5h", "Week", "Fable week"])
    }

    func testThresholdsFallBackToGrazrsDefaults() {
        XCTAssertEqual(GrazrReport().sessionThreshold, 15)
        XCTAssertEqual(GrazrReport().weeklyThreshold, 20)
        let report = GrazrReport(settings: ["REMAINING_WEEKLY": "10", "DRY_RUN": "1", "ENABLED": "0"])
        XCTAssertEqual(report.weeklyThreshold, 10)
        XCTAssertTrue(report.dryRun)
        XCTAssertFalse(report.enabled)
    }

    func testALapsedBlockNoLongerApplies() {
        let account = GrazrAccount(id: "a", name: "a")
        let lapsed = GrazrReport(blocked: ["a": GrazrBlock(reason: "rate_limit", until: now.timeIntervalSince1970 - 1)])
        XCTAssertNil(lapsed.block(for: account, now: now))
        let refused = GrazrReport(blocked: ["a": GrazrBlock(reason: "billing_error")])
        XCTAssertEqual(refused.block(for: account, now: now)?.reason, "billing_error")
    }

    func testSwitchTargetsAreEveryUnblockedAccountButTheActiveOne() {
        let report = GrazrReport(
            active: "a",
            accounts: [GrazrAccount(id: "a", name: "a"), GrazrAccount(id: "b", name: "b"), GrazrAccount(id: "c", name: "c")],
            blocked: ["c": GrazrBlock(reason: "authentication_failed")]
        )
        XCTAssertEqual(report.accounts.filter { report.canSwitch(to: $0, now: now) }.map(\.id), ["b"])
    }

    func testTheRotationIsTheConfiguredOrderPlusAnUnlistedActiveAccount() {
        let report = GrazrReport(
            active: "z",
            accounts: [
                GrazrAccount(id: "a", name: "a@x"), GrazrAccount(id: "b", name: "b@x"),
                GrazrAccount(id: "z", name: "z@x"), GrazrAccount(id: "y", name: "y@x"),
            ],
            order: ["b@x", "a@x", "gone@x"]
        )
        XCTAssertEqual(report.rotation.map(\.id), ["b", "a", "z"])
    }

    func testTheNextAccountIsTheFirstListedOneWithHeadroom() {
        let report = GrazrReport(
            active: "a",
            accounts: [
                GrazrAccount(id: "a", name: "a", windows: [window("weekly", 90, resetsIn: 30)]),
                GrazrAccount(id: "b", name: "b", windows: [window("weekly", 50, resetsIn: 30)]),
                GrazrAccount(id: "c", name: "c", windows: [
                    window("session", 100, resetsIn: 2),
                    window("weekly", 10, resetsIn: 30),
                ]),
                GrazrAccount(id: "d", name: "d", windows: [
                    window("weekly", 0, resetsIn: -1),
                    window("weekly", 40, scope: "Fable", resetsIn: 30),
                ]),
                GrazrAccount(id: "e", name: "e"),
            ],
            order: ["a", "b", "c", "d", "e"],
            settings: ["REMAINING_WEEKLY": "15"],
            blocked: ["b": GrazrBlock(reason: "authentication_failed")]
        )
        // a is active, b blocked, c below its week; d's spent week has reset.
        XCTAssertEqual(report.predictedNext(now: now)?.id, "d")

        let unread = GrazrReport(active: "a", accounts: report.accounts, order: ["a", "c", "e"], settings: report.settings)
        XCTAssertEqual(unread.predictedNext(now: now)?.id, "e")
    }

    func testTheNextAccountIsTheOneFullAgainWhenTheActiveOneRunsOut() {
        // 44% of the week used two days in: 22%/day, so 41 more points last
        // about 1.86 days. b's week resets before then, d's and c's after.
        let report = GrazrReport(
            active: "a",
            accounts: [
                GrazrAccount(id: "a", name: "a", windows: [window("weekly", 56, resetsIn: 5 * 24)], updated: now.timeIntervalSince1970),
                GrazrAccount(id: "b", name: "b", windows: [window("weekly", 0, resetsIn: 10)]),
                GrazrAccount(id: "c", name: "c", windows: [window("weekly", 0, resetsIn: 100)]),
                GrazrAccount(id: "d", name: "d", windows: [window("weekly", 0, resetsIn: 50)]),
            ],
            order: ["d", "a", "c", "b"],
            settings: ["REMAINING_WEEKLY": "15"]
        )
        let swap = report.expectedSwap(now: now)
        XCTAssertEqual(swap.timeIntervalSince(now) / 3600, 41.0 / 22 * 24, accuracy: 0.01)

        XCTAssertEqual(report.predictedNext(now: now)?.id, "b")
        XCTAssertEqual(report.availableAt(report.accounts[1], now: now), now.addingTimeInterval(10 * 3600))
        XCTAssertEqual(report.dialOrder(now: now).map(\.id), ["a", "b", "d", "c"])
    }

    func testTheDialPutsBlockedAndAvailableAccountsWhereTheyComeRound() {
        let report = GrazrReport(
            active: "a",
            accounts: [
                GrazrAccount(id: "a", name: "a"),
                GrazrAccount(id: "b", name: "b", windows: [window("weekly", 0, resetsIn: 20)]),
                GrazrAccount(id: "c", name: "c", windows: [window("weekly", 60, resetsIn: 20)]),
                GrazrAccount(id: "d", name: "d", windows: [window("weekly", 80, resetsIn: 20)]),
                GrazrAccount(id: "e", name: "e"),
            ],
            order: ["e", "b", "c", "d", "a"],
            blocked: ["e": GrazrBlock(reason: "authentication_failed")]
        )
        // e is blocked, so c is next; d has headroom now, b refills in 20h.
        XCTAssertEqual(report.dialOrder(now: now).map(\.id), ["a", "c", "d", "b", "e"])
        XCTAssertNil(report.availableAt(report.accounts[4], now: now))
    }

    func testWithNothingToSwapToTheSoonestRefillIsNamed() {
        let report = GrazrReport(
            active: "a",
            accounts: [
                GrazrAccount(id: "a", name: "a"),
                GrazrAccount(id: "b", name: "b", windows: [window("weekly", 0, resetsIn: 40)]),
                GrazrAccount(id: "c", name: "c", windows: [
                    window("session", 3, resetsIn: 2),
                    window("weekly", 5, resetsIn: 10),
                ]),
            ],
            order: ["a", "b", "c"]
        )
        XCTAssertNil(report.predictedNext(now: now))
        let refill = report.nextHeadroom(now: now)
        XCTAssertEqual(refill?.account.id, "c")
        XCTAssertEqual(refill?.at, now.addingTimeInterval(10 * 3600))
    }

    func testTheSwapEstimateCarriesTheWindowsPaceOn() {
        let report = GrazrReport(settings: ["REMAINING_WEEKLY": "15"])
        func account(_ windows: [GrazrWindow]) -> GrazrAccount {
            GrazrAccount(id: "a", name: "a", windows: windows, updated: now.timeIntervalSince1970)
        }
        // 25% used two days into the week: 12.5%/day, so 60 more points last 4.8 days.
        let steady = account([window("weekly", 75, resetsIn: 5 * 24)])
        XCTAssertEqual(report.swapEstimate(for: steady, now: now), now.addingTimeInterval(4.8 * 86400))
        // Three days in, the same 25% runs out after the week resets.
        XCTAssertNil(report.swapEstimate(for: account([window("weekly", 75, resetsIn: 4 * 24)]), now: now))
        XCTAssertNil(report.swapEstimate(for: account([window("weekly", 100, resetsIn: 5 * 24)]), now: now))
        XCTAssertEqual(report.swapEstimate(for: account([window("weekly", 10, resetsIn: 24)]), now: now), now)
        XCTAssertNil(report.swapEstimate(for: GrazrAccount(id: "a", name: "a", windows: steady.windows), now: now))
    }

    func testTheDialPicksTheSessionOrTheAllModelsWeek() {
        let account = GrazrAccount(id: "a", name: "a", windows: [
            window("weekly", 42, scope: "Fable", resetsIn: 30),
            window("weekly", 14, resetsIn: 30),
            window("session", 70, resetsIn: 2),
        ])
        XCTAssertEqual(account.window(.week)?.remaining, 14)
        XCTAssertEqual(account.window(.session)?.remaining, 70)
    }

    func testOnlyABlockWithoutAnEndNeedsASignIn() {
        let report = GrazrReport(
            accounts: [GrazrAccount(id: "a", name: "a"), GrazrAccount(id: "b", name: "b"), GrazrAccount(id: "c", name: "c")],
            blocked: [
                "a": GrazrBlock(reason: "authentication_failed"),
                "b": GrazrBlock(reason: "rate_limit", until: now.timeIntervalSince1970 + 600),
            ]
        )
        XCTAssertEqual(report.accounts.filter { report.needsSignIn($0, now: now) }.map(\.id), ["a"])
    }

    func testASwitchSummaryIsGrazrsLastLine() {
        XCTAssertEqual(GrazrSwitchResult(ok: true, output: "notice\nRotated a -> b\n\n").summary, "Rotated a -> b")
        XCTAssertNil(GrazrSwitchResult(ok: false, output: " \n").summary)
    }

    #if os(macOS)
    /// The reader script itself, against grazr's real file layout in a
    /// throwaway home: what it reports, and that nothing else leaves.
    func testTheReaderReportsGrazrsFilesAndNothingSecret() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("grazr-reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = home.appendingPathComponent(".local/state/herdr/plugins/wazum.grazr")
        let accounts = state.appendingPathComponent("accounts")
        let config = home.appendingPathComponent(".config/herdr/plugins/config/wazum.grazr")
        try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

        func write(_ text: String, to url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("""
        {"name": "work@x", "email": "work@x", "organization": "Acme",
         "accessToken": "sk-SECRET-1",
         "oauthAccount": {"accountUuid": "uuid-work", "emailAddress": "work@x", "refreshToken": "SECRET-2",
                          "organizationType": "claude_pro", "organizationRateLimitTier": "default_claude_ai"},
         "snapshot": [
           {"kind": "session", "scope": null, "group": "session", "remaining": 0, "resets_at": "2026-10-01T21:50:00+00:00"},
           {"kind": "weekly_scoped", "scope": "Fable", "group": "weekly", "remaining": 84, "resets_at": "2026-10-04T18:00:00.513830+00:00"}
         ]}
        """, to: accounts.appendingPathComponent("uuid-work.json"))
        try write(#"{"name": "home@x", "oauthAccount": {"accountUuid": "uuid-home", "organizationType": "claude_pro", "organizationRateLimitTier": "default_claude_ai"}, "snapshot": null}"#,
                  to: accounts.appendingPathComponent("uuid-home.json"))
        try write("not json", to: accounts.appendingPathComponent(".grazr-tmp"))
        try write("""
        # comment
        REMAINING_WEEKLY=10   # weekly
        ACCOUNTS="work@x home@x"
        """, to: config.appendingPathComponent("config.env"))
        try write(#"{"uuid-home": {"reason": "billing_error", "at": 1, "until": null, "reading": [{"secret": "SECRET-3"}]}}"#,
                  to: state.appendingPathComponent("blocked.json"))
        try write(#"{"oauthAccount": {"accountUuid": "uuid-work", "organizationType": "claude_max", "organizationRateLimitTier": "default_claude_max_20x"}, "primaryApiKey": "SECRET-4"}"#,
                  to: home.appendingPathComponent(".claude.json"))

        let environment = "HOME='\(home.path)' XDG_STATE_HOME= XDG_CONFIG_HOME= CLAUDE_CONFIG_DIR= "
        let output = try await DeviceFileService(device: .local).run(environment + Grazr.readerCommand)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("SECRET"))

        let report = try JSONDecoder().decode(GrazrReport.self, from: output)
        XCTAssertEqual(report.active, "uuid-work")
        XCTAssertEqual(report.order, ["work@x", "home@x"])
        XCTAssertEqual(report.weeklyThreshold, 10)
        XCTAssertEqual(report.blocked["uuid-home"]?.reason, "billing_error")
        XCTAssertEqual(report.sortedAccounts.map(\.id), ["uuid-work", "uuid-home"])
        let work = report.sortedAccounts[0]
        XCTAssertEqual(work.organization, "Acme")
        XCTAssertEqual(work.windows.map(\.label), ["5h", "Fable week"])
        XCTAssertEqual(work.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-10-01T21:50:00Z"))
        XCTAssertEqual(report.sortedAccounts[1].windows, [])
        // Claude's own profile for the active account outranks grazr's older
        // copy (an upgrade since); a parked account has only grazr's.
        XCTAssertEqual(report.sortedAccounts.map { $0.plan?.label }, ["Max 20x", "Pro"])
    }

    /// The refresh script runs `grazr.py refresh` in herdr's plugin
    /// environment, and an older grazr without the command says so.
    func testRefreshRunsGrazrsRefreshAndAnOlderGrazrSaysItCannot() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("grazr-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("plugins/wazum.grazr")
        let bin = home.appendingPathComponent(".local/bin")
        for directory in [root, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func write(_ text: String, to url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("""
        #!/bin/sh
        printf '{"result":{"plugins":[{"plugin_id":"wazum.grazr","plugin_root":"%s"}]}}' '\(root.path)'
        """, to: bin.appendingPathComponent("herdr"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("herdr").path)
        try write("", to: root.appendingPathComponent("accounts.py"))
        try write("", to: root.appendingPathComponent("core.py"))
        let environment = "export HOME='\(home.path)' XDG_STATE_HOME= XDG_CONFIG_HOME=; "
        func refreshing() async throws -> GrazrSwitchResult {
            let output = try await DeviceFileService(device: .local).run(environment + Grazr.refreshCommand)
            return try JSONDecoder().decode(GrazrSwitchResult.self, from: output)
        }

        try write("""
        import os
        def refresh():
            pass
        def main(argv):
            print("%s %s" % (argv[1], os.environ["HERDR_PLUGIN_STATE_DIR"].endswith("/wazum.grazr")))
            print("personal: weekly_all 49% left")
            return 0
        """, to: root.appendingPathComponent("grazr.py"))
        let refreshed = try await refreshing()
        XCTAssertEqual(refreshed, GrazrSwitchResult(ok: true, output: "refresh True\npersonal: weekly_all 49% left\n"))

        try write("def main(argv):\n    return 0\n", to: root.appendingPathComponent("grazr.py"))
        let older = try await refreshing()
        XCTAssertFalse(older.ok)
        XCTAssertEqual(older.summary, "This grazr cannot re-read accounts. Update it to 0.4.7+senad.2 or later")
    }

    /// The switch and sign-in scripts, against a stand-in herdr and grazr in a
    /// throwaway home: they find grazr through `herdr plugin list` and run it in
    /// herdr's plugin environment. A switch pins the pick to the chosen
    /// account, listed in ACCOUNTS or not.
    func testSwitchAndSignInRunGrazrPinnedToTheChosenAccount() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("grazr-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("plugins/wazum.grazr")
        let bin = home.appendingPathComponent(".local/bin")
        let accounts = home.appendingPathComponent(".local/state/herdr/plugins/wazum.grazr/accounts")
        for directory in [root, bin, accounts] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func write(_ text: String, to url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("""
        #!/bin/sh
        printf '{"result":{"plugins":[{"plugin_id":"other","plugin_root":"/nowhere"},{"plugin_id":"wazum.grazr","plugin_root":"%s"}]}}' '\(root.path)'
        """, to: bin.appendingPathComponent("herdr"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("herdr").path)
        for id in ["uuid-work", "uuid-spare"] {
            try write("{}", to: accounts.appendingPathComponent("\(id).json"))
        }
        try write("""
        def load(paths, names):
            everyone = ["uuid-work", "uuid-home", "uuid-spare"]
            return [type("Account", (), {"id": id}) for id in (everyone if not names else everyone[:2])]
        """, to: root.appendingPathComponent("accounts.py"))
        try write("""
        def next_account(active, accounts, now, thresholds):
            return "unpatched"
        """, to: root.appendingPathComponent("core.py"))
        try write("""
        import json, os, accounts, core
        def read_key():
            return "q"
        def _enrol_from(runtime, source):
            name = input("account name: ")
            print("Enrolled %s from %s" % (name, os.path.basename(source)))
            return 0
        def main(argv):
            if argv[1] == "enrol":
                if read_key() != "l":
                    return 0
                source = os.path.join(os.environ["HERDR_PLUGIN_STATE_DIR"], "enrol-1")
                os.makedirs(source, exist_ok=True)
                with open(os.path.join(source, ".claude.json"), "w") as handle:
                    json.dump({"oauthAccount": {"accountUuid": os.environ["LOGIN"], "emailAddress": os.environ["LOGIN"] + "@x"}}, handle)
                return _enrol_from(None, source)
            try:
                picked = core.next_account("uuid-work", accounts.load(None, ["work@x", "home@x"]), None, {})
            except RuntimeError as error:
                print("grazr: %s" % error)
                return 1
            if picked is None:
                print("grazr: Nothing to swap to")
                return 1
            same = lambda a, b: os.path.realpath(a) == os.path.realpath(b)
            print("%s %s %s" % (argv[1], same(os.getcwd(), os.environ["HERDR_PLUGIN_ROOT"]), os.environ["HERDR_PLUGIN_STATE_DIR"].endswith("/wazum.grazr")))
            print("Rotated uuid-work -> %s" % picked)
            return 0
        """, to: root.appendingPathComponent("grazr.py"))

        let environment = "export HOME='\(home.path)' XDG_STATE_HOME= XDG_CONFIG_HOME=; "
        func switching(to id: String) async throws -> GrazrSwitchResult {
            let output = try await DeviceFileService(device: .local).run(environment + Grazr.switchCommand(to: id))
            return try JSONDecoder().decode(GrazrSwitchResult.self, from: output)
        }

        let moved = try await switching(to: "uuid-spare")
        XCTAssertTrue(moved.ok)
        XCTAssertEqual(moved.output, "swap True True\nRotated uuid-work -> uuid-spare\n")

        let stayed = try await switching(to: "uuid-work")
        XCTAssertFalse(stayed.ok)
        XCTAssertEqual(stayed.summary, "grazr: Already on that account")

        let gone = try await switching(to: "it's-gone")
        XCTAssertEqual(gone, GrazrSwitchResult(ok: false, output: "That account is no longer enrolled"))

        // Re-authenticating: grazr's enrol, pre-answered with "l" and the
        // account's name, and refused when the browser signed in elsewhere.
        _ = try await DeviceFileService(device: .local).run(environment + Grazr.installReauthCommand)
        func reauthenticating(signedInAs login: String) async throws -> String {
            let output = try await DeviceFileService(device: .local).run(
                environment + "export LOGIN=\(login) PATH=\"$HOME/.local/bin:$PATH\"; "
                    // A refused login exits 1, which `run` would throw on.
                    + "(\(Grazr.reauthInvocation(accountID: "uuid-home", name: "home's@x"))); true"
            )
            return String(decoding: output, as: UTF8.self)
        }
        let renewed = try await reauthenticating(signedInAs: "uuid-home")
        XCTAssertTrue(renewed.contains("account name: home's@x\nEnrolled home's@x from enrol-1\n"), renewed)

        let elsewhere = try await reauthenticating(signedInAs: "uuid-work")
        XCTAssertTrue(elsewhere.contains("That login is uuid-work@x, not home's@x, so nothing changed"), elsewhere)
        XCTAssertFalse(elsewhere.contains("Enrolled"), elsewhere)
    }

    /// Pins and token expiry come through; the token itself, kept beside the
    /// parked logins on Linux, never does.
    func testTheReaderReportsPinsAndTokenExpiryButNoToken() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("grazr-pins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = home.appendingPathComponent(".local/state/herdr/plugins/wazum.grazr")
        for directory in ["accounts", "tokens", "bin"] {
            try FileManager.default.createDirectory(
                at: state.appendingPathComponent(directory), withIntermediateDirectories: true
            )
        }
        func write(_ text: String, to path: String) throws {
            try text.write(to: state.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try write(#"{"name": "home@x", "oauthAccount": {"accountUuid": "uuid-home"}, "snapshot": []}"#,
                  to: "accounts/uuid-home.json")
        try write("sk-ant-oat01-SECRET-T", to: "tokens/uuid-home")
        try write(#"{"uuid-home": {"set_at": 1, "expires_at": 1900000000}}"#, to: "tokens.json")
        try write(#"{"w1:p1": {"account": "uuid-home", "running": null, "at": 1}}"#, to: "pins.json")
        try write("#!/usr/bin/env python3\n", to: "bin/claude")

        let environment = "HOME='\(home.path)' XDG_STATE_HOME= XDG_CONFIG_HOME= CLAUDE_CONFIG_DIR= "
        let output = try await DeviceFileService(device: .local).run(environment + Grazr.readerCommand)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("SECRET"))

        let report = try JSONDecoder().decode(GrazrReport.self, from: output)
        XCTAssertEqual(report.pins, ["w1:p1": GrazrPin(account: "uuid-home", running: nil)])
        XCTAssertTrue(report.pinsInstalled)
        XCTAssertEqual(report.accounts.first?.tokenExpires, 1_900_000_000)
        XCTAssertTrue(report.pinIsPending(paneID: "w1:p1"))
    }

    /// The pin scripts hand their arguments to grazr in herdr's plugin
    /// environment; a grazr from before pinned agents says it needs updating.
    func testPinCommandsRunGrazrWithTheirArguments() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("grazr-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("plugins/wazum.grazr")
        let bin = home.appendingPathComponent(".local/bin")
        for directory in [root, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func write(_ text: String, to url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("""
        #!/bin/sh
        printf '{"result":{"plugins":[{"plugin_id":"wazum.grazr","plugin_root":"%s"}]}}' '\(root.path)'
        """, to: bin.appendingPathComponent("herdr"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("herdr").path)
        try write("", to: root.appendingPathComponent("accounts.py"))
        try write("", to: root.appendingPathComponent("core.py"))
        let environment = "export HOME='\(home.path)' XDG_STATE_HOME= XDG_CONFIG_HOME=; "
        func run(_ command: String) async throws -> GrazrSwitchResult {
            let output = try await DeviceFileService(device: .local).run(environment + command)
            return try JSONDecoder().decode(GrazrSwitchResult.self, from: output)
        }

        try write("""
        def pin():
            pass
        def main(argv):
            print(" ".join(argv[1:]))
            return 0 if argv[1] != "pin" or argv[3] != "spent" else 1
        """, to: root.appendingPathComponent("grazr.py"))
        let pinned = try await run(Grazr.pinCommand(paneID: "w1:p1", accountID: "uuid-a b"))
        XCTAssertEqual(pinned, GrazrSwitchResult(ok: true, output: "pin w1:p1 uuid-a b\n"))
        let refused = try await run(Grazr.pinCommand(paneID: "w1:p1", accountID: "spent"))
        XCTAssertFalse(refused.ok)
        let unpinned = try await run(Grazr.unpinCommand(paneID: "w1:p1"))
        XCTAssertEqual(unpinned.summary, "unpin w1:p1")
        let kept = try await run(Grazr.setPinnedRotationCommand(keep: true))
        XCTAssertEqual(kept.summary, "set PINNED_ROTATION keep")
        let installed = try await run(Grazr.installPinsCommand)
        XCTAssertEqual(installed.summary, "pins-install")

        try write("def main(argv):\n    return 0\n", to: root.appendingPathComponent("grazr.py"))
        let older = try await run(Grazr.unpinCommand(paneID: "w1:p1"))
        XCTAssertFalse(older.ok)
        XCTAssertEqual(older.summary, "This grazr cannot pin agents. Update it to 0.4.7+senad.3 or later")
    }

    #endif

    func testAPlanReadsAsItsNameAndMultiplier() {
        XCTAssertEqual(GrazrPlan(type: "claude_pro", tier: "default_claude_ai").label, "Pro")
        XCTAssertEqual(GrazrPlan(type: "claude_max", tier: "default_claude_max_20x").label, "Max 20x")
        XCTAssertEqual(GrazrPlan(type: "claude_max", tier: "default_claude_max_5x").label, "Max 5x")
        // A Team seat's own tier is the one its usage runs on.
        XCTAssertEqual(GrazrPlan(type: "claude_team", tier: "default_raven", seatTier: "default_claude_max_5x").label, "Team 5x")
        XCTAssertEqual(GrazrPlan(type: "claude_team", tier: "default_raven").label, "Team")
        XCTAssertEqual(GrazrPlan(type: "claude_some_new_plan").label, "Some New Plan")
    }

    func testAReportDecodesAPlanAndItsAbsence() throws {
        let json = Data("""
        {"installed": true, "active": "a", "order": [], "settings": {}, "blocked": {}, "accounts": [
          {"id": "a", "name": "a@x", "organization": null, "windows": [], "updated": 1,
           "plan": {"type": "claude_max", "tier": "default_claude_max_20x", "seat_tier": null}},
          {"id": "b", "name": "b@x", "organization": null, "windows": [], "updated": 1, "plan": null},
          {"id": "c", "name": "c@x", "windows": []}
        ]}
        """.utf8)

        let report = try JSONDecoder().decode(GrazrReport.self, from: json)

        XCTAssertEqual(report.accounts.map { $0.plan?.label }, ["Max 20x", nil, nil])
    }

    func testPinsSayWhichPaneRunsOnWhichAccount() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let home = GrazrAccount(id: "home", name: "home@x", tokenExpires: now.timeIntervalSince1970 + 86_400 * 10.5)
        let work = GrazrAccount(id: "work", name: "work@x", tokenExpires: now.timeIntervalSince1970 - 1)
        let report = GrazrReport(
            active: "work",
            accounts: [home, work],
            settings: ["PINNED_ROTATION": "keep"],
            pins: [
                "w1:p1": GrazrPin(account: "home", running: "home"),
                "w1:p2": GrazrPin(account: "home"),
                "w1:p3": GrazrPin(account: nil, running: "work"),
            ]
        )

        XCTAssertEqual(report.pinnedAccount(paneID: "w1:p1"), home)
        XCTAssertNil(report.pinnedAccount(paneID: "w1:p3"))
        XCTAssertEqual(report.runningAccount(paneID: "w1:p3"), work)
        XCTAssertEqual(["w1:p1", "w1:p2", "w1:p3", "w9:p9"].map(report.pinIsPending), [false, true, true, false])
        XCTAssertEqual(report.pinnedPanes(for: home), ["w1:p1", "w1:p2"])
        XCTAssertEqual(report.pinnedPanes(for: work), ["w1:p3"])
        // A lapsed token cannot be pinned to.
        XCTAssertEqual(report.pinnableAccounts(now: now), [home])
        XCTAssertEqual(home.tokenDaysLeft(now: now), 10)
        XCTAssertNil(work.tokenDaysLeft(now: now))
        XCTAssertTrue(report.keepsPinnedInRotation)
        XCTAssertFalse(GrazrReport().keepsPinnedInRotation)
    }
}
