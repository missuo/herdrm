import Charts
import HerdrKit
import SwiftUI

/// The usage sheet: one section per device, one card per provider, in the
/// grazr Accounts sheet's visual language. Everything it shows comes
/// precomputed from `UsageModel` — the view only arranges states, meters,
/// the history charts and the refresh affordance. Cards describe usage,
/// never quota: providers without quota windows show token statistics
/// captioned as usage.
struct UsageView: View {
    /// Stands in for `UsageModel.refresh(force:)` in the sheet's UIUX tests,
    /// so pressing Refresh never runs the providers' real commands. nil
    /// refreshes for real.
    typealias Refresh = (UsageModel, Device, _ force: Bool) async -> Void

    /// Stands in for `UsageModel.refreshHistory(_:)` the same way, so the
    /// history reads stay as stubbed as the quota ones in tests.
    typealias HistoryRefresh = (UsageModel, Device) async -> Void

    @ObservedObject var model: UsageModel
    let anchor: Device
    /// What the presenter knows, in sidebar order; sections sort local first.
    /// The sheet line passes only the anchor, so this is usually just it.
    var devices: [Device] = []
    var refresh: Refresh?
    /// nil refreshes history for real. Injected together with `refresh`, it
    /// replaces the history half of a refresh; without it an injected
    /// `refresh` leaves history untouched, so quota-only test harnesses
    /// never trigger real history commands.
    var historyRefresh: HistoryRefresh?

    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    /// The model whose weekly window the sidebar's Claude meter follows;
    /// empty means all models. `@AppStorage` in a view publishes and
    /// persists in one move, and matches `AppModel.sidebarWatchedModel`'s
    /// key from the other side.
    @AppStorage("usage.sidebarWatchedModel") private var watchedModel = ""
    /// Which agents the sidebar's usage row shows; the same comma list
    /// `AppModel.sidebarAgents` reads, written through the row's toggling.
    @AppStorage("usage.sidebarAgents") private var sidebarAgents = "claude,codex,opencode"

    init(
        model: UsageModel,
        anchor: Device,
        devices: [Device] = [],
        refresh: Refresh? = nil,
        historyRefresh: HistoryRefresh? = nil
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.anchor = anchor
        self.devices = devices
        self.refresh = refresh
        self.historyRefresh = historyRefresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                SheetHeader(
                    systemImage: "chart.bar",
                    title: String(localized: "Usage"),
                    subtitle: sectionDevices.map(\.name).joined(separator: " · ")
                )
                if !scopes.isEmpty {
                    Picker(String(localized: "Watched model"), selection: $watchedModel) {
                        Text(String(localized: "All models")).tag("")
                        ForEach(scopes, id: \.self) { scope in
                            Text(verbatim: scope).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help(String(localized: "The sidebar's Claude meter follows this model's weekly window"))
                    .padding(.trailing, 16)
                }
                Menu {
                    ForEach(UsageProvider.allCases, id: \.self) { provider in
                        Button {
                            sidebarAgents = SidebarUsageStats.toggling(provider, in: sidebarAgents)
                        } label: {
                            if sidebarAgents.split(separator: ",").contains(Substring(provider.rawValue)) {
                                Label(SidebarUsageStats.name(provider), systemImage: "checkmark")
                            } else {
                                Text(verbatim: SidebarUsageStats.name(provider))
                            }
                        }
                    }
                } label: {
                    Label(String(localized: "Sidebar row"), systemImage: "menubar.rectangle")
                }
                .fixedSize()
                .help(String(localized: "Choose which agents the sidebar's usage row shows"))
                .padding(.trailing, 16)
            }
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

    /// Every distinct window scope in the current readings ("Fable"), in
    /// first-seen order — the watched-model picker's options. Hidden while
    /// no provider reports a per-model window.
    private var scopes: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for device in sectionDevices {
            guard let perProvider = model.states[device.id] else { continue }
            for provider in UsageProvider.allCases {
                guard case .readings(let readings) = perProvider[provider] else { continue }
                for reading in readings {
                    for window in reading.windows {
                        if let scope = window.scope, seen.insert(scope).inserted {
                            out.append(scope)
                        }
                    }
                }
            }
        }
        return out
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
                // One history per device once its first read lands; gemini
                // keeps no transcripts and simply contributes nothing.
                if let history = model.histories[device.id] {
                    UsageHistoryBlock(history: history, now: Date())
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
        // History rides along on every refresh path — appear and ⌘R. A
        // quota-only test seam leaves history alone rather than running
        // real commands behind the stub's back.
        if let historyRefresh {
            await historyRefresh(model, device)
        } else if refresh == nil {
            await model.refreshHistory(device)
        }
    }
}

/// The chart's span: seven days by default, the whole fetched month as the
/// alternative.
private enum HistoryWindow: Int, CaseIterable, Hashable {
    case seven = 7
    case thirty = 30

    var label: String {
        switch self {
        case .seven: String(localized: "7d")
        case .thirty: String(localized: "30d")
        }
    }
}

/// One device's history card: stacked daily token bars (claude and codex —
/// the only providers whose transcripts carry a daily series), a 7d/30d
/// toggle, the approximate dollar total over every model the history
/// priced, and a per-model breakdown for all three providers. The chart
/// stays dumb — data in, bars out; everything it reads is precomputed.
private struct UsageHistoryBlock: View {
    let history: UsageHistory
    let now: Date

    @State private var window: HistoryWindow = .seven

    /// The providers charted, in stack order. OpenCode reports only 30-day
    /// per-model totals (no daily series), gemini nothing at all.
    private static let charted: [UsageProvider] = [.claude, .codex]

    /// The providers with per-model rows.
    private static let modeled: [UsageProvider] = [.claude, .codex, .opencode]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Usage history"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Picker(String(localized: "History range"), selection: $window) {
                    ForEach(HistoryWindow.allCases, id: \.self) { span in
                        Text(span.label).tag(span)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if isEmpty {
                Text(String(localized: "No history yet"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "No history yet"))
            } else {
                chart
                legend
                totalsRow
                modelRows
                ageRow
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.itemWash))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Usage history"))
    }

    // MARK: - Chart

    /// Stacked bars of each day's tokens per provider, one accessibility
    /// child per day so VoiceOver reads "Oct 12 · 1.2M tokens" instead of
    /// the chart's opaque marks.
    private var chart: some View {
        Chart {
            ForEach(visibleDays) { day in
                ForEach(Self.charted, id: \.self) { provider in
                    if let tokens = day.tokens[provider], Self.total(tokens) > 0 {
                        BarMark(
                            x: .value(String(localized: "Day"), Self.localStart(of: day.date), unit: .day),
                            y: .value(String(localized: "Tokens"), Self.total(tokens)),
                            stacking: .standard
                        )
                        .foregroundStyle(Self.color(provider))
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(verbatim: UsageFormat.compact(tokens))
                    }
                }
            }
        }
        .frame(height: 110)
        .accessibilityChildren {
            ForEach(visibleDays) { day in
                Color.clear
                    .frame(width: 8, height: 8)
                    .accessibilityElement()
                    .accessibilityLabel(dayLabel(day))
            }
        }
    }

    /// Dots and names for the stacked series — the chart's own legend is
    /// hidden so the palette stays the sheet's. Decorative: VoiceOver
    /// already meets the providers on their cards.
    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(Self.charted, id: \.self) { provider in
                HStack(spacing: 4) {
                    Circle().fill(Self.color(provider)).frame(width: 6, height: 6)
                    Text(Self.name(provider))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
        }
        .accessibilityHidden(true)
    }

    // MARK: - Totals and models

    /// The dollar figure over every model the history priced at its list
    /// rate — approximate even when every model matched, because list
    /// rates are themselves the estimate. The model totals span the
    /// fetched 30-day range however far the chart's toggle reaches back
    /// (days carry no per-model split), so the row says "(30d)" outright
    /// and the tooltip spells the span out.
    private var totalsRow: some View {
        let dollars = String(localized: "$\(String(format: "%.2f", totalDollars)) (approx.)")
        return HStack(alignment: .firstTextBaseline) {
            SheetSectionLabel("Total (30d)")
            Spacer()
            Text(dollars)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.text)
                .help(String(localized: "Totals span the fetched 30 days; priced at API list rates; table fetched \(UsagePricing.tableUpdated)"))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Total (30d)") + ", " + dollars)
    }

    @ViewBuilder
    private var modelRows: some View {
        let rows = Self.modelRows(in: history)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows, id: \.id) { row in
                    let tokens = String(localized: "\(Self.count(Self.total(row.tokens))) tokens")
                    HStack {
                        Text(verbatim: row.model)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(tokens)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.model + ", " + tokens)
                }
            }
        }
    }

    /// When the history was generated, so stale data reads as stale — the
    /// cards' "Read X ago" discipline.
    private var ageRow: some View {
        Text(String(localized: "Updated \(Self.age(history.generatedAt, now: now))"))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textGhost)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Updated \(Self.age(history.generatedAt, now: now))"))
    }

    // MARK: - Derived data

    /// Nothing chartable and no model rows: the device ran its history
    /// commands but has no transcript usage to show.
    private var isEmpty: Bool {
        visibleDays.isEmpty && Self.modelRows(in: history).isEmpty
    }

    /// The days inside the window, oldest first — the chart's whole input,
    /// every day normalized through `localStart(of:)` so the cutoff counts
    /// days in the same calendar the bars and labels render in.
    private var visibleDays: [UsageDay] {
        let cutoff = Self.localStart(of: now).addingTimeInterval(-Double(window.rawValue - 1) * 86400)
        return history.days
            .filter { Self.localStart(of: $0.date) >= cutoff }
            .sorted { Self.localStart(of: $0.date) < Self.localStart(of: $1.date) }
    }

    /// "Oct 12 · 1.2M tokens" — the day's label in the device's calendar,
    /// the same one the chart's axis buckets by, every charted provider
    /// summed.
    private func dayLabel(_ day: UsageDay) -> String {
        let tokens = Self.charted.reduce(0) { $0 + (day.tokens[$1].map(Self.total) ?? 0) }
        return String(localized: "\(Self.dayText(day.date)) · \(Self.count(tokens)) tokens")
    }

    private var totalDollars: Double {
        var dollars = 0.0
        for provider in Self.modeled {
            for (model, tokens) in history.modelTotals[provider] ?? [:] where Self.total(tokens) > 0 {
                dollars += UsagePricing.cost(of: tokens, model: model).dollars
            }
        }
        return dollars
    }

    // MARK: - Formatting

    /// One model row: provider-scoped identity, the raw tokens, zero-token
    /// entries omitted.
    private static func modelRows(in history: UsageHistory) -> [ModelRow] {
        var out: [ModelRow] = []
        for provider in modeled {
            for (model, tokens) in (history.modelTotals[provider] ?? [:]).sorted(by: { $0.key < $1.key })
            where total(tokens) > 0 {
                out.append(ModelRow(id: "\(provider.rawValue):\(model)", model: model, tokens: tokens))
            }
        }
        return out
    }

    private struct ModelRow: Identifiable {
        let id: String
        let model: String
        let tokens: UsageTokens
    }

    /// A reading's whole size. Reasoning is a subset of output (it prices
    /// as output for the same reason), so it is not added again.
    private static func total(_ tokens: UsageTokens) -> Int {
        tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite
    }

    /// `date`'s start of day in the device's calendar — the one day
    /// identity the chart's axis buckets by, the window cutoff counts,
    /// and the labels format, so a bar, its axis tick, and its
    /// accessibility label never disagree for users west or east of UTC.
    private static func localStart(of date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// "Oct 12" — the day's own label, in the device's calendar like
    /// every other day the block renders.
    private static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: localStart(of: date))
    }

    /// The K/M style the provider cards' token lines use.
    private static func count(_ n: Int) -> String {
        UsageFormat.compact(n)
    }

    private static func age(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Each provider's series color, from the sheet's palette: claude the
    /// rust accent, codex the palette's teal (the deliberately
    /// non-semantic chip tints).
    private static func color(_ provider: UsageProvider) -> Color {
        switch provider {
        case .claude: Theme.accent
        case .codex: Theme.devicePalette[1]
        default: Theme.textSecondary
        }
    }

    private static func name(_ provider: UsageProvider) -> String {
        switch provider {
        case .claude: String(localized: "Claude")
        case .codex: String(localized: "Codex")
        case .opencode: String(localized: "OpenCode")
        case .gemini: String(localized: "Gemini")
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
                .help(text)
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
        UsageFormat.compact(n)
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
