import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Hosts the real `UsageView` with preloaded states and histories and
/// answers what a user would see, the way VoiceOver reads it — the
/// `UsageSheetHarness` pattern (private there), plus segment pressing for
/// the 7d/30d toggle.
@MainActor
private final class UsageHistoryHarness {
    let model: UsageModel
    private let root: NSHostingView<AnyView>
    private let window: NSWindow

    init(
        model: UsageModel,
        devices: [Device] = [],
        refresh: ((UsageModel, Device, Bool) async -> Void)? = nil,
        historyRefresh: ((UsageModel, Device) async -> Void)? = nil
    ) throws {
        self.model = model
        let view = UsageView(
            model: model, anchor: .local, devices: devices,
            refresh: refresh, historyRefresh: historyRefresh)
            .frame(width: 520, height: 640)
        root = NSHostingView(rootView: AnyView(view))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "UsageHistoryHarness \(UUID().uuidString)" // AccessibilityProbe finds the window by title
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        settle()
    }

    deinit {
        MainActor.assumeIsolated {
            window.close()
        }
    }

    /// What VoiceOver reads, depth first.
    var labels: [String] {
        AccessibilityProbe.elements(in: window).compactMap(\.name)
    }

    /// Presses the refresh button, as the sheet's ⌘R affordance does.
    func pressRefresh() throws {
        let button = try XCTUnwrap(
            AccessibilityProbe.elements(in: window).first {
                $0.role == "AXButton" && $0.name == String(localized: "Refresh")
            },
            "no Refresh button among: \(labels)"
        )
        AccessibilityProbe.press(button)
        settle(seconds: 0.4)
    }

    /// Presses a named control (a segmented picker's segment).
    func press(_ named: String) throws {
        let element = try XCTUnwrap(
            AccessibilityProbe.elements(in: window).first { $0.name == named },
            "no '\(named)' control among: \(labels)"
        )
        AccessibilityProbe.press(element)
        settle(seconds: 0.4)
    }

    func settle(seconds: TimeInterval = 0.2) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
    }
}

/// The sheet's history block: per-day bars VoiceOver can read, the 7d/30d
/// toggle, the approximate dollar total, per-model rows that omit zeros,
/// the empty state, the age line, and refresh covering history alongside
/// quota.
@MainActor
final class UsageHistoryUITests: XCTestCase {
    private static let allLoading: [UsageProvider: UsageProviderState] = [
        .claude: .loading, .codex: .loading, .opencode: .loading, .gemini: .loading,
    ]

    // MARK: - Fixtures

    /// Midnight UTC of today ± `offset` days — the history days' shape.
    private func utcDay(_ offset: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: Date()).addingTimeInterval(Double(offset) * 86400)
    }

    /// "Oct 12" — the chart's day label, in the device's calendar the way
    /// the block now renders every day.
    private func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    private func tokens(_ input: Int, _ output: Int = 0) -> UsageTokens {
        UsageTokens(input: input, output: output, reasoning: 0, cacheRead: 0, cacheWrite: 0)
    }

    /// The K/M style the card rows already use.
    private func count(_ n: Int) -> String {
        UsageFormat.compact(n)
    }

    private func history(
        days: [UsageDay] = [],
        modelTotals: [UsageProvider: [String: UsageTokens]] = [:],
        generatedAt: Date = Date()
    ) -> UsageHistory {
        UsageHistory(days: days, modelTotals: modelTotals, generatedAt: generatedAt)
    }

    /// The label one chart day reads as: "Oct 12 · 1.2M tokens".
    private func dayLabel(_ date: Date, _ tokens: Int) -> String {
        String(localized: "\(dayText(date)) · \(count(tokens)) tokens")
    }

    // MARK: - Bars

    /// Each day's bar reads its date and total tokens, the way the window
    /// meters read label + percent.
    func testBarsExposePerDayTotalsThroughAccessibility() throws {
        let recent = utcDay(-1), older = utcDay(-2)
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        model.preloadHistory(.local, history(days: [
            UsageDay(date: recent, tokens: [.claude: tokens(1_000_000, 200_000)]),
            UsageDay(date: older, tokens: [.codex: tokens(400_000)]),
        ]))
        let harness = try UsageHistoryHarness(model: model)

        let labels = harness.labels
        XCTAssertTrue(labels.contains(dayLabel(recent, 1_200_000)), "\(labels)")
        XCTAssertTrue(labels.contains(dayLabel(older, 400_000)), "\(labels)")
    }

    /// The toggle defaults to 7 days; 30d reaches back to the whole range.
    func testToggleSwitchesBetweenSevenAndThirtyDays() throws {
        let day1 = utcDay(-1), day10 = utcDay(-10), day29 = utcDay(-29)
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        model.preloadHistory(.local, history(days: [
            UsageDay(date: day1, tokens: [.claude: tokens(900_000)]),
            UsageDay(date: day10, tokens: [.claude: tokens(800_000)]),
            UsageDay(date: day29, tokens: [.claude: tokens(700_000)]),
        ]))
        let harness = try UsageHistoryHarness(model: model)

        let sevenDay = harness.labels
        XCTAssertTrue(sevenDay.contains(dayLabel(day1, 900_000)), "\(sevenDay)")
        XCTAssertFalse(sevenDay.contains(dayLabel(day10, 800_000)), "10 days back is outside the default window: \(sevenDay)")

        try harness.press(String(localized: "30d"))
        let thirtyDay = harness.labels
        XCTAssertTrue(thirtyDay.contains(dayLabel(day10, 800_000)), "\(thirtyDay)")
        XCTAssertTrue(thirtyDay.contains(dayLabel(day29, 700_000)), "\(thirtyDay)")
    }

    /// West of UTC, the store's day encoding (each transcript day as its
    /// UTC midnight) falls on the previous local day: a day encoded as
    /// UTC-midnight Oct 12 reads "Oct 11" in New York. The label must
    /// follow that device-calendar date — the same calendar the chart's
    /// axis buckets bars by — rather than the UTC date, or every bar
    /// lands one bucket away from its own accessibility label.
    func testDayLabelsFollowTheDeviceCalendarWestOfUTC() throws {
        let inherited = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "America/New_York", 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let inherited {
                setenv("TZ", inherited, 1)
            } else {
                unsetenv("TZ")
            }
            tzset()
            NSTimeZone.resetSystemTimeZone()
        }

        // UTC midnight yesterday: always inside the 7-day window, and in
        // New York always the local day before its UTC date.
        let day = utcDay(-1)
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        model.preloadHistory(.local, history(days: [
            UsageDay(date: day, tokens: [.claude: tokens(1_200_000)]),
        ]))
        let harness = try UsageHistoryHarness(model: model)

        // `dayText` formats in the device's (now New York's) calendar, so
        // this expectation is the local date — one day before the UTC
        // date the day is encoded as.
        XCTAssertTrue(harness.labels.contains(dayLabel(day, 1_200_000)), "\(harness.labels)")
    }

    // MARK: - Totals

    /// The totals row prices every model total, always says approx. — even
    /// when every model matched a listed rate — and discloses its 30-day
    /// span outright, since the 7d/30d toggle above it changes only the
    /// chart.
    func testTotalsRowShowsApproximateDollarsEvenForKnownModels() throws {
        let opus = tokens(1_000_000, 200_000) // claude-opus-5-5 is a listed rate
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        model.preloadHistory(.local, history(modelTotals: [
            .claude: ["claude-opus-5-5": opus],
        ]))
        let harness = try UsageHistoryHarness(model: model)

        let dollars = UsagePricing.cost(of: opus, model: "claude-opus-5-5").dollars
        let expected = String(
            format: String(localized: "$%@ (approx.)"),
            String(format: "%.2f", dollars))
        let row = try XCTUnwrap(
            harness.labels.first { $0.contains("$") && $0.contains(expected) },
            "no totals row reading \(expected): \(harness.labels)"
        )
        XCTAssertTrue(
            row.hasPrefix(String(localized: "Total (30d)") + ","),
            "the row must disclose its 30-day span: \(row)"
        )
    }

    /// Per-model rows list model and tokens for all three providers and
    /// omit zero-token entries.
    func testPerModelRowsListModelAndTokensOmitZeros() throws {
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        model.preloadHistory(.local, history(modelTotals: [
            .claude: ["claude-opus-5-5": tokens(1_000_000, 200_000), "claude-idle": tokens(0)],
            .codex: ["gpt-5.3-codex": tokens(500_000)],
            .opencode: ["glm-5.3": tokens(2_000_000, 400_000)],
        ]))
        let harness = try UsageHistoryHarness(model: model)

        let labels = harness.labels
        XCTAssertTrue(labels.contains { $0.contains("claude-opus-5-5") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("gpt-5.3-codex") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("glm-5.3") }, "\(labels)")
        XCTAssertTrue(
            labels.contains { $0.contains(count(1_200_000)) && $0.contains("tokens") },
            "formatted tokens: \(labels)"
        )
        XCTAssertFalse(
            labels.contains { $0.contains("claude-idle") },
            "zero-token models must be omitted: \(labels)"
        )
    }

    // MARK: - Empty and stale

    /// A loaded history with nothing in it reads as no history yet.
    func testEmptyHistoryReadsNoHistoryYet() throws {
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        model.preloadHistory(.local, history())
        let harness = try UsageHistoryHarness(model: model)

        XCTAssertTrue(harness.labels.contains(String(localized: "No history yet")), "\(harness.labels)")
    }

    /// The block says when its history was generated, so stale data reads
    /// as stale — the cards' "Read X ago" discipline.
    func testStaleHistoryShowsAge() throws {
        let generatedAt = Date().addingTimeInterval(-3 * 3600)
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        model.preloadHistory(.local, history(
            days: [UsageDay(date: utcDay(-1), tokens: [.claude: tokens(100_000)])],
            generatedAt: generatedAt))
        let harness = try UsageHistoryHarness(model: model)

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let expected = String(
            localized: "Updated \(formatter.localizedString(for: generatedAt, relativeTo: Date()))")
        XCTAssertTrue(harness.labels.contains(expected), "\(harness.labels)")
    }

    // MARK: - Refresh

    /// ⌘R / the refresh button refreshes quota and history together.
    func testRefreshRunsQuotaAndHistoryTogether() throws {
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        var quotaReads: [(UUID, Bool)] = []
        var historyReads: [UUID] = []
        let harness = try UsageHistoryHarness(
            model: model,
            refresh: { _, device, force in quotaReads.append((device.id, force)) },
            historyRefresh: { _, device in historyReads.append(device.id) })

        try harness.pressRefresh()

        XCTAssertEqual(quotaReads.map(\.0), [Device.local.id], "\(quotaReads)")
        XCTAssertTrue(quotaReads.allSatisfy(\.1), "the button forces the quota re-read: \(quotaReads)")
        XCTAssertEqual(historyReads, [Device.local.id], "history refreshes with quota: \(historyReads)")
    }

    /// Presenting the sheet refreshes history alongside quota for devices
    /// it knows nothing about.
    func testSheetOnAppearRefreshesHistoryToo() async throws {
        let model = UsageModel()
        var quotaReads: [(UUID, Bool)] = []
        var historyReads: [UUID] = []
        let harness = try UsageHistoryHarness(
            model: model,
            refresh: { _, device, force in
                quotaReads.append((device.id, force))
                model.preload(device, Self.allLoading)
            },
            historyRefresh: { _, device in historyReads.append(device.id) })
        harness.settle(seconds: 0.5)

        XCTAssertEqual(quotaReads.map(\.0), [Device.local.id], "\(quotaReads)")
        XCTAssertEqual(quotaReads.map(\.1), [false], "the first read is not forced: \(quotaReads)")
        XCTAssertEqual(historyReads, [Device.local.id], "\(historyReads)")
    }
}

/// The store's history read: one merged history per device under its own
/// key namespace, gemini skipped, cached under the same TTL, thrown only
/// when every command failed. Commands are stubbed per provider and the
/// clock is injected, exactly like `UsageStoreTests`.
final class UsageHistoryStoreTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_760_000_000)

    /// A runner that answers each provider's history command with its own
    /// fixture, so one store call fans out over all three.
    private final class RoutingRunner: @unchecked Sendable {
        private let lock = NSLock()
        private var ran: [String] = []
        private let stdout: (String) -> Data
        private let failure: Error?

        init(stdout: @escaping (String) -> Data, failure: Error? = nil) {
            self.stdout = stdout
            self.failure = failure
        }

        var commands: [String] {
            lock.withLock { ran }
        }

        func run(_ command: String, device: Device) async throws -> Data {
            let failure: Error? = lock.withLock {
                ran.append(command)
                return failure ?? self.failure
            }
            if let failure { throw failure }
            return stdout(command)
        }
    }

    /// Routes by the command's own text: the claude heredoc reads
    /// `.claude`, codex's `.codex`, opencode's sqlite walk reads
    /// `opencode.db` and prints the same normalized document.
    private func fixture(_ command: String) -> Data {
        if command.contains(".claude") {
            return Data(Self.claudeDocument.utf8)
        }
        if command.contains(".codex") {
            return Data(Self.codexDocument.utf8)
        }
        if command.contains("opencode.db") {
            return Data(Self.opencodeDocument.utf8)
        }
        return Data("{}".utf8)
    }

    func testHistoryMergesProvidersSkippingGemini() async throws {
        let runner = RoutingRunner(stdout: fixture)
        let clock = MutableClock(stamp)
        let store = UsageStore(runner: runner.run, now: { clock.date })

        let history = try await store.history(on: .local)

        // One command per transcript-keeping provider; gemini has none.
        XCTAssertEqual(runner.commands.count, 3, "\(runner.commands)")
        XCTAssertFalse(
            runner.commands.contains { $0.contains("gemini") },
            "\(runner.commands)")

        // Days from both heredoc providers merge on the shared date.
        let day = try XCTUnwrap(history.days.first, "\(history.days)")
        XCTAssertEqual(day.date, Self.sharedDay)
        XCTAssertNotNil(day.tokens[.claude], "\(day.tokens)")
        XCTAssertNotNil(day.tokens[.codex], "\(day.tokens)")
        XCTAssertEqual(history.days.count, 1, "\(history.days)")

        // Per-model totals keep their providers; opencode's sqlite walk
        // contributes its own day alongside the transcript providers.
        XCTAssertEqual(history.modelTotals[.claude]?["claude-opus-5-5"], tokens(1_000_000, 200_000))
        XCTAssertEqual(history.modelTotals[.codex]?["gpt-5.3-codex"], tokens(100_000))
        XCTAssertEqual(history.modelTotals[.opencode]?["glm-5.3"], tokens(300_000, 50_000))
        XCTAssertNotNil(day.tokens[.opencode], "\(day.tokens)")
        XCTAssertNil(history.modelTotals[.gemini], "\(history.modelTotals)")
        XCTAssertEqual(history.generatedAt, stamp)
    }

    func testHistoryServesFreshCacheWithoutRerunning() async throws {
        let runner = RoutingRunner(stdout: fixture)
        let clock = MutableClock(stamp)
        let store = UsageStore(runner: runner.run, now: { clock.date })

        let first = try await store.history(on: .local)
        clock.advance(299)
        let second = try await store.history(on: .local)

        XCTAssertEqual(runner.commands.count, 3, "the fresh cache serves without a run")
        XCTAssertEqual(first, second)

        clock.advance(2)
        _ = try await store.history(on: .local)
        XCTAssertEqual(runner.commands.count, 6, "past the TTL every provider re-runs")
    }

    func testHistoryThrowsOnlyWhenEveryCommandFails() async throws {
        let runner = RoutingRunner(stdout: fixture, failure: HerdrError.malformedResponse("offline"))
        let clock = MutableClock(stamp)
        let store = UsageStore(runner: runner.run, now: { clock.date })

        do {
            _ = try await store.history(on: .local)
            XCTFail("an all-provider failure must surface")
        } catch {}

        // The failure left nothing cached: the next call runs again and,
        // with the runner repaired, succeeds.
        let repaired = RoutingRunner(stdout: fixture)
        let fresh = UsageStore(runner: repaired.run, now: { clock.date })
        let history = try await fresh.history(on: .local)
        XCTAssertEqual(history.modelTotals[.claude]?["claude-opus-5-5"], tokens(1_000_000, 200_000))
    }

    // MARK: - Fixtures

    private static let sharedDay: Date = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: "2026-10-12")!
    }()

    private static let claudeDocument = #"""
    {"days": [{"date": "2026-10-12", "input": 1000000, "output": 200000, "reasoning": 0, "cache_read": 0, "cache_write": 0}], "models": {"claude-opus-5-5": {"input": 1000000, "output": 200000, "reasoning": 0, "cache_read": 0, "cache_write": 0}}}
    """#

    private static let codexDocument = #"""
    {"days": [{"date": "2026-10-12", "input": 100000, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}], "models": {"gpt-5.3-codex": {"input": 100000, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}}}
    """#

    private static let opencodeDocument = #"""
    {"days": [{"date": "2026-10-12", "input": 300000, "output": 50000, "reasoning": 0, "cache_read": 0, "cache_write": 0}], "models": {"glm-5.3": {"input": 300000, "output": 50000, "reasoning": 0, "cache_read": 0, "cache_write": 0}}}
    """#

    private func tokens(_ input: Int, _ output: Int = 0) -> UsageTokens {
        UsageTokens(input: input, output: output, reasoning: 0, cacheRead: 0, cacheWrite: 0)
    }
}

/// A mutable clock the store reads through, advanced by tests instead of
/// waiting real TTLs out.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var date: Date {
        lock.withLock { current }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
