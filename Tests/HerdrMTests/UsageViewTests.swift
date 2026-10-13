import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Hosts the real `UsageView` with preloaded states and answers what a user
/// would see, the way VoiceOver reads it. All rendering/pixel mechanics live
/// here so tests read as specs.
@MainActor
private final class UsageSheetHarness {
    let model: UsageModel
    private let root: NSHostingView<AnyView>
    private let window: NSWindow

    /// - Parameters:
    ///   - devices: what the presenter knows, in sidebar order; the sheet
    ///     sorts local first itself.
    ///   - refresh: stands in for `UsageModel.refresh`, so pressing Refresh
    ///     or presenting the sheet never runs the providers' real commands.
    ///     nil lets the view refresh for real.
    init(
        model: UsageModel,
        devices: [Device] = [],
        refresh: ((UsageModel, Device, Bool) async -> Void)? = nil
    ) throws {
        self.model = model
        let view = UsageView(model: model, anchor: .local, devices: devices, refresh: refresh)
            .frame(width: 520, height: 420)
        root = NSHostingView(rootView: AnyView(view))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "UsageHarness \(UUID().uuidString)" // AccessibilityProbe finds the window by title
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

    func settle(seconds: TimeInterval = 0.2) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
    }
}

/// The usage sheet: provider cards carry their names for VoiceOver, window
/// meters read label + percent left + reset time, every non-reading state has
/// its own line, sections sort local first, and ⌘R forces a re-read of every
/// visible device.
@MainActor
final class UsageViewTests: XCTestCase {
    private static let allLoading: [UsageProvider: UsageProviderState] = [
        .claude: .loading, .codex: .loading, .opencode: .loading, .gemini: .loading,
    ]

    private func window(_ group: String, left: Int, resetsIn: TimeInterval?) -> GrazrWindow {
        GrazrWindow(
            kind: "quota",
            group: group,
            remaining: left,
            resetsAt: resetsIn.map { Date().addingTimeInterval($0) }
        )
    }

    private func reading(
        _ provider: UsageProvider,
        account: String? = nil,
        windows: [GrazrWindow] = [],
        tokens: UsageTokens? = nil
    ) -> AgentUsageReading {
        AgentUsageReading(
            id: "\(provider.rawValue)-\(account ?? "only")",
            provider: provider,
            account: account,
            windows: windows,
            tokens: tokens,
            fetchedAt: Date().addingTimeInterval(-3 * 3600)
        )
    }

    func testProviderCardsReadTheirNamesAndWindowMeters() throws {
        let model = UsageModel()
        model.preload(.local, [
            .claude: .readings([
                reading(.claude, account: "senad@example.com", windows: [
                    window("session", left: 42, resetsIn: 2 * 3600),
                    window("weekly", left: 87, resetsIn: 3 * 86400),
                ]),
                reading(.claude, account: "tomasz@example.com", windows: [
                    window("session", left: 7, resetsIn: 2 * 3600),
                ]),
            ]),
            .codex: .readings([
                reading(.codex, windows: [window("30d", left: 98, resetsIn: 3 * 86400)])
            ]),
            .opencode: .readings([
                reading(.opencode, tokens: UsageTokens(
                    input: 1_234_567, output: 45_678, reasoning: 7_000,
                    cacheRead: 980_111, cacheWrite: 1_000
                ))
            ]),
            .gemini: .failed("offline"),
        ])
        let harness = try UsageSheetHarness(model: model)

        let labels = harness.labels
        XCTAssertTrue(labels.contains("Claude"), "\(labels)")
        XCTAssertTrue(labels.contains("Codex"), "\(labels)")
        XCTAssertTrue(labels.contains("OpenCode"), "\(labels)")
        XCTAssertTrue(labels.contains("Gemini"), "\(labels)")
        XCTAssertTrue(labels.contains("senad@example.com"), "account row: \(labels)")
        XCTAssertTrue(labels.contains("offline"), "failed reason: \(labels)")
        let meter = try XCTUnwrap(labels.first { $0.contains("98% left") }, "no meter: \(labels)")
        XCTAssertTrue(meter.contains("30d"), "meter should read its label: \(meter)")
        XCTAssertTrue(labels.contains { $0.contains("42% left") }, "claude 5h meter: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("87% left") }, "claude week meter: \(labels)")
    }

    func testWindowMeterExposesTheResetTime() throws {
        let resetsAt = Date().addingTimeInterval(3 * 86400)
        let model = UsageModel()
        model.preload(.local, [
            .codex: .readings([reading(.codex, windows: [
                GrazrWindow(kind: "quota", group: "30d", remaining: 98, resetsAt: resetsAt),
            ])]),
        ])
        let harness = try UsageSheetHarness(model: model)

        let expected = GrazrStyle.time(resetsAt, now: Date())
        let meter = try XCTUnwrap(harness.labels.first { $0.contains("98% left") }, "\(harness.labels)")
        XCTAssertTrue(meter.contains(expected), "\(meter) should read the reset time \(expected)")
    }

    func testTokensCardReadsAsUsageNeverQuota() throws {
        let model = UsageModel()
        model.preload(.local, [
            .opencode: .readings([reading(.opencode, tokens: UsageTokens(
                input: 1_234_567, output: 45_678, reasoning: 0,
                cacheRead: 980_111, cacheWrite: 1_000
            ))]),
        ])
        let harness = try UsageSheetHarness(model: model)

        let labels = harness.labels
        XCTAssertTrue(labels.contains { $0.hasPrefix("Usage") }, "usage caption: \(labels)")
        XCTAssertTrue(
            labels.contains { $0.contains("1.2M") && $0.contains("input") },
            "token line: \(labels)"
        )
        XCTAssertFalse(
            labels.contains { $0.localizedCaseInsensitiveContains("quota") },
            "token statistics must never be framed as quota: \(labels)"
        )
    }

    func testLoadingStateReadsCheckingUsage() throws {
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        let harness = try UsageSheetHarness(model: model)

        XCTAssertTrue(harness.labels.contains(String(localized: "Checking usage…")), "\(harness.labels)")
    }

    func testNotInstalledStateReadsPlainlyForEveryProvider() throws {
        let model = UsageModel()
        model.preload(.local, [
            .claude: .notInstalled, .codex: .notInstalled,
            .opencode: .notInstalled, .gemini: .notInstalled,
        ])
        let harness = try UsageSheetHarness(model: model)

        // Claude's quota now comes from the Claude CLI itself, so every
        // provider reads the same plain "Not installed".
        XCTAssertEqual(
            harness.labels.filter { $0 == String(localized: "Not installed") }.count, 4,
            "\(harness.labels)"
        )
        XCTAssertFalse(
            harness.labels.contains("Needs grazr"), "\(harness.labels)")
    }

    func testUnknownStateReadsNoUsageYet() throws {
        let model = UsageModel()
        model.preload(.local, [
            .claude: .unknown, .codex: .unknown,
            .opencode: .unknown, .gemini: .unknown,
        ])
        let harness = try UsageSheetHarness(model: model)

        XCTAssertTrue(harness.labels.contains(String(localized: "No usage yet")), "\(harness.labels)")
    }

    func testFailedStateReadsTheReason() throws {
        let model = UsageModel()
        model.preload(.local, [
            .claude: .failed("offline"), .codex: .failed("offline"),
            .opencode: .failed("offline"), .gemini: .failed("offline"),
        ])
        let harness = try UsageSheetHarness(model: model)

        XCTAssertTrue(harness.labels.contains("offline"), "\(harness.labels)")
    }

    func testSectionsRenderLocalFirstThenSidebarOrder() throws {
        let studio = Device(id: UUID(), name: "Studio", kind: .ssh(target: "studio.example"))
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        model.preload(studio, Self.allLoading)
        // Sidebar order puts the remote device first; the sheet must not.
        let harness = try UsageSheetHarness(model: model, devices: [studio, .local])

        let labels = harness.labels
        let local = try XCTUnwrap(labels.firstIndex(of: "Local"), "\(labels)")
        let studioIndex = try XCTUnwrap(labels.firstIndex(of: "Studio"), "\(labels)")
        XCTAssertLessThan(local, studioIndex, "local section should lead: \(labels)")
    }

    func testRefreshRefreshesEveryVisibleDeviceForced() throws {
        let studio = Device(id: UUID(), name: "Studio", kind: .ssh(target: "studio.example"))
        let model = UsageModel()
        model.preload(.local, Self.allLoading)
        model.preload(studio, Self.allLoading)
        var reads: [(UUID, Bool)] = []
        let harness = try UsageSheetHarness(model: model, devices: [studio, .local]) { _, device, force in
            reads.append((device.id, force))
        }

        try harness.pressRefresh()
        XCTAssertEqual(
            Set(reads.map(\.0)),
            [Device.local.id, studio.id],
            "every visible device refreshes: \(reads)"
        )
        XCTAssertTrue(reads.allSatisfy(\.1), "the refresh button forces a re-read: \(reads)")
    }

    func testSheetRefreshesUnknownDevicesOnAppear() async throws {
        let model = UsageModel()
        var reads: [(UUID, Bool)] = []
        let harness = try UsageSheetHarness(model: model) { m, device, force in
            reads.append((device.id, force))
            m.preload(device, Self.allLoading)
        }
        harness.settle(seconds: 0.5)

        XCTAssertEqual(reads.map(\.0), [Device.local.id], "the anchor reads on appear: \(reads)")
        XCTAssertEqual(reads.map(\.1), [false], "the first read is not forced: \(reads)")
    }
}
