import AppKit
import SwiftUI

/// A two-pane split with a draggable divider and a persisted ratio. `axis == nil` shows
/// `first()` filling the whole area; the second pane and the divider are what come and go.
///
/// The `GeometryReader` and the layout are present in every state on purpose, and the axis
/// is switched with `AnyLayout` rather than by branching. Do not "simplify" this into
/// `if axis != nil { … } else { first() }`: SwiftUI does not preserve identity across a
/// `_ConditionalContent` branch swap, so `first()` would be destroyed and rebuilt on every
/// split — which killed the agent's attach process and relaunched it with `--takeover`.
struct SplitContainer<First: View, Second: View>: View {
    let axis: SplitAxis?
    let activeSide: SplitSide
    @Binding var ratio: Double
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second

    /// The ratio when the current drag began. `DragGesture.translation` is a delta,
    /// so the divider follows the mouse from wherever it was; `location` would be
    /// measured against the divider's own origin, not the container's, and make the
    /// divider jump on mouse-down.
    @State private var dragStartRatio: Double?

    var body: some View {
        // One structural position for first()/second(), always. Putting first() in two
        // branches of a conditional made SwiftUI destroy and rebuild it on every split:
        // identity does not survive a _ConditionalContent branch swap, .id() included, so
        // the agent's attach process was killed and relaunched with --takeover. AnyLayout
        // swaps the axis without touching child identity.
        GeometryReader { proxy in
            let total = axis == .vertical ? proxy.size.width : proxy.size.height
            let firstLength = total * SplitContainerRatioBounds.clamp(ratio)
            let layout = axis == .horizontal
                ? AnyLayout(VStackLayout(spacing: 0))
                : AnyLayout(HStackLayout(spacing: 0))
            layout {
                first()
                    .frame(
                        width: axis == .vertical ? firstLength : nil,
                        height: axis == .horizontal ? firstLength : nil
                    )
                    .opacity(paneOpacity(for: .agent))
                if let axis {
                    divider(axis: axis, total: total)
                    second()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(paneOpacity(for: .shell))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A gesture cancelled without onEnded leaves a stale anchor;
            // clearing on axis change covers the case that shows.
            .onChange(of: axis) { _, _ in dragStartRatio = nil }
        }
    }

    private func paneOpacity(for side: SplitSide) -> Double {
        guard axis != nil else { return 1.0 }
        return activeSide == side ? 1.0 : inactivePaneOpacity
    }

    private func divider(axis: SplitAxis, total: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .overlay(
                Rectangle()
                    .fill(.clear)
                    .frame(width: axis == .vertical ? 7 : nil, height: axis == .horizontal ? 7 : nil)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard total > 0 else { return }
                                let start = dragStartRatio ?? SplitContainerRatioBounds.clamp(ratio)
                                if dragStartRatio == nil { dragStartRatio = start }
                                let travelled = axis == .vertical
                                    ? value.translation.width
                                    : value.translation.height
                                ratio = SplitContainerRatioBounds.clamp(start + travelled / total)
                            }
                            .onEnded { _ in dragStartRatio = nil }
                    )
                    // set() instead of push()/pop(): closing the split with the
                    // pointer over the divider never delivers onHover(false), and an
                    // unbalanced push leaves the resize cursor stuck app-wide.
                    .onHover { hovering in
                        if hovering {
                            (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
            )
    }
}

private enum SplitContainerRatioBounds {
    static let bounds = 0.2...0.8

    static func clamp(_ value: Double) -> Double {
        Swift.min(Swift.max(value, bounds.lowerBound), bounds.upperBound)
    }
}

/// Tracks which side of the ⌘D split holds the keyboard by KVO-observing the key
/// window's `firstResponder`.
///
/// `NSWindow.firstResponder` is documented as KVO-observable. `NSApplication.keyWindow`
/// is NOT documented as such, but was verified empirically to fire — including on the
/// transitions through nil — so the observer reinstalls itself when the key window
/// changes. Treat that half as a measured, non-contractual dependency on AppKit.
///
/// This class holds no copy of the active side on purpose: it reports every computed
/// value to `onSideChanged` without deduplicating. A cached side here went stale when
/// the split closed and then silently stopped reporting, which drew the active pane
/// dimmed and inverted the resize direction.
///
/// AppKit changes `firstResponder` and `keyWindow` on the main thread, so the callback
/// is delivered there too.
final class SplitFocusTracker {
    /// Called with the side that now holds the keyboard. Fires on every observed
    /// change, even when the value repeats — see the note above.
    var onSideChanged: ((SplitSide) -> Void)?

    /// Reports whether a view belongs to the agent side. Backed by the attach
    /// registry's live views: kept-alive attaches persist across selection switches,
    /// and only the selected one is visible/focusable, so a responder inside any of
    /// them means the agent side holds the keyboard. A single stored agent view would
    /// go stale the moment the selection switched while the old view was still first
    /// responder — the exact staleness the class comment above warns against.
    var isAgentView: (NSView) -> Bool = { _ in false }
    weak var shellView: LineBreakTerminalView?

    private var keyWindowObservation: NSKeyValueObservation?
    private var firstResponderObservation: NSKeyValueObservation?

    func start() {
        keyWindowObservation = NSApp.observe(\.keyWindow, options: [.new]) { [weak self] _, _ in
            self?.installFirstResponderObserver()
        }
        installFirstResponderObserver()
    }

    private func installFirstResponderObserver() {
        firstResponderObservation?.invalidate()
        firstResponderObservation = NSApp.keyWindow?.observe(
            \.firstResponder,
            options: [.new]
        ) { [weak self] _, _ in
            self?.updateActiveSide()
        }
        updateActiveSide()
    }

    private func updateActiveSide() {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else { return }
        var view: NSView? = responder
        while let current = view {
            if isAgentView(current) { onSideChanged?(.agent); return }
            if current === shellView { onSideChanged?(.shell); return }
            view = current.superview
        }
    }

    deinit {
        keyWindowObservation?.invalidate()
        firstResponderObservation?.invalidate()
    }
}

/// Dims the inactive pane enough to show which side has the keyboard without making
/// its text unreadable. Tuned visually; deliberately not exposed as a setting.
private let inactivePaneOpacity = 0.55
