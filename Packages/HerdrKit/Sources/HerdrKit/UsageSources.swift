import Foundation

/// Pure parsing from each provider's command stdout to a `UsageParseResult`.
/// The device-side command builders are `UsageSource.command(for:)`.
public enum UsageSource {
    /// Decodes the `stdout` that `provider`'s command printed at `fetchedAt`.
    /// Nil when the output is not the provider's JSON shape at all.
    public static func parse(_ provider: UsageProvider, stdout: Data, fetchedAt: Date) -> UsageParseResult? {
        switch provider {
        case .claude: parseClaude(stdout: stdout, fetchedAt: fetchedAt)
        case .codex: parseCodex(stdout: stdout, fetchedAt: fetchedAt)
        case .opencode: parseOpencode(stdout: stdout, fetchedAt: fetchedAt)
        case .gemini: parseGemini(stdout: stdout, fetchedAt: fetchedAt)
        }
    }

    /// The shell command that prints `provider`'s normalized JSON on the
    /// device, nil for Claude (the store runs grazr's own commands there).
    /// Each prepends the remote PATH export so the tools resolve over SSH;
    /// locally that export is a harmless no-op.
    public static func command(for provider: UsageProvider) -> String? {
        switch provider {
        case .claude: nil
        case .codex: codexCommand
        case .opencode: opencodeCommand
        case .gemini: geminiCommand
        }
    }

    // MARK: - Device-side commands

    /// Scans the newest codex session rollouts for the latest `token_count`
    /// record and prints it normalized, the record `parseCodex` reads. Only
    /// token totals and rate-limit windows leave the device; credentials
    /// (`~/.codex/auth.json`) are never touched.
    private static let codexCommand = SSHTunnel.remotePathExport + "\n"
        + #"""
        python3 - <<'USAGE_EOF'
        import glob, json, os
        sessions = os.path.join(os.path.expanduser("~"), ".codex", "sessions")
        report = {"installed": os.path.isdir(sessions), "windows": [], "tokens": None, "updated": None}
        files = sorted(glob.glob(os.path.join(sessions, "**", "*.jsonl"), recursive=True), key=os.path.getmtime) if report["installed"] else []
        for path in reversed(files[-20:]):
            for line in reversed(open(path, errors="replace").read().splitlines()):
                try: rec = json.loads(line)
                except Exception: continue
                payload = rec.get("payload") or {}
                if payload.get("type") != "token_count": continue
                info, limits = payload.get("info") or {}, payload.get("rate_limits") or {}
                total = info.get("total_token_usage") or {}
                report["tokens"] = {"input": total.get("input_tokens"), "output": total.get("output_tokens"),
                                    "reasoning": total.get("reasoning_output_tokens"),
                                    "cache_read": total.get("cached_input_tokens"),
                                    "cache_write": total.get("cache_write_input_tokens")}
                report["updated"] = rec.get("timestamp")
                report["windows"] = [w for side in ("primary", "secondary")
                                     if isinstance((w := limits.get(side)), dict)
                                     and isinstance(w.get("used_percent"), (int, float))]
                break
            else: continue
            break
        print(json.dumps(report))
        USAGE_EOF
        """#

    /// Sums the last week's gemini `usage.json` files into one normalized
    /// total, the record `parseGemini` reads. Files that fail to parse are
    /// skipped; gemini writes no reasoning or cache-write counts.
    private static let geminiCommand = SSHTunnel.remotePathExport + "\n"
        + #"""
        python3 - <<'USAGE_EOF'
        import glob, json, os, time
        home = os.path.expanduser("~")
        totals, files = {"input": 0, "output": 0, "cached": 0}, 0
        for path in glob.glob(os.path.join(home, ".gemini", "tmp", "*", "usage.json")):
            if os.path.getmtime(path) < time.time() - 7 * 86400:
                continue
            try:
                with open(path) as handle:
                    tokens = (json.load(handle).get("total") or {}).get("tokens") or {}
            except Exception:
                continue
            for key in totals:
                if isinstance(tokens.get(key), (int, float)):
                    totals[key] += int(tokens[key])
            files += 1
        print(json.dumps({
            "installed": os.path.isdir(os.path.join(home, ".gemini")),
            "tokens": {"input": totals["input"], "output": totals["output"], "reasoning": 0,
                       "cache_read": totals["cached"], "cache_write": 0},
            "files": files}))
        USAGE_EOF
        """#

    /// Runs `opencode stats` for the last week with `opencode auth list`
    /// after the `---AUTH---` marker `parseOpencode` splits on; where
    /// opencode is missing, the installed-false envelope instead.
    private static let opencodeCommand = SSHTunnel.remotePathExport + "\n"
        + #"if command -v opencode >/dev/null 2>&1; then opencode stats --json --days 7; echo; echo ---AUTH---; opencode auth list; else echo '{"installed": false}'; fi"#

    // MARK: - Claude

    /// The grazr reader's report: one reading per enrolled account, quota
    /// windows as grazr read them, no token counts.
    private static func parseClaude(stdout: Data, fetchedAt: Date) -> UsageParseResult? {
        guard let report = try? JSONDecoder().decode(GrazrReport.self, from: stdout) else { return nil }
        guard report.installed else { return UsageParseResult(installed: false, readings: []) }
        return UsageParseResult(
            installed: true,
            readings: report.accounts.map { account in
                AgentUsageReading(
                    id: account.id, provider: .claude, account: account.name,
                    windows: account.windows, fetchedAt: fetchedAt)
            })
    }

    // MARK: - Codex

    /// The codex session scan's normalized record.
    private struct CodexRecord: Decodable {
        let installed: Bool
        let windows: [CodexWindow]
        let tokens: ProviderTokens?
    }

    /// One rate-limit entry from Codex's newest `token_count` record, as a
    /// `GrazrWindow`: the 5-hour and weekly scopes keep grazr's group names,
    /// anything else is labeled by whole days ("30d").
    private struct CodexWindow: Decodable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }

        var window: GrazrWindow {
            GrazrWindow(
                kind: "usage",
                scope: nil,
                group: windowMinutes == 300 ? "session"
                    : windowMinutes == 10080 ? "weekly"
                    : "\(windowMinutes / 1440)d",
                remaining: max(0, 100 - Int(usedPercent.rounded())),
                resetsAt: resetsAt.map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// A codex record without rate-limit windows has nothing to show: no
    /// reading, so the card reads as unknown rather than empty meters.
    private static func parseCodex(stdout: Data, fetchedAt: Date) -> UsageParseResult? {
        guard let record = try? JSONDecoder().decode(CodexRecord.self, from: stdout) else { return nil }
        guard record.installed else { return UsageParseResult(installed: false, readings: []) }
        guard !record.windows.isEmpty else { return UsageParseResult(installed: true, readings: []) }
        let reading = AgentUsageReading(
            id: UsageProvider.codex.rawValue, provider: .codex,
            windows: record.windows.map(\.window),
            tokens: record.tokens?.tokens, fetchedAt: fetchedAt)
        return UsageParseResult(installed: true, readings: [reading])
    }

    // MARK: - OpenCode

    /// Task 2's opencode command appends `---AUTH---` and `opencode auth
    /// list` to the stats; plain stats output has no marker. Returns the
    /// stats JSON and the auth text, nil without the marker.
    private static func splitAtAuthMarker(_ stdout: Data) -> (stats: Data, auth: String?) {
        guard let text = String(data: stdout, encoding: .utf8),
              let marker = text.range(of: authMarker)
        else { return (stdout, nil) }
        return (Data(String(text[..<marker.lowerBound]).utf8), String(text[marker.upperBound...]))
    }

    private static let authMarker = "---AUTH---"

    /// The login `opencode auth list` prints for a Z.AI Coding Plan token.
    private static let zaiPlanName = "Z.AI Coding Plan"

    /// `opencode stats --json`'s own shape; only the not-installed envelope
    /// carries `installed`, plain stats leave it out.
    private struct OpencodeStats: Decodable {
        let installed: Bool?
        let range: OpencodeRange?
        let tokens: OpencodeTokens?

        struct OpencodeRange: Decodable {
            let from: Double
            let to: Double
        }

        struct OpencodeTokens: Decodable {
            let input: Int
            let output: Int
            let reasoning: Int
            let cache: OpencodeCache

            struct OpencodeCache: Decodable {
                let read: Int
                let write: Int
            }
        }
    }

    private static func parseOpencode(stdout: Data, fetchedAt: Date) -> UsageParseResult? {
        let (statsData, auth) = splitAtAuthMarker(stdout)
        guard let stats = try? JSONDecoder().decode(OpencodeStats.self, from: statsData) else { return nil }
        guard stats.installed != false else { return UsageParseResult(installed: false, readings: []) }
        // An installed opencode with an empty stats payload has nothing to
        // show yet — codex's shape: `.unknown`, never a thrown failure.
        guard stats.tokens != nil || stats.range != nil else {
            return UsageParseResult(installed: true, readings: [])
        }
        let range = stats.range
        let reading = AgentUsageReading(
            id: UsageProvider.opencode.rawValue, provider: .opencode,
            account: auth?.contains(zaiPlanName) == true ? zaiPlanName : nil,
            tokens: stats.tokens.map { tokens in
                UsageTokens(
                    input: tokens.input, output: tokens.output, reasoning: tokens.reasoning,
                    cacheRead: tokens.cache.read, cacheWrite: tokens.cache.write,
                    periodStart: range.map { Date(timeIntervalSince1970: $0.from / 1000) },
                    periodEnd: range.map { Date(timeIntervalSince1970: $0.to / 1000) })
            },
            fetchedAt: fetchedAt)
        return UsageParseResult(installed: true, readings: [reading])
    }

    // MARK: - Gemini

    /// The gemini usage.json aggregate's normalized output.
    private struct GeminiAggregate: Decodable {
        let installed: Bool
        let tokens: ProviderTokens?
    }

    private static func parseGemini(stdout: Data, fetchedAt: Date) -> UsageParseResult? {
        guard let aggregate = try? JSONDecoder().decode(GeminiAggregate.self, from: stdout) else { return nil }
        guard aggregate.installed else { return UsageParseResult(installed: false, readings: []) }
        let reading = AgentUsageReading(
            id: UsageProvider.gemini.rawValue, provider: .gemini,
            tokens: aggregate.tokens?.tokens, fetchedAt: fetchedAt)
        return UsageParseResult(installed: true, readings: [reading])
    }

    // MARK: - Shared

    /// The snake_case token totals codex and gemini's normalized output carry.
    private struct ProviderTokens: Decodable {
        let input: Int
        let output: Int
        let reasoning: Int
        let cacheRead: Int
        let cacheWrite: Int

        enum CodingKeys: String, CodingKey {
            case input, output, reasoning
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }

        var tokens: UsageTokens {
            UsageTokens(
                input: input, output: output, reasoning: reasoning,
                cacheRead: cacheRead, cacheWrite: cacheWrite)
        }
    }
}
