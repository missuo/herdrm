/// USD list prices for the models this repo's agents report, and the
/// cost of a token reading under them.
public struct UsagePricing {
    /// When the rates below were last fetched from the vendor pages.
    public static let tableUpdated = "2026-10-13"

    /// One model family's USD rates per 1M tokens. `prefix` matches the
    /// model strings agents put in transcripts and stats output; the
    /// longest matching prefix wins, so dated snapshots
    /// (`claude-opus-5-5-20261001`) bill at their family's row.
    struct Rate: Sendable {
        let prefix: String
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    /// List rates, standard tier, fetched `tableUpdated`:
    static let table: [Rate] = [
        // claude-opus-5-5 — https://www.anthropic.com/pricing, fetched
        // 2026-10-13: input $4/MTok, output $20/MTok, cache read $0.20/MTok
        // (5-min TTL), cache write $5/MTok.
        Rate(prefix: "claude-opus-5-5", input: 4.0, output: 20.0, cacheRead: 0.20, cacheWrite: 5.0),
        // glm-5.3 — https://docs.z.ai/guides/overview/pricing, fetched
        // 2026-10-13: input $1.4/MTok, output $4.4/MTok, cached input
        // $0.26/MTok; cache storage limited-time free → $0 write.
        Rate(prefix: "glm-5.3", input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 0.0),
        // gpt-6-astra — https://platform.openai.com/docs/pricing, fetched
        // 2026-10-13, short context: input $10/MTok, cached input $1/MTok,
        // cache writes $12.50/MTok, output $50/MTok.
        Rate(prefix: "gpt-6-astra", input: 10.0, output: 50.0, cacheRead: 1.0, cacheWrite: 12.5),
        // gpt-6.1-sol — same page, short context: input $2/MTok, cached
        // input $0.10/MTok, cache writes $2.50/MTok, output $10/MTok.
        Rate(prefix: "gpt-6.1-sol", input: 2.0, output: 10.0, cacheRead: 0.1, cacheWrite: 2.5),
        // gpt-6-luna — same page, short context: input $0.10/MTok, cached
        // input $0.01/MTok, cache writes $0.125/MTok, output $0.50/MTok.
        Rate(prefix: "gpt-6-luna", input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
        // gpt-5.3-codex — same page, "Specialized models > Codex": input
        // $1.75/MTok, cached input $0.175/MTok, output $14/MTok; no
        // cache-write charge listed → $0.
        Rate(prefix: "gpt-5.3-codex", input: 1.75, output: 14.0, cacheRead: 0.175, cacheWrite: 0.0),
    ]

    /// The cost of `tokens` on `model` in dollars. The model matches the
    /// table by longest prefix, case-insensitively; a model no row
    /// matches bills at the cheapest rate of each token class and comes
    /// back `approximate`. Reasoning tokens price as output — they are a
    /// subset of the output the transcripts report.
    public static func cost(
        of tokens: UsageTokens, model: String
    ) -> (dollars: Double, approximate: Bool) {
        let matched = match(model: model)
        let rate = matched ?? cheapest
        let dollars = Double(tokens.input) / 1e6 * rate.input
            + Double(tokens.output) / 1e6 * rate.output
            + Double(tokens.reasoning) / 1e6 * rate.output
            + Double(tokens.cacheRead) / 1e6 * rate.cacheRead
            + Double(tokens.cacheWrite) / 1e6 * rate.cacheWrite
        return (dollars, matched == nil)
    }

    /// The table row whose prefix names `model`, longest first.
    private static func match(model: String) -> Rate? {
        let lowered = model.lowercased()
        return table
            .filter { lowered.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }
    }

    /// The fallback rate: the cheapest of each token class across the
    /// table, so an unknown model is under- rather than overestimated.
    private static let cheapest = Rate(
        prefix: "",
        input: table.map(\.input).min() ?? 0,
        output: table.map(\.output).min() ?? 0,
        cacheRead: table.map(\.cacheRead).min() ?? 0,
        cacheWrite: table.map(\.cacheWrite).min() ?? 0
    )
}
