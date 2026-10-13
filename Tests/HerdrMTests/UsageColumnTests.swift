import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Hosts the real `SidebarMachineStats` and answers what a user would see,
/// the way VoiceOver reads it — the `UsageSheetHarness` conventions, sized
/// for the sidebar footer's stats row. All rendering mechanics live here so
/// tests read as specs.
@MainActor
private final class UsageColumnHarness {
    private let root: NSHostingView<AnyView>
    private let window: NSWindow

    /// - Parameters:
    ///   - usagePercent: the USAGE column's reading, nil while nothing has
    ///     been read.
    ///   - onUsageTap: what the sidebar wires to the column's tap.
    init(usagePercent: Double?, onUsageTap: @escaping () -> Void = {}) throws {
        let device = Device(id: UUID(), name: "Studio", kind: .ssh(target: "studio.example"))
        let view = SidebarMachineStats(
            stats: MachineStatsModel(),
            device: device,
            isOpen: false,
            usagePercent: usagePercent,
            onUsageTap: onUsageTap
        ) {}
        .frame(width: 240)
        root = NSHostingView(rootView: AnyView(view))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "UsageColumnHarness \(UUID().uuidString)" // AccessibilityProbe finds the window by title
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
    /// the probe's lookup) is not part of the row.
    var labels: [String] {
        AccessibilityProbe.elements(in: window)
            .filter { $0.role != "AXWindow" }
            .compactMap(\.name)
    }

    /// Presses the USAGE column — the nested button inside the stats row,
    /// not the row itself.
    func pressUsageColumn() throws {
        let button = try XCTUnwrap(
            AccessibilityProbe.elements(in: window).first {
                $0.role == "AXButton" && $0.name?.contains("USAGE") == true
            },
            "no USAGE button among: \(labels)"
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

/// The stats row's USAGE meter column: a fourth meter that renders even
/// before anything is read (dimmed dash), taps through to the Usage sheet
/// instead of the machine panel, and the refresh discipline round one's
/// hint carried — first read for state-less devices, non-forced retries for
/// failed or unknown ones.
@MainActor
final class UsageColumnTests: XCTestCase {
    private var studio: Device {
        Device(id: UUID(), name: "Studio", kind: .ssh(target: "studio.example"))
    }

    private func reading(_ provider: UsageProvider, windows: [GrazrWindow]) -> AgentUsageReading {
        AgentUsageReading(id: provider.rawValue, provider: provider, windows: windows, fetchedAt: Date())
    }

    func testStatsRowRendersAUsageMeterColumn() throws {
        let harness = try UsageColumnHarness(usagePercent: 88)

        XCTAssertTrue(harness.labels.contains { $0.contains("USAGE") }, "no USAGE column: \(harness.labels)")
        XCTAssertTrue(harness.labels.contains { $0.contains("88%") }, "the percent used reads: \(harness.labels)")
    }

    /// Nothing read yet: the column stays, its dash dimmed — and it stays
    /// tappable, keeping the sheet one tap away.
    func testNoReadingsShowsADimmedDashThatStillOpens() throws {
        var taps = 0
        let harness = try UsageColumnHarness(usagePercent: nil, onUsageTap: { taps += 1 })

        XCTAssertTrue(
            harness.labels.contains { $0.contains("USAGE") && $0.contains("—") },
            "the dimmed dash column: \(harness.labels)"
        )
        try harness.pressUsageColumn()
        XCTAssertEqual(taps, 1, "the dash column still taps through to the sheet")
    }

    /// The production wiring: through the real SidebarView, pressing the
    /// USAGE column opens the Usage sheet on a device — never the machine
    /// panel the rest of the row toggles.
    func testTappingTheColumnOpensTheUsageSheetNotMachineStats() throws {
        let model = AppModel()
        if !model.devices.contains(where: \.isLocal) {
            model.devices.append(.local)
        }
        let local = try XCTUnwrap(model.devices.first(where: \.isLocal), "no local device")
        model.newShellSession(on: local)
        let shell = try XCTUnwrap(model.shellSessions.last, "no shell session")
        model.selectShell(shell.id)
        XCTAssertNotNil(model.statsDevice, "stats block not visible at all")

        let sidebar = SidebarView(model: model, collapsed: .constant(false), width: 260)
            .frame(width: 260, height: 600)
        let root = NSHostingView(rootView: AnyView(sidebar))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "UsageColumnTap \(UUID().uuidString)"
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        defer { window.close() }

        let settle: (TimeInterval) -> Void = { seconds in
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            }
        }
        settle(0.5)
        let usageButton = try XCTUnwrap(
            AccessibilityProbe.elements(in: window).first {
                $0.role == "AXButton" && $0.name?.contains("USAGE") == true
            },
            "no USAGE button in the real sidebar"
        )
        AccessibilityProbe.press(usageButton)
        settle(0.3)

        XCTAssertEqual(model.usageDevice, local, "the tap opens the Usage sheet on the local device")
        XCTAssertFalse(model.showMachineStats, "the USAGE column never opens the machine panel")
    }

    /// The sheet header's watched-model picker: "All models" plus every
    /// scope the current readings carry, persisting straight to the
    /// sidebar's AppStorage key.
    func testWatchedModelPickerListsScopesAndPersists() throws {
        let key = "usage.sidebarWatchedModel"
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let now = Date()
        let model = UsageModel()
        model.preload(.local, [
            .claude: .readings([reading(.claude, windows: [
                GrazrWindow(kind: "quota", group: "weekly", remaining: 87, resetsAt: now.addingTimeInterval(3 * 86400)),
                GrazrWindow(kind: "quota", scope: "Fable", group: "weekly", remaining: 42, resetsAt: now.addingTimeInterval(3 * 86400)),
            ])]),
        ])
        let view = UsageView(model: model, anchor: .local, devices: [.local], refresh: { _, _, _ in })
            .frame(width: 520, height: 420)
        let root = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "UsageColumnPicker \(UUID().uuidString)"
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        defer { window.close() }

        let end = Date().addingTimeInterval(0.5)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
        let labels = AccessibilityProbe.elements(in: window).compactMap(\.name)
        XCTAssertTrue(labels.contains(String(localized: "All models")), "the picker's all-models entry: \(labels)")
        XCTAssertTrue(labels.contains("Fable"), "every reading scope is listed: \(labels)")

        let fable = try XCTUnwrap(
            AccessibilityProbe.elements(in: window).first { $0.name == "Fable" },
            "no Fable segment among: \(labels)"
        )
        AccessibilityProbe.press(fable)
        let settleEnd = Date().addingTimeInterval(0.5)
        while Date() < settleEnd {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
        XCTAssertEqual(
            defaults.string(forKey: key), "Fable",
            "the pick persists to the sidebar's watched-model key"
        )
    }

    /// Round one's refresh discipline, kept: devices standing `.failed` or
    /// `.unknown` re-read, never-read devices get their first read, fresh
    /// readings stand — all non-forced, so the store's cache bounds the
    /// cost. The stats block's `.task` runs this on mount and on every
    /// device-set change.
    func testRefreshReadsFailedUnknownAndNewcomersNonForced() async throws {
        let studio = studio
        let fresh = Device(id: UUID(), name: "Fresh", kind: .ssh(target: "fresh.example"))
        let states: [UUID: [UsageProvider: UsageProviderState]] = [
            studio.id: [
                .claude: .failed("offline"),
                .codex: .unknown, .gemini: .unknown, .opencode: .unknown,
            ],
            Device.local.id: [
                .claude: .readings([reading(.claude, windows: [])]),
            ],
        ]
        var reads: [(UUID, Bool)] = []
        await SidebarView.refreshUsageReads(
            states: states, devices: [studio, .local]
        ) { device, force in
            reads.append((device.id, force))
        }
        XCTAssertEqual(
            reads.map(\.0), [studio.id],
            "the failed device re-reads; fresh readings stand: \(reads)")
        XCTAssertTrue(reads.allSatisfy { !$0.1 }, "the retry is not forced: \(reads)")

        // The refire on a device-set change also reads the newcomer.
        reads.removeAll()
        await SidebarView.refreshUsageReads(
            states: states, devices: [studio, .local, fresh]
        ) { device, force in
            reads.append((device.id, force))
        }
        XCTAssertEqual(
            reads.map(\.0), [studio.id, fresh.id],
            "the refire re-reads the failed device and reads the newcomer: \(reads)")
        XCTAssertTrue(
            reads.allSatisfy { !$0.1 },
            "every refresh stays non-forced — the store's cache bounds the cost: \(reads)")
    }
}
