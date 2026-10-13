import Foundation

/// One device-local day's token totals per provider — one row of the
/// history charts. `date` is midnight UTC of the device's day label
/// ("YYYY-MM-DD"), a stable stand-in for the label the chart renders.
public struct UsageDay: Identifiable, Equatable, Sendable {
    public var date: Date
    public var tokens: [UsageProvider: UsageTokens]
    public var id: Date { date }

    public init(date: Date, tokens: [UsageProvider: UsageTokens]) {
        self.date = date
        self.tokens = tokens
    }
}

/// One device's 30-day usage history: per-day per-provider series and
/// per-model totals, aggregated on the device by `UsageHistorySource`.
public struct UsageHistory: Equatable, Sendable {
    public var days: [UsageDay]
    public var modelTotals: [UsageProvider: [String: UsageTokens]]
    public var generatedAt: Date

    public init(
        days: [UsageDay],
        modelTotals: [UsageProvider: [String: UsageTokens]],
        generatedAt: Date
    ) {
        self.days = days
        self.modelTotals = modelTotals
        self.generatedAt = generatedAt
    }
}
