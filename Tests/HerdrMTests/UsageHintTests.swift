import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Hosts the real `UsageHintLine` with preloaded states and answers what a
/// user would see, the way VoiceOver reads it — the `UsageSheetHarness`
/// conventions, sized for the sidebar footer line. All rendering mechanics
/// live here so tests read as specs.
@MainActor
private final class UsageHintHarness {
    let model: UsageModel
    private let onSelect: (Device) -> Void
    private let refresh: UsageHintLine.Refresh?
    private let root: NSHostingView<AnyView>
    private let window: NSWindow

    /// - Parameters:
    ///   - devices: what the presenter knows, in sidebar order.
    ///   - refresh: stands in for `UsageModel.refresh`, so appearing never
    ///     runs the providers' real commands. nil lets the hint refresh for
    ///     real — devices standing `.failed` or `.unknown` re-read too, so
    ///     tests pinning preloaded states pass a no-op instead.
    init(
        model: UsageModel,
        devices: [Device] = [],
        onSelect: @escaping (Device) -> Void = { _ in },
        refresh: UsageHintLine.Refresh? = nil
    ) throws {
        self.model = model
        self.onSelect = onSelect
        self.refresh = refresh
        root = NSHostingView(rootView: AnyView(Self.view(
            usage: model, devices: devices, onSelect: onSelect, refresh: refresh
        )))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "UsageHintHarness \(UUID().uuidString)" // AccessibilityProbe finds the window by title
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

    /// What VoiceOver reads, depth first; the window itself (named only for
    /// the probe's lookup) is not part of the hint.
    var labels: [String] {
        AccessibilityProbe.elements(in: window)
            .filter { $0.role != "AXWindow" }
            .compactMap(\.name)
    }

    /// Swaps the presented devices: `.task(id:)` refires on identity change,
    /// the way the sidebar's device set changing re-runs the hint's refresh.
    func setDevices(_ devices: [Device]) {
        root.rootView = AnyView(Self.view(
            usage: model, devices: devices, onSelect: onSelect, refresh: refresh
        ))
        root.layoutSubtreeIfNeeded()
        settle()
    }

    private static func view(
        usage: UsageModel,
        devices: [Device],
        onSelect: @escaping (Device) -> Void,
        refresh: UsageHintLine.Refresh?
    ) -> some View {
        UsageHintLine(usage: usage, devices: devices, onSelect: onSelect, refresh: refresh)
            .frame(width: 240)
    }

    /// The hint line's ideal height: zero when nothing renders.
    var fittingHeight: CGFloat { root.fittingSize.height }

    func pressHint(named name: String) throws {
        let button = try XCTUnwrap(
            AccessibilityProbe.elements(in: window).first {
                $0.role == "AXButton" && $0.name == name
            },
            "no hint button among: \(labels)"
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

/// The sidebar footer's usage hint: the tightest open window wins across
/// every device and provider, closed windows never show, nothing renders
/// without fresh readings, and a tap opens the Usage sheet on the window's
/// device in the severity colour the ruling pins.
@MainActor
final class UsageHintTests: XCTestCase {
    private var studio: Device {
        Device(id: UUID(), name: "Studio", kind: .ssh(target: "studio.example"))
    }

    private func window(_ group: String, left: Int, resetsIn: TimeInterval?) -> GrazrWindow {
        GrazrWindow(
            kind: "quota",
            group: group,
            remaining: left,
            resetsAt: resetsIn.map { Date().addingTimeInterval($0) }
        )
    }

    private func reading(_ provider: UsageProvider, windows: [GrazrWindow]) -> AgentUsageReading {
        AgentUsageReading(id: provider.rawValue, provider: provider, windows: windows, fetchedAt: Date())
    }

    func testTightestOpenWindowWinsAcrossDevicesAndProviders() throws {
        let studio = studio
        let model = UsageModel()
        model.preload(.local, [
            .claude: .readings([reading(.claude, windows: [
                window("session", left: 47, resetsIn: 2 * 3600),
                window("weekly", left: 1, resetsIn: -60), // closed: refilled, never the hint
            ])]),
        ])
        model.preload(studio, [
            .codex: .readings([reading(.codex, windows: [
                window("30d", left: 12, resetsIn: 3 * 86400),
            ])]),
        ])
        let harness = try UsageHintHarness(model: model, devices: [studio, .local])

        let hint = try XCTUnwrap(harness.labels.first { $0.contains("12%") }, "hint: \(harness.labels)")
        XCTAssertTrue(hint.contains("30d"), "the tightest window reads its label: \(hint)")
        XCTAssertFalse(
            harness.labels.contains { $0.contains("47%") },
            "only the tightest window shows: \(harness.labels)"
        )
        XCTAssertFalse(
            harness.labels.contains { $0.contains("1%") },
            "a closed window is refilled, never the hint: \(harness.labels)"
        )
    }

    func testHintExposesTheResetTime() throws {
        let resetsAt = Date().addingTimeInterval(2 * 3600)
        let model = UsageModel()
        model.preload(.local, [
            .codex: .readings([reading(.codex, windows: [
                GrazrWindow(kind: "quota", group: "30d", remaining: 42, resetsAt: resetsAt),
            ])]),
        ])
        let harness = try UsageHintHarness(model: model, devices: [.local])

        let expected = GrazrStyle.time(resetsAt, now: Date())
        let hint = try XCTUnwrap(harness.labels.first { $0.contains("42%") }, "\(harness.labels)")
        XCTAssertTrue(hint.contains(expected), "\(hint) should read the reset time \(expected)")
    }

    func testTapOpensTheUsageSheetOnTheTightestDevicesDevice() throws {
        let studio = studio
        let model = UsageModel()
        model.preload(.local, [
            .claude: .readings([reading(.claude, windows: [
                window("session", left: 47, resetsIn: 2 * 3600),
            ])]),
        ])
        model.preload(studio, [
            .codex: .readings([reading(.codex, windows: [
                window("30d", left: 12, resetsIn: 3 * 86400),
            ])]),
        ])
        // The sidebar's own wiring: the tap sets `model.usageDevice`, and the
        // sheet presents on that device.
        let app = AppModel()
        let harness = try UsageHintHarness(
            model: model, devices: [studio, .local],
            onSelect: { app.usageDevice = $0 }
        )

        let hint = try XCTUnwrap(harness.labels.first { $0.contains("12%") }, "\(harness.labels)")
        try harness.pressHint(named: hint)
        XCTAssertEqual(app.usageDevice, studio, "the tap opens the sheet on the tightest window's device")
    }

    func testRendersNothingWithoutFreshReadings() throws {
        let studio = studio
        let model = UsageModel()
        var reads: [(UUID, Bool)] = []
        let harness = try UsageHintHarness(
            model: model, devices: [studio, .local],
            refresh: { _, device, force in
                reads.append((device.id, force))
            }
        )
        harness.settle(seconds: 0.3)

        XCTAssertTrue(harness.labels.isEmpty, "no fresh readings, nothing renders: \(harness.labels)")
        XCTAssertEqual(harness.fittingHeight, 0, "frame zero content")
        XCTAssertEqual(
            Set(reads.map(\.0)),
            [Device.local.id, studio.id],
            "state-less devices get their first read: \(reads)"
        )
        XCTAssertEqual(reads.map(\.1), [false, false], "the first read is not forced: \(reads)")
    }

    /// Every window reset but reads attempted: the neutral `Usage` entry keeps
    /// the sheet one tap away — label only, no percentage or time — opening
    /// it on the local device.
    func testStatesWithoutOpenWindowRenderANeutralEntryThatOpensTheSheet() throws {
        let studio = studio
        let model = UsageModel()
        model.preload(.local, [.claude: .failed("offline")])
        model.preload(studio, [.codex: .readings([reading(.codex, windows: [
            window("30d", left: 1, resetsIn: -60), // closed: refilled
        ])])])
        let app = AppModel()
        let harness = try UsageHintHarness(
            model: model, devices: [studio, .local],
            onSelect: { app.usageDevice = $0 },
            refresh: { _, _, _ in } // preloaded states stand; no real re-read
        )

        let usage = String(localized: "Usage")
        XCTAssertEqual(harness.labels, [usage], "states but no open window: the neutral entry alone")
        XCTAssertGreaterThan(harness.fittingHeight, 0)
        try harness.pressHint(named: usage)
        XCTAssertEqual(app.usageDevice, .local, "the neutral entry opens the sheet on the local device")
    }

    /// Never-read devices render nothing at all — the sheet's entry appears
    /// only once a read has been attempted for a listed device.
    func testNoStatesAtAllRendersNothing() throws {
        let model = UsageModel()
        model.preload(.local, [.claude: .failed("offline")])
        let ghost = Device(id: UUID(), name: "Ghost", kind: .ssh(target: "ghost.example"))
        let harness = try UsageHintHarness(
            model: model, devices: [ghost],
            refresh: { _, _, _ in } // nothing ever read
        )

        XCTAssertTrue(harness.labels.isEmpty, "no listed device ever read: \(harness.labels)")
        XCTAssertEqual(harness.fittingHeight, 0)
    }

    /// A `.task` refire (device-set change) retries devices standing
    /// `.failed` or `.unknown` and reads newcomers, all non-forced; devices
    /// with fresh readings stand.
    func testTaskRefireReadsFailedUnknownAndNewDevicesNonForced() throws {
        let studio = studio
        let model = UsageModel()
        model.preload(studio, [
            .claude: .failed("offline"),
            .codex: .unknown, .gemini: .unknown, .opencode: .unknown,
        ])
        var reads: [(UUID, Bool)] = []
        let harness = try UsageHintHarness(
            model: model, devices: [studio],
            refresh: { _, device, force in reads.append((device.id, force)) }
        )
        harness.settle(seconds: 0.3)
        XCTAssertEqual(reads.map(\.0), [studio.id], "a failed provider re-reads on mount")
        XCTAssertTrue(reads.allSatisfy { $0.1 == false }, "the retry is not forced: \(reads)")

        let fresh = Device(id: UUID(), name: "Fresh", kind: .ssh(target: "fresh.example"))
        harness.setDevices([studio, fresh])
        harness.settle(seconds: 0.3)
        XCTAssertEqual(
            reads.map(\.0),
            [studio.id, studio.id, fresh.id],
            "the refire re-reads the failed device and reads the newcomer: \(reads)")
        XCTAssertEqual(
            reads.map(\.1),
            [false, false, false],
            "retries stay non-forced — the store's cache bounds the cost: \(reads)")
    }

    func testSeverityColorsFollowTheThresholdRuling() {
        XCTAssertEqual(UsageHintLine.severityColor(left: 14), Theme.danger)
        XCTAssertEqual(UsageHintLine.severityColor(left: 15), Theme.warning)
        XCTAssertEqual(UsageHintLine.severityColor(left: 24), Theme.warning)
        XCTAssertEqual(UsageHintLine.severityColor(left: 25), Theme.textSecondary)
    }

    func testTightestWindowHelperSkipsClosedUnknownDevicesAndNonReadings() throws {
        let studio = studio
        let ghost = Device(id: UUID(), name: "Ghost", kind: .ssh(target: "ghost.example"))
        let now = Date()
        let tightest = GrazrWindow(kind: "quota", group: "session", remaining: 3, resetsAt: now.addingTimeInterval(60))
        let closed = GrazrWindow(kind: "quota", group: "30d", remaining: 5, resetsAt: now.addingTimeInterval(-60))
        let model = UsageModel()
        model.preload(.local, [
            .claude: .failed("offline"), // not a fresh reading
            .codex: .readings([reading(.codex, windows: [closed])]), // closed: refilled
            .gemini: .readings([reading(.gemini, windows: [tightest])]),
        ])
        model.preload(studio, [
            .opencode: .readings([reading(.opencode, windows: [])]), // tokens only, no windows
        ])
        model.preload(ghost, [
            .gemini: .readings([reading(.gemini, windows: [
                GrazrWindow(kind: "quota", group: "session", remaining: 1, resetsAt: now.addingTimeInterval(60)),
            ])]),
        ])

        let pick = UsageHintLine.tightestOpenWindow(states: model.states, devices: [.local, studio], now: now)
        XCTAssertEqual(pick?.device, .local, "the ghost device cannot be opened on, so it is skipped")
        XCTAssertEqual(pick?.window, tightest, "the open window with the least left wins")
    }
}
