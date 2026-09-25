import AppKit
import SwiftUI
import XCTest
@testable import herdrm

/// The sidebar can be made wider or narrower by dragging the line between it
/// and the terminal, so long Space / Agent names are readable.
@MainActor
final class SidebarResizeUIUXTests: XCTestCase {
    // MARK: - Sidebar content

    func testSidebarFillsTheWidthItIsGiven() throws {
        let narrow = try SidebarHarness(spaces: 14, agents: 20, width: 260)
        let wide = try SidebarHarness(spaces: 14, agents: 20, width: 400)
        XCTAssertEqual(narrow.listWidth, 260, accuracy: 1)
        XCTAssertEqual(wide.listWidth, 400, accuracy: 1)
    }

    // MARK: - Dragging

    func testDraggingTheDividerChangesTheWidth() throws {
        let split = try SplitHarness()
        split.drag(by: 100)
        XCTAssertEqual(split.width, 360, accuracy: 1)
        XCTAssertEqual(split.detailMinX, 361, accuracy: 1, "detail starts after sidebar + 1pt line")
        split.drag(by: -60)
        XCTAssertEqual(split.width, 300, accuracy: 1)
    }

    /// AppKit can coalesce the last drag into the release; the release point counts.
    func testReleasePointCountsEvenWithoutAFinalDrag() throws {
        let split = try SplitHarness()
        split.drag(by: 100, lastDragAt: 0.5)
        XCTAssertEqual(split.width, 360, accuracy: 1)
    }

    func testDraggingStopsAtTheLimits() throws {
        let split = try SplitHarness()
        split.drag(by: 2000)
        XCTAssertEqual(split.width, SidebarWidth.range.upperBound, accuracy: 1)
        split.drag(by: -2000)
        XCTAssertEqual(split.width, SidebarWidth.range.lowerBound, accuracy: 1)
    }

    func testDoubleClickResetsToDefault() throws {
        let split = try SplitHarness(storedWidth: 420)
        split.doubleClick()
        XCTAssertEqual(split.width, SidebarWidth.defaultWidth, accuracy: 1)
    }

    /// The grab area straddles the line, so part of it lies over the terminal,
    /// which is an NSView that takes clicks itself. A press there must still resize.
    func testPressingJustInsideTheTerminalStillResizes() throws {
        let split = try SplitHarness()
        split.drag(by: 40, fromX: 263)
        XCTAssertEqual(split.width, 300, accuracy: 1)
        XCTAssertEqual(split.detailMouseDowns, 0, "the terminal did not see the press")
    }

    // MARK: - Remembering the width

    func testTheNextWindowOpensAtTheDraggedWidth() throws {
        let store = SplitHarness.freshStore()
        try SplitHarness(store: store).drag(by: 100)
        let next = try SplitHarness(store: store)
        XCTAssertEqual(next.detailMinX, 361, accuracy: 1)
    }

    func testStoredWidthOutsideTheLimitsIsClamped() throws {
        XCTAssertEqual(SidebarWidth.clamp(10), SidebarWidth.range.lowerBound)
        XCTAssertEqual(SidebarWidth.clamp(5000), SidebarWidth.range.upperBound)
        XCTAssertEqual(SidebarWidth.clamp(333), 333)
        let split = try SplitHarness(storedWidth: 5000)
        XCTAssertEqual(split.detailMinX, SidebarWidth.range.upperBound + 1, accuracy: 1)
    }

    // MARK: - The terminal survives

    /// Rebuilding the terminal's NSView kills its attach process and re-attaches
    /// with --takeover (see SplitContainer). Resizing and collapsing must not.
    func testResizingAndCollapsingKeepTheSameTerminalView() throws {
        let split = try SplitHarness()
        XCTAssertEqual(split.detailViewsMade, 1)
        split.drag(by: 100)
        split.setCollapsed(true)
        split.setCollapsed(false)
        split.doubleClick()
        XCTAssertEqual(split.detailViewsMade, 1, "the detail NSView was rebuilt")
    }

    // MARK: - Collapsed

    func testCollapsedSidebarTakesNoWidthAndHasNoGrabArea() throws {
        let split = try SplitHarness(storedWidth: 300)
        XCTAssertEqual(split.grabAreaCount, 1, "known-yes")
        split.setCollapsed(true)
        XCTAssertEqual(split.detailMinX, 0, accuracy: 1)
        XCTAssertEqual(split.grabAreaCount, 0)
        split.setCollapsed(false)
        XCTAssertEqual(split.detailMinX, 301, accuracy: 1, "expanding restores the width")
    }
}

/// Hosts the real `SidebarSplit` with a plain sidebar and a click-taking NSView
/// as the detail pane (like the terminal), on its own UserDefaults suite, and
/// drives it with mouse events.
@MainActor
private final class SplitHarness {
    final class State: ObservableObject {
        @Published var collapsed = false
    }

    private struct Host: View {
        @ObservedObject var state: State
        let store: UserDefaults
        let made: (ClickCatcherView) -> Void

        var body: some View {
            SidebarSplit(collapsed: state.collapsed, store: store) { _ in
                Color.gray
            } detail: {
                ClickCatcher(made: made)
            }
        }
    }

    let store: UserDefaults
    private let state = State()
    /// Every detail NSView SwiftUI has made, in order; the last is on screen.
    private var catchers: [ClickCatcherView] = []
    private var catcher: ClickCatcherView { catchers.last! }
    private let window: NSWindow
    private var eventNumber = 0

    nonisolated static func freshStore() -> UserDefaults {
        let name = "herdrm.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    init(store: UserDefaults = SplitHarness.freshStore(), storedWidth: Double? = nil) throws {
        self.store = store
        if let storedWidth { store.set(storedWidth, forKey: SidebarWidth.storageKey) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(state: state, store: store) { [unowned self] in
            self.catchers.append($0)
        })
        window.orderFrontRegardless()
        settle()
    }

    deinit { window.close() }

    // MARK: Observations

    /// The stored width, clamped the way the layout reads it.
    var width: Double {
        SidebarWidth.clamp(store.object(forKey: SidebarWidth.storageKey) as? Double ?? SidebarWidth.defaultWidth)
    }

    /// Left edge of the detail pane in window coordinates.
    var detailMinX: CGFloat { catcher.convert(catcher.bounds, to: nil).minX }

    var detailMouseDowns: Int { catcher.mouseDowns }

    var detailViewsMade: Int { catchers.count }

    var grabAreaCount: Int { Self.count(SidebarResizeHandleView.self, in: window.contentView) }

    // MARK: Actions

    func setCollapsed(_ collapsed: Bool) {
        state.collapsed = collapsed
        settle(seconds: 0.5) // collapse animates for 0.2s
    }

    /// Press at `fromX` (default: on the line), move by `dx` in small steps, release.
    /// `lastDragAt` < 1 stops the drag events at that share of `dx` and releases at `dx`.
    func drag(by dx: CGFloat, fromX: CGFloat? = nil, lastDragAt: CGFloat = 1) {
        let start = NSPoint(x: fromX ?? width + 0.5, y: 200)
        send(.leftMouseDown, at: start, clicks: 1)
        let steps = 10
        for i in 1...steps where CGFloat(i) / CGFloat(steps) <= lastDragAt {
            send(.leftMouseDragged, at: NSPoint(x: start.x + dx * CGFloat(i) / CGFloat(steps), y: start.y), clicks: 1)
        }
        send(.leftMouseUp, at: NSPoint(x: start.x + dx, y: start.y), clicks: 1)
        settle()
    }

    func doubleClick() {
        let p = NSPoint(x: width + 0.5, y: 200)
        send(.leftMouseDown, at: p, clicks: 1)
        send(.leftMouseUp, at: p, clicks: 1)
        send(.leftMouseDown, at: p, clicks: 2)
        send(.leftMouseUp, at: p, clicks: 2)
        settle(seconds: 0.5)
    }

    // MARK: Mechanics

    private func send(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int) {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1) else { return XCTFail("mouse event") }
        window.sendEvent(event)
        settle(seconds: 0.03)
    }

    private func settle(seconds: TimeInterval = 0.2) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private static func count<T: NSView>(_ type: T.Type, in view: NSView?) -> Int {
        guard let view else { return 0 }
        return (view is T ? 1 : 0) + view.subviews.reduce(0) { $0 + count(type, in: $1) }
    }
}

/// Stands in for the terminal: an NSView that takes the first click itself.
private final class ClickCatcherView: NSView {
    var mouseDowns = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { mouseDowns += 1 }
}

private struct ClickCatcher: NSViewRepresentable {
    let made: (ClickCatcherView) -> Void
    func makeNSView(context: Context) -> ClickCatcherView {
        let view = ClickCatcherView()
        made(view)
        return view
    }
    func updateNSView(_ view: ClickCatcherView, context: Context) {}
}
