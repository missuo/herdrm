import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// ⌃Tab, through the real switcher view and its key handling: keys go through
/// the same handler the window's event monitor calls, clicks through AppKit
/// hit-testing, and rows are read by the names VoiceOver hears.
@MainActor
final class PaneSwitcherUIUXTests: XCTestCase {
    func testOneTapGoesBackToThePreviousAgentWithoutShowingTheList() throws {
        let h = try PaneSwitcherHarness()
        h.select("a1")
        h.select("a2")
        h.tapControlTab()
        XCTAssertEqual(h.selected, "a1")
        h.settle(seconds: PaneSwitcherKeys.showDelay + 0.2)
        XCTAssertFalse(h.model.paneSwitcherShown, "a quick tap never shows the list")
        XCTAssertEqual(h.rows, [])
    }

    func testTappingAgainFlipsBack() throws {
        let h = try PaneSwitcherHarness()
        h.select("a1")
        h.select("a2")
        h.tapControlTab()
        h.tapControlTab()
        XCTAssertEqual(h.selected, "a2")
        h.tapControlTab()
        XCTAssertEqual(h.selected, "a1")
    }

    func testHoldingListsRecentFirstAndReleasingOpensTheHighlightedPane() throws {
        let h = try PaneSwitcherHarness()
        h.select("t1")
        h.select("a2")
        h.select("m1")
        h.select("a1")
        h.holdControlTab()
        h.tab()
        XCTAssertEqual(h.rows.map(h.firstPart), ["test1", "test4", "test2", "test3", "test5"],
                       "most recent first, then the panes never opened")
        XCTAssertEqual(h.highlightedRow.map(h.firstPart), "test2")
        h.releaseControl()
        XCTAssertEqual(h.selected, "a2")
        XCTAssertEqual(h.rows, [], "the list closes on release")
    }

    func testTheListShowsAfterAShortHoldWithoutASecondTab() throws {
        let h = try PaneSwitcherHarness()
        h.select("a1")
        h.select("a2")
        h.holdControlTab()
        XCTAssertFalse(h.model.paneSwitcherShown)
        h.settle(seconds: PaneSwitcherKeys.showDelay + 0.2)
        XCTAssertEqual(h.highlightedRow.map(h.firstPart), "test1")
    }

    func testSteppingNeverReordersTheListAndShiftTabStepsForward() throws {
        let h = try PaneSwitcherHarness()
        h.select("a2")
        h.select("a1")
        h.holdControlTab()
        h.tab()
        let opened = h.rows
        XCTAssertEqual(opened.count, 5, "the list is up with every pane")
        guard opened.count == 5 else { return }
        h.tab()
        h.tab()
        XCTAssertEqual(h.rows, opened)
        h.tab(shift: true)
        XCTAssertEqual(h.highlightedRow, opened[3])
        h.releaseControl()
        XCTAssertEqual(h.selected, h.paneID(forRow: opened[3]))
    }

    func testEscapeCancelsAndKeepsTheCurrentPane() throws {
        let h = try PaneSwitcherHarness()
        h.select("a1")
        h.select("a2")
        h.holdControlTab()
        h.tab()
        XCTAssertFalse(h.rows.isEmpty, "the list is up before Esc")
        h.press(keyCode: 53, characters: "\u{1B}", modifiers: .control)
        XCTAssertEqual(h.rows, [])
        h.releaseControl()
        XCTAssertEqual(h.selected, "a2")
    }

    func testTheListCrossesTheDeviceFilterAndOpeningAPaneClearsIt() throws {
        let h = try PaneSwitcherHarness()
        h.select("m1")
        h.select("a1")
        h.model.setDeviceFilter(h.local.id)
        h.tapControlTab()
        XCTAssertEqual(h.selected, "m1")
        XCTAssertNil(h.model.deviceFilter, "the sidebar shows the device the pane is on")
    }

    func testPanesOnADisconnectedDeviceStayListedAndSayTheyAreDisconnected() throws {
        let h = try PaneSwitcherHarness()
        h.model.sessions[h.mini.id]?.connection = .failed("test")
        h.select("m1")
        h.select("a1")
        h.holdControlTab()
        h.tab()
        let row = try XCTUnwrap(h.rows.first { h.firstPart($0) == "test4" })
        XCTAssertTrue(row.hasSuffix("Disconnected"), row)
    }

    func testClosedPanesDropOut() throws {
        let h = try PaneSwitcherHarness()
        h.select("a2")
        h.select("a1")
        h.model.sessions[h.local.id]?.agents.removeAll { $0.paneID == "a2" }
        h.holdControlTab()
        h.tab()
        XCTAssertEqual(h.rows.map(h.firstPart), ["test1", "test3", "test4", "test5"])
    }

    func testClickingARowWithControlHeldOpensIt() throws {
        let h = try PaneSwitcherHarness()
        h.select("a2")
        h.select("a1")
        h.holdControlTab()
        h.tab()
        try h.clickRow("test4")
        XCTAssertEqual(h.selected, "m1")
        XCTAssertEqual(h.rows, [])
    }

    func testControlTabAndKeysTypedMidSwitchNeverReachThePane() throws {
        let h = try PaneSwitcherHarness()
        h.select("a1")
        // Nothing else open on screen yet still swallowed: ⌃Tab belongs to the app.
        h.model.sessions[h.local.id]?.agents.removeAll { $0.paneID != "a1" }
        h.model.sessions[h.local.id]?.panes = []
        h.model.sessions[h.mini.id]?.agents = []
        h.model.sessions[h.mini.id]?.panes = []
        XCTAssertTrue(h.press(keyCode: 48, characters: "\t", modifiers: .control))
        XCTAssertNil(h.model.paneSwitcher)

        let h2 = try PaneSwitcherHarness()
        h2.select("a1")
        h2.holdControlTab()
        XCTAssertTrue(h2.press(keyCode: 8, characters: "\u{03}", modifiers: .control), "⌃C mid-switch is not sent")
        XCTAssertFalse(h2.press(keyCode: 8, characters: "c", modifiers: []), "after ⌃ comes up, keys go through again")
    }

    func testTheOrderIsRememberedAcrossLaunches() throws {
        let h = try PaneSwitcherHarness()
        h.select("a2")
        h.select("m1")
        let relaunched = AppModel(recentPanesDefaults: h.defaults)
        XCTAssertEqual(relaunched.recentPanes.prefix(2).map(\.paneID), ["m1", "a2"])
    }
}

/// A window holding the switcher layer and its key catcher over fake data:
/// Local has test1 (a1), test2 (a2) and terminal test3; "test-mini" has test4 (m1)
/// and terminal test5.
@MainActor
final class PaneSwitcherHarness {
    let model: AppModel
    let defaults: UserDefaults
    let local = Device.local
    let mini = Device(name: "test-mini", kind: .ssh(target: "test@test-mini"))
    private let window: NSWindow
    private let keys: PaneSwitcherKeys

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "PaneSwitcherUIUXTests-\(UUID())"))
        let model = AppModel(recentPanesDefaults: defaults)
        model.devices = [local, mini]
        model.sessions[local.id] = try Self.session(
            agents: [("a1", "test1"), ("a2", "test2")], terminal: ("t1", "test3"))
        model.sessions[mini.id] = try Self.session(agents: [("m1", "test4")], terminal: ("t2", "test5"))
        self.model = model

        let content = ZStack {
            Color.clear.frame(width: 700, height: 500)
            PaneSwitcherLayer(model: model)
        }
        .background(PaneSwitcherKeyCatcher(model: model))
        let root = NSHostingView(rootView: content)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "PaneSwitcherHarness \(UUID().uuidString)"
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        keys = try XCTUnwrap(Self.keyView(in: root)?.keys, "key catcher installed")
        settle()
    }

    deinit {
        window.close()
    }

    var selected: String? { model.selectedPane?.paneID }

    /// Select a pane the way clicking its sidebar row does.
    func select(_ paneID: String) {
        let device = ["m1", "t2"].contains(paneID) ? mini : local
        model.selectAgent(PaneRef(deviceID: device.id, paneID: paneID))
        settle()
    }

    // MARK: Keys

    func tapControlTab() {
        holdControlTab()
        releaseControl()
    }

    func holdControlTab() {
        flags(.control)
        press(keyCode: 48, characters: "\t", modifiers: .control)
    }

    func tab(shift: Bool = false) {
        press(keyCode: 48, characters: "\t", modifiers: shift ? [.control, .shift] : .control)
    }

    func releaseControl() {
        flags([])
    }

    /// Returns true when the switcher kept the key from the window.
    @discardableResult
    func press(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
        let passed = keys.handle(event)
        settle()
        return passed == nil
    }

    private func flags(_ modifiers: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 59
        )!
        _ = keys.handle(event)
        settle()
    }

    // MARK: What a user sees

    private var rowElements: [AccessibilityProbe.Element] {
        AccessibilityProbe.elements(in: window).filter { $0.identifier == "paneSwitcher.row" }
    }

    /// The rows' names as VoiceOver reads them, top to bottom.
    var rows: [String] { rowElements.compactMap(\.name) }

    /// The row of the pane that releasing ⌃ would open.
    var highlightedRow: String? {
        guard let ref = model.paneSwitcher?.selection, let entry = model.attachedEntry(for: ref) else { return nil }
        return rows.first { firstPart($0) == title(entry) }
    }

    func firstPart(_ name: String) -> String {
        String(name.split(separator: ",").first ?? "")
    }

    func paneID(forRow name: String) -> String? {
        model.switcherEntries.first { title($0) == firstPart(name) }?.ref.paneID
    }

    private func title(_ entry: AppModel.AttachedEntry) -> String {
        switch entry {
        case .agent(let agent): return agent.title
        case .terminal(let terminal): return terminal.title
        }
    }

    /// Click a row with ⌃ still held. The events pass the switcher's handler as
    /// the window's monitor would pass them, then go to whichever view AppKit
    /// hit-tests there. The test window is never key, so a view that does not
    /// accept first mouse gets the press directly, as in `SidebarHarness`.
    func clickRow(_ title: String) throws {
        let row = try XCTUnwrap(rowElements.first { firstPart($0.name ?? "") == title }, "no row \(title)")
        let rect = try XCTUnwrap(row.frame)
        let mainHeight = try XCTUnwrap(NSScreen.screens.first).frame.height
        let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: mainHeight - rect.midY))
        let content = try XCTUnwrap(window.contentView)
        let target = try XCTUnwrap(content.hitTest(content.superview?.convert(point, from: nil) ?? point), "nothing under \(point)")
        let events = try [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.05)].map { type, offset in
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: .control,
                timestamp: ProcessInfo.processInfo.systemUptime + offset, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            return try XCTUnwrap(keys.handle(event), "the switcher passes clicks on")
        }
        XCTAssertFalse(events[0].modifierFlags.contains(.control), "a ⌃-click would be a right-click")
        if target.acceptsFirstMouse(for: events[0]) {
            window.sendEvent(events[0])
            settle()
            window.sendEvent(events[1])
        } else {
            target.mouseDown(with: events[0])
            settle()
            target.mouseUp(with: events[1])
        }
        settle()
    }

    func settle(seconds: TimeInterval = 0.1) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Fake data

    private static func session(agents: [(pane: String, name: String)], terminal: (pane: String, cwd: String)) throws -> DeviceSessionState {
        var state = DeviceSessionState()
        state.connection = .connected(version: "test")
        state.workspaces = [try decode(WorkspaceInfo.self, ["workspace_id": "ws-0", "number": 1, "label": "Space 1"])]
        state.agents = try agents.enumerated().map { i, agent in
            try decode(AgentInfo.self, [
                "agent": "claude", "name": agent.name, "workspace_id": "ws-0",
                "tab_id": "tab-\(i)", "pane_id": agent.pane,
            ])
        }
        state.panes = [try decode(PaneInfo.self, [
            "pane_id": terminal.pane, "terminal_id": "term-\(terminal.pane)", "workspace_id": "ws-0",
            "tab_id": "term-tab", "cwd": "/tmp/\(terminal.cwd)",
        ])]
        return state
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func keyView(in view: NSView) -> PaneSwitcherKeyView? {
        if let found = view as? PaneSwitcherKeyView { return found }
        for child in view.subviews { if let found = keyView(in: child) { return found } }
        return nil
    }
}
