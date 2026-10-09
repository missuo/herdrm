import AppKit
import HerdrKit
import SwiftUI

enum SidebarContextMenuItem {
    case item(title: String, action: () -> Void)
    case destructive(title: String, action: () -> Void)
    case submenu(title: String, items: [SidebarContextMenuItem])
    /// One of a set, ticked when it is the current one; no action greys it out.
    case choice(title: String, isChecked: Bool, action: (() -> Void)?)
    case separator
}

/// AppKit drag/drop host. SwiftUI `.onDrag` on macOS does not start when a
/// `Button` (or even `onTapGesture`) owns mouseDown; a few points of movement
/// here begin an `NSDraggingSession` instead.
struct SidebarRowDragHost: NSViewRepresentable {
    let entryID: String
    let pasteboardType: NSPasteboard.PasteboardType
    let menuItems: [SidebarContextMenuItem]
    let onClick: () -> Void
    var onDoubleClick: (() -> Void)?
    var onMenuOpen: (() -> Void)?
    var allowsDrag = true
    var onDragStart: ((String) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDropHover: ((Bool) -> Void)?
    var onHoverExit: (() -> Void)?
    var onDrop: ((String, Bool) -> Void)?

    func makeNSView(context: Context) -> SidebarRowDragNSView {
        // Non-zero seed frame: a SwiftUI overlay NSView that starts at .zero
        // can stay 0-size, so clicks and drags never arrive (#42).
        let view = SidebarRowDragNSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.pasteboardType = pasteboardType
        view.allowsDrag = allowsDrag
        if allowsDrag { view.registerForDraggedTypes([pasteboardType]) }
        return view
    }

    func updateNSView(_ view: SidebarRowDragNSView, context: Context) {
        if view.pasteboardType != pasteboardType || view.allowsDrag != allowsDrag {
            view.unregisterDraggedTypes()
            view.pasteboardType = pasteboardType
            if allowsDrag { view.registerForDraggedTypes([pasteboardType]) }
        }
        view.entryID = entryID
        view.menuItems = menuItems
        view.allowsDrag = allowsDrag
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onMenuOpen = onMenuOpen
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.onDropHover = onDropHover
        view.onHoverExit = onHoverExit
        view.onDrop = onDrop
    }
}

struct SpaceRowDragHost: View {
    let entryID: String
    let label: String
    let onClick: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void
    let onDragStart: (String) -> Void
    let onDragEnd: () -> Void
    let onDropHover: (Bool) -> Void
    let onHoverExit: () -> Void
    let onDrop: (String, Bool) -> Void

    var body: some View {
        SidebarRowDragHost(
            entryID: entryID,
            pasteboardType: SidebarRowDragNSView.spacePasteboardType,
            menuItems: [
                .item(title: String(localized: "Rename Space…"), action: onRename),
                .separator,
                .destructive(title: String(localized: "Close Space \"\(label)\"…"), action: onClose),
            ],
            onClick: onClick,
            onDoubleClick: onRename,
            onDragStart: onDragStart,
            onDragEnd: onDragEnd,
            onDropHover: onDropHover,
            onHoverExit: onHoverExit,
            onDrop: onDrop
        )
    }
}

struct AgentRowDragHost: View {
    let entryID: String
    let paneID: String
    /// Only a Claude pane can be pinned to one of grazr's accounts.
    let isClaude: Bool
    let pluginActions: [PluginActionGroup]
    let grazrReport: GrazrReport?
    let onClick: () -> Void
    let onRename: () -> Void
    let onPluginAction: (PluginAction) -> Void
    let onGrazrAccounts: () -> Void
    let onSwitchGrazrAccount: (GrazrAccount) -> Void
    let onReauthenticateGrazrAccount: (GrazrAccount) -> Void
    /// nil puts the pane back on the shared rotation.
    let onPinGrazrAccount: (GrazrAccount?) -> Void
    let onSetUpGrazrToken: (GrazrAccount) -> Void
    let onInstallGrazrPins: () -> Void
    let onMenuOpen: () -> Void
    let onClose: () -> Void
    let onDragStart: (String) -> Void
    let onDragEnd: () -> Void
    let onDropHover: (Bool) -> Void
    let onHoverExit: () -> Void
    let onDrop: (String, Bool) -> Void

    var body: some View {
        SidebarRowDragHost(
            entryID: entryID,
            pasteboardType: SidebarRowDragNSView.agentPasteboardType,
            menuItems: menuItems,
            onClick: onClick,
            onDoubleClick: onRename,
            onMenuOpen: onMenuOpen,
            onDragStart: onDragStart,
            onDragEnd: onDragEnd,
            onDropHover: onDropHover,
            onHoverExit: onHoverExit,
            onDrop: onDrop
        )
    }

    /// herdr plugin actions sit between rename and close, one submenu per
    /// plugin: grazr's account swap, agent-quota's refresh, …
    private var menuItems: [SidebarContextMenuItem] {
        var items: [SidebarContextMenuItem] = [
            .item(title: String(localized: "Rename Agent…"), action: onRename),
        ]
        if !pluginActions.isEmpty {
            items.append(.separator)
            for group in pluginActions {
                var actions: [SidebarContextMenuItem] = group.actions.map { action in
                    .item(title: action.menuTitle, action: { onPluginAction(action) })
                }
                if group.pluginID == Grazr.pluginID {
                    var accounts: [SidebarContextMenuItem] = [
                        .item(title: String(localized: "Accounts…"), action: onGrazrAccounts),
                    ]
                    if let pinMenu = grazrPinMenu {
                        accounts.append(pinMenu)
                    }
                    if let switchMenu = grazrSwitchMenu {
                        accounts.append(switchMenu)
                    }
                    accounts += grazrSignInItems
                    actions.insert(contentsOf: accounts + [.separator], at: 0)
                }
                items.append(.submenu(title: group.name, items: actions))
            }
        }
        items.append(.separator)
        items.append(.destructive(title: String(localized: "Close Agent…"), action: onClose))
        return items
    }

    /// grazr's accounts as last read, the active one ticked. A blocked one
    /// says why and cannot be picked.
    private var grazrSwitchMenu: SidebarContextMenuItem? {
        guard let report = grazrReport, report.accounts.count > 1 else { return nil }
        let now = Date()
        let accounts: [SidebarContextMenuItem] = report.sortedAccounts.map { account in
            var title = account.name
            if account.id != report.active, let block = report.block(for: account, now: now) {
                title = String(localized: "\(account.name) (blocked: \(block.reason))")
            }
            return .choice(
                title: title,
                isChecked: account.id == report.active,
                action: report.canSwitch(to: account, now: now) ? { onSwitchGrazrAccount(account) } : nil
            )
        }
        return .submenu(title: String(localized: "Switch Shared Account"), items: accounts)
    }

    /// Which account this agent runs on: the shared rotation, or one of its
    /// own. An account without a pin token offers to set one up instead.
    private var grazrPinMenu: SidebarContextMenuItem? {
        guard isClaude, let report = grazrReport, !report.accounts.isEmpty else { return nil }
        let now = Date()
        let pinned = report.pinnedAccount(paneID: paneID)
        var items: [SidebarContextMenuItem] = []
        if !report.pinsInstalled {
            items += [
                .item(title: String(localized: "Install Pin Support"), action: onInstallGrazrPins),
                .separator,
            ]
        }
        items.append(.choice(
            title: String(localized: "Shared Rotation"),
            isChecked: pinned == nil,
            action: pinned == nil ? nil : { onPinGrazrAccount(nil) }
        ))
        items.append(.separator)
        for account in report.sortedAccounts {
            if account.hasToken(now: now) {
                items.append(.choice(
                    title: account.name,
                    isChecked: pinned?.id == account.id,
                    action: pinned?.id == account.id ? nil : { onPinGrazrAccount(account) }
                ))
            } else {
                items.append(.item(
                    title: String(localized: "Set Up Token for \(account.name)…"),
                    action: { onSetUpGrazrToken(account) }
                ))
            }
        }
        if report.pinIsPending(paneID: paneID) {
            items += [
                .separator,
                .choice(title: String(localized: "Applies when Claude restarts here"), isChecked: false, action: nil),
            ]
        }
        return .submenu(title: String(localized: "Pin to Account"), items: items)
    }

    /// One per account whose login grazr found refused.
    private var grazrSignInItems: [SidebarContextMenuItem] {
        guard let report = grazrReport else { return [] }
        let now = Date()
        return report.sortedAccounts
            .filter { report.needsSignIn($0, now: now) }
            .map { account in
                .item(
                    title: String(localized: "Re-authenticate \(account.name)…"),
                    action: { onReauthenticateGrazrAccount(account) }
                )
            }
    }
}

struct TerminalRowDragHost: View {
    let entryID: String
    let onClick: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void
    let onDragStart: (String) -> Void
    let onDragEnd: () -> Void
    let onDropHover: (Bool) -> Void
    let onHoverExit: () -> Void
    let onDrop: (String, Bool) -> Void

    var body: some View {
        SidebarRowDragHost(
            entryID: entryID,
            pasteboardType: SidebarRowDragNSView.terminalPasteboardType,
            menuItems: [
                .item(title: String(localized: "Rename Terminal…"), action: onRename),
                .separator,
                .destructive(title: String(localized: "Close Terminal…"), action: onClose),
            ],
            onClick: onClick,
            onDoubleClick: onRename,
            onDragStart: onDragStart,
            onDragEnd: onDragEnd,
            onDropHover: onDropHover,
            onHoverExit: onHoverExit,
            onDrop: onDrop
        )
    }
}

final class SidebarRowDragNSView: NSView, NSDraggingSource {
    static let spacePasteboardType = NSPasteboard.PasteboardType("dev.bybee.herdrm.space-id")
    static let agentPasteboardType = NSPasteboard.PasteboardType("dev.bybee.herdrm.agent-id")
    static let terminalPasteboardType = NSPasteboard.PasteboardType("dev.bybee.herdrm.terminal-id")

    var pasteboardType = SidebarRowDragNSView.spacePasteboardType
    var entryID = ""
    var menuItems: [SidebarContextMenuItem] = []
    var allowsDrag = true
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onMenuOpen: (() -> Void)?
    var onDragStart: ((String) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDropHover: ((Bool) -> Void)?
    var onHoverExit: (() -> Void)?
    var onDrop: ((String, Bool) -> Void)?

    private var downEvent: NSEvent?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Explicit hit-test so a 0-size overlay cannot silently drop clicks.
        // AppKit passes the point in the superview's coordinate space.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsDrag, let down = downEvent, !didDrag else { return }
        let start = convert(down.locationInWindow, from: nil)
        let now = convert(event.locationInWindow, from: nil)
        guard hypot(now.x - start.x, now.y - start.y) >= 4 else { return }
        didDrag = true
        let preview = dragPreviewImage()
        onDragStart?(entryID)
        let pbItem = NSPasteboardItem()
        pbItem.setString(entryID, forType: pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pbItem)
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            // Native clickCount on mouse-up (Apple NSEvent.clickCount), not a
            // home-grown streak. First up is 1 (select); second is 2 (rename).
            if event.clickCount >= 2, let onDoubleClick {
                onDoubleClick()
            } else {
                onClick?()
            }
        }
        downEvent = nil
        didDrag = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenuOpen?()
        return buildMenu(menuItems)
    }

    private func buildMenu(_ items: [SidebarContextMenuItem]) -> NSMenu {
        let menu = NSMenu()
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let action):
                let menuItem = menu.addItem(withTitle: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = MenuAction(action)
            case .destructive(let title, let action):
                let menuItem = menu.addItem(withTitle: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = MenuAction(action)
            case .choice(let title, let isChecked, let action):
                let menuItem = menu.addItem(
                    withTitle: title,
                    action: action == nil ? nil : #selector(runMenuItem(_:)),
                    keyEquivalent: ""
                )
                menuItem.state = isChecked ? .on : .off
                if let action {
                    menuItem.target = self
                    menuItem.representedObject = MenuAction(action)
                }
            case .submenu(let title, let children):
                let menuItem = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
                menuItem.submenu = buildMenu(children)
            }
        }
        return menu
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnd?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedID(from: sender) != nil else { return [] }
        onDropHover?(placeAfter(sender))
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedID(from: sender) != nil else { return [] }
        onDropHover?(placeAfter(sender))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHoverExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedID(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let sourceID = draggedID(from: sender) else { return false }
        let after = placeAfter(sender)
        onDrop?(sourceID, after)
        return true
    }

    /// Snapshot the SwiftUI row under this transparent overlay. Taken before
    /// `onDragStart` dims the source so the drag image stays opaque.
    private func dragPreviewImage() -> NSImage? {
        guard let content = window?.contentView else { return nil }
        let rect = convert(bounds, to: content)
        guard !rect.isEmpty, let rep = content.bitmapImageRepForCachingDisplay(in: rect) else {
            return nil
        }
        content.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    private func placeAfter(_ sender: NSDraggingInfo) -> Bool {
        convert(sender.draggingLocation, from: nil).y > bounds.midY
    }

    private func draggedID(from sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: pasteboardType)
    }
}

/// NSMenu `representedObject` must be an object; a closure is not.
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
