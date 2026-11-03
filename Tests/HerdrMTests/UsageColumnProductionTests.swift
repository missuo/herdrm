import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Pins the production wiring of the sidebar's usage row: the REAL
/// SidebarView, a real AppModel with a selected shell, and the row's real
/// `.task` → `UsageModel.refresh` → `UsageStore.shared` → device commands
/// — no spies, no preloads. The row is opt-in (off by default), so the
/// tests turn the setting on first and check it stays gone without it.
/// Keeps the `600ce7d` lesson honest too: the refresh task anchors to a
/// view that renders while a pane is selected, because a task on a view
/// that never renders never fires.
@MainActor
final class UsageColumnProductionTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: UsageDefaults.showKey)
        super.tearDown()
    }

    func testRowStaysUnmountedWhenOptedInOut() throws {
        UserDefaults.standard.removeObject(forKey: UsageDefaults.showKey)
        let model = Self.modelWithSelectedShell()
        var labels = Self.mountAndPump(model, seconds: 2)
        XCTAssertFalse(labels.contains { $0.contains("Usage:") },
                       "usage row rendered while the opt-in is off: \(labels.filter { $0.contains("Usage") })")
    }

    func testRealSidebarMountsTheUsageRowWhenOptedIn() throws {
        UserDefaults.standard.set(true, forKey: UsageDefaults.showKey)
        let model = Self.modelWithSelectedShell()
        let deadline = Date().addingTimeInterval(20)
        var labels: [String] = []
        while Date() < deadline {
            labels = Self.mountAndPump(model, seconds: 0.5)
            if labels.contains(where: { $0.contains("Usage:") }) { break }
        }

        XCTAssertTrue(
            labels.contains { $0.contains("Usage:") },
            "usage row never appeared in the real sidebar (statsDevice=\(String(describing: model.statsDevice?.name)), devices=\(model.devices.map(\.name)))"
        )
    }

    // MARK: - Helpers

    private static func modelWithSelectedShell() -> AppModel {
        let model = AppModel()
        if !model.devices.contains(where: \.isLocal) {
            model.devices.append(.local)
        }
        guard let local = model.devices.first(where: \.isLocal) else {
            fatalError("no local device")
        }
        // A selected shell makes statsDevice non-nil so the footer block
        // renders — the user's situation.
        model.newShellSession(on: local)
        guard let shell = model.shellSessions.last else { fatalError("no shell session") }
        model.selectShell(shell.id)
        return model
    }

    /// Mounts the real sidebar in a window, pumps the run loop, and
    /// returns the accessibility labels a VoiceOver user would see.
    private static func mountAndPump(_ model: AppModel, seconds: TimeInterval) -> [String] {
        let sidebar = SidebarView(model: model, collapsed: .constant(false), width: 260)
            .frame(width: 260, height: 600)
        let root = NSHostingView(rootView: AnyView(sidebar))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "UsageColumnProductionTests \(UUID().uuidString)"
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        defer { window.close() }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
        return AccessibilityProbe.elements(in: window)
            .filter { $0.role != "AXWindow" }
            .compactMap(\.name)
    }
}
