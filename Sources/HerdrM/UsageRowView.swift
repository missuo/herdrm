import HerdrKit
import SwiftUI

// MARK: - Values

/// One window line in a usage meter: its label (5H, 7D, 30D), the percent
/// used, and how long until it refills.
struct UsageWindowValue: Equatable {
    /// The compact visual label: `5H`, `7D`, `30D`.
    let label: String
    /// What VoiceOver says for the window: "5-hour window".
    let spokenName: String
    let percentUsed: Double
    /// Seconds until the window refills; nil when the reading has no reset.
    let secondsUntilReset: TimeInterval?

    init(group: String, percentUsed: Double, secondsUntilReset: TimeInterval?) {
        label = Self.label(group)
        spokenName = Self.spokenName(group)
        self.percentUsed = percentUsed
        self.secondsUntilReset = secondsUntilReset
    }

    /// `45m`, `2h51m`, `1d2h`.
    var untilReset: String? { secondsUntilReset.map(Self.compactDuration) }

    /// The ~5h session, the week, or the window's own span (30D).
    static func label(_ group: String) -> String {
        switch group {
        case "session": return "5H"
        case "weekly": return "7D"
        default: return group.uppercased()
        }
    }

    static func spokenName(_ group: String) -> String {
        switch group {
        case "session": return String(localized: "5-hour window")
        case "weekly": return String(localized: "weekly window")
        default:
            if group.hasSuffix("d"), let days = Int(group.dropLast()) {
                return String(localized: "\(days)-day window")
            }
            return String(localized: "\(group) window")
        }
    }

    static func compactDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h\(minutes % 60)m" }
        return "\(hours / 24)d\(hours % 24)h"
    }

    /// "1 hour, 12 minutes" in the app's language.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, (seconds / 60).rounded() * 60)) ?? compactDuration(seconds)
    }
}

/// One meter's data in the sidebar's usage row: up to two open windows —
/// the ~5h session and the longer limit (week, 30d) — or, for agents that
/// report no windows, a token total. Neither dims to a dash.
struct UsageMeterValue: Identifiable, Equatable {
    let provider: UsageProvider
    var windows: [UsageWindowValue] = []
    var tokens: Int?
    var id: UsageProvider { provider }

    /// `12M`: the compact total tokens-only meters show.
    var tokenTotal: String? { tokens.map(UsageFormat.compact) }

    /// What VoiceOver reads for the meter: "Claude: 5-hour window 34% used,
    /// resets in 1 hour, 12 minutes; weekly window 12% used".
    var spokenSummary: String {
        let name = UsageDefaults.name(provider)
        let details: String
        if !windows.isEmpty {
            details = windows.map { window in
                let percent = MachineStatsFormat.percent(window.percentUsed)
                guard let seconds = window.secondsUntilReset else {
                    return String(localized: "\(window.spokenName) \(percent) used")
                }
                let duration = UsageWindowValue.spokenDuration(seconds)
                return String(localized: "\(window.spokenName) \(percent) used, resets in \(duration)")
            }.joined(separator: "; ")
        } else if let tokens {
            let count = NumberFormatter.localizedString(from: NSNumber(value: tokens), number: .decimal)
            details = String(localized: "\(count) tokens in the last 7 days")
        } else {
            details = String(localized: "no reading yet")
        }
        return String(localized: "\(name): \(details)")
    }
}

// MARK: - Row

/// The opt-in usage row in the sidebar footer for the selected device:
/// reads the picked agents there when it appears and every five minutes
/// while it stays on screen in a visible window. Hidden, occluded, turned
/// off, or moved to another device, the reads stop.
struct SidebarUsageRow: View {
    @ObservedObject var usage: UsageModel
    let device: Device
    let providers: [UsageProvider]
    @State private var windowVisible = true

    private struct WatchKey: Hashable {
        let device: Device
        let providers: [UsageProvider]
        let visible: Bool
    }

    var body: some View {
        // A minute tick keeps the reset countdowns honest between reads.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            SidebarUsageStats(meters: Self.meters(
                states: usage.states[device.id] ?? [:],
                device: device, providers: providers, now: context.date))
        }
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .task(id: WatchKey(device: device, providers: providers, visible: windowVisible)) {
            guard windowVisible else { return }
            await usage.watch(device, providers: providers)
        }
    }

    /// The row's meters: one per picked agent, from `device`'s states
    /// only. Window-bearing agents fill a line per open window — the ~5h
    /// session and the longer limit; tokens-only agents a total. Readings
    /// older than `UsageModel.staleAfter` count as not read.
    static func meters(
        states: [UsageProvider: UsageProviderState],
        device: Device,
        providers: [UsageProvider],
        now: Date
    ) -> [UsageMeterValue] {
        providers.map { provider in
            guard case .readings(let all)? = states[provider] else {
                return UsageMeterValue(provider: provider)
            }
            let fresh = all.filter { now.timeIntervalSince($0.fetchedAt) < UsageModel.staleAfter }
            let scoped: [UUID: [UsageProvider: UsageProviderState]] = [device.id: [provider: .readings(fresh)]]
            func line(_ found: (device: Device, window: GrazrWindow)?) -> UsageWindowValue? {
                guard let window = found?.window else { return nil }
                return UsageWindowValue(
                    group: window.group,
                    percentUsed: 100 - Double(window.left(now: now)),
                    secondsUntilReset: window.resetsAt.map { $0.timeIntervalSince(now) })
            }
            let windows = [
                line(UsageSelection.tightestSession(
                    states: scoped, devices: [device], provider: provider, now: now)),
                line(UsageSelection.tightestLimit(
                    states: scoped, devices: [device], provider: provider, scope: nil, now: now)),
            ].compactMap { $0 }
            return UsageMeterValue(
                provider: provider,
                windows: windows,
                tokens: windows.isEmpty ? tokenTotal(fresh) : nil)
        }
    }

    /// The readings' summed token count; nil when they carry none.
    static func tokenTotal(_ readings: [AgentUsageReading]) -> Int? {
        let total = readings.compactMap(\.tokens).reduce(0) { sum, tokens in
            sum + tokens.input + tokens.output + tokens.reasoning + tokens.cacheRead + tokens.cacheWrite
        }
        return total > 0 ? total : nil
    }
}

/// The row's visuals: one meter column per picked agent. Window-bearing
/// agents fill a level-tinted bar with the percent used; tokens-only agents
/// show a labeled 7D total line over a dimmed track. One VoiceOver element
/// that reads every meter in words.
struct SidebarUsageStats: View {
    let meters: [UsageMeterValue]

    var body: some View {
        // Top-aligned so every column's icon + value headline sits on
        // one line; shorter columns just leave space below.
        HStack(alignment: .top, spacing: 12) {
            ForEach(meters) { meter in
                UsageMeter(meter: meter)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenSummary(meters))
    }

    static func spokenSummary(_ meters: [UsageMeterValue]) -> String {
        let details = meters.map(\.spokenSummary).joined(separator: ". ")
        return String(localized: "Agent usage: \(details)")
    }
}

/// One meter column: the agent's brand icon over a line per open window —
/// label, percent used, time until reset — each above its level-tinted
/// bar. Tokens-only agents show one labeled 7D line — the total — above a
/// single dimmed track, so every column's first bar sits at the same
/// height. Icons, not names: three-plus meters leave no room for words.
private struct UsageMeter: View {
    let meter: UsageMeterValue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let resource = BrandIconLoader.agentIcon(for: meter.provider.rawValue) {
                    BrandIcon(resource: resource, size: 11, fallbackSystemName: fallback)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Image(systemName: fallback)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 2)
                Text(verbatim: header)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(headerTint)
                    .lineLimit(1)
            }
            if meter.windows.isEmpty {
                // A labeled line like the window rows, so the first track
                // sits level with window columns' first row. "7D" is
                // honest: every tokens-only source reads a 7-day period.
                VStack(alignment: .leading, spacing: 1) {
                    if let total = meter.tokenTotal {
                        HStack(spacing: 3) {
                            Text(verbatim: "7D")
                                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                            Text(verbatim: total)
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    track(percent: nil)
                }
            } else {
                ForEach(Array(meter.windows.enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Text(verbatim: window.label)
                                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                            Text(verbatim: line(window))
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(Self.levelColor(window.percentUsed))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        track(percent: window.percentUsed)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.35), value: meter)
    }

    /// The header value: the tightest window's percent, the token total,
    /// or a dimmed dash.
    private var header: String {
        meter.windows.map(\.percentUsed).max().map(MachineStatsFormat.percent) ?? meter.tokenTotal ?? "—"
    }

    private var headerTint: Color {
        meter.windows.map(\.percentUsed).max().map(Self.levelColor)
            ?? (meter.tokenTotal != nil ? Theme.textSecondary : Theme.textGhost)
    }

    private func line(_ window: UsageWindowValue) -> String {
        let percent = MachineStatsFormat.percent(window.percentUsed)
        return window.untilReset.map { "\(percent) · \($0)" } ?? percent
    }

    private func track(percent: Double?) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textGhost.opacity(0.22))
                Capsule()
                    .fill(percent.map(Self.levelColor) ?? Theme.textGhost)
                    .frame(width: max((percent ?? 0) > 0 ? 3 : 0, proxy.size.width * (percent ?? 0) / 100))
            }
        }
        .frame(height: 4)
    }

    /// The machine row's own rule, percent used: calm until the window is
    /// nearly spent.
    private static func levelColor(_ percent: Double) -> Color {
        if percent >= 90 { return Theme.danger }
        if percent >= 75 { return Theme.warning }
        return Theme.textSecondary
    }

    /// An SF fallback when no brand icon is bundled for the agent.
    private var fallback: String {
        switch meter.provider {
        case .claude: return "sparkles"
        case .codex: return "infinity"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "wand.and.stars"
        }
    }
}
