import AppKit
import SwiftUI

/// Pins an `NSView.identifier` for AppKit test probes. SwiftUI's
/// `accessibilityIdentifier` alone is not always mirrored onto `NSView.identifier`.
struct SidebarAccessibilityAnchor: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(identifier)
    }
}

extension View {
    func sidebarTestIdentifier(_ identifier: String) -> some View {
        background(SidebarAccessibilityAnchor(identifier: identifier))
            .accessibilityIdentifier(identifier)
    }
}
