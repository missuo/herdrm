import AppKit
import HerdrKit
import SwiftUI

// ⌃Tab switches between recently used agents and terminals, like ⌘Tab
// between apps. A quick tap goes straight back to the previous pane; holding
// ⌃ and pressing Tab again shows the list, and releasing ⌃ opens the
// highlighted pane.

extension View {
    /// The ⌃Tab switcher over this view and the key handling that drives it.
    /// One modifier rather than two keeps `RootView`'s long chain within what
    /// the type checker solves in reasonable time.
    func paneSwitcher(model: AppModel) -> some View {
        overlay { PaneSwitcherLayer(model: model) }
            .background(PaneSwitcherKeyCatcher(model: model))
    }
}

/// The panel over the window while ⌃ is held, plus a click-away layer that cancels.
struct PaneSwitcherLayer: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.paneSwitcherShown, let switcher = model.paneSwitcher {
            ZStack {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { model.cancelPaneSwitch() }
                PaneSwitcherPanel(model: model, switcher: switcher)
            }
        }
    }
}

private struct PaneSwitcherPanel: View {
    @ObservedObject var model: AppModel
    let switcher: RecentSwitcher<PaneRef>

    private static let rowHeight: CGFloat = 36

    private var entries: [AppModel.AttachedEntry] {
        switcher.items.compactMap { model.attachedEntry(for: $0) }
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(entries) { entry in
                            row(entry, isHighlighted: entry.ref == switcher.selection)
                                .id(entry.ref)
                        }
                    }
                    .padding(8)
                }
                .frame(height: min(CGFloat(entries.count) * (Self.rowHeight + 1) + 15, 380))
                .onChange(of: switcher.highlighted) { _, _ in
                    proxy.scrollTo(switcher.selection, anchor: nil)
                }
                .onAppear { proxy.scrollTo(switcher.selection, anchor: nil) }
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack(spacing: 12) {
                KeyHint(key: "⇥", label: "older")
                KeyHint(key: "⇧⇥", label: "newer")
                KeyHint(key: "⌃", label: "release to open")
                Spacer()
                KeyHint(key: "esc", label: "cancel")
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent agents and terminals")
        .accessibilityIdentifier("paneSwitcher")
    }

    private func row(_ entry: AppModel.AttachedEntry, isHighlighted: Bool) -> some View {
        let connected: Bool
        if case .connected = model.session(entry.device.id).connection { connected = true } else { connected = false }
        return Button { model.choosePaneSwitch(entry.ref) } label: {
            PaneRowLabel(model: model, entry: entry)
                .opacity(connected ? 1 : 0.45)
                .padding(.horizontal, 10)
                .frame(height: Self.rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isHighlighted ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityLabel(accessibilityLabel(entry, connected: connected))
            .accessibilityIdentifier("paneSwitcher.row")
    }

    private func accessibilityLabel(_ entry: AppModel.AttachedEntry, connected: Bool) -> String {
        var parts: [String]
        switch entry {
        case .agent(let agent):
            parts = [agent.title]
            switch agent.agent.status {
            case .working: parts.append(String(localized: "Working"))
            case .blocked: parts.append(String(localized: "Needs input"))
            case .done where model.isUnread(agent): parts.append(String(localized: "Unread"))
            case .done, .idle, .unknown: break
            }
            parts.append(model.spaceName(deviceID: agent.device.id, workspaceID: agent.agent.workspaceID))
        case .terminal(let terminal):
            parts = [
                terminal.title,
                String(localized: "Terminal"),
                model.spaceName(deviceID: terminal.device.id, workspaceID: terminal.pane.workspaceID),
            ]
        }
        if model.showsDeviceBadges { parts.append(entry.device.name) }
        if !connected { parts.append(String(localized: "Disconnected")) }
        return parts.joined(separator: ", ")
    }
}

/// An agent or terminal as ⌘K and the ⌃Tab switcher list it: icon, name,
/// status, then its space and device on the right.
struct PaneRowLabel: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.AttachedEntry

    var body: some View {
        HStack(spacing: 9) {
            switch entry {
            case .agent(let entry):
                if let resource = BrandIconLoader.agentIcon(for: entry.agent.agent) {
                    BrandIcon(resource: resource, size: 13)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                }
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                AgentStatusGlyph(status: entry.agent.status, unreadDone: model.isUnread(entry))
                Spacer(minLength: 8)
                if entry.agent.status == .blocked {
                    Text("needs input")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                }
                RowTrailing(
                    model: model,
                    text: "\(entry.agent.agent) · \(model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID))",
                    device: entry.device
                )
            case .terminal(let entry):
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                RowTrailing(
                    model: model,
                    text: String(localized: "Terminal · \(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID))"),
                    device: entry.device
                )
            }
        }
    }
}

/// The right end of a ⌘K / ⌃Tab row: a detail line and, with several devices, the device chip.
struct RowTrailing: View {
    @ObservedObject var model: AppModel
    let text: String
    let device: Device

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            if model.showsDeviceBadges {
                DeviceChip(device: device)
            }
        }
    }
}

/// A key and what it does, in the footer of ⌘K and the ⌃Tab switcher.
struct KeyHint: View {
    let key: String
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 4)
                .frame(height: 16)
                .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textGhost)
        }
    }
}

// MARK: - Keys

/// Installs `PaneSwitcherKeys` for the window this view is in.
struct PaneSwitcherKeyCatcher: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context _: Context) -> PaneSwitcherKeyView {
        PaneSwitcherKeyView(model: model)
    }

    func updateNSView(_: PaneSwitcherKeyView, context _: Context) {}
}

final class PaneSwitcherKeyView: NSView {
    private let model: AppModel
    private(set) var keys: PaneSwitcherKeys?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keys = window.map { PaneSwitcherKeys(model: model, window: $0) }
    }
}

/// Catches ⌃Tab before the terminal does, as the app's ⌘ shortcuts are caught:
/// a local event monitor sees the key before the window hands it to the
/// focused pane. Only events for its own window with no sheet open are used.
@MainActor
final class PaneSwitcherKeys {
    /// How long ⌃ must stay down after the first Tab before the list shows,
    /// so a quick tap switches without a flash of the panel.
    static let showDelay: TimeInterval = 0.2

    private enum KeyCode {
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    private let model: AppModel
    private weak var window: NSWindow?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var showWork: DispatchWorkItem?

    init(model: AppModel, window: NSWindow) {
        self.model = model
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
        // ⌃ released in another app or window never reaches us.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(commit: false) }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        showWork?.cancel()
    }

    /// The event to pass on, or nil when the switcher used it.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.attachedSheet == nil else { return event }
        let active = model.paneSwitcher != nil
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        switch event.type {
        case .flagsChanged:
            if active, !modifiers.contains(.control) { end(commit: true) }
            return event

        case .keyDown:
            if event.keyCode == KeyCode.tab, modifiers == .control || modifiers == [.control, .shift] {
                model.paneSwitcherTab(backward: modifiers.contains(.shift))
                if !active, model.paneSwitcher != nil { scheduleShow() }
                return nil
            }
            guard active else { return event }
            // ⌃ came up without a flagsChanged reaching us: treat it as released.
            guard modifiers.contains(.control) else {
                end(commit: true)
                return event
            }
            switch event.keyCode {
            case KeyCode.escape: end(commit: false)
            case KeyCode.returnKey, KeyCode.keypadEnter: end(commit: true)
            case KeyCode.upArrow: model.paneSwitcherStep(backward: true)
            case KeyCode.downArrow: model.paneSwitcherStep(backward: false)
            default: break
            }
            // Nothing typed with ⌃ held mid-switch (⌃C!) reaches the terminal.
            return nil

        case .leftMouseDown, .leftMouseUp:
            // ⌃ is still down while the list is up, and AppKit reads a ⌃-click
            // as a right-click. Drop ⌃ so clicking a row picks it.
            guard model.paneSwitcherShown, event.modifierFlags.contains(.control) else { return event }
            return NSEvent.mouseEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags.subtracting(.control),
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                eventNumber: event.eventNumber,
                clickCount: event.clickCount,
                pressure: event.pressure
            ) ?? event

        default:
            return event
        }
    }

    private func scheduleShow() {
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.paneSwitcher != nil else { return }
                self.model.paneSwitcherShown = true
            }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    private func end(commit: Bool) {
        showWork?.cancel()
        showWork = nil
        guard model.paneSwitcher != nil else { return }
        if commit { model.commitPaneSwitch() } else { model.cancelPaneSwitch() }
    }
}
