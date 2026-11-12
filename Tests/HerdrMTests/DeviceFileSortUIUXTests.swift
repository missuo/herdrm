import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

@MainActor
final class DeviceFileSortUIUXTests: XCTestCase {
    func testColumnClicksReverseTheOrderAndAnnounceTheDirection() async throws {
        let files = try await DeviceFilesHarness()
        XCTAssertEqual(files.left.entries.map(\.name), ["test-folder", "test1.txt", "test2.txt", "test10.txt"])
        XCTAssertEqual(try files.heading("Name").value, String(localized: "Ascending"))

        try files.click("Modified")
        XCTAssertEqual(files.left.entries.map(\.name), ["test-folder", "test10.txt", "test1.txt", "test2.txt"])
        XCTAssertEqual(try files.heading("Modified").value, String(localized: "Descending"))
        XCTAssertEqual(try files.heading("Name").value, String(localized: "Not sorted"))
        try files.click("Modified")
        XCTAssertEqual(files.left.entries.map(\.name), ["test-folder", "test2.txt", "test1.txt", "test10.txt"])
        XCTAssertEqual(try files.heading("Modified").value, String(localized: "Ascending"))

        try files.click("Size")
        XCTAssertEqual(files.left.entries.map(\.name), ["test-folder", "test2.txt", "test1.txt", "test10.txt"])
        try files.click("Size")
        XCTAssertEqual(files.left.entries.map(\.name), ["test-folder", "test10.txt", "test1.txt", "test2.txt"])

        try files.click("Name")
        XCTAssertEqual(files.left.entries.map(\.name), ["test-folder", "test1.txt", "test2.txt", "test10.txt"])
        try files.click("Name")
        XCTAssertEqual(files.left.entries.map(\.name), ["test-folder", "test10.txt", "test2.txt", "test1.txt"])
        XCTAssertEqual(try files.heading("Name").value, String(localized: "Descending"))
    }

    func testPanesSortIndependentlyAndKeepTheirOrderAndSelectionOnRefresh() async throws {
        let files = try await DeviceFilesHarness()
        files.left.selectedPaths = [try XCTUnwrap(files.left.entries.first { $0.name == "test1.txt" }).path]
        try files.click("Modified")
        try files.click("Size", pane: 1)
        try files.click("Size", pane: 1)
        XCTAssertEqual(try files.heading("Modified").value, String(localized: "Descending"))
        XCTAssertEqual(try files.heading("Size", pane: 1).value, String(localized: "Ascending"))

        try files.write("test3.txt", size: 150, date: 1_800_000_000)
        await files.left.refresh()
        await files.right.refresh()
        XCTAssertEqual(files.left.entries.map(\.name), ["test-folder", "test3.txt", "test10.txt", "test1.txt", "test2.txt"])
        XCTAssertEqual(files.right.entries.map(\.name), ["test-folder", "test10.txt", "test3.txt", "test1.txt", "test2.txt"])
        XCTAssertEqual(files.left.selectedEntries.first?.name, "test1.txt")

        await files.left.navigate(to: files.directory.appendingPathComponent("test-folder").path)
        await files.left.navigate(to: files.directory.path)
        XCTAssertEqual(files.left.entries.map(\.name), ["test-folder", "test3.txt", "test10.txt", "test1.txt", "test2.txt"])
        XCTAssertEqual(files.right.entries.map(\.name), ["test-folder", "test10.txt", "test3.txt", "test1.txt", "test2.txt"])
    }
}

/// Like SidebarHarness, hosts real views with fake files and routes mouse
/// events through AppKit hit-testing. No server or SSH connection is needed.
@MainActor
final class DeviceFilesHarness {
    let left = DeviceFileBrowserModel()
    let right = DeviceFileBrowserModel()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdrm-files-\(UUID().uuidString)")
    private let window: NSWindow

    init() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 360),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("test-folder"), withIntermediateDirectories: true)
        try write("test1.txt", size: 200, date: 1_700_000_000)
        try write("test2.txt", size: 300, date: 1_600_000_000)
        try write("test10.txt", size: 100, date: 1_750_000_000)
        await left.navigate(to: directory.path)
        await right.navigate(to: directory.path)
        XCTAssertNil(left.error)
        XCTAssertNil(right.error)
        let view = HStack(spacing: 1) {
            DeviceFilePane(title: "test1", device: .local, browser: left)
            DeviceFilePane(title: "test2", device: .local, browser: right)
        }
        window.contentView = NSHostingView(rootView: view)
        window.title = "DeviceFilesHarness \(UUID().uuidString)"
        window.orderFrontRegardless()
        settle()
    }

    deinit {
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func write(_ name: String, size: Int, date: TimeInterval) throws {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0, count: size).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: url.path)
    }

    func heading(_ name: String.LocalizationValue, pane: Int = 0) throws -> AccessibilityProbe.Element {
        settle()
        let buttons = AccessibilityProbe.elements(in: window).filter {
            $0.role == "AXButton" && $0.name == String(localized: name) && $0.frame != nil
        }.sorted { $0.frame!.minX < $1.frame!.minX }
        XCTAssertEqual(buttons.count, 2, "each pane needs its own \(name) button")
        return try XCTUnwrap(buttons.indices.contains(pane) ? buttons[pane] : nil)
    }

    func click(_ name: String.LocalizationValue, pane: Int = 0) throws {
        let rect = try XCTUnwrap(heading(name, pane: pane).frame)
        try click(rect, modifiers: [])
    }

    var visibleText: [String] {
        settle()
        return AccessibilityProbe.elements(in: window).compactMap { $0.value ?? $0.name }
    }

    func clickFile(_ name: String, pane: Int = 0, modifiers: NSEvent.ModifierFlags = []) throws {
        let matches = AccessibilityProbe.elements(in: window).filter {
            ($0.role == "AXStaticText" && $0.value == name)
                || ($0.role == "AXButton" && ($0.name == name || $0.name?.hasPrefix(name + ",") == true))
        }.sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
        let element = try XCTUnwrap(matches.indices.contains(pane) ? matches[pane] : nil)
        try click(XCTUnwrap(element.frame), modifiers: modifiers)
    }

    func selectAll() throws {
        XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(#selector(NSText.selectAll(_:)), with: nil))
        settle()
    }

    private func click(_ rect: CGRect, modifiers: NSEvent.ModifierFlags) throws {
        let screenTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: screenTop - rect.midY))
        let content = try XCTUnwrap(window.contentView)
        _ = try XCTUnwrap(content.hitTest(content.superview?.convert(point, from: nil) ?? point))
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Native lists track mouse-up synchronously inside mouseDown.
        // Queue it first so real hit-testing can run without hanging the test.
        NSApp.postEvent(up, atStart: true)
        // AppKit's list selection reads the current event's modifiers.
        window.makeKey()
        NSApp.sendEvent(down)
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(release)
        }
        settle()
    }

    private func settle() {
        let end = Date().addingTimeInterval(0.2)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
}
