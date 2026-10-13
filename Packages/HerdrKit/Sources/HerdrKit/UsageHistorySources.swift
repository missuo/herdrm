import Foundation

/// Device-side usage history aggregation: each provider's command streams
/// its own transcript store into the normalized day/model document that
/// `parse` decodes to a `UsageHistory`. Only token totals leave the device —
/// transcript text and credentials stay local.
public enum UsageHistorySource {
    /// The shell command that prints `provider`'s normalized history JSON on
    /// the device, nil where no transcript source exists (gemini keeps no
    /// transcripts).
    public static func command(for provider: UsageProvider) -> String? {
        switch provider {
        case .claude: claudeCommand
        case .codex: codexCommand
        case .opencode: opencodeCommand
        case .gemini: nil
        }
    }

    /// Decodes the normalized document `provider`'s command printed at
    /// `fetchedAt`: one `UsageDay` per emitted date and per-model totals
    /// keyed under `provider`. Nil when the output is not the history shape
    /// at all.
    public static func parse(_ provider: UsageProvider, stdout: Data, fetchedAt: Date) -> UsageHistory? {
        if provider == .opencode {
            return parseOpencode(stdout: stdout, fetchedAt: fetchedAt)
        }
        guard let document = try? JSONDecoder().decode(NormalizedDocument.self, from: stdout) else {
            return nil
        }
        let days = document.days.compactMap { day -> UsageDay? in
            guard let date = dayDate(day.date) else { return nil }
            return UsageDay(date: date, tokens: [provider: day.usageTokens])
        }
        return UsageHistory(
            days: days,
            modelTotals: [provider: document.models.mapValues(\.usageTokens)],
            generatedAt: fetchedAt)
    }

    /// The device's day label ("YYYY-MM-DD") as midnight UTC — unambiguous
    /// for equality, relabeled by the chart's own formatter.
    private static func dayDate(_ label: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: label)
    }

    // MARK: - Claude command

    /// Streams the month's Claude Code transcripts (`~/.claude/projects/
    /// **/*.jsonl`) into the normalized document: `type == "assistant"`
    /// records carrying `message.usage`, deduped on `message.id + requestId`
    /// (resumed sessions rewrite the same message into every session file).
    /// `cache_read` is `cache_read_input_tokens`, `cache_write` is
    /// `cache_creation_input_tokens`; day buckets use the record timestamp
    /// in the device's local zone. Files untouched for 30 days by mtime are
    /// skipped before parsing; lines stream one at a time.
    private static let claudeCommand = SSHTunnel.remotePathExport + "\n"
        + #"""
        python3 - <<'USAGE_EOF'
        import calendar, glob, json, os, time

        def iso_day(stamp):
            return time.strftime("%Y-%m-%d", time.localtime(calendar.timegm(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))))

        def blank():
            return {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}

        def add(bucket, key, usage):
            row = bucket.setdefault(key, blank())
            row["input"] += int(usage.get("input_tokens") or 0)
            row["output"] += int(usage.get("output_tokens") or 0)
            row["cache_read"] += int(usage.get("cache_read_input_tokens") or 0)
            row["cache_write"] += int(usage.get("cache_creation_input_tokens") or 0)

        home = os.path.expanduser("~")
        cutoff = time.time() - 30 * 86400
        days, models, seen = {}, {}, set()
        for path in glob.glob(os.path.join(home, ".claude", "projects", "**", "*.jsonl"), recursive=True):
            if os.path.getmtime(path) < cutoff:
                continue
            with open(path, errors="replace") as handle:
                for line in handle:
                    try: rec = json.loads(line)
                    except Exception: continue
                    if rec.get("type") != "assistant": continue
                    message = rec.get("message") or {}
                    usage = message.get("usage")
                    if not isinstance(usage, dict): continue
                    key = "{}\t{}".format(message.get("id") or "", rec.get("requestId") or "")
                    if key in seen: continue
                    seen.add(key)
                    stamp = rec.get("timestamp")
                    if not isinstance(stamp, str): continue
                    try: day = iso_day(stamp)
                    except Exception: continue
                    add(days, day, usage)
                    add(models, message.get("model") or "unknown", usage)
        print(json.dumps({
            "days": [dict(date=day, **days[day]) for day in sorted(days)],
            "models": dict(sorted(models.items()))}))
        USAGE_EOF
        """#

    // MARK: - Codex command

    /// Streams the month's codex session rollouts (`~/.codex/sessions/
    /// **/*.jsonl`) into the normalized document. `total_token_usage` is
    /// cumulative, so each file contributes only its **last**
    /// `payload.type == "token_count"` event's totals — added once at EOF,
    /// bucketed by that event's timestamp day, model from
    /// `payload.info.model` when present. Same mtime filter and streaming
    /// as the claude command.
    private static let codexCommand = SSHTunnel.remotePathExport + "\n"
        + #"""
        python3 - <<'USAGE_EOF'
        import calendar, glob, json, os, time

        def iso_day(stamp):
            return time.strftime("%Y-%m-%d", time.localtime(calendar.timegm(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))))

        def blank():
            return {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}

        def add(bucket, key, total):
            row = bucket.setdefault(key, blank())
            row["input"] += int(total.get("input_tokens") or 0)
            row["output"] += int(total.get("output_tokens") or 0)
            row["reasoning"] += int(total.get("reasoning_output_tokens") or 0)
            row["cache_read"] += int(total.get("cached_input_tokens") or 0)
            row["cache_write"] += int(total.get("cache_write_input_tokens") or 0)

        home = os.path.expanduser("~")
        cutoff = time.time() - 30 * 86400
        days, models = {}, {}
        for path in glob.glob(os.path.join(home, ".codex", "sessions", "**", "*.jsonl"), recursive=True):
            if os.path.getmtime(path) < cutoff:
                continue
            last = None
            with open(path, errors="replace") as handle:
                for line in handle:
                    try: rec = json.loads(line)
                    except Exception: continue
                    payload = rec.get("payload") or {}
                    if isinstance(payload, dict) and payload.get("type") == "token_count":
                        last = rec
            if last is None: continue
            payload = last.get("payload") or {}
            info = payload.get("info") or {}
            total = info.get("total_token_usage") if isinstance(info, dict) else None
            if not isinstance(total, dict): continue
            stamp = last.get("timestamp")
            if not isinstance(stamp, str): continue
            try: day = iso_day(stamp)
            except Exception: continue
            add(days, day, total)
            if isinstance(info.get("model"), str) and info.get("model"):
                add(models, info["model"], total)
        print(json.dumps({
            "days": [dict(date=day, **days[day]) for day in sorted(days)],
            "models": dict(sorted(models.items()))}))
        USAGE_EOF
        """#

    // MARK: - OpenCode

    /// Runs `opencode stats` for the last 30 days behind the `command -v`
    /// guard that prints the installed-false envelope when the CLI is
    /// missing. opencode prints its own JSON — no heredoc normalization —
    /// so `parseOpencode` reads the stats shape directly.
    private static let opencodeCommand = SSHTunnel.remotePathExport + "\n"
        + #"if command -v opencode >/dev/null 2>&1; then opencode stats --json --days 30; else echo '{"installed": false}'; fi"#

    /// opencode reports tokens only as per-model 30-day range totals (the
    /// pinned 2026-10-13 `stats --json` shape; `activity` is steps-only),
    /// so there is no daily series: every variant of one bare `model.id`
    /// merges into a single entry and `days` stays empty. The
    /// installed-false envelope and any non-stats output are nil, matching
    /// the normalized parse's semantics.
    private static func parseOpencode(stdout: Data, fetchedAt: Date) -> UsageHistory? {
        guard let document = try? JSONDecoder().decode(OpencodeStatsDocument.self, from: stdout) else {
            return nil
        }
        var totals: [String: UsageTokens] = [:]
        for entry in document.models {
            let row = totals[entry.model.id]
                ?? UsageTokens(input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0)
            totals[entry.model.id] = UsageTokens(
                input: row.input + entry.tokens.input,
                output: row.output + entry.tokens.output,
                reasoning: row.reasoning + entry.tokens.reasoning,
                cacheRead: row.cacheRead + entry.tokens.cache.read,
                cacheWrite: row.cacheWrite + entry.tokens.cache.write)
        }
        return UsageHistory(days: [], modelTotals: [.opencode: totals], generatedAt: fetchedAt)
    }

    /// opencode's `stats --json` document: only the `models` array carries
    /// tokens — `range`, `sessions`, and `activity` are unused.
    private struct OpencodeStatsDocument: Decodable {
        let models: [OpencodeModelUsage]
    }

    /// One model row: the model ref plus its range token totals.
    private struct OpencodeModelUsage: Decodable {
        let model: OpencodeModelID
        let tokens: OpencodeModelTokens
    }

    /// The bare model id; `providerID` and `variant` distinguish rows that
    /// merge into the same entry.
    private struct OpencodeModelID: Decodable {
        let id: String
    }

    /// One row's range totals; cache splits into read and write.
    private struct OpencodeModelTokens: Decodable {
        let input: Int
        let output: Int
        let reasoning: Int
        let cache: OpencodeCache
    }

    private struct OpencodeCache: Decodable {
        let read: Int
        let write: Int
    }

    // MARK: - Normalized schema

    /// The device document: per-day rows and per-model totals, snake_case
    /// exactly as the heredocs print it.
    private struct NormalizedDocument: Decodable {
        let days: [NormalizedDay]
        let models: [String: NormalizedTokens]
    }

    /// One day row: the device-local date label plus its token totals.
    private struct NormalizedDay: Decodable {
        let date: String
        let input: Int
        let output: Int
        let reasoning: Int
        let cacheRead: Int
        let cacheWrite: Int

        enum CodingKeys: String, CodingKey {
            case date, input, output, reasoning
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }

        var usageTokens: UsageTokens {
            UsageTokens(
                input: input, output: output, reasoning: reasoning,
                cacheRead: cacheRead, cacheWrite: cacheWrite)
        }
    }

    /// One model's token totals.
    private struct NormalizedTokens: Decodable {
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

        var usageTokens: UsageTokens {
            UsageTokens(
                input: input, output: output, reasoning: reasoning,
                cacheRead: cacheRead, cacheWrite: cacheWrite)
        }
    }
}
