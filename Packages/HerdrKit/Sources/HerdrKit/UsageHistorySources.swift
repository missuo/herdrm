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

    /// Walks opencode's local database (`~/.local/share/opencode/
    /// opencode.db`) read-only and streams per-SESSION token aggregates
    /// into the normalized document. opencode's v2 schema (the
    /// `migration.v1-v2` kv marker) moved token accounting from
    /// `message.data` — frozen at the migration — to `session_v2`'s
    /// `tokens_*` columns; each session's totals bucket by its
    /// `time_created` local day and by the `model` JSON's id. The 30-day
    /// window is an indexed SQL cutoff; python3's sqlite3 stdlib opens
    /// the db read-only so the running daemon's WAL never blocks the
    /// read. A missing db prints the installed-false envelope.
    private static let opencodeCommand = SSHTunnel.remotePathExport + "\n"
        + #"""
        python3 - <<'USAGE_EOF'
        import json, os, sqlite3, time

        db = os.path.join(os.path.expanduser("~"), ".local", "share", "opencode", "opencode.db")
        installed = os.path.isfile(db)
        report = {"days": [], "models": {}}
        if installed:
            cutoff = int((time.time() - 30 * 86400) * 1000)
            days, models = {}, {}

            def blank():
                return {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}

            try:
                conn = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
                rows = conn.execute(
                    "SELECT time_created, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, model"
                    " FROM session_v2 WHERE time_created >= ?",
                    (cutoff,))
                for created, i, o, r, cr, cw, model in rows:
                    day = time.strftime("%Y-%m-%d", time.localtime((created or 0) / 1000))
                    try:
                        name = (json.loads(model or "{}").get("id")) or "unknown"
                    except Exception:
                        name = "unknown"
                    if day not in days:
                        days[day] = blank()
                    if name not in models:
                        models[name] = blank()
                    for bucket in (days[day], models[name]):
                        bucket["input"] += int(i or 0)
                        bucket["output"] += int(o or 0)
                        bucket["reasoning"] += int(r or 0)
                        bucket["cache_read"] += int(cr or 0)
                        bucket["cache_write"] += int(cw or 0)
                conn.close()
            except Exception:
                pass
            report["days"] = [dict(date=day, **days[day]) for day in sorted(days)]
            report["models"] = {model: models[model] for model in sorted(models)}
        else:
            report["installed"] = False
        print(json.dumps(report))
        USAGE_EOF
        """#


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
