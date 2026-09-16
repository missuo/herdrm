import AppKit
import SwiftUI
import XCTest
@testable import herdrm

/// Visual/geometry: pinned header global frame stays put across a mid-section scroll.
final class SidebarStickyVisualTests: XCTestCase {
    @MainActor
    func testPinnedHeaderBandStableAcrossScroll() throws {
        let frames = StickyProbeFrameStore()
        let root = NSHostingView(
            rootView: SidebarStickyProbeStack(
                rowCountPerSection: 50,
                terminalsVisible: false,
                frames: frames
            )
            .frame(width: 260, height: 420)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        pump()
        defer { window.close() }

        let id = SidebarSectionID.spaces.accessibilityIdentifier
        let before = try XCTUnwrap(frames.frames[id])

        guard let scroll = findScroll(in: root) else {
            return XCTFail("expected NSScrollView")
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 220))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump()

        let after = try XCTUnwrap(frames.frames[id])
        XCTAssertEqual(before.minY, after.minY, accuracy: 3.0, "pinned header global Y must not drift")
        XCTAssertEqual(before.height, after.height, accuracy: 0.5)
        XCTAssertEqual(before.width, after.width, accuracy: 1.0)
    }
}

@MainActor
private func pump() {
    for _ in 0..<4 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

@MainActor
private func findScroll(in root: NSView) -> NSScrollView? {
    if let scroll = root as? NSScrollView { return scroll }
    for child in root.subviews {
        if let found = findScroll(in: child) { return found }
    }
    return nil
}
