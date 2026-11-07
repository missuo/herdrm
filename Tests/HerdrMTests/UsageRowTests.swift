import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Hosts the real `SidebarUsageStats` row and answers what a user would
/// hear, the way VoiceOver reads it.
@MainActor
private final class UsageRowHarness {
    private let root: NSHostingView<AnyView>
    private let window: NSWindow

    init(meters: [UsageMeterValue]) throws {
        let view = SidebarUsageStats(meters: meters)
            .frame(width: 240)
        root = NSHostingView(rootView: AnyView(view))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "UsageRowHarness \(UUID().uuidString)" // AccessibilityProbe finds the window by title
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

    var labels: [String] {
        AccessibilityProbe.elements(in: window)
            .filter { $0.role != "AXWindow" }
            .compactMap(\.name)
    }

    func settle(seconds: TimeInterval = 0.2) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
    }
}

/// The sidebar's usage row: one meter per picked agent for the selected
/// device. Compact on screen (`5H 34% · 1h12m`), read in words by
/// VoiceOver ("Claude: 5-hour window 34% used, resets in 1 hour, 12
/// minutes").
@MainActor
final class UsageRowTests: XCTestCase {
    private let studio = Device(id: UUID(), name: "Studio", kind: .ssh(target: "studio.example"))

    func testVoiceOverReadsEveryWindowInWords() throws {
        let harness = try UsageRowHarness(meters: [
            UsageMeterValue(provider: .claude, windows: [
                UsageWindowValue(group: "session", percentUsed: 88, secondsUntilReset: 171 * 60),
                UsageWindowValue(group: "weekly", percentUsed: 40, secondsUntilReset: nil),
            ]),
            UsageMeterValue(provider: .codex, windows: [
                UsageWindowValue(group: "30d", percentUsed: 12, secondsUntilReset: nil),
            ]),
        ])

        let row = try XCTUnwrap(harness.labels.first { $0.hasPrefix("Agent usage:") }, "\(harness.labels)")
        XCTAssertTrue(row.contains("Claude: 5-hour window 88% used, resets in 2 hours"), row)
        XCTAssertTrue(row.contains("weekly window 40% used"), row)
        XCTAssertTrue(row.contains("Codex: 30-day window 12% used"), row)
        XCTAssertFalse(row.contains("5H") || row.contains("CLAUDE") || row.contains("·"), "compact text leaked into speech: \(row)")
    }

    func testUnpickedAgentsDoNotRender() throws {
        let harness = try UsageRowHarness(meters: [
            UsageMeterValue(provider: .claude, windows: [
                UsageWindowValue(group: "session", percentUsed: 88, secondsUntilReset: nil),
            ]),
        ])

        let row = try XCTUnwrap(harness.labels.first { $0.hasPrefix("Agent usage:") }, "\(harness.labels)")
        XCTAssertTrue(row.contains("Claude"), row)
        XCTAssertFalse(row.contains("Codex"), "unpicked codex absent: \(row)")
    }

    func testTokensOnlyAndUnreadAgentsInWords() throws {
        let harness = try UsageRowHarness(meters: [
            UsageMeterValue(provider: .opencode, tokens: 1_200_000),
            UsageMeterValue(provider: .gemini),
        ])

        let row = try XCTUnwrap(harness.labels.first { $0.hasPrefix("Agent usage:") }, "\(harness.labels)")
        let count = NumberFormatter.localizedString(from: 1_200_000, number: .decimal)
        XCTAssertTrue(row.contains("OpenCode: \(count) tokens in the last 7 days"), row)
        XCTAssertTrue(row.contains("Gemini: no reading yet"), row)
    }

    // MARK: - Values (no window)

    func testCompactVisualForms() {
        let session = UsageWindowValue(group: "session", percentUsed: 34, secondsUntilReset: 72 * 60)
        XCTAssertEqual(session.label, "5H")
        XCTAssertEqual(session.untilReset, "1h12m")
        XCTAssertEqual(UsageWindowValue.label("weekly"), "7D")
        XCTAssertEqual(UsageWindowValue.label("30d"), "30D")
        XCTAssertEqual(UsageWindowValue.compactDuration(45 * 60), "45m")
        XCTAssertEqual(UsageWindowValue.compactDuration((26 * 3600) + (2 * 60)), "1d2h")
        XCTAssertEqual(UsageWindowValue.compactDuration(-(10 * 60)), "0m", "past resets clamp")
        XCTAssertNil(UsageWindowValue(group: "session", percentUsed: 1, secondsUntilReset: nil).untilReset)
        XCTAssertEqual(UsageMeterValue(provider: .opencode, tokens: 12_000_000).tokenTotal, "12M")
    }

    /// The compact token tiers everywhere usage shows a number: k, M, G,
    /// T, P — never scientific.
    func testCompactTokenTiers() {
        XCTAssertEqual(UsageFormat.compact(943), "943")
        XCTAssertEqual(UsageFormat.compact(12_000), "12k")
        XCTAssertEqual(UsageFormat.compact(1_234_500), "1.2M")
        XCTAssertEqual(UsageFormat.compact(1_500_000_000), "1.5G")
        XCTAssertEqual(UsageFormat.compact(3_400_000_000_000), "3.4T")
        XCTAssertEqual(UsageFormat.compact(7_800_000_000_000_000), "7.8P")
    }

    /// Meters read only the given device's states and only the picked
    /// providers; token totals never add another device's readings.
    func testMetersScopeToTheDeviceAndPick() {
        let now = Date()
        let tokens = UsageTokens(input: 4_000_000, output: 400_000, reasoning: 0, cacheRead: 800_000, cacheWrite: 0)
        let states: [UsageProvider: UsageProviderState] = [
            .claude: .readings([AgentUsageReading(
                id: "claude", provider: .claude,
                windows: [
                    GrazrWindow(kind: "usage", group: "session", remaining: 66, resetsAt: now.addingTimeInterval(3600)),
                    GrazrWindow(kind: "usage", group: "weekly", remaining: 88, resetsAt: nil),
                ],
                fetchedAt: now)]),
            .opencode: .readings([AgentUsageReading(id: "opencode", provider: .opencode, tokens: tokens, fetchedAt: now)]),
            .gemini: .readings([AgentUsageReading(id: "gemini", provider: .gemini, tokens: tokens, fetchedAt: now)]),
        ]
        let meters = SidebarUsageRow.meters(states: states, device: studio, providers: [.claude, .codex, .opencode], now: now)

        XCTAssertEqual(meters.map(\.provider), [.claude, .codex, .opencode], "gemini is not picked")
        XCTAssertEqual(meters[0].windows.map(\.label), ["5H", "7D"])
        XCTAssertEqual(meters[0].windows.map(\.percentUsed), [34, 12])
        XCTAssertEqual(meters[1], UsageMeterValue(provider: .codex), "no readings: a dash")
        XCTAssertEqual(meters[2].tokens, 5_200_000, "this device's readings only")
    }

    /// Readings past `UsageModel.staleAfter` are not shown as current.
    func testStaleReadingsDimToADash() {
        let now = Date()
        let old = now.addingTimeInterval(-UsageModel.staleAfter - 1)
        let states: [UsageProvider: UsageProviderState] = [
            .claude: .readings([AgentUsageReading(
                id: "claude", provider: .claude,
                windows: [GrazrWindow(kind: "usage", group: "session", remaining: 66, resetsAt: nil)],
                fetchedAt: old)]),
        ]
        let meters = SidebarUsageRow.meters(states: states, device: studio, providers: [.claude], now: now)
        XCTAssertEqual(meters, [UsageMeterValue(provider: .claude)])
    }

    /// A window past its reset reads as refilled (0% used), never vanishes.
    func testResetWindowShowsRefilled() {
        let now = Date()
        let states: [UsageProvider: UsageProviderState] = [
            .claude: .readings([AgentUsageReading(
                id: "claude", provider: .claude,
                windows: [GrazrWindow(kind: "usage", group: "session", remaining: 3, resetsAt: now.addingTimeInterval(-120))],
                fetchedAt: now)]),
        ]
        let meters = SidebarUsageRow.meters(states: states, device: studio, providers: [.claude], now: now)
        XCTAssertEqual(meters.first?.windows.first?.percentUsed, 0)
        XCTAssertEqual(meters.first?.windows.first?.untilReset, "0m")
    }

    /// The pick persists as a comma list in canonical order; junk drops,
    /// nothing valid falls back to the default pick.
    func testAgentPickParsingAndToggling() {
        XCTAssertEqual(UsageDefaults.providers(from: UsageDefaults.defaultAgents), [.claude, .codex, .opencode])
        XCTAssertEqual(UsageDefaults.providers(from: "gemini,claude,nonsense"), [.claude, .gemini])
        XCTAssertEqual(UsageDefaults.providers(from: "nonsense"), [.claude, .codex, .opencode])
        XCTAssertEqual(UsageDefaults.toggling(.opencode, in: "claude,codex"), "claude,codex,opencode")
        XCTAssertEqual(UsageDefaults.toggling(.codex, in: "claude,codex"), "claude")
        XCTAssertEqual(UsageDefaults.toggling(.gemini, in: "codex,claude"), "claude,codex,gemini")
    }
}

/// `UsageModel` over a fake store: no command runs on this machine.
@MainActor
final class UsageModelTests: XCTestCase {
    private let studio = Device(id: UUID(), name: "Studio", kind: .ssh(target: "studio.example"))

    func testRefreshReadsOnlyThePickedProviders() async {
        let runner = FakeUsageRunner()
        let model = UsageModel(store: runner.store())

        await model.refresh(studio, providers: [.claude, .opencode])

        XCTAssertEqual(Set(runner.asked), [.claude, .opencode])
        XCTAssertEqual(Set(model.states[studio.id].map { Array($0.keys) } ?? []), [.claude, .opencode])
        guard case .readings(let readings)? = model.states[studio.id]?[.claude] else {
            return XCTFail("claude: \(String(describing: model.states[studio.id]?[.claude]))")
        }
        XCTAssertEqual(readings.first?.windows.first?.remaining, 66)
    }

    func testFailedRunBecomesFailedWithoutTouchingOthers() async {
        let runner = FakeUsageRunner(failing: [.codex])
        let model = UsageModel(store: runner.store())

        await model.refresh(studio, providers: [.claude, .codex])

        guard case .failed? = model.states[studio.id]?[.codex] else {
            return XCTFail("codex: \(String(describing: model.states[studio.id]?[.codex]))")
        }
        guard case .readings? = model.states[studio.id]?[.claude] else {
            return XCTFail("claude: \(String(describing: model.states[studio.id]?[.claude]))")
        }
    }

    /// `watch` reads again on every tick, and stops once its task is
    /// cancelled — the row leaving the screen, the window hiding, the
    /// setting turning off or the device changing.
    func testWatchRereadsPeriodicallyUntilCancelled() async throws {
        let runner = FakeUsageRunner()
        let model = UsageModel(store: runner.store(uncached: true))

        let watch = Task { await model.watch(studio, providers: [.claude], every: 0.05) }
        let deadline = Date().addingTimeInterval(5)
        while runner.asked.count < 3, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(runner.asked.count, 3, "re-reads on each tick")

        watch.cancel()
        _ = await watch.value
        let stopped = runner.asked.count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(runner.asked.count, stopped, "no reads after cancel")
    }

    /// The default cadence is the store's cache lifetime, never faster.
    func testRefreshCadenceMatchesTheCache() {
        XCTAssertEqual(UsageModel.refreshInterval, 300)
        XCTAssertGreaterThan(UsageModel.staleAfter, UsageModel.refreshInterval)
    }
}
