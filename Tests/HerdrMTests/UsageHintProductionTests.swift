import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Pins the production wiring of the sidebar's usage hint: the REAL
/// SidebarView, a real AppModel with a selected shell (so the stats block
/// renders), and the hint's real `.task` → `UsageModel.refresh` →
/// `UsageStore.shared` → device commands — no spies, no preloads. Guards
/// the regression where the task anchored to a transparent empty Group and
/// never fired, so the hint rendered nothing forever.
@MainActor
final class UsageHintProductionTests: XCTestCase {
    func testRealSidebarMountsTheUsageRow() throws {
        // Real model: DeviceStore.load() + the local device.
        let model = AppModel()
        if !model.devices.contains(where: \.isLocal) {
            model.devices.append(.local)
        }
        let local = try XCTUnwrap(model.devices.first(where: \.isLocal), "no local device")

        // A selected shell makes statsDevice non-nil so the stats block
        // (hint + machine stats) renders — the user's situation.
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
        window.title = "UsageHintProductionTests \(UUID().uuidString)"
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        defer { window.close() }

        // Pump while the real device commands run; the row appears as soon
        // as the first read seeds, long before the commands finish.
        let deadline = Date().addingTimeInterval(20)
        var labels: [String] = []
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            labels = AccessibilityProbe.elements(in: window)
                .filter { $0.role != "AXWindow" }
                .compactMap(\.name)
            let machineStatsVisible = labels.contains { $0.contains("CPU") || $0.contains("RAM") }
            let usageRow = labels.contains {
                $0 == "Usage" || $0.contains("Usage across your devices") || $0.contains("% · ")
            }
            if machineStatsVisible, usageRow { break }
        }

        XCTAssertTrue(
            labels.contains {
                $0 == "Usage" || $0.contains("Usage across your devices") || $0.contains("% · ")
            },
            "usage row never appeared in the real sidebar (statsDevice=\(String(describing: model.statsDevice?.name)), devices=\(model.devices.map(\.name)))"
        )
    }
}
