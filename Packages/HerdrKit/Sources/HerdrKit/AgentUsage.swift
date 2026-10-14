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

/// Which window the sidebar's USAGE column watches.
public enum UsageSelection {
    /// The open window with the least left among those matching `scope`,
    /// across every provider on every listed device with readings. `scope`
    /// nil matches scope-nil windows only (the all-models week, sessions);
    /// a non-nil scope matches that scope's windows first, falling back to
    /// the scope-nil ones when the model yields none — the meter never
    /// blanks. A window past its reset has refilled and never wins; a
    /// device missing from `devices` is skipped, the tap could not open a
    /// sheet on it. Ties keep the first in device and provider order.
    public static func tightestWindow(
        states: [UUID: [UsageProvider: UsageProviderState]],
        devices: [Device],
        scope: String?,
        now: Date
    ) -> (device: Device, window: GrazrWindow)? {
        pick(states: states, devices: devices, scope: scope, now: now)
            ?? scope.flatMap { _ in
                pick(states: states, devices: devices, scope: nil, now: now)
            }
    }

    /// One provider's own tightest open window — the sidebar's per-agent
    /// meter. Scope rules match the cross-provider variant: nil matches the
    /// provider's scope-nil windows; non-nil prefers the provider's windows
    /// of that scope, falling back to its scope-nil ones.
    public static func tightestWindow(
        states: [UUID: [UsageProvider: UsageProviderState]],
        devices: [Device],
        provider: UsageProvider,
        scope: String?,
        now: Date
    ) -> (device: Device, window: GrazrWindow)? {
        pick(states: states, devices: devices, scope: scope, now: now, provider: provider)
            ?? scope.flatMap { _ in
                pick(states: states, devices: devices, scope: nil, now: now, provider: provider)
            }
    }

    /// The provider's tightest open **session** window (~5h) across
    /// devices — the usage row's first line.
    public static func tightestSession(
        states: [UUID: [UsageProvider: UsageProviderState]],
        devices: [Device],
        provider: UsageProvider,
        now: Date
    ) -> (device: Device, window: GrazrWindow)? {
        var best: (device: Device, window: GrazrWindow)?
        for device in devices {
            guard case .readings(let readings)? = states[device.id]?[provider] else { continue }
            for reading in readings {
                for window in reading.windows
                where window.group == "session" && window.isOpen(now: now) {
                    if window.left(now: now) < best?.window.left(now: now) ?? .max {
                        best = (device, window)
                    }
                }
            }
        }
        return best
    }

    /// The provider's tightest open **limit** window — weekly, monthly,
    /// anything not a session — the usage row's second line. Scope rules
    /// as `tightestWindow`.
    public static func tightestLimit(
        states: [UUID: [UsageProvider: UsageProviderState]],
        devices: [Device],
        provider: UsageProvider,
        scope: String?,
        now: Date
    ) -> (device: Device, window: GrazrWindow)? {
        var scoped: (device: Device, window: GrazrWindow)?
        var plain: (device: Device, window: GrazrWindow)?
        for device in devices {
            guard case .readings(let readings)? = states[device.id]?[provider] else { continue }
            for reading in readings {
                for window in reading.windows
                where window.group != "session" && window.isOpen(now: now) {
                    let candidate = (device, window)
                    func tighter(_ current: (device: Device, window: GrazrWindow)?) -> Bool {
                        window.left(now: now) < current?.window.left(now: now) ?? .max
                    }
                    if window.scope == scope, tighter(scoped) { scoped = candidate }
                    if window.scope == nil, tighter(plain) { plain = candidate }
                }
            }
        }
        return scoped ?? plain
    }

    /// The tightest open window whose scope is exactly `scope`, across
    /// every provider — or within `provider` alone when given.
    private static func pick(
        states: [UUID: [UsageProvider: UsageProviderState]],
        devices: [Device],
        scope: String?,
        now: Date,
        provider: UsageProvider? = nil
    ) -> (device: Device, window: GrazrWindow)? {
        var best: (device: Device, window: GrazrWindow)?
        for device in devices {
            guard let perProvider = states[device.id] else { continue }
            for candidate in UsageProvider.allCases {
                if let provider, candidate != provider { continue }
                guard case .readings(let readings) = perProvider[candidate] else { continue }
                for reading in readings {
                    for window in reading.windows
                    where window.scope == scope && window.isOpen(now: now) {
                        if window.left(now: now) < best?.window.left(now: now) ?? .max {
                            best = (device, window)
                        }
                    }
                }
            }
        }
        return best
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
