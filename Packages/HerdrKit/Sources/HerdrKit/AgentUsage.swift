import Foundation

/// Which coding agent's usage a reading describes.
public enum UsageProvider: String, CaseIterable, Sendable {
    case claude, codex, opencode, gemini
}

/// The token totals a provider reported over its stats period. Claude and
/// Codex carry their quota as `GrazrWindow`s instead; OpenCode and Gemini
/// publish token counts only.
public struct UsageTokens: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var reasoning: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    /// When the provider's stats period opens and closes, nil when it
    /// reports no period.
    public var periodStart: Date?
    public var periodEnd: Date?

    public init(
        input: Int, output: Int, reasoning: Int, cacheRead: Int, cacheWrite: Int,
        periodStart: Date? = nil, periodEnd: Date? = nil
    ) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }
}

/// One provider's usage on one device, as one command run read it.
public struct AgentUsageReading: Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: UsageProvider
    /// The grazr account or provider login it is for, nil when the provider
    /// has no notion of one.
    public var account: String?
    /// Quota windows in grazr's shape (Claude, Codex).
    public var windows: [GrazrWindow]
    public var tokens: UsageTokens?
    public var fetchedAt: Date

    public init(
        id: String, provider: UsageProvider, account: String? = nil,
        windows: [GrazrWindow] = [], tokens: UsageTokens? = nil, fetchedAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.account = account
        self.windows = windows
        self.tokens = tokens
        self.fetchedAt = fetchedAt
    }
}

/// What one provider's command printed, decoded.
public struct UsageParseResult: Equatable, Sendable {
    public var installed: Bool
    public var readings: [AgentUsageReading]

    public init(installed: Bool, readings: [AgentUsageReading]) {
        self.installed = installed
        self.readings = readings
    }
}

/// Where a provider's usage card stands, as the sidebar shows it.
public enum UsageProviderState: Equatable, Sendable {
    case loading
    case readings([AgentUsageReading])
    case notInstalled
    case unknown
    case failed(String)

    /// `installed == false` means the provider is not on the device; a
    /// decodable output without readings means it is there but has nothing
    /// to show yet.
    public init(parse result: UsageParseResult?, fetchedAt: Date) {
        guard let result else {
            self = .unknown
            return
        }
        guard result.installed else {
            self = .notInstalled
            return
        }
        guard !result.readings.isEmpty else {
            self = .unknown
            return
        }
        self = .readings(result.readings.map { reading in
            var reading = reading
            reading.fetchedAt = fetchedAt
            return reading
        })
    }
}
