import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Hosts the real `SidebarView` with fake data and answers questions about
/// what a user would see: which header is pinned, how tall the list is, and
/// what a click on the pinned header does. All rendering/pixel mechanics live
/// here so tests read as specs.
@MainActor
final class SidebarHarness {
    enum Header: String, CaseIterable { case spaces, agents, terminals }
    enum ScrollTarget { case top, bottom, offset(CGFloat) }

    let model: AppModel
    private let root: NSHostingView<AnyView>
    private let window: NSWindow
    private let scroll: NSScrollView
    private var signatures: [Header: [Double]] = [:]

    /// - Parameters: number of fake workspaces / agents shown in the sidebar.
    /// - Parameter agentTokens: pane `tokens` map given to every fake agent
    ///   (what grazr / herdr-agent-quota publish); nil leaves the agents untagged.
    /// - Parameter sheets: attach the app's New Agent / New Terminal / New Space
    ///   sheets, so a button press can be followed to the sheet it opens.
    init(spaces: Int, agents: Int, terminals: Int = 0, agentTokens: [String: String]? = nil, sheets: Bool = false, width: CGFloat = 260, height: CGFloat = 600) throws {
        model = try Self.fakeModel(spaces: spaces, agents: agents, terminals: terminals, agentTokens: agentTokens)
        let sidebar = SidebarView(model: model, collapsed: .constant(false), width: width).frame(width: width, height: height)
        root = NSHostingView(rootView: sheets ? AnyView(sidebar.newItemSheets(model: model)) : AnyView(sidebar))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "SidebarHarness \(UUID().uuidString)" // AccessibilityProbe finds the window by title
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        scroll = try XCTUnwrap(Self.firstScrollView(in: root), "sidebar scroll view")
        settle()
        try learnHeaderSignatures()
    }

    deinit {
        window.sheets.forEach { window.endSheet($0) }
        window.close()
    }

    // MARK: - Actions

    func scroll(_ target: ScrollTarget) {
        let y: CGFloat
        switch target {
        case .top: y = 0
        case .bottom: y = maxOffset
        case .offset(let o): y = o
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
    }

    /// Click the title of whatever header is pinned at the top.
    func clickPinnedHeader() throws {
        let r = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        try click(at: NSPoint(x: r.minX + 40, y: r.maxY - 14))
        settle(seconds: 0.6) // disclosure toggle animates for 0.2s
    }

    /// Click the small button at the right end of whatever header is pinned.
    func clickPinnedHeaderButton() throws {
        let r = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        try click(at: NSPoint(x: r.maxX - 28, y: r.maxY - 14))
        settle(seconds: 0.6)
    }

    /// Press a section header's button the way VoiceOver does, by its name.
    func pressHeaderButton(_ header: Header, named name: String) throws {
        let button = try XCTUnwrap(headerButtonElements(header).first { $0.name == name }, "no \(name) button on \(header)")
        AccessibilityProbe.press(button)
        settle(seconds: 0.8) // a sheet slides in
    }

    /// Select the first fake agent, the way clicking its row does.
    func selectFirstAgent() {
        guard let device = model.devices.first, let agent = model.sessions[device.id]?.agents.first else { return }
        model.selectedPane = PaneRef(deviceID: device.id, paneID: agent.paneID)
        settle()
    }

    // MARK: - Observations

    /// Whether the CPU / RAM / DISK meters are in the sidebar footer.
    var showsMachineStats: Bool {
        AccessibilityProbe.elements(in: window).contains { $0.identifier == "sidebar.machineStats" }
    }

    /// Names VoiceOver reads for the buttons on a section header.
    func headerButtons(_ header: Header) -> [String] {
        headerButtonElements(header).compactMap(\.name)
    }

    /// Names of the buttons on the sheet attached to the sidebar's window; empty when there is none.
    var sheetButtons: [String] {
        let all = AccessibilityProbe.elements(in: window)
        guard let start = all.firstIndex(where: { $0.role == "AXSheet" }) else { return [] }
        return all[start...].filter { $0.role == "AXButton" }.compactMap(\.name)
    }

    private func headerButtonElements(_ header: Header) -> [AccessibilityProbe.Element] {
        AccessibilityProbe.elements(in: window).filter {
            $0.role == "AXButton" && $0.identifier == "sidebar.section.\(header.rawValue)"
        }
    }


    /// The header currently pinned at the top of the list, by its rendered title.
    var pinnedHeader: Header? {
        guard let band = try? headerBand() else { return nil }
        let scored = signatures.map { ($0.key, Self.changedFraction($0.value, band)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 0.02 else { return nil }
        return best.0
    }

    /// Render the whole sidebar to a PNG (for eyeballing a layout change).
    func writeSnapshot(to url: URL) throws {
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    var scrollOffset: CGFloat { scroll.contentView.bounds.origin.y }
    var listHeight: CGFloat { scroll.documentView?.bounds.height ?? 0 }
    var listWidth: CGFloat { scroll.frame.width }
    var maxOffset: CGFloat { max(listHeight - scroll.contentView.bounds.height, 0) }

    // MARK: - Fake data

    private static func fakeModel(spaces: Int, agents: Int, terminals: Int, agentTokens: [String: String]?) throws -> AppModel {
        let model = AppModel()
        let device = Device.local
        model.devices = [device]
        var state = DeviceSessionState()
        state.workspaces = try (0..<spaces).map { i in
            try decode(WorkspaceInfo.self, ["workspace_id": "ws-\(i)", "number": i + 1, "label": "Space \(i + 1)"])
        }
        state.agents = try (0..<agents).map { i in
            var json: [String: Any] = ["agent": "claude", "name": "Agent \(i + 1)", "workspace_id": "ws-0", "tab_id": "tab-\(i)", "pane_id": "pane-\(i)"]
            if let agentTokens { json["tokens"] = agentTokens }
            return try decode(AgentInfo.self, json)
        }
        state.panes = try (0..<terminals).map { i in
            try decode(PaneInfo.self, ["pane_id": "term-pane-\(i)", "terminal_id": "term-\(i)", "workspace_id": "ws-0", "tab_id": "term-tab-\(i)"])
        }
        model.sessions[device.id] = state
        return model
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - Mechanics

    /// Learn what each title looks like by rendering it at rest (Spaces) or
    /// pinned after scrolling past the previous sections (Agents, Terminals).
    private func learnHeaderSignatures() throws {
        scroll(.top)
        signatures[.spaces] = try headerBand()
        scroll(.bottom)
        let last: Header = model.visibleTerminals.isEmpty && model.shellSessions.isEmpty ? .agents : .terminals
        signatures[last] = try headerBand()
        scroll(.top)
        XCTAssertGreaterThan(Self.changedFraction(signatures[.spaces]!, signatures[last]!), 0.03, "known-yes: titles render differently")
    }

    /// Luminance over the pinned header's title area (6–22pt below the list
    /// top, 12–90pt from its left edge).
    private func headerBand() throws -> [Double] {
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        let r = scroll.contentView.convert(scroll.contentView.bounds, to: root)
        let x0 = r.minX
        let y0 = root.isFlipped ? r.minY : root.bounds.height - r.maxY
        var out: [Double] = []
        for py in Int((y0 + 6) * scale)..<Int((y0 + 22) * scale) {
            for px in Int((x0 + 12) * scale)..<Int((x0 + 90) * scale) {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { out.append(0); continue }
                out.append(0.299 * Double(c.redComponent) + 0.587 * Double(c.greenComponent) + 0.114 * Double(c.blueComponent))
            }
        }
        return out
    }

    /// Share of pixels whose luminance differs by more than 0.1.
    private static func changedFraction(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        return Double(zip(a, b).filter { abs($0 - $1) > 0.1 }.count) / Double(a.count)
    }

    private func click(at point: NSPoint) throws {
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        window.sendEvent(down)
        settle()
        window.sendEvent(up)
    }

    private func settle(seconds: TimeInterval = 0.2) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
    }

    private static func firstScrollView(in root: NSView) -> NSScrollView? {
        if let s = root as? NSScrollView { return s }
        for child in root.subviews { if let found = firstScrollView(in: child) { return found } }
        return nil
    }
}
