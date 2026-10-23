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
    /// - Parameter pinnedHeaders: learn the header titles for `pinnedHeader`; needs a list long enough to scroll.
    init(spaces: Int, agents: Int, terminals: Int = 0, agentTokens: [String: String]? = nil, agentKinds: [String] = [], device: Device = .local, sheets: Bool = false, appearance: NSAppearance.Name = .darkAqua, pinnedHeaders: Bool = true, width: CGFloat = 260, height: CGFloat = 600) throws {
        model = try Self.fakeModel(spaces: spaces, agents: agents, terminals: terminals, agentTokens: agentTokens, agentKinds: agentKinds, device: device)
        let sidebar = SidebarView(model: model, collapsed: .constant(false), width: width).frame(width: width, height: height)
        root = NSHostingView(rootView: sheets ? AnyView(sidebar.newItemSheets(model: model)) : AnyView(sidebar))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.title = "SidebarHarness \(UUID().uuidString)" // AccessibilityProbe finds the window by title
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        scroll = try XCTUnwrap(Self.firstScrollView(in: root), "sidebar scroll view")
        settle()
        if pinnedHeaders { try learnHeaderSignatures() }
    }

    deinit {
        window.sheets.forEach { window.endSheet($0) }
        window.close()
    }

    // MARK: - Actions

    func showReconnectOverlay(_ view: TerminalReconnectOverlay) {
        root.rootView = AnyView(view)
        root.layoutSubtreeIfNeeded()
        settle()
    }

    /// Click a named action at the top of the sidebar through real hit-testing.
    func clickAction(named name: String) throws {
        let button = try XCTUnwrap(AccessibilityProbe.elements(in: window).first {
            $0.role == "AXButton" && $0.name == name && $0.frame != nil
        }, "no sidebar action \(name)")
        try click(atScreen: XCTUnwrap(button.frame))
        settle(seconds: 0.8)
    }

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

    /// Inspect focus immediately after the row click, before SwiftUI has time to
    /// mount a terminal for an agent that has never been opened.
    func clickAgentTitleWithoutSettling(_ title: String) throws {
        let element = try XCTUnwrap(AccessibilityProbe.elements(in: window)
            .filter { $0.role == "AXButton" && ($0.name ?? "").hasPrefix(title) && $0.frame != nil }
            .max { $0.frame!.width < $1.frame!.width },
            "no agent row \(title)\n\(accessibilityDump)")
        try click(atScreen: XCTUnwrap(element.frame))
    }

    func mountTerminal(_ view: LineBreakTerminalView, focus: Bool = false) {
        root.addSubview(view)
        if focus { window.makeFirstResponder(view) }
    }

    var terminalFirstResponder: NSResponder? { window.firstResponder }

    func activateWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The command-line test host has no NSApplication.run() loop. Drain
        // its AppKit events so the requested activation actually takes effect.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline && !(NSApp.isActive && window.isKeyWindow) {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05),
                                          inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        settle()
    }

    func settleTerminalFocus() async {
        // Let deferred AppKit focus run even when the test itself is executing
        // on the main dispatch queue, where a nested RunLoop cannot drain it.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        settle()
    }

    /// Click, with the mouse, the disclosure chevron on a space's row (grouped mode).
    func clickSpaceDisclosure(_ space: String) throws {
        try click(atScreen: XCTUnwrap(spaceDisclosure(space).frame))
        settle(seconds: 0.6) // the fold animates for 0.2s
    }

    /// Click, with the mouse, the title of a space's row.
    func clickSpaceTitle(_ space: String) throws {
        try click(atScreen: spaceTitle(space).frame!)
        settle()
    }

    /// Titles in the menu a right-click on a space's row opens.
    func spaceMenu(_ space: String) throws -> [String] {
        try spaceRowMenu(space).items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    /// Right-click a space's row and choose `title` from its menu.
    func chooseFromSpaceMenu(_ space: String, _ title: String) throws {
        let menu = try spaceRowMenu(space)
        let index = menu.indexOfItem(withTitle: title)
        XCTAssertNotEqual(index, -1, "no \(title) in \(menu.items.map(\.title))")
        guard index != -1 else { return }
        menu.performActionForItem(at: index)
        settle(seconds: 0.8) // a sheet slides in
    }

    /// Close whatever sheet is attached, as Cancel does.
    func dismissSheet() {
        model.showNewAgent = false
        model.showNewTerminal = false
        model.showNewSpace = false
        settle(seconds: 0.8) // the sheet slides out
    }

    /// Choose a device using the native popup's selection action.
    func selectSheetDevice(from current: String, to name: String) throws {
        let sheet = try XCTUnwrap(window.sheets.first)
        let popup = try XCTUnwrap(Self.popup(named: current, in: XCTUnwrap(sheet.contentView)))
        let menu = try XCTUnwrap(popup.menu)
        let index = menu.indexOfItem(withTitle: name)
        XCTAssertNotEqual(index, -1, "no device \(name)")
        guard index != -1 else { return }
        // SwiftUI's picker binding is updated by the menu item's action,
        // not by selecting the NSPopUpButton's displayed item programmatically.
        menu.performActionForItem(at: index)
        settle()
    }

    private static func popup(named title: String, in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton, popup.titleOfSelectedItem == title { return popup }
        return view.subviews.lazy.compactMap { popup(named: title, in: $0) }.first
    }

    /// The texts on the sheet attached to the sidebar's window; empty when there is none.
    var sheetTexts: [String] {
        let all = AccessibilityProbe.elements(in: window)
        guard let start = all.firstIndex(where: { $0.role == "AXSheet" }) else { return [] }
        return all[start...].filter { $0.role == "AXStaticText" }.compactMap { $0.value ?? $0.name }
    }

    var sheetButtonNames: [String] {
        let all = AccessibilityProbe.elements(in: window)
        guard let start = all.firstIndex(where: { $0.role == "AXSheet" }) else { return [] }
        return all[start...].filter { $0.role == "AXButton" }.compactMap(\.name)
    }

    /// Hit-test the actual sheet, so a clipped or covered agent choice cannot
    /// pass just because its accessibility action exists.
    func clickSheetButton(named name: String) throws {
        let sheet = try XCTUnwrap(window.sheets.first)
        let all = AccessibilityProbe.elements(in: window)
        let start = try XCTUnwrap(all.firstIndex { $0.role == "AXSheet" })
        let button = try XCTUnwrap(all[start...].first { $0.role == "AXButton" && $0.name == name })
        let frame = try XCTUnwrap(button.frame)
        XCTAssertGreaterThan(frame.height, 0)
        let screenTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let point = sheet.convertPoint(fromScreen: NSPoint(x: frame.midX, y: screenTop - frame.midY))
        let content = try XCTUnwrap(sheet.contentView)
        let target = try XCTUnwrap(content.hitTest(content.superview?.convert(point, from: nil) ?? point))
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
            windowNumber: sheet.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        if target.acceptsFirstMouse(for: down) {
            sheet.sendEvent(down)
            sheet.sendEvent(up)
        } else {
            target.mouseDown(with: down)
            target.mouseUp(with: up)
        }
        settle()
    }

    /// What VoiceOver reads for the disclosure chevron on a space's row.
    func spaceDisclosureName(_ space: String) throws -> String? {
        settle()
        return try spaceDisclosure(space).name
    }

    var accessibilityDump: String {
        AccessibilityProbe.elements(in: window).map { "\($0.role) \($0.name ?? "-") \($0.identifier ?? "-") \($0.frame.map { "\($0)" } ?? "-")" }.joined(separator: "\n")
    }

    /// The menu AppKit asks the view under the space's title for on a right-click.
    private func spaceRowMenu(_ space: String) throws -> NSMenu {
        let (point, target) = try hit(atScreen: spaceTitle(space).frame!)
        let rightDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        return try XCTUnwrap(target.menu(for: rightDown), "no menu on \(space)")
    }

    /// The widest element named for the space: its title, or the row content holding it.
    private func spaceTitle(_ space: String) throws -> AccessibilityProbe.Element {
        try XCTUnwrap(
            AccessibilityProbe.elements(in: window)
                .filter { ($0.name ?? "").hasPrefix(space) && $0.frame != nil }
                .max { $0.frame!.width < $1.frame!.width },
            "no row \(space)\n\(accessibilityDump)"
        )
    }

    /// The leftmost button level with the space's title and before it.
    private func spaceDisclosure(_ space: String) throws -> AccessibilityProbe.Element {
        let title = try XCTUnwrap(spaceTitle(space).frame)
        return try XCTUnwrap(
            AccessibilityProbe.elements(in: window)
                .filter { e in
                    guard e.role == "AXButton", let f = e.frame else { return false }
                    return f.maxX <= title.minX && (title.minY...title.maxY).contains(f.midY)
                }
                .min { $0.frame!.minX < $1.frame!.minX },
            "no chevron on \(space)\n\(accessibilityDump)"
        )
    }

    /// Open an individual card's history through its independent AX action.
    func pressAgentHistoryButton(for entry: AppModel.AgentEntry) throws {
        AccessibilityProbe.press(try historyButton(for: entry))
        settle()
    }

    /// Send ordinary mouse events to the actual footer button. This catches a
    /// full-row native drag host accidentally intercepting its pointer events.
    func clickAgentHistoryButton(for entry: AppModel.AgentEntry) throws {
        let frame = try XCTUnwrap(try historyButton(for: entry).frame, "history button's screen frame")
        let screenTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let screenPoint = NSPoint(x: frame.midX, y: screenTop - frame.midY)
        try click(at: window.convertPoint(fromScreen: screenPoint))
        settle()
    }

    // MARK: - Observations

    /// Whether the CPU / RAM / DISK meters are in the sidebar footer.
    var showsMachineStats: Bool {
        AccessibilityProbe.elements(in: window).contains { $0.identifier == "sidebar.machineStats" }
    }

    /// The controls VoiceOver lists in the sidebar, without the scroll bar's own parts.
    var controls: [AccessibilityProbe.Element] {
        let all = AccessibilityProbe.elements(in: window)
        let scrollBars = all.filter { $0.role == "AXScrollBar" }.compactMap(\.frame)
        let roles: Set<String> = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXRadioButton", "AXTextField"]
        return all.filter { e in
            guard roles.contains(e.role), let f = e.frame, f.width > 0, f.height > 0 else { return false }
            return !scrollBars.contains { $0.contains(CGPoint(x: f.midX, y: f.midY)) }
        }
    }

    var agentHistoryButtons: [AccessibilityProbe.Element] {
        AccessibilityProbe.elements(in: window).filter {
            $0.role == "AXButton" && $0.identifier?.hasPrefix("sidebar.agent.history.") == true
        }
    }

    private func historyButton(for entry: AppModel.AgentEntry) throws -> AccessibilityProbe.Element {
        try XCTUnwrap(agentHistoryButtons.first { $0.identifier == "sidebar.agent.history.\(entry.id)" }, "history button for \(entry.agent.paneID)")
    }

    /// Names VoiceOver reads for the buttons on a section header.
    func headerButtons(_ header: Header) -> [String] {
        headerButtonElements(header).compactMap(\.name)
    }

    /// Names of the sidebar's top action rows (New Agent … Search), top to bottom.
    func actionRowNames() -> [String] {
        AccessibilityProbe.elements(in: window)
            .filter { $0.role == "AXButton" && $0.identifier == nil }
            .compactMap(\.name)
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


    /// Every system-material surface drawn in the sidebar (the body and each
    /// section header's background), and whether it blends what is behind the window.
    var materialSurfaces: [(blending: NSVisualEffectView.BlendingMode, state: NSVisualEffectView.State)] {
        func walk(_ view: NSView) -> [NSVisualEffectView] {
            let own = (view as? NSVisualEffectView).map { [$0] } ?? []
            return own + view.subviews.flatMap(walk)
        }
        return walk(root).map { ($0.blendingMode, $0.state) }
    }

    /// The header currently pinned at the top of the list, by its rendered title.
    var pinnedHeader: Header? {
        guard let band = try? headerBand() else { return nil }
        let scored = signatures.map { ($0.key, Self.changedFraction($0.value, band)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 0.02 else { return nil }
        return best.0
    }

    /// How strongly a space row's name (left half) and its agent count (last
    /// quarter) stand out from the row's own background, as WCAG contrast.
    func spaceRowInk(_ name: String) throws -> (name: Double, count: Double) {
        // Space rows are read as their label alone, so the row is the label's
        // line across the full width of the All Spaces row (a button, read whole).
        let elements = AccessibilityProbe.elements(in: window)
        func widest(_ n: String) throws -> CGRect {
            try XCTUnwrap(elements.filter { $0.name == n || $0.name?.hasPrefix(n + ",") == true }
                .compactMap(\.frame).max { $0.width < $1.width }, "no row named \(n)")
        }
        let column = try widest("All Spaces")
        let label = try widest(name)
        let row = CGRect(x: column.minX, y: label.midY - column.height / 2, width: column.width, height: column.height)
        let screenTop = NSScreen.screens[0].frame.maxY
        let inWindow = window.convertFromScreen(NSRect(x: row.minX, y: screenTop - row.maxY, width: row.width, height: row.height))
        let r = root.convert(inWindow, from: nil)
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        let top = root.isFlipped ? r.minY : root.bounds.height - r.maxY
        let nameInk = luminances(rep, scale: scale, x: r.minX..<r.midX, y: top..<(top + r.height))
        let countInk = luminances(rep, scale: scale, x: (r.maxX - r.width / 4)..<r.maxX, y: top..<(top + r.height))
        let background = Self.background(nameInk + countInk)
        return (Self.ink(nameInk, on: background), Self.ink(countInk, on: background))
    }

    /// How strongly the top header's title and its trailing button stand out
    /// from the header's own background: the WCAG contrast of the pixel that
    /// differs most from it, in the title area and in the button area.
    func headerInk() throws -> (title: Double, button: Double) {
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        let r = scroll.contentView.convert(scroll.contentView.bounds, to: root)
        let top = root.isFlipped ? r.minY : root.bounds.height - r.maxY
        // Header layout: 8pt side padding, a 20pt trailing button.
        let title = luminances(rep, scale: scale, x: (r.minX + 8)..<(r.minX + 90), y: (top + 4)..<(top + 24))
        let button = luminances(rep, scale: scale, x: (r.maxX - 8 - 20)..<(r.maxX - 8), y: (top + 4)..<(top + 24))
        let background = Self.background(title + button)
        return (Self.ink(title, on: background), Self.ink(button, on: background))
    }

    /// WCAG relative luminance of every pixel in a region given in points.
    private func luminances(_ rep: NSBitmapImageRep, scale: CGFloat, x: Range<CGFloat>, y: Range<CGFloat>) -> [Double] {
        var out: [Double] = []
        for py in Int(y.lowerBound * scale)..<Int(y.upperBound * scale) {
            for px in Int(x.lowerBound * scale)..<Int(x.upperBound * scale) {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                out.append(0.2126 * Self.linear(c.redComponent) + 0.7152 * Self.linear(c.greenComponent) + 0.0722 * Self.linear(c.blueComponent))
            }
        }
        return out
    }

    /// Ink is thin, so most of a region is background.
    private static func background(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    /// Contrast of the pixel that differs most from the background.
    private static func ink(_ values: [Double], on background: Double) -> Double {
        values.map { (max($0, background) + 0.05) / (min($0, background) + 0.05) }.max() ?? 1
    }

    /// WCAG relative luminance of one sRGB channel.
    private static func linear(_ c: CGFloat) -> Double {
        let c = Double(c)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
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

    private static func fakeModel(spaces: Int, agents: Int, terminals: Int, agentTokens: [String: String]?, agentKinds: [String], device: Device) throws -> AppModel {
        let model = AppModel()
        model.devices = device == .local ? [device] : [.local, device]
        var state = DeviceSessionState()
        state.workspaces = try (0..<spaces).map { i in
            try decode(WorkspaceInfo.self, ["workspace_id": "ws-\(i)", "number": i + 1, "label": "Space \(i + 1)"])
        }
        state.agents = try (0..<agents).map { i in
            let kind = agentKinds.indices.contains(i) ? agentKinds[i] : "claude"
            var json: [String: Any] = ["agent": kind, "name": "Agent \(i + 1)", "workspace_id": "ws-0", "tab_id": "tab-\(i)", "pane_id": "pane-\(i)"]
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

    /// Click the middle of a rect given in accessibility screen coordinates.
    /// The press goes to whichever view AppKit hit-tests there, the way a real
    /// click picks its target. The test window is never key, so for a view that
    /// does not accept first mouse (the row's drag view) `sendEvent` would spend
    /// the click on activating the window; such a view gets the press directly.
    private func click(atScreen rect: CGRect) throws {
        let (point, target) = try hit(atScreen: rect)
        let (down, up) = try mouseClick(at: point)
        if target.acceptsFirstMouse(for: down) {
            try click(at: point)
            return
        }
        target.mouseDown(with: down)
        settle()
        target.mouseUp(with: up)
    }

    /// The window point at the middle of a rect in accessibility screen
    /// coordinates, and the view AppKit hit-tests there.
    private func hit(atScreen rect: CGRect) throws -> (NSPoint, NSView) {
        let mainHeight = try XCTUnwrap(NSScreen.screens.first).frame.height
        let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: mainHeight - rect.midY))
        let content = try XCTUnwrap(window.contentView)
        let target = try XCTUnwrap(content.hitTest(content.superview?.convert(point, from: nil) ?? point), "nothing under \(point)")
        return (point, target)
    }

    private func mouseClick(at point: NSPoint) throws -> (NSEvent, NSEvent) {
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        return (down, up)
    }

    private func click(at point: NSPoint) throws {
        let (down, up) = try mouseClick(at: point)
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
