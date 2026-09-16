import AppKit
import SwiftUI
import XCTest
@testable import herdrm

/// End-to-end: scroll the AppKit clip view and assert the active section’s
/// global frame stays in the pin slot.
final class SidebarStickyE2ETests: XCTestCase {
    @MainActor
    func testProbeExposesSectionHeadersAndScrollSurface() throws {
        let frames = StickyProbeFrameStore()
        let root = NSHostingView(
            rootView: SidebarStickyProbeStack(
                rowCountPerSection: 30,
                terminalsVisible: true,
                frames: frames
            )
            .frame(width: 260, height: 360)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 360),
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

        let spacesY = try XCTUnwrap(frames.frames[SidebarSectionID.spaces.accessibilityIdentifier]?.minY)

        guard let scroll = findScroll(in: root) else {
            return XCTFail("missing scroll view")
        }

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_200))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump()

        let agentsY = try XCTUnwrap(frames.frames[SidebarSectionID.agents.accessibilityIdentifier]?.minY)
        XCTAssertEqual(
            agentsY,
            spacesY,
            accuracy: 4.0,
            "after takeover, Agents should sit in the same global pin slot"
        )
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
