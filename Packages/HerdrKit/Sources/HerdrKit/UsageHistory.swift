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

/// One device's 30-day usage history: per-day per-provider series,
/// per-model totals, and the session list the drilldown groups by
/// working directory — all aggregated on the device by
/// `UsageHistorySource`.
public struct UsageHistory: Equatable, Sendable {
    public var days: [UsageDay]
    public var modelTotals: [UsageProvider: [String: UsageTokens]]
    /// One row per session the window caught — the drilldown's raw
    /// material: project rows group these by `path` inside the visible
    /// window, so one shape serves both levels.
    public var sessions: [UsageSession]
    public var generatedAt: Date

    public init(
        days: [UsageDay] = [],
        modelTotals: [UsageProvider: [String: UsageTokens]] = [:],
        sessions: [UsageSession] = [],
        generatedAt: Date
    ) {
        self.days = days
        self.modelTotals = modelTotals
        self.sessions = sessions
        self.generatedAt = generatedAt
    }
}

/// One agent session's usage: where it ran (`path`), what it was called
/// (`title`, when the CLI recorded one), when it started, and what it
/// spent. Tokens land on the session's start day — long sessions
/// attribute wholesale, the granularity the CLIs persist.
public struct UsageSession: Identifiable, Equatable, Sendable {
    public let provider: UsageProvider
    public let path: String
    public let title: String?
    public let created: Date
    public let tokens: UsageTokens

    public init(
        provider: UsageProvider,
        path: String,
        title: String?,
        created: Date,
        tokens: UsageTokens
    ) {
        self.provider = provider
        self.path = path
        self.title = title
        self.created = created
        self.tokens = tokens
    }

    public var id: String { "\(provider.rawValue):\(path):\(created.timeIntervalSince1970)" }
}
