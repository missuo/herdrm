import AppKit
import Foundation
import XCTest
@testable import herdrm

/// The CPU / RAM / DISK meters in the sidebar footer can be turned off. Off
/// means gone from the sidebar and no sampler running for them, not just hidden.
@MainActor
final class SidebarMachineStatsToggleUIUXTests: XCTestCase {
    private var savedSetting: Any?

    override func setUp() async throws {
        savedSetting = UserDefaults.standard.object(forKey: MachineStatsDefaults.showKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedSetting, forKey: MachineStatsDefaults.showKey)
    }

    func testMetersShowAndSampleByDefault() throws {
        UserDefaults.standard.removeObject(forKey: MachineStatsDefaults.showKey)
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        sidebar.selectFirstAgent()
        XCTAssertTrue(sidebar.showsMachineStats, "known-yes: meters on screen")
        XCTAssertTrue(waitFor { Self.samplerRunning }, "known-yes: a sampler is running for them")
    }

    func testTurnedOffMetersLeaveTheSidebarAndStopSampling() throws {
        UserDefaults.standard.removeObject(forKey: MachineStatsDefaults.showKey)
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        sidebar.selectFirstAgent()
        XCTAssertTrue(waitFor { Self.samplerRunning })

        UserDefaults.standard.set(false, forKey: MachineStatsDefaults.showKey)
        XCTAssertTrue(waitFor { !sidebar.showsMachineStats }, "meters still on screen")
        XCTAssertTrue(waitFor { !Self.samplerRunning }, "sampler still running")

        UserDefaults.standard.set(true, forKey: MachineStatsDefaults.showKey)
        XCTAssertTrue(waitFor { sidebar.showsMachineStats }, "meters did not come back")
        XCTAssertTrue(waitFor { Self.samplerRunning }, "sampler did not restart")
    }

    func testHidingClosesAnOpenDetailsPanel() throws {
        UserDefaults.standard.removeObject(forKey: MachineStatsDefaults.showKey)
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        sidebar.selectFirstAgent()
        sidebar.model.showMachineStats = true

        UserDefaults.standard.set(false, forKey: MachineStatsDefaults.showKey)
        XCTAssertTrue(waitFor { !sidebar.model.showMachineStats }, "panel left open with no meters to close it")
    }

    /// The app's real View menu item: its checkmark follows the setting, and
    /// choosing it hides the meters, then brings them back.
    func testViewMenuItemTogglesTheMeters() throws {
        UserDefaults.standard.removeObject(forKey: MachineStatsDefaults.showKey)
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        sidebar.selectFirstAgent()
        XCTAssertTrue(sidebar.showsMachineStats, "known-yes: meters on screen")
        XCTAssertEqual(try Self.openViewMenuItem("Show Machine Stats").state, .on)

        try Self.chooseViewMenuItem("Show Machine Stats")
        XCTAssertTrue(waitFor { !sidebar.showsMachineStats }, "meters still on screen")
        XCTAssertEqual(try Self.openViewMenuItem("Show Machine Stats").state, .off)

        try Self.chooseViewMenuItem("Show Machine Stats")
        XCTAssertTrue(waitFor { sidebar.showsMachineStats }, "meters did not come back")
        XCTAssertEqual(try Self.openViewMenuItem("Show Machine Stats").state, .on)
    }

    // MARK: - Helpers

    /// The app's View menu item `title`, as it reads once the menu opens:
    /// SwiftUI fills in checkmarks when its menu delegate hears the menu open.
    private static func openViewMenuItem(_ title: String) throws -> NSMenuItem {
        let view = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu, "no View menu")
        view.delegate?.menuNeedsUpdate?(view)
        view.delegate?.menuWillOpen?(view)
        defer { view.delegate?.menuDidClose?(view) }
        return try XCTUnwrap(view.items.first { $0.title == title }, "no View ▸ \(title)")
    }

    /// Choose View ▸ `title`, as a click on it does.
    private static func chooseViewMenuItem(_ title: String) throws {
        let item = try openViewMenuItem(title)
        let menu = try XCTUnwrap(item.menu)
        menu.performActionForItem(at: menu.index(of: item))
    }

    /// A local `herdrm-stats` sampler started by this test process.
    private static var samplerRunning: Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(ProcessInfo.processInfo.processIdentifier), "-f", "herdrm-stats"]
        pgrep.standardOutput = Pipe()
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    private func waitFor(seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
