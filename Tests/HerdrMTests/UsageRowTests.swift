import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Hosts the real `SidebarUsageStats` row and answers what a user would
/// see, the way VoiceOver reads it — the `UsageSheetHarness` conventions,
/// sized for the sidebar footer's stats rows.
@MainActor
private final class UsageRowHarness {
    private let root: NSHostingView<AnyView>
    private let window: NSWindow

    init(meters: [UsageMeterValue], onOpenSheet: @escaping () -> Void = {}) throws {
        let view = SidebarUsageStats(meters: meters, onOpenSheet: onOpenSheet)
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

    func pressRow() throws {
        let button = try XCTUnwrap(
            AccessibilityProbe.elements(in: window).first {
                $0.role == "AXButton" && $0.name?.contains("Usage") == true
            },
            "no usage row button among: \(labels)"
        )
        AccessibilityProbe.press(button)
        settle(seconds: 0.2)
    }

    func settle(seconds: TimeInterval = 0.2) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
    }
}

/// The sidebar's usage row: one meter per picked agent, in the machine
/// stats row's visual language, sitting above it. Window-bearing agents
/// fill a level-tinted bar; tokens-only agents show a compact total over a
/// dimmed track; nothing read dims to a dash. The whole row opens the
/// Usage sheet.
@MainActor
final class UsageRowTests: XCTestCase {
    func testRowShowsBothWindowsPerAgent() throws {
        let harness = try UsageRowHarness(meters: [
            UsageMeterValue(provider: .claude, windows: [
                UsageWindowValue(label: "5H", percentUsed: 88, untilReset: "2h51m"),
                UsageWindowValue(label: "7D", percentUsed: 40, untilReset: "1d2h"),
            ], tokenTotal: nil),
            UsageMeterValue(provider: .codex, windows: [
                UsageWindowValue(label: "30D", percentUsed: 12, untilReset: "6d18h"),
            ], tokenTotal: nil),
        ])

        XCTAssertTrue(harness.labels.contains { $0.contains("CLAUDE") }, "claude meter: \(harness.labels)")
        XCTAssertTrue(harness.labels.contains { $0.contains("5H") && $0.contains("88%") && $0.contains("2h51m") }, "claude 5h line: \(harness.labels)")
        XCTAssertTrue(harness.labels.contains { $0.contains("7D") && $0.contains("40%") && $0.contains("1d2h") }, "claude 7d line: \(harness.labels)")
        XCTAssertTrue(harness.labels.contains { $0.contains("30D") && $0.contains("12%") && $0.contains("6d18h") }, "codex single 30d line: \(harness.labels)")
    }

    func testUnpickedAgentsDoNotRender() throws {
        let harness = try UsageRowHarness(meters: [
            UsageMeterValue(provider: .claude, windows: [
                UsageWindowValue(label: "5H", percentUsed: 88, untilReset: nil),
            ], tokenTotal: nil),
        ])

        XCTAssertTrue(harness.labels.contains { $0.contains("CLAUDE") }, "\(harness.labels)")
        XCTAssertFalse(harness.labels.contains { $0.contains("CODEX") }, "unpicked codex absent: \(harness.labels)")
    }

    /// Tokens-only agents have no honest percent: a compact total over a
    /// dimmed track, a dash when even that is missing.
    func testTokensOnlyAgentsShowTotalOrDash() throws {
        let harness = try UsageRowHarness(meters: [
            UsageMeterValue(provider: .opencode, windows: [], tokenTotal: "12M"),
            UsageMeterValue(provider: .gemini, windows: [], tokenTotal: nil),
        ])

        XCTAssertTrue(harness.labels.contains { $0.contains("OPENCODE") && $0.contains("12M") }, "opencode total: \(harness.labels)")
        XCTAssertTrue(harness.labels.contains { $0.contains("GEMINI") && $0.contains("—") }, "gemini dimmed: \(harness.labels)")
    }

    func testNothingReadDimsEveryMeterButTheRowStillOpens() throws {
        var opens = 0
        let harness = try UsageRowHarness(meters: [
            UsageMeterValue(provider: .claude, windows: [], tokenTotal: nil),
        ], onOpenSheet: { opens += 1 })

        XCTAssertTrue(harness.labels.contains { $0.contains("CLAUDE") && $0.contains("—") }, "\(harness.labels)")
        try harness.pressRow()
        XCTAssertEqual(opens, 1, "the dimmed row still opens the sheet")
    }

    /// The compact token tiers everywhere usage shows a number: k, M, G,
    /// T, P — never scientific.
    func testCompactTokenTiers() {
        XCTAssertEqual(UsageFormat.compact(943), "943")
        XCTAssertEqual(UsageFormat.compact(12_000), "12k")
        XCTAssertEqual(UsageFormat.compact(1_234_500), "1.2M")
        XCTAssertEqual(UsageFormat.compact(12_000_000), "12M")
        XCTAssertEqual(UsageFormat.compact(1_500_000_000), "1.5G")
        XCTAssertEqual(UsageFormat.compact(3_400_000_000_000), "3.4T")
        XCTAssertEqual(UsageFormat.compact(7_800_000_000_000_000), "7.8P")
    }

    /// `45m`, `2h51m`, `1d2h` — the countdown lines carry; nil without a
    /// reset time.
    func testUntilResetFormatting() {
        let now = Date()
        XCTAssertEqual(SidebarView.untilReset(now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(SidebarView.untilReset(now.addingTimeInterval(171 * 60), now: now), "2h51m")
        XCTAssertEqual(SidebarView.untilReset(now.addingTimeInterval((26 * 3600) + (2 * 60)), now: now), "1d2h")
        XCTAssertEqual(SidebarView.untilReset(now.addingTimeInterval(-(10 * 60)), now: now), "0m", "past resets clamp")
        XCTAssertNil(SidebarView.untilReset(nil, now: now))
    }

    /// The picked set persists as a comma list; toggling is its whole
    /// algebra. Default is the window-bearing pair.
    func testAgentPickTogglingAndDefaults() {
        let key = "usage.sidebarAgents"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertEqual(AppModel().sidebarAgents, "claude,codex", "the default pick")
        XCTAssertEqual(SidebarUsageStats.toggling(.opencode, in: "claude,codex"), "claude,codex,opencode")
        XCTAssertEqual(SidebarUsageStats.toggling(.codex, in: "claude,codex"), "claude")
        XCTAssertEqual(SidebarUsageStats.toggling(.codex, in: "claude,codex,opencode"), "claude,opencode")
        XCTAssertEqual(SidebarUsageStats.toggling(.gemini, in: ""), "gemini")
    }

    /// The parsed pick keeps `UsageProvider.allCases` order and drops junk.
    func testParsedPickFiltersAndOrders() {
        let key = "usage.sidebarAgents"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let model = AppModel()
        model.sidebarAgents = "gemini,claude,nonsense"
        XCTAssertEqual(model.sidebarAgentProviders, [.claude, .gemini])
    }

    /// Round one's refresh discipline, kept: devices standing `.failed` or
    /// `.unknown` re-read, never-read devices get their first read, fresh
    /// readings stand — all non-forced.
    func testRefreshReadsFailedUnknownAndNewcomersNonForced() async throws {
        let studio = Device(id: UUID(), name: "Studio", kind: .ssh(target: "studio.example"))
        let fresh = Device(id: UUID(), name: "Fresh", kind: .ssh(target: "fresh.example"))
        func reading(_ provider: UsageProvider) -> AgentUsageReading {
            AgentUsageReading(id: provider.rawValue, provider: provider, windows: [], fetchedAt: Date())
        }
        let states: [UUID: [UsageProvider: UsageProviderState]] = [
            studio.id: [
                .claude: .failed("offline"),
                .codex: .unknown, .gemini: .unknown, .opencode: .unknown,
            ],
            Device.local.id: [
                .claude: .readings([reading(.claude)]),
            ],
        ]
        var reads: [(UUID, Bool)] = []
        await SidebarView.refreshUsageReads(
            states: states, devices: [studio, .local]
        ) { device, force in
            reads.append((device.id, force))
        }
        XCTAssertEqual(reads.map(\.0), [studio.id], "failed re-reads, fresh stands: \(reads)")
        XCTAssertTrue(reads.allSatisfy { !$0.1 })

        reads.removeAll()
        await SidebarView.refreshUsageReads(
            states: states, devices: [studio, .local, fresh]
        ) { device, force in
            reads.append((device.id, force))
        }
        XCTAssertEqual(reads.map(\.0), [studio.id, fresh.id], "refire reads newcomer too: \(reads)")
        XCTAssertTrue(reads.allSatisfy { !$0.1 })
    }
}
