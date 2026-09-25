import AppKit
import SwiftUI

/// Sidebar width limits and where the chosen width is remembered.
enum SidebarWidth {
    static let defaultWidth: Double = 260
    /// 480 still leaves 500pt for the terminal at the window's 980pt minimum.
    static let range: ClosedRange<Double> = 200...480
    static let storageKey = "sidebar.width"

    static func clamp(_ value: Double) -> Double {
        Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }
}

/// The line between the sidebar and the detail pane. Drag it to resize the
/// sidebar; double-click it to go back to the default width. The line stays
/// 1pt; the grab area is 7pt wide (as in SplitContainer) and straddles it, so the parent must keep
/// this view above the detail pane (`.zIndex`).
struct SidebarResizeDivider: View {
    @Binding var width: Double
    let collapsed: Bool

    var body: some View {
        Rectangle()
            .fill(Theme.sidebarBorder)
            .frame(width: collapsed ? 0 : 1)
            .overlay {
                if !collapsed {
                    SidebarResizeHandle(width: $width).frame(width: 7)
                }
            }
    }
}

/// AppKit rather than `DragGesture`: an NSView can take the first click in an
/// inactive window (`acceptsFirstMouse`), and its cursor rect is managed by
/// AppKit instead of an `onHover` that the terminal's I-beam can override.
private struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var width: Double

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        // Non-zero seed frame, as in SidebarRowDragHost (#42).
        SidebarResizeHandleView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ view: SidebarResizeHandleView, context: Context) {
        view.currentWidth = { width }
        view.setWidth = { width = $0 }
    }
}

final class SidebarResizeHandleView: NSView {
    var currentWidth: () -> Double = { SidebarWidth.defaultWidth }
    var setWidth: (Double) -> Void = { _ in }

    /// Pointer x in window coordinates and sidebar width when the drag began.
    /// Window coordinates, because this view moves with the width it changes.
    private var dragStart: (x: CGFloat, width: Double)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStart = nil
            setWidth(SidebarWidth.defaultWidth)
            return
        }
        dragStart = (event.locationInWindow.x, SidebarWidth.clamp(currentWidth()))
    }

    override func mouseDragged(with event: NSEvent) {
        follow(event)
    }

    /// AppKit can coalesce the last drag into the release, so the release
    /// point is applied too (measured in the Debug app: 7pt short without it).
    override func mouseUp(with event: NSEvent) {
        follow(event)
        dragStart = nil
    }

    private func follow(_ event: NSEvent) {
        guard let start = dragStart else { return }
        setWidth(SidebarWidth.clamp(start.width + event.locationInWindow.x - start.x))
    }
}

/// The sidebar, the resize line and the detail pane side by side. Owns the
/// remembered width; `store` is injectable so tests do not touch the app's
/// defaults.
struct SidebarSplit<Sidebar: View, Detail: View>: View {
    let collapsed: Bool
    @AppStorage private var storedWidth: Double
    private let sidebar: (CGFloat) -> Sidebar
    private let detail: () -> Detail

    init(
        collapsed: Bool,
        store: UserDefaults = .standard,
        @ViewBuilder sidebar: @escaping (CGFloat) -> Sidebar,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.collapsed = collapsed
        _storedWidth = AppStorage(wrappedValue: SidebarWidth.defaultWidth, SidebarWidth.storageKey, store: store)
        self.sidebar = sidebar
        self.detail = detail
    }

    var body: some View {
        let width = SidebarWidth.clamp(storedWidth)
        HStack(spacing: 0) {
            // Laid out at full width and clipped, so collapsing slides it out
            // instead of squeezing its rows.
            sidebar(width)
                .frame(width: collapsed ? 0 : width, alignment: .trailing)
                .clipped()
            // Above the detail pane: half the grab area lies over the terminal.
            SidebarResizeDivider(width: $storedWidth, collapsed: collapsed)
                .ignoresSafeArea()
                .zIndex(1)
            detail()
        }
        .animation(.easeInOut(duration: 0.2), value: collapsed)
    }
}
