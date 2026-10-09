import Foundation

/// grazr (github.com/wazum/herdr-grazr) rotates Claude Code between several
/// subscriptions. It keeps what each account had left in plain JSON files on
/// the device; this reads them for the sidebar's Accounts window.
public enum Grazr {
    public static let pluginID = "wazum.grazr"
    public static let swapActionID = "swap"

    /// Prints a `GrazrReport` as JSON. Runs on the device with the python3
    /// grazr itself needs. Only names, ids, plans and usage readings leave the
    /// device: the parked credentials live elsewhere, and `.claude.json`
    /// contributes the active account's id and plan and nothing else.
    public static let readerCommand = #"""
    python3 - <<'GRAZR_EOF'
    import glob, json, os
    from datetime import datetime

    home = os.path.expanduser("~")
    state = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local/state"), "herdr/plugins/wazum.grazr")
    config = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config"), "herdr/plugins/config/wazum.grazr/config.env")

    def load(path, default=None):
        try:
            with open(path) as handle:
                return json.load(handle)
        except Exception:
            return default

    def epoch(text):
        try:
            return datetime.fromisoformat(text).timestamp()
        except Exception:
            return None

    def plan(oauth):
        if not oauth.get("organizationType"):
            return None
        return {
            "type": oauth["organizationType"],
            "tier": oauth.get("organizationRateLimitTier"),
            "seat_tier": oauth.get("userRateLimitTier"),
        }

    claude = (load(os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or home, ".claude.json"), {}) or {}).get("oauthAccount") or {}
    report = {"installed": os.path.isdir(state), "accounts": [], "order": [], "settings": {}, "blocked": {}}
    # When each pin token lapses: grazr's bookkeeping, never the token.
    tokens = load(os.path.join(state, "tokens.json"), {}) or {}
    report["active"] = claude.get("accountUuid")
    for path in sorted(glob.glob(os.path.join(state, "accounts", "*.json"))):
        entry = load(path)
        if not isinstance(entry, dict):
            continue
        oauth = entry.get("oauthAccount") or {}
        windows = []
        for window in entry.get("snapshot") or []:
            if isinstance(window, dict) and isinstance(window.get("remaining"), (int, float)):
                windows.append({
                    "kind": str(window.get("kind") or ""),
                    "scope": window.get("scope"),
                    "group": str(window.get("group") or ""),
                    "remaining": int(window["remaining"]),
                    "resets_at": epoch(window.get("resets_at") or ""),
                })
        identifier = oauth.get("accountUuid") or os.path.basename(path)[:-5]
        report["accounts"].append({
            "id": identifier,
            "name": entry.get("name") or entry.get("email") or "",
            "organization": entry.get("organization"),
            # grazr's copy is the profile at enrolment or the last park, so a
            # plan changed since shows only on the account Claude is on: its
            # own copy is fresh. Older enrolments kept no plan at all.
            "plan": (plan(claude) if identifier == report["active"] else None) or plan(oauth),
            "windows": windows,
            "updated": os.path.getmtime(path),
            "token_expires": (tokens.get(identifier) or {}).get("expires_at") if isinstance(tokens, dict) else None,
        })

    try:
        with open(config) as handle:
            for line in handle:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    key, value = line.split("=", 1)
                    report["settings"][key.strip()] = value.strip().strip("\"'")
    except Exception:
        pass
    report["order"] = report["settings"].get("ACCOUNTS", "").split()

    for identifier, entry in (load(os.path.join(state, "blocked.json"), {}) or {}).items():
        if isinstance(entry, dict):
            report["blocked"][identifier] = {"reason": str(entry.get("reason") or ""), "until": entry.get("until")}

    report["pins"] = {
        pane: {"account": entry.get("account"), "running": entry.get("running")}
        for pane, entry in (load(os.path.join(state, "pins.json"), {}) or {}).items()
        if isinstance(entry, dict)
    }
    report["pins_installed"] = os.path.exists(os.path.join(state, "bin", "claude"))

    print(json.dumps(report))
    GRAZR_EOF
    """#

    #if os(macOS)
    /// Moves Claude to one chosen account and prints a `GrazrSwitchResult`.
    /// grazr's own `swap` only knows "the next account with headroom", so this
    /// runs that same swap -- rotation lock, credential park, pane tags, log --
    /// with its pick pinned to `accountID`, from any enrolled account rather
    /// than only those in ACCOUNTS. grazr's refusals land in `output`, not in a
    /// failed exit.
    public static func switchCommand(to accountID: String) -> String {
        SSHTunnel.remotePathExport + "\n"
            + "python3 - \(HerdrService.shellQuoted(accountID)) <<'GRAZR_EOF'\n"
            + #"""
            import json, sys

            target = sys.argv[1]

            def fail(output):
                print(json.dumps({"ok": False, "output": output}))
                sys.exit(0)

            """#
            + pluginPreamble
            + #"""

            if not os.path.isfile(os.path.join(state, "accounts", target + ".json")):
                fail("That account is no longer enrolled")

            load = accounts.load
            accounts.load = lambda paths, names: load(paths, [])

            def pinned(active, enrolled, now, thresholds):
                # grazr prints a RuntimeError as its refusal.
                if active == target:
                    raise RuntimeError("Already on that account")
                return next((entry.id for entry in enrolled if entry.id == target), None)

            core.next_account = pinned
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = grazr.main(["grazr.py", "swap"])
            print(json.dumps({"ok": code == 0, "output": output.getvalue()}))
            GRAZR_EOF
            """#
    }

    /// Has grazr read every account's usage from Claude now (`grazr.py
    /// refresh`), so the reader that follows sees current numbers rather than
    /// what each parked account showed when grazr left it. Prints a
    /// `GrazrSwitchResult`; a grazr without the command says so instead.
    public static let refreshCommand: String =
        SSHTunnel.remotePathExport + "\n"
            + "python3 - <<'GRAZR_EOF'\n"
            + #"""
            import json, sys

            def fail(output):
                print(json.dumps({"ok": False, "output": output}))
                sys.exit(0)

            """#
            + pluginPreamble
            + #"""

            if not hasattr(grazr, "refresh"):
                fail("This grazr cannot re-read accounts. Update it to 0.4.7+senad.2 or later")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = grazr.main(["grazr.py", "refresh"])
            print(json.dumps({"ok": code == 0, "output": output.getvalue()}))
            GRAZR_EOF
            """#

    /// Runs `grazr.py <arguments>` (pin, unpin, set, pins-install) and prints
    /// a `GrazrSwitchResult` with what grazr said. A grazr from before pinned
    /// agents says it needs updating instead.
    public static func pinsCommand(_ arguments: [String]) -> String {
        SSHTunnel.remotePathExport + "\n"
            + "python3 - \(arguments.map(HerdrService.shellQuoted).joined(separator: " ")) <<'GRAZR_EOF'\n"
            + #"""
            import json, sys

            def fail(output):
                print(json.dumps({"ok": False, "output": output}))
                sys.exit(0)

            """#
            + pluginPreamble
            + #"""

            if not hasattr(grazr, "pin"):
                fail("This grazr cannot pin agents. Update it to 0.4.7+senad.3 or later")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = grazr.main(["grazr.py"] + sys.argv[1:])
            print(json.dumps({"ok": code == 0, "output": output.getvalue()}))
            GRAZR_EOF
            """#
    }

    public static func pinCommand(paneID: String, accountID: String) -> String {
        pinsCommand(["pin", paneID, accountID])
    }

    public static func unpinCommand(paneID: String) -> String {
        pinsCommand(["unpin", paneID])
    }

    public static func setPinnedRotationCommand(keep: Bool) -> String {
        pinsCommand(["set", "PINNED_ROTATION", keep ? "keep" : "exclude"])
    }

    public static let installPinsCommand = pinsCommand(["pins-install"])

    /// Where `installTokenCommand` puts the token script on the device.
    public static let tokenScriptPath = "~/.cache/herdrm/grazr-token.py"

    /// Writes the script `tokenInvocation` runs in a terminal: grazr's own
    /// `token` entry, which has Claude make the account's pin token in the
    /// browser and stores it. The token never passes through HerdrM.
    public static var installTokenCommand: String {
        "mkdir -p ~/.cache/herdrm && cat > \(tokenScriptPath) <<'GRAZR_EOF'\n"
            + #"""
            import json, sys

            def fail(message):
                print(message + "\n\npress return to close")
                sys.stdin.readline()
                sys.exit(1)

            """#
            + pluginPreamble
            + #"""

            if not hasattr(grazr, "token"):
                fail("This grazr cannot pin agents. Update it to 0.4.7+senad.3 or later")
            code = grazr.main(["grazr.py", "token", sys.argv[1]])
            print("\npress any key to close")
            grazr.read_key()
            sys.exit(code)
            GRAZR_EOF
            """#
    }

    public static func tokenInvocation(accountID: String) -> String {
        "exec python3 \(tokenScriptPath) \(HerdrService.shellQuoted(accountID))"
    }

    /// Where `installReauthCommand` puts the sign-in script on the device.
    public static let reauthScriptPath = "~/.cache/herdrm/grazr-reauth.py"

    /// Writes the sign-in script that `reauthInvocation` runs in a terminal.
    /// It goes to a file first so the terminal shows one short line, not the
    /// script pasted into the shell.
    public static var installReauthCommand: String {
        "mkdir -p ~/.cache/herdrm && cat > \(reauthScriptPath) <<'GRAZR_EOF'\n"
            + #"""
            import json, sys

            target, name = sys.argv[1], sys.argv[2]

            def fail(message):
                print(message + "\n\npress return to close")
                sys.stdin.readline()
                sys.exit(1)

            """#
            + pluginPreamble
            + #"""

            # grazr's enrol, pre-answered: "l" logs in with an isolated config
            # dir, leaving the account Claude is on alone, and the name is the
            # account's own. Re-enrolling lifts grazr's block on it.
            key = grazr.read_key
            grazr.read_key = lambda *args: "l"
            grazr.input = lambda prompt="": print(prompt + name) or name
            enrol_from = grazr._enrol_from

            def same_account(runtime, source):
                try:
                    with open(os.path.join(source, ".claude.json")) as handle:
                        signed = json.load(handle).get("oauthAccount") or {}
                except Exception:
                    signed = {}
                if signed.get("accountUuid") != target:
                    print("\nThat login is %s, not %s, so nothing changed. Sign in as %s."
                          % (signed.get("emailAddress") or "another account", name, name))
                    return 1
                return enrol_from(runtime, source)

            grazr._enrol_from = same_account
            print("Sign in to Claude as %s. Claude's current account is left as it is.\n" % name)
            code = grazr.main(["grazr.py", "enrol"])
            print("\npress any key to close")
            key()
            sys.exit(code)
            GRAZR_EOF
            """#
    }

    /// The line typed into a fresh terminal on the device; the tab closes
    /// with the script.
    public static func reauthInvocation(accountID: String, name: String) -> String {
        "exec python3 \(reauthScriptPath) \(HerdrService.shellQuoted(accountID)) \(HerdrService.shellQuoted(name))"
    }

    /// Finds grazr through `herdr plugin list` and sets the environment herdr
    /// gives a plugin action, then imports grazr's modules. Expects `fail`.
    private static let pluginPreamble = #"""
    import contextlib, io, os, shutil, subprocess

    home = os.path.expanduser("~")
    herdr = shutil.which("herdr")
    if not herdr:
        fail("herdr is not on this device's PATH")
    try:
        listed = subprocess.run([herdr, "plugin", "list", "--json"], capture_output=True, text=True, timeout=10)
        plugins = json.loads(listed.stdout)["result"]["plugins"]
        root = next(plugin["plugin_root"] for plugin in plugins if plugin.get("plugin_id") == "wazum.grazr")
    except Exception:
        fail("grazr is not installed")

    state = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local/state"), "herdr/plugins/wazum.grazr")
    config = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config"), "herdr/plugins/config/wazum.grazr")
    os.environ.update({
        "HERDR_BIN_PATH": herdr,
        "HERDR_PLUGIN_ROOT": root,
        "HERDR_PLUGIN_CONFIG_DIR": config,
        "HERDR_PLUGIN_STATE_DIR": state,
    })
    os.chdir(root)
    sys.path.insert(0, root)
    import accounts, core, grazr
    """#
    #endif
}

/// What `Grazr.switchCommand` printed: whether Claude moved, and grazr's say.
public struct GrazrSwitchResult: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let output: String

    public init(ok: Bool, output: String) {
        self.ok = ok
        self.output = output
    }

    /// grazr's verdict ("Rotated a -> b", "grazr: Busy rotating already, …")
    /// is its last line.
    public var summary: String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

public struct GrazrReport: Decodable, Sendable, Equatable {
    public let installed: Bool
    public let active: String?
    public let accounts: [GrazrAccount]
    /// `ACCOUNTS` in config.env: the order grazr tries them in.
    public let order: [String]
    public let settings: [String: String]
    public let blocked: [String: GrazrBlock]
    /// Agents pinned to an account, by Herdr pane id.
    public let pins: [String: GrazrPin]
    /// Whether grazr's `claude` shim is installed, without which a pin waits.
    public let pinsInstalled: Bool

    enum CodingKeys: String, CodingKey {
        case installed, active, accounts, order, settings, blocked, pins
        case pinsInstalled = "pins_installed"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        installed = try container.decode(Bool.self, forKey: .installed)
        active = try container.decodeIfPresent(String.self, forKey: .active)
        accounts = try container.decode([GrazrAccount].self, forKey: .accounts)
        order = try container.decode([String].self, forKey: .order)
        settings = try container.decode([String: String].self, forKey: .settings)
        blocked = try container.decode([String: GrazrBlock].self, forKey: .blocked)
        pins = try container.decodeIfPresent([String: GrazrPin].self, forKey: .pins) ?? [:]
        pinsInstalled = try container.decodeIfPresent(Bool.self, forKey: .pinsInstalled) ?? false
    }

    public init(
        installed: Bool = true,
        active: String? = nil,
        accounts: [GrazrAccount] = [],
        order: [String] = [],
        settings: [String: String] = [:],
        blocked: [String: GrazrBlock] = [:],
        pins: [String: GrazrPin] = [:],
        pinsInstalled: Bool = false
    ) {
        self.installed = installed
        self.active = active
        self.accounts = accounts
        self.order = order
        self.settings = settings
        self.blocked = blocked
        self.pins = pins
        self.pinsInstalled = pinsInstalled
    }

    /// grazr's own defaults when config.env does not say.
    public var sessionThreshold: Int { settings["REMAINING_SESSION"].flatMap(Int.init) ?? 15 }
    public var weeklyThreshold: Int { settings["REMAINING_WEEKLY"].flatMap(Int.init) ?? 20 }
    public var enabled: Bool { settings["ENABLED"] != "0" }
    public var dryRun: Bool { settings["DRY_RUN"] == "1" }
    /// `PINNED_ROTATION=keep`: the shared rotation may still move to an
    /// account an agent is pinned to. grazr excludes it by default.
    public var keepsPinnedInRotation: Bool { settings["PINNED_ROTATION"] == "keep" }

    // MARK: - Pinned agents

    /// The account `paneID` is pinned to, nil when it is on the shared rotation.
    public func pinnedAccount(paneID: String) -> GrazrAccount? {
        guard let id = pins[paneID]?.account else { return nil }
        return accounts.first { $0.id == id }
    }

    /// The account Claude in `paneID` runs pinned on right now, which differs
    /// from the pin until Claude restarts there.
    public func runningAccount(paneID: String) -> GrazrAccount? {
        guard let id = pins[paneID]?.running else { return nil }
        return accounts.first { $0.id == id }
    }

    /// Whether a pin set or dropped on `paneID` still waits for Claude to restart.
    public func pinIsPending(paneID: String) -> Bool {
        guard let pin = pins[paneID] else { return false }
        return pin.account != pin.running
    }

    /// The panes pinned to `account` or still running on it, sorted.
    public func pinnedPanes(for account: GrazrAccount) -> [String] {
        pins.filter { $0.value.account == account.id || $0.value.running == account.id }
            .map(\.key).sorted()
    }

    /// Accounts with a token an agent can be pinned to at `now`.
    public func pinnableAccounts(now: Date) -> [GrazrAccount] {
        sortedAccounts.filter { $0.hasToken(now: now) }
    }

    /// The models that carry a weekly limit of their own on any account
    /// ("Fable"), by name: one inner ring each on the dial's week.
    public var modelScopes: [String] {
        Set(accounts.flatMap { $0.windows.filter { $0.group == "weekly" }.compactMap(\.scope) }).sorted()
    }

    /// The active account first, then `ACCOUNTS` order, then any enrolled
    /// account the config leaves out.
    public var sortedAccounts: [GrazrAccount] {
        accounts.sorted { lhs, rhs in
            func rank(_ account: GrazrAccount) -> (Int, Int, String) {
                let listed = order.firstIndex(of: account.name) ?? order.count
                return (account.id == active ? 0 : 1, listed, account.name)
            }
            return rank(lhs) < rank(rhs)
        }
    }

    public func isListed(_ account: GrazrAccount) -> Bool { order.contains(account.name) }

    /// A block with a lapsed `until` no longer applies.
    public func block(for account: GrazrAccount, now: Date) -> GrazrBlock? {
        guard let block = blocked[account.id] else { return nil }
        if let until = block.until, until <= now.timeIntervalSince1970 { return nil }
        return block
    }

    /// Any enrolled account but the active one, unless grazr has blocked it:
    /// a failed login or a hard limit would leave Claude unable to answer.
    public func canSwitch(to account: GrazrAccount, now: Date) -> Bool {
        account.id != active && block(for: account, now: now) == nil
    }

    /// A block with no end (a refused login, say) lifts only when the account
    /// is enrolled again; one that ends (a rate limit) lifts on its own.
    public func needsSignIn(_ account: GrazrAccount, now: Date) -> Bool {
        guard let block = block(for: account, now: now) else { return false }
        return block.until == nil
    }

    public func threshold(for window: GrazrWindow) -> Int? {
        switch window.group {
        case "session": return sessionThreshold
        case "weekly": return weeklyThreshold
        default: return nil
        }
    }

    // MARK: - Rotation

    /// The accounts grazr rotates through, in its order: `ACCOUNTS`, plus the
    /// active account when the config leaves it out. grazr never moves into an
    /// unlisted account, so the others are not part of it.
    public var rotation: [GrazrAccount] {
        let listed = order.compactMap { name in accounts.first { $0.name == name } }
        guard let active, !listed.contains(where: { $0.id == active }),
              let current = accounts.first(where: { $0.id == active })
        else { return listed }
        return listed + [current]
    }

    /// Whether grazr would move into `account` at `time`: every window it
    /// watches still open then is at or above its threshold. A parked account
    /// spends nothing, so a window that resets by then is full again. An
    /// account with no reading yet counts.
    public func hasHeadroom(_ account: GrazrAccount, now time: Date) -> Bool {
        account.windows.allSatisfy { window in
            guard let threshold = threshold(for: window), window.isOpen(now: time) else { return true }
            return window.remaining >= threshold
        }
    }

    /// When the active account is expected to reach a threshold, at the pace
    /// of its last reading; `now` when that is already past or unknown.
    public func expectedSwap(now: Date) -> Date {
        guard let current = accounts.first(where: { $0.id == active }),
              let eta = swapEstimate(for: current, now: now), eta > now
        else { return now }
        return eta
    }

    /// The account grazr's next swap goes to, as its `core.next_account`
    /// picks it when that swap comes: the first listed account, not active and
    /// not blocked, with headroom then. One whose window resets before the
    /// active account runs out counts, since it is full again by the time.
    public func predictedNext(now: Date) -> GrazrAccount? {
        let swap = expectedSwap(now: now)
        return order.lazy
            .compactMap { name in accounts.first { $0.name == name } }
            .first { $0.id != active && block(for: $0, now: now) == nil && hasHeadroom($0, now: swap) }
    }

    /// When `account` next has headroom: `now` when it has it already,
    /// otherwise when the last of its low windows resets. Nil when blocked, or
    /// when a low window has no reset time to wait for.
    public func availableAt(_ account: GrazrAccount, now: Date) -> Date? {
        guard block(for: account, now: now) == nil else { return nil }
        let low = account.windows.filter { window in
            guard let threshold = threshold(for: window), window.isOpen(now: now) else { return false }
            return window.remaining < threshold
        }
        guard !low.isEmpty else { return now }
        let resets = low.compactMap(\.resetsAt)
        return resets.count == low.count ? resets.max() : nil
    }

    /// The rotation as it will come round: the active account, then the one
    /// grazr moves to next, then the rest by when they have headroom again,
    /// soonest first, ties in `ACCOUNTS` order. Blocked accounts and ones
    /// with no known refill go last.
    public func dialOrder(now: Date) -> [GrazrAccount] {
        let members = rotation
        let next = predictedNext(now: now)
        let rank = { (account: GrazrAccount) -> (Int, Date, Int) in
            let listed = order.firstIndex(of: account.name) ?? order.count
            if account.id == active { return (0, .distantPast, listed) }
            if account.id == next?.id { return (1, .distantPast, listed) }
            return (2, availableAt(account, now: now) ?? .distantFuture, listed)
        }
        return members.sorted { rank($0) < rank($1) }
    }

    /// A stretch with no account to run: when the active account reaches its
    /// swap point and no other has headroom by then, the work waits for the
    /// soonest refill. Nil when grazr has somewhere to go.
    public func upcomingGap(now: Date) -> GrazrGap? {
        guard active != nil, predictedNext(now: now) == nil,
              let refill = nextHeadroom(now: now), refill.at > expectedSwap(now: now)
        else { return nil }
        return GrazrGap(until: refill.at, account: refill.account)
    }

    /// With nothing to swap to: the soonest an account other than the active
    /// one has headroom again, once its low windows reset.
    public func nextHeadroom(now: Date) -> (account: GrazrAccount, at: Date)? {
        rotation
            .filter { $0.id != active && block(for: $0, now: now) == nil }
            .compactMap { account -> (GrazrAccount, Date)? in
                let low = account.windows.filter { window in
                    guard let threshold = threshold(for: window), window.isOpen(now: now) else { return false }
                    return window.remaining < threshold
                }
                let resets = low.compactMap(\.resetsAt)
                guard !low.isEmpty, resets.count == low.count, let last = resets.max() else { return nil }
                return (account, last)
            }
            .min { $0.1 < $1.1 }
            .map { (account: $0.0, at: $0.1) }
    }

    /// When `account` falls below a threshold at the pace of its last reading,
    /// the soonest over the windows grazr watches: used ÷ time elapsed in the
    /// window, carried on from the reading. A window that resets first does
    /// not count; one already below its threshold answers the reading's time.
    /// Nil with no reading, no usage yet, or no window that runs out.
    public func swapEstimate(for account: GrazrAccount, now: Date) -> Date? {
        guard let updated = account.updated.map(Date.init(timeIntervalSince1970:)) else { return nil }
        return account.windows.compactMap { window -> Date? in
            guard let threshold = threshold(for: window), let resetsAt = window.resetsAt,
                  window.isOpen(now: now), let length = window.length
            else { return nil }
            if window.remaining < threshold { return updated }
            let elapsed = length - resetsAt.timeIntervalSince(updated)
            let used = Double(100 - window.remaining)
            // A window's first minutes after a swap are Claude reloading, not a pace.
            guard elapsed >= Self.minimumPaceSample, used > 0 else { return nil }
            let eta = updated.addingTimeInterval(Double(window.remaining - threshold) * elapsed / used)
            return eta < resetsAt ? eta : nil
        }.min()
    }
}

/// Nothing to swap to until `account` has headroom again at `until`.
public struct GrazrGap: Sendable, Equatable {
    public let until: Date
    public let account: GrazrAccount
}

/// Which window the Accounts dial fills its slices with.
public enum GrazrDialWindow: String, CaseIterable, Sendable {
    case week
    case session
}

public struct GrazrAccount: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let organization: String?
    /// The subscription: Claude's live profile for the active account,
    /// otherwise grazr's copy from enrolment or the last park.
    public let plan: GrazrPlan?
    public let windows: [GrazrWindow]
    /// When grazr last wrote this account's reading (unix seconds).
    public let updated: Double?
    /// When this account's pin token lapses (unix seconds); nil without one.
    public let tokenExpires: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, organization, plan, windows, updated
        case tokenExpires = "token_expires"
    }

    public init(
        id: String, name: String, organization: String? = nil, plan: GrazrPlan? = nil,
        windows: [GrazrWindow] = [], updated: Double? = nil, tokenExpires: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.organization = organization
        self.plan = plan
        self.windows = windows
        self.updated = updated
        self.tokenExpires = tokenExpires
    }

    /// An agent can be pinned to it: it has a token that has not lapsed.
    public func hasToken(now: Date) -> Bool {
        tokenExpires.map { $0 > now.timeIntervalSince1970 } ?? false
    }

    /// Whole days until the pin token lapses, nil without a current one.
    public func tokenDaysLeft(now: Date) -> Int? {
        guard let tokenExpires, hasToken(now: now) else { return nil }
        return Int((tokenExpires - now.timeIntervalSince1970) / 86_400)
    }

    /// Session first, then the all-models week, then per-model weeks.
    public var sortedWindows: [GrazrWindow] {
        windows.sorted { lhs, rhs in
            func rank(_ window: GrazrWindow) -> Int {
                switch (window.group, window.scope) {
                case ("session", _): return 0
                case ("weekly", nil): return 1
                default: return 2
                }
            }
            return (rank(lhs), lhs.scope ?? "") < (rank(rhs), rhs.scope ?? "")
        }
    }

    /// The 5-hour window, or the all-models week (not a per-model one).
    public func window(_ kind: GrazrDialWindow) -> GrazrWindow? {
        switch kind {
        case .session: return windows.first { $0.group == "session" }
        case .week: return windows.first { $0.group == "weekly" && $0.scope == nil }
        }
    }

    /// The weekly limit Claude keeps for one model ("Fable") on this account.
    public func modelWindow(_ scope: String) -> GrazrWindow? {
        windows.first { $0.group == "weekly" && $0.scope == scope }
    }

    /// The tightest window still open: how close the account is to the wall.
    public func leastLeft(now: Date) -> Int? {
        windows.filter { $0.isOpen(now: now) }.map(\.remaining).min()
    }
}

/// One Herdr pane pinned to an account, from grazr's pins.json.
public struct GrazrPin: Decodable, Sendable, Equatable {
    /// The account the pane is pinned to; nil once unpinned while Claude
    /// there still runs on the old one.
    public let account: String?
    /// The account Claude in the pane started on, nil on the shared rotation.
    public let running: String?

    public init(account: String?, running: String? = nil) {
        self.account = account
        self.running = running
    }
}

/// An account's Claude subscription, as `oauthAccount` in `.claude.json`
/// describes it.
public struct GrazrPlan: Decodable, Sendable, Equatable {
    /// `organizationType`: "claude_pro", "claude_max", "claude_team", …
    public let type: String
    /// `organizationRateLimitTier`: "default_claude_max_20x", …
    public let tier: String?
    /// `userRateLimitTier`: a Team seat's own tier ("default_claude_max_5x").
    public let seatTier: String?

    enum CodingKeys: String, CodingKey {
        case type, tier
        case seatTier = "seat_tier"
    }

    public init(type: String, tier: String? = nil, seatTier: String? = nil) {
        self.type = type
        self.tier = tier
        self.seatTier = seatTier
    }

    /// "Pro", "Max 20x", "Team 5x": the plan with its usage multiplier, the
    /// seat's own before the organization's.
    public var label: String {
        let name: String
        switch type {
        case "claude_pro": name = "Pro"
        case "claude_max": name = "Max"
        case "claude_team": name = "Team"
        case "claude_enterprise": name = "Enterprise"
        default:
            name = type.replacingOccurrences(of: "claude_", with: "")
                .split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
        guard let multiplier = Self.multiplier(seatTier) ?? Self.multiplier(tier) else { return name }
        return "\(name) \(multiplier)"
    }

    /// "5x" from "default_claude_max_5x".
    private static func multiplier(_ tier: String?) -> String? {
        guard let last = tier?.split(separator: "_").last, last.count > 1, last.hasSuffix("x"),
              last.dropLast().allSatisfy(\.isNumber)
        else { return nil }
        return String(last)
    }
}

public struct GrazrWindow: Decodable, Sendable, Equatable {
    public let kind: String
    /// A model name for a per-model weekly limit ("Fable"), nil otherwise.
    public let scope: String?
    public let group: String
    /// Percent left, as Claude reported it.
    public let remaining: Int
    public let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case kind, scope, group, remaining
        case resetsAt = "resets_at"
    }

    public init(kind: String, scope: String? = nil, group: String, remaining: Int, resetsAt: Date?) {
        self.kind = kind
        self.scope = scope
        self.group = group
        self.remaining = remaining
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        group = try container.decode(String.self, forKey: .group)
        remaining = try container.decode(Int.self, forKey: .remaining)
        resetsAt = try container.decodeIfPresent(Double.self, forKey: .resetsAt)
            .map(Date.init(timeIntervalSince1970:))
    }

    /// A window past its reset has refilled, whatever the last reading said.
    public func isOpen(now: Date) -> Bool {
        resetsAt.map { $0 > now } ?? true
    }

    /// How long the window runs, from reset to reset.
    public var length: TimeInterval? {
        switch group {
        case "session": return 5 * 3600
        case "weekly": return 7 * 86400
        default: return nil
        }
    }

    /// What is left right now: the reading inside the window, all of it after.
    public func left(now: Date) -> Int {
        isOpen(now: now) ? remaining : 100
    }

    public var label: String {
        switch (group, scope) {
        case ("session", _): return "5h"
        case ("weekly", nil): return "Week"
        case (_, let scope?): return "\(scope) week"
        default: return group
        }
    }
}

public struct GrazrBlock: Decodable, Sendable, Equatable {
    public let reason: String
    public let until: Double?

    public init(reason: String, until: Double? = nil) {
        self.reason = reason
        self.until = until
    }
}
