import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

@MainActor
final class DeviceFilePathUIUXTests: XCTestCase {
    func testDelayedDirectoryReplyPreservesTheEditedPathField() async throws {
        let requests = HeldDeviceDirectoryRequests()
        let browser = DeviceFileBrowserModel(listDirectory: requests.list)
        browser.pathText = "/test1"
        let initial = Task { await browser.navigate(to: browser.pathText) }
        try await requests.waitForCount(1)
        requests.finish(0, path: "/test1")
        await initial.value

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DeviceFilePathUIUXTests \(UUID().uuidString)"
        window.contentView = NSHostingView(rootView: DeviceFilePane(
            title: "test1", device: .local, browser: browser))
        window.orderFrontRegardless()
        defer { window.close() }
        await settle(window)

        let loading = Task { await browser.refresh() }
        try await requests.waitForCount(2)
        let field = try pathField(in: window)
        try click(try XCTUnwrap(field.frame), in: window)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("/test2/edited-path", replacementRange: editor.selectedRange())
        await settle(window)
        XCTAssertEqual(browser.pathText, "/test2/edited-path")

        requests.finish(1, path: "/test1")
        await loading.value
        await settle(window)
        XCTAssertEqual(browser.pathText, "/test2/edited-path")
        XCTAssertEqual(try pathField(in: window).value, "/test2/edited-path")
        XCTAssertEqual(browser.currentPath, "/test1")
    }

    private func pathField(in window: NSWindow) throws -> AccessibilityProbe.Element {
        let fields = AccessibilityProbe.elements(in: window).filter { $0.role == "AXTextField" }
        XCTAssertEqual(fields.count, 1, "The isolated file pane has one path field")
        return try XCTUnwrap(fields.first)
    }

    private func click(_ rect: CGRect, in window: NSWindow) throws {
        let screenTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: screenTop - rect.midY))
        let content = try XCTUnwrap(window.contentView)
        _ = try XCTUnwrap(content.hitTest(content.superview?.convert(point, from: nil) ?? point))
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // NSTextField tracks the release inside mouseDown; use real hit-testing.
        NSApp.postEvent(up, atStart: true)
        window.makeKey()
        NSApp.sendEvent(down)
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(release)
        }
    }

    private func settle(_ window: NSWindow) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let end = Date().addingTimeInterval(0.2)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
}
