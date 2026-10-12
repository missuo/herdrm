import HerdrKit
import SwiftUI

/// The usage sheet: one section per device, one card per provider, in the
/// grazr Accounts sheet's visual language. Everything it shows comes
/// precomputed from `UsageModel` — the view only arranges states, meters and
/// the refresh affordance. Cards describe usage, never quota: providers
/// without quota windows show token statistics captioned as usage.
struct UsageView: View {
    /// Stands in for `UsageModel.refresh(force:)` in the sheet's UIUX tests,
    /// so pressing Refresh never runs the providers' real commands. nil
    /// refreshes for real.
    typealias Refresh = (UsageModel, Device, _ force: Bool) async -> Void

    @ObservedObject var model: UsageModel
    let anchor: Device
    /// What the presenter knows, in sidebar order; sections sort local first.
    /// The sheet line passes only the anchor, so this is usually just it.
    var devices: [Device] = []
    var refresh: Refresh?

    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false

    init(model: UsageModel, anchor: Device, devices: [Device] = [], refresh: Refresh? = nil) {
        _model = ObservedObject(wrappedValue: model)
        self.anchor = anchor
        self.devices = devices
        self.refresh = refresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "chart.bar",
                title: String(localized: "Usage"),
                subtitle: sectionDevices.map(\.name).joined(separator: " · ")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sectionDevices) { device in
                        deviceSection(device)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 520)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            footer
        }
        .frame(width: 520)
        .task { await refreshUnknownDevices() }
    }

    /// Sections in display order: the presenter's list is already sidebar
    /// order, local devices lead it, and the anchor leads when the list
    /// omits it (as the sheet line does).
    private var sectionDevices: [Device] {
        var list = devices
        if !list.contains(anchor) { list.insert(anchor, at: 0) }
        return list.filter(\.isLocal) + list.filter { !$0.isLocal }
    }

    private func deviceSection(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: device.name)
                .font(.system(size: 10.5, weight: .medium))
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(device.name)
            VStack(spacing: 10) {
                ForEach(UsageProvider.allCases, id: \.self) { provider in
                    UsageProviderCard(
                        provider: provider,
                        state: model.states[device.id]?[provider] ?? .loading,
                        now: Date()
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                refreshVisible()
            } label: {
                Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
            }
            // ⌘R re-reads every visible device even when the store's cache is
            // still fresh — the store's five-minute TTL is for appearances.
            .keyboardShortcut("r", modifiers: .command)
            .help(String(localized: "Run every provider's usage command again, even when the last reading is still fresh"))
            .disabled(isRefreshing)
            if isRefreshing {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(String(localized: "Done")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func refreshVisible() {
        isRefreshing = true
        Task {
            for device in sectionDevices {
                await runRefresh(device, force: true)
            }
            isRefreshing = false
        }
    }

    /// Devices the model knows nothing about get their first read; preloaded
    /// states (the store's five-minute cache) are left standing, so re-opening
    /// a device inside the window re-runs nothing.
    private func refreshUnknownDevices() async {
        for device in sectionDevices where model.states[device.id] == nil {
            await runRefresh(device, force: false)
        }
    }

    private func runRefresh(_ device: Device, force: Bool) async {
        if let refresh {
            await refresh(model, device, force)
        } else {
            await model.refresh(device, force: force)
        }
    }
}

/// One provider's card: name header, then either an account row per reading
/// (grazr windows, token statistics) or the state line — loading, not
/// installed, no usage, or the failure's localized reason.
private struct UsageProviderCard: View {
    let provider: UsageProvider
    let state: UsageProviderState
    let now: Date

    private var name: String {
        switch provider {
        case .claude: String(localized: "Claude")
        case .codex: String(localized: "Codex")
        case .opencode: String(localized: "OpenCode")
        case .gemini: String(localized: "Gemini")
        }
    }

    private var statusColor: Color {
        switch state {
        case .loading: Theme.textSecondary
        case .failed: Theme.warning
        default: Theme.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.itemWash))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .readings(let readings):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(readings) { reading in
                    accountRow(reading)
                }
                if let newest = readings.map(\.fetchedAt).max() {
                    Text(String(localized: "Read \(Self.age(newest, now: now))"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textGhost)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(localized: "Read \(Self.age(newest, now: now))"))
                }
            }
        default:
            if let text = state.statusText {
                HStack(spacing: 6) {
                    if case .loading = state {
                        ProgressView().controlSize(.small)
                    }
                    Text(text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(statusColor)
                        .lineLimit(3)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ reading: AgentUsageReading) -> some View {
        let row = VStack(alignment: .leading, spacing: 6) {
            if let account = reading.account {
                Text(account)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !reading.windows.isEmpty {
                VStack(spacing: 5) {
                    ForEach(Array(reading.windows.enumerated()), id: \.offset) { _, window in
                        UsageWindowMeter(window: window, now: now)
                    }
                }
            }
            if let tokens = reading.tokens {
                tokensRow(tokens)
            }
        }
        if let account = reading.account {
            row
                .accessibilityElement(children: .contain)
                .accessibilityLabel(account)
        } else {
            row
        }
    }

    /// Token statistics, captioned as usage: OpenCode and Gemini publish
    /// counts, not quotas, and the card says so.
    private func tokensRow(_ tokens: UsageTokens) -> some View {
        let line = Self.line(for: tokens)
        return VStack(alignment: .leading, spacing: 3) {
            SheetSectionLabel("Usage")
            Text(line)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Usage") + ", " + line)
    }

    private static func line(for tokens: UsageTokens) -> String {
        String(
            localized: "\(Self.count(tokens.input)) input · \(Self.count(tokens.output)) output · \(Self.count(tokens.cacheRead + tokens.cacheWrite)) cache"
        )
    }

    private static func count(_ n: Int) -> String {
        switch n {
        case 0..<1_000: return "\(n)"
        case 1_000..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    private static func age(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// One grazr window's meter row: label, bar of what is left, the percent, and
/// when it resets — the Accounts sheet's window row, without its thresholds
/// (the usage readings carry none; 25% is the swap line the hint uses).
private struct UsageWindowMeter: View {
    let window: GrazrWindow
    let now: Date

    var body: some View {
        let left = window.left(now: now)
        let color = GrazrStyle.tint(left: left, threshold: 25)
        return HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
            ProgressView(value: Double(left) / 100)
                .progressViewStyle(.linear)
                .tint(color)
            Text(String(localized: "\(left)% left"))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 62, alignment: .trailing)
            Text(resetText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 110, alignment: .trailing)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var resetText: String {
        guard let resetsAt = window.resetsAt else { return "" }
        guard window.isOpen(now: now) else { return String(localized: "reset since") }
        return String(localized: "resets \(GrazrStyle.time(resetsAt, now: now))")
    }
}
