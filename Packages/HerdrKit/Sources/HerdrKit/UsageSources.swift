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
        guard stats.tokens != nil || stats.range != nil else { return nil }
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
