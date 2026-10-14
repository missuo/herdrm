import AppKit
import ApplicationServices

/// Reads a window through the system accessibility API, the way VoiceOver
/// does, so tests can find controls by role and name instead of by position.
/// SwiftUI only builds its accessibility tree for such a client.
@MainActor
enum AccessibilityProbe {
    struct Element {
        let role: String
        /// What VoiceOver reads: the description, else the title.
        let name: String?
        let identifier: String?
        /// Screen frame, top-left origin, as the accessibility API reports it.
        let frame: CGRect?
        fileprivate let ref: AXUIElement
    }

    /// Every element in `window` (and a sheet attached to it), depth first.
    /// The window is matched by title, so give it one no other window has.
    static func elements(in window: NSWindow) -> [Element] {
        let app = AXUIElementCreateApplication(getpid())
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let match = windows.first(where: { attribute($0, kAXTitleAttribute) as? String == window.title }) else { return [] }
        var out: [Element] = []
        walk(match, into: &out)
        return out
    }

    /// Requests to our own process are answered in-process on the calling
    /// thread, and SwiftUI runs a button's action there, so stay on main.
    static func press(_ element: Element) {
        _ = AXUIElementPerformAction(element.ref, kAXPressAction as CFString)
    }

    // MARK: - Mechanics

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p = attribute(element, kAXPositionAttribute), let z = attribute(element, kAXSizeAttribute),
              AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(z as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func walk(_ element: AXUIElement, into out: inout [Element], depth: Int = 0) {
        guard depth < 40 else { return }
        let name = (attribute(element, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (attribute(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
        out.append(Element(
            role: attribute(element, kAXRoleAttribute) as? String ?? "",
            name: name,
            identifier: attribute(element, kAXIdentifierAttribute) as? String,
            frame: frame(of: element),
            ref: element
        ))
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            walk(child, into: &out, depth: depth + 1)
        }
    }
}
