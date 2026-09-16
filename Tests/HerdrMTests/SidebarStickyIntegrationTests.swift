import AppKit
import SwiftUI
import XCTest
@testable import herdrm

/// Hosts `SidebarStickyProbeStack` and asserts pinned header global frames
/// stay stable (and hand off) while the AppKit clip view scrolls.
final class SidebarStickyIntegrationTests: XCTestCase {
    @MainActor
    func testSpacesHeaderStaysPinnedWhileScrollingItsBody() throws {
        let frames = StickyProbeFrameStore()
        let host = StickyProbeHost(frames: frames, rowCountPerSection: 40, terminalsVisible: true)
        let window = try host.makeWindow()
        defer { window.close() }

        let scrollView = try host.scrollView(in: window)
        let id = SidebarSectionID.spaces.accessibilityIdentifier
        let topBefore = try XCTUnwrap(frames.frames[id]?.minY)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        host.pump()

        let topAfter = try XCTUnwrap(frames.frames[id]?.minY)
        XCTAssertEqual(
            topAfter,
            topBefore,
            accuracy: 3.0,
            "spaces header must stay pinned while its body scrolls"
        )
    }

    @MainActor
    func testAgentsHeaderReplacesSpacesAfterTakeover() throws {
        let frames = StickyProbeFrameStore()
        let host = StickyProbeHost(frames: frames, rowCountPerSection: 40, terminalsVisible: true)
        let window = try host.makeWindow()
        defer { window.close() }

        let scrollView = try host.scrollView(in: window)
        let spacesBefore = try XCTUnwrap(frames.frames[SidebarSectionID.spaces.accessibilityIdentifier]?.minY)

        let spacesBody = CGFloat(host.rowCountPerSection) * 32
        let pastSpaces =
            SidebarStickyLayout.headerHeight
            + spacesBody
            + SidebarStickyLayout.interSectionGap
            + 40
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: pastSpaces))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        host.pump()

        let agentsY = try XCTUnwrap(frames.frames[SidebarSectionID.agents.accessibilityIdentifier]?.minY)
        XCTAssertEqual(
            agentsY,
            spacesBefore,
            accuracy: 4.0,
            "agents header should occupy the same pin slot Spaces held at rest"
        )
    }
}

@MainActor
private struct StickyProbeHost {
    let frames: StickyProbeFrameStore
    let rowCountPerSection: Int
    let terminalsVisible: Bool

    func makeWindow() throws -> NSWindow {
        let root = NSHostingView(
            rootView: SidebarStickyProbeStack(
                rowCountPerSection: rowCountPerSection,
                terminalsVisible: terminalsVisible,
                frames: frames
            )
            .frame(width: 260, height: 480)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        pump()
        return window
    }

    func scrollView(in window: NSWindow) throws -> NSScrollView {
        guard let scroll = firstDescendant(of: window.contentView, as: NSScrollView.self) else {
            throw StickyProbeError.missingScrollView
        }
        return scroll
    }

    func pump() {
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            NSApp.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
    }
}

private enum StickyProbeError: Error {
    case missingScrollView
}

@MainActor
private func firstDescendant<T: NSView>(of root: NSView?, as type: T.Type) -> T? {
    guard let root else { return nil }
    if let match = root as? T { return match }
    for child in root.subviews {
        if let found = firstDescendant(of: child, as: type) { return found }
    }
    return nil
}
