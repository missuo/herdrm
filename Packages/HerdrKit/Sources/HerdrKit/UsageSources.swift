import Foundation

/// Pure parsing from each provider's command stdout to a `UsageParseResult`.
/// The device-side commands are `UsageSource.command(for:)`.
public enum UsageSource {
    /// Decodes the `stdout` that `provider`'s command printed at `fetchedAt`.
    /// Nil when the output is not the provider's shape at all.
    public static func parse(_ provider: UsageProvider, stdout: Data, fetchedAt: Date) -> UsageParseResult? {
        switch provider {
        case .claude:
            guard let text = String(data: stdout, encoding: .utf8) else { return nil }
            return parseClaudeUsage(text, fetchedAt: fetchedAt)
        case .codex: return parseCodex(stdout: stdout, fetchedAt: fetchedAt)
        case .opencode: return parseOpencode(stdout: stdout, fetchedAt: fetchedAt)
        case .gemini: return parseGemini(stdout: stdout, fetchedAt: fetchedAt)
        }
    }

    /// The command that prints `provider`'s usage on the device: a static
    /// POSIX `sh` script (no user input, no python) run under an explicit
    /// `/bin/sh`, since an SSH login shell may be fish or zsh. Only parsed
    /// numbers are printed; no credential file is read.
    public static func command(for provider: UsageProvider) -> String {
        "exec /bin/sh -c \(ShellQuoting.quoted(script(for: provider))) herdrm-usage"
    }

    /// How long the Mac lets `provider`'s command run before killing it.
    /// Claude's covers a cold CLI start plus its own 45 s `/usage` bound.
    public static func timeout(for provider: UsageProvider) -> TimeInterval {
        switch provider {
        case .claude: 75
        case .codex, .opencode, .gemini: 30
        }
    }

    /// The script `command(for:)` runs. It carries no backslash: fish reads
    /// one as an escape even inside single quotes.
    static func script(for provider: UsageProvider) -> String {
        let body = switch provider {
        case .claude: claudeScript
        case .codex: codexScript
        case .opencode: opencodeScript
        case .gemini: geminiScript
        }
        return prelude + body
    }

    // MARK: - Device-side scripts

    /// PATH mirrors `SSHTunnel.remotePathExport` (sshd exec is not a login
    /// shell; that type is macOS-only, this file is not). `tm <seconds>
    /// <cmd…>` bounds a CLI on the device itself, so a hung tool cannot
    /// outlive the Mac's timeout on a remote host: GNU timeout where
    /// present, else perl (its alarm survives exec), else unbounded.
    private static let prelude = #"""
        for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
        PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH
        have() { command -v "$1" >/dev/null 2>&1; }
        if have timeout; then tm() { timeout "$@"; }
        elif have perl; then tm() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }
        else tm() { shift; "$@"; }
        fi

        """#

    /// `claude -p /usage` for the CLI session's own quota. The CLI's own
    /// login is the only auth (no `--bare`, which would skip OAuth). Flags
    /// the installed CLI's `--help` lists keep the run side-effect free: no
    /// session transcript under `~/.claude/projects`, no MCP servers, no
    /// hooks; an older CLI without them gets the plain form. stdin is
    /// closed so `-p` never waits on it.
    private static let claudeScript = #"""
        if ! have claude; then echo '{"installed": false}'; exit 0; fi
        help=$(tm 15 claude --help </dev/null 2>/dev/null)
        set -- -p
        case $help in *--no-session-persistence*) set -- "$@" --no-session-persistence ;; esac
        case $help in *--strict-mcp-config*) set -- "$@" --strict-mcp-config ;; esac
        case $help in *--settings*) set -- "$@" --settings '{"disableAllHooks":true}' ;; esac
        tm 45 claude "$@" /usage </dev/null

        """#

    /// The newest `token_count` record that has `info`, from the newest five
    /// rollouts in the last seven day directories of `~/.codex/sessions`
    /// (only those files are stat'ed), printed normalized for `parseCodex`:
    /// token totals and rate-limit windows, nothing else.
    private static let codexScript = #"""
        s=$HOME/.codex/sessions
        if [ ! -d "$s" ]; then echo '{"installed": false}'; exit 0; fi
        IFS='
        '
        set --
        for d in $(ls -d "$s"/[0-9]*/[0-9]*/[0-9]* 2>/dev/null | tail -n 7); do
          for f in "$d"/*.jsonl; do [ -f "$f" ] && set -- "$@" "$f"; done
        done
        rec=
        if [ $# -gt 0 ]; then
          for f in $(ls -t "$@" | head -n 5); do
            rec=$(LC_ALL=C grep -a '"type":"token_count"' "$f" | LC_ALL=C grep -a -v '"info": *null' | tail -n 1)
            [ -n "$rec" ] && break
          done
        fi
        printf '%s' "$rec" | LC_ALL=C awk '
        function blk(s, k,   i, r) {
          i = index(s, q k q ":{")
          if (!i) return ""
          r = substr(s, i + length(k) + 4)
          return substr(r, 1, index(r, "}") - 1)
        }
        function num(s, k,   r) {
          if (!match(s, q k q ": *-?[0-9][0-9.eE+-]*")) return "null"
          r = substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 3)
          sub(/^ */, "", r)
          return r
        }
        BEGIN { q = sprintf("%c", 34) }
        { line = $0 }
        END {
          i = index(line, q "rate_limits" q ":")
          rl = i ? substr(line, i) : ""
          w = ""
          split("primary secondary", sides, " ")
          for (n = 1; n <= 2; n++) {
            b = blk(rl, sides[n])
            u = num(b, "used_percent"); m = num(b, "window_minutes")
            if (u == "null" || m == "null") continue
            w = w (w == "" ? "" : ",") "{~used_percent~:" u ",~window_minutes~:" m ",~resets_at~:" num(b, "resets_at") "}"
          }
          t = blk(line, "total_token_usage")
          tok = "null"
          if (t != "") tok = "{~input~:" num(t, "input_tokens") ",~output~:" num(t, "output_tokens") ",~reasoning~:" num(t, "reasoning_output_tokens") ",~cache_read~:" num(t, "cached_input_tokens") ",~cache_write~:" num(t, "cache_write_input_tokens") "}"
          out = "{~installed~:true,~windows~:[" w "],~tokens~:" tok "}"
          gsub(/~/, q, out)
          print out
        }'

        """#

    /// Sums the last week's gemini `usage.json` totals (one per project
    /// directory, at most 200) into one normalized record for
    /// `parseGemini`. Files that fail to parse are skipped; gemini writes
    /// no reasoning or cache-write counts.
    private static let geminiScript = #"""
        g=$HOME/.gemini
        if [ ! -d "$g" ]; then echo '{"installed": false}'; exit 0; fi
        find "$g/tmp/" -mindepth 2 -maxdepth 2 -name usage.json -mtime -7 2>/dev/null | head -n 200 |
        while IFS= read -r f; do
          LC_ALL=C awk '
          function v(s, k) {
            if (!match(s, q k q ":-?[0-9][0-9.eE+-]*")) return "0"
            return substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 3)
          }
          BEGIN { q = sprintf("%c", 34) }
          { s = s $0 }
          END {
            gsub(/ /, "", s); gsub(sprintf("%c", 9), "", s); gsub(sprintf("%c", 13), "", s)
            i = index(s, q "total" q ":{"); if (!i) exit
            s = substr(s, i)
            i = index(s, q "tokens" q ":{"); if (!i) exit
            s = substr(s, i + 10)
            s = substr(s, 1, index(s, "}") - 1)
            print v(s, "input"), v(s, "output"), v(s, "cached")
          }' "$f"
        done | LC_ALL=C awk '
        BEGIN { q = sprintf("%c", 34) }
        NF == 3 { i += $1; o += $2; c += $3; n++ }
        END {
          out = sprintf("{~installed~:true,~tokens~:{~input~:%.0f,~output~:%.0f,~reasoning~:0,~cache_read~:%.0f,~cache_write~:0},~files~:%d}", i, o, c, n)
          gsub(/~/, q, out)
          print out
        }'

        """#

    /// `opencode stats` for the last week, bounded on the device; where
    /// opencode is missing, the installed-false envelope instead.
    private static let opencodeScript = #"""
        if ! have opencode; then echo '{"installed": false}'; exit 0; fi
        tm 20 opencode stats --json --days 7 </dev/null

        """#

    // MARK: - Claude

    /// The not-installed envelope the claude script prints without the CLI.
    private struct ClaudeEnvelope: Decodable {
        let installed: Bool?
    }

    /// Recognizes one `Current …` line: the scope (`session`, `week`, or
    /// `week (Model)`), the used percent, and the optional reset stamp.
    private static let claudeLinePattern =
        "^Current (session|week(?: \\((.+)\\))?): (\\d+)% used(?: · resets (.*))?$"

    /// Decodes `claude -p /usage`'s stdout: one `Current …` line per quota
    /// window, the same reading shape codex's record parses to (no token
    /// counts). The not-installed envelope maps to a not-installed result;
    /// anything else an installed CLI prints without window lines is
    /// unknown, never a thrown failure.
    public static func parseClaudeUsage(_ text: String, fetchedAt: Date) -> UsageParseResult? {
        if let envelope = try? JSONDecoder().decode(ClaudeEnvelope.self, from: Data(text.utf8)),
           envelope.installed == false
        {
            return UsageParseResult(installed: false, readings: [])
        }
        guard let lineRegex = try? NSRegularExpression(pattern: claudeLinePattern) else { return nil }
        let windows = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            claudeWindow(String(line), regex: lineRegex, fetchedAt: fetchedAt)
        }
        guard !windows.isEmpty else { return UsageParseResult(installed: true, readings: []) }
        let reading = AgentUsageReading(
            id: UsageProvider.claude.rawValue, provider: .claude,
            windows: windows, fetchedAt: fetchedAt)
        return UsageParseResult(installed: true, readings: [reading])
    }

    /// One line's window: `session` keeps its group, `week (all models)` is
    /// the scope-less weekly and `week (Model)` a per-model one; `remaining`
    /// is what is left of 100.
    private static func claudeWindow(
        _ line: String, regex: NSRegularExpression, fetchedAt: Date
    ) -> GrazrWindow? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let head = Range(match.range(at: 1), in: line),
              let used = Range(match.range(at: 3), in: line),
              let usedPercent = Int(line[used])
        else { return nil }
        let scope = Range(match.range(at: 2), in: line).map { String(line[$0]) }
        let resetText = Range(match.range(at: 4), in: line).map { String(line[$0]) }
        return GrazrWindow(
            kind: "usage",
            scope: scope == "all models" ? nil : scope,
            group: line[head] == "session" ? "session" : "weekly",
            remaining: max(0, 100 - usedPercent),
            resetsAt: resetText.flatMap { claudeResetDate($0, fetchedAt: fetchedAt) })
    }

    /// The CLI stamps resets without a year: pin them to `fetchedAt`'s
    /// calendar year, rolling +1 when that lands nearly a year before the
    /// fetch (a January window seen from December). The stamp carries its
    /// own zone, which the `VV` (long zone ID) section parses — `zzz` reads
    /// only localized zone names and fails on `(Europe/Warsaw)`.
    private static func claudeResetDate(_ text: String, fetchedAt: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d 'at' h:mma (VV)"
        guard let parsed = formatter.date(from: text) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let shifted = calendar.date(
            byAdding: .year,
            value: calendar.component(.year, from: fetchedAt) - calendar.component(.year, from: parsed),
            to: parsed) ?? parsed
        // Eleven months: anything further back than that is next year's
        // window, not a stale one.
        return shifted.timeIntervalSince(fetchedAt) < -330 * 86400
            ? calendar.date(byAdding: .year, value: 1, to: shifted)
            : shifted
    }

    // MARK: - Codex

    /// The codex session scan's normalized record. Only `installed` is
    /// required: the not-installed envelope carries nothing else.
    private struct CodexRecord: Decodable {
        let installed: Bool
        let windows: [CodexWindow]
        let tokens: ProviderTokens?

        enum CodingKeys: String, CodingKey {
            case installed, windows, tokens
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            installed = try container.decode(Bool.self, forKey: .installed)
            windows = try container.decodeIfPresent([CodexWindow].self, forKey: .windows) ?? []
            tokens = try container.decodeIfPresent(ProviderTokens.self, forKey: .tokens)
        }
    }

    /// One rate-limit entry from Codex's newest `token_count` record, as a
    /// `GrazrWindow`: the 5-hour and weekly scopes keep grazr's group names,
    /// anything else is labeled by whole days ("30d"). An entry missing its
    /// percent or span has nothing to show and is dropped.
    private struct CodexWindow: Decodable {
        let usedPercent: Double?
        let windowMinutes: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }

        var window: GrazrWindow? {
            guard let usedPercent, usedPercent.isFinite,
                  let windowMinutes, windowMinutes.isFinite
            else { return nil }
            let minutes = Int(windowMinutes)
            return GrazrWindow(
                kind: "usage",
                scope: nil,
                group: minutes == 300 ? "session"
                    : minutes == 10080 ? "weekly"
                    : "\(minutes / 1440)d",
                remaining: max(0, 100 - Int(usedPercent.rounded())),
                resetsAt: resetsAt.map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// A codex record without rate-limit windows has nothing to show: no
    /// reading, so the card reads as unknown rather than empty meters.
    private static func parseCodex(stdout: Data, fetchedAt: Date) -> UsageParseResult? {
        guard let record = try? JSONDecoder().decode(CodexRecord.self, from: stdout) else { return nil }
        guard record.installed else { return UsageParseResult(installed: false, readings: []) }
        let windows = record.windows.compactMap(\.window)
        guard !windows.isEmpty else { return UsageParseResult(installed: true, readings: []) }
        let reading = AgentUsageReading(
            id: UsageProvider.codex.rawValue, provider: .codex,
            windows: windows,
            tokens: record.tokens?.tokens, fetchedAt: fetchedAt)
        return UsageParseResult(installed: true, readings: [reading])
    }

    // MARK: - OpenCode

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
        guard let stats = try? JSONDecoder().decode(OpencodeStats.self, from: stdout) else { return nil }
        guard stats.installed != false else { return UsageParseResult(installed: false, readings: []) }
        // An installed opencode with an empty stats payload has nothing to
        // show yet — codex's shape: `.unknown`, never a thrown failure.
        guard stats.tokens != nil || stats.range != nil else {
            return UsageParseResult(installed: true, readings: [])
        }
        let range = stats.range
        let reading = AgentUsageReading(
            id: UsageProvider.opencode.rawValue, provider: .opencode,
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

    /// The snake_case token totals codex and gemini's normalized output
    /// carry. A null or missing count (an older codex build has no
    /// cache-write field) is zero rather than a failed decode.
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func count(_ key: CodingKeys) -> Int {
                guard let value = try? container.decodeIfPresent(Double.self, forKey: key),
                      value.isFinite, value >= 0, value < 9e18
                else { return 0 }
                return Int(value)
            }
            input = count(.input)
            output = count(.output)
            reasoning = count(.reasoning)
            cacheRead = count(.cacheRead)
            cacheWrite = count(.cacheWrite)
        }

        var tokens: UsageTokens {
            UsageTokens(
                input: input, output: output, reasoning: reasoning,
                cacheRead: cacheRead, cacheWrite: cacheWrite)
        }
    }
}
