import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Pins the production wiring of the sidebar's usage row: the REAL
/// SidebarView and a real AppModel with a selected shell, whose
/// `UsageModel` reads through a fake runner — no provider command runs on
/// the test machine. Settings go to a private defaults suite through
/// `.defaultAppStorage`, so the user's own View-menu choices stay as they
/// are and the app's own window never starts reading.
@MainActor
final class UsageColumnProductionTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "UsageColumnProductionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRowStaysUnmountedAndReadsNothingWhenOff() {
        let runner = FakeUsageRunner()
        let model = Self.modelWithSelectedShell(runner: runner)

        let labels = mountAndPump(model, seconds: 1)

        XCTAssertFalse(labels.contains { $0.hasPrefix("Agent usage:") },
                       "usage row rendered while off: \(labels.filter { $0.contains("usage") })")
        XCTAssertEqual(runner.asked, [], "reads ran while the row is off")
    }

    func testRowReadsThePickedAgentsOnTheSelectedDevice() {
        defaults.set(true, forKey: UsageDefaults.showKey)
        let runner = FakeUsageRunner()
        let model = Self.modelWithSelectedShell(runner: runner)

        let row = waitForRow(model) { $0.contains("Claude: 5-hour window 34% used") }

        XCTAssertNotNil(row, "usage row never showed claude's reading (statsDevice=\(String(describing: model.statsDevice?.name)))")
        let count = NumberFormatter.localizedString(from: 1_200_000, number: .decimal)
        XCTAssertTrue(row?.contains("OpenCode: \(count) tokens in the last 7 days") == true, row ?? "")
        XCTAssertEqual(Set(runner.asked), [.claude, .codex, .opencode], "default pick only, gemini never runs")
    }

    func testRowFollowsTheAgentPick() {
        defaults.set(true, forKey: UsageDefaults.showKey)
        defaults.set("claude", forKey: UsageDefaults.agentsKey)
        let runner = FakeUsageRunner()
        let model = Self.modelWithSelectedShell(runner: runner)

        let row = waitForRow(model) { $0.contains("Claude: 5-hour window 34% used") }

        XCTAssertNotNil(row)
        XCTAssertFalse(row?.contains("OpenCode") == true, row ?? "")
        XCTAssertEqual(Set(runner.asked), [.claude])
    }

    /// The app's real View menu offers the switch, off by default, and the
    /// agent pick beside it. Only reads the menu: nothing is turned on.
    func testViewMenuOffersTheSwitchOffByDefault() throws {
        let saved = UserDefaults.standard.object(forKey: UsageDefaults.showKey)
        defer { UserDefaults.standard.set(saved, forKey: UsageDefaults.showKey) }
        UserDefaults.standard.removeObject(forKey: UsageDefaults.showKey)

        let view = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu, "no View menu")
        view.delegate?.menuNeedsUpdate?(view)
        view.delegate?.menuWillOpen?(view)
        defer { view.delegate?.menuDidClose?(view) }
        let toggle = try XCTUnwrap(view.items.first { $0.title == "Show Agent Usage" }, "no View ▸ Show Agent Usage")
        XCTAssertEqual(toggle.state, .off)
        let picker = try XCTUnwrap(view.items.first { $0.title == "Agents in Usage Row" }, "no View ▸ Agents in Usage Row")
        XCTAssertNotNil(picker.submenu)
    }

    // MARK: - Helpers

    private static func modelWithSelectedShell(runner: FakeUsageRunner) -> AppModel {
        let model = AppModel()
        model.usage = UsageModel(store: runner.store())
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

    /// The row's spoken label once it satisfies `condition`, nil if it
    /// never does within the deadline.
    private func waitForRow(_ model: AppModel, _ condition: (String) -> Bool) -> String? {
        let deadline = Date().addingTimeInterval(10)
        var last: String?
        while Date() < deadline {
            last = mountAndPump(model, seconds: 0.5).first { $0.hasPrefix("Agent usage:") }
            if let last, condition(last) { return last }
        }
        XCTFail("row label: \(last ?? "none")")
        return nil
    }

    /// Mounts the real sidebar in a window, pumps the run loop, and
    /// returns the accessibility labels a VoiceOver user would hear.
    private func mountAndPump(_ model: AppModel, seconds: TimeInterval) -> [String] {
        let sidebar = SidebarView(model: model, collapsed: .constant(false), width: 260)
            .frame(width: 260, height: 600)
            .defaultAppStorage(defaults)
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
