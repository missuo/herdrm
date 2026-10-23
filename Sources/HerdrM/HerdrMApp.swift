import AppKit
import Darwin
import HerdrKit
import Sparkle
import SwiftUI
import UserNotifications

/// Holds app termination open long enough to tear the SSH tunnels down: without
/// `.terminateLater` the process dies before the teardown task gets to run, and the
/// `ssh` children survive with PPID 1 along with their sockets.
///
/// The delegate owns the model rather than borrowing it from the window: closing the
/// last window (⌘W) would otherwise drop the only strong reference, and the quit that
/// follows would find nothing left to tear down.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var terminationSignal: DispatchSourceSignal?
    private var terminationRequested = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any session starts, so a reaped socket can never be one of ours.
        SSHTunnel.reapOrphanedForwards()

        // `pkill herdrm` (and launchd) send SIGTERM, whose default action ends the
        // process on the spot: this delegate never hears of it and every ssh child
        // survives. Route it through the normal quit; a second SIGTERM still ends a
        // quit that hangs.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.terminationRequested else { exit(0) }
                self.terminationRequested = true
                // Not from inside this handler: it runs on the main queue, and
                // terminate waits for applicationShouldTerminate's reply, whose
                // main-actor Task needs that same queue, so the quit never ends
                // (and a second SIGTERM queues behind it). A run-loop block
                // leaves the main queue free.
                RunLoop.main.perform {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                }
            }
        }
        source.resume()
        terminationSignal = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.shutdownAllSessions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct AppModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

/// The split axis travels as its own focused value, not read off the model. `Commands`
/// gets the AppModel by reference and never subscribes to its objectWillChange, so
/// `focusedModel?.shellSplitAxis` was evaluated once and stuck: the menu items stayed
/// disabled with a split open, and a disabled NSMenuItem does not fire its key
/// equivalent. A value type changes identity, which does invalidate the commands body —
/// that is also what lets the shortcuts follow the current axis.
private struct SplitAxisFocusedValueKey: FocusedValueKey {
    typealias Value = SplitAxis
}

/// Same reasoning as the split axis: whether a tab layout is on screen travels as
/// a value so the pane-navigation items enable and disable with it.
private struct TabLayoutActiveFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

private struct ClaudeHistorySelectedFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }

    var splitAxis: SplitAxis? {
        get { self[SplitAxisFocusedValueKey.self] }
        set { self[SplitAxisFocusedValueKey.self] = newValue }
    }

    var tabLayoutActive: Bool? {
        get { self[TabLayoutActiveFocusedValueKey.self] }
        set { self[TabLayoutActiveFocusedValueKey.self] = newValue }
    }

    var claudeHistorySelected: Bool? {
        get { self[ClaudeHistorySelectedFocusedValueKey.self] }
        set { self[ClaudeHistorySelectedFocusedValueKey.self] = newValue }
    }
}

@main
struct HerdrMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("app.theme") private var themePreference = "system"
    /// Read here as well as in DetailView and Settings: an @AppStorage on the App
    /// invalidates the commands body, so the menu checkmark follows the setting.
    @AppStorage(TerminalDefaults.tabLayoutKey) private var tabLayoutEnabled = true
    @AppStorage(MachineStatsDefaults.showKey) private var showsMachineStats = true
    @AppStorage(SidebarDefaults.groupBySpaceKey) private var groupSidebarBySpace = false
    @FocusedValue(\.appModel) private var focusedModel
    @FocusedValue(\.splitAxis) private var focusedSplitAxis
    @FocusedValue(\.tabLayoutActive) private var focusedTabLayoutActive
    @FocusedValue(\.claudeHistorySelected) private var claudeHistorySelected
    private var tabLayoutActive: Bool { focusedTabLayoutActive == true }

    private let updaterController: SPUStandardUpdaterController

    init() {
        if ProcessInfo.processInfo.environment[SSHCredentialStore.askPassModeEnvironmentKey] == "1" {
            Self.runSSHAskPass()
        }
        AppLanguage.synchronize()
        SSHCredentialStore.purgeAuthorizations()
        TerminalDefaults.registerBundledFonts()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: appDelegate.model)
                .onAppear { Self.applyTheme(themePreference) }
                .onChange(of: themePreference) { _, newValue in
                    Self.applyTheme(newValue)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // herdrm is a single-window console: a second window would duplicate the
            // whole device tree, so New Window gives up ⌘N to the action that matters.
            CommandGroup(replacing: .newItem) {
                Button("New Agent") { focusedModel?.showNewAgent = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(focusedModel == nil)
                Button("New Terminal") { focusedModel?.showNewTerminal = true }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(focusedModel == nil)
                Button("New Space") { focusedModel?.showNewSpace = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(focusedModel == nil)
            }

            CommandGroup(after: .sidebar) {
                // Off removes the sidebar meters and stops their sampler (one ssh per remote host).
                Toggle("Show Machine Stats", isOn: $showsMachineStats)
                Button("Read full conversation") {
                    if let model = focusedModel, let entry = model.selectedEntry {
                        model.toggleConversationHistory(for: entry.ref)
                    }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(claudeHistorySelected != true)
                // Same key the sidebar's own button and Settings write.
                Toggle("Group Sidebar by Space", isOn: $groupSidebarBySpace)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }

            CommandMenu("Terminal") {
                // ⌘D splits the herdr pane, as it does in the herdr TUI: the new
                // shell joins the tab, shows in the sidebar under its pane, and is
                // reachable with the pane keys. The app's own local shell split is
                // the ⌃⇧ pair below.
                Button("Split Pane Right") { focusedModel?.splitSelectedPane(.right) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(focusedModel?.selectedAttachedEntry == nil)
                Button("Split Pane Down") { focusedModel?.splitSelectedPane(.down) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(focusedModel?.selectedAttachedEntry == nil)
                // A login shell on this Mac beside the attach, outside herdr: no pane,
                // no sidebar row, gone with the window. Guarded on selectedAttachedEntry,
                // not just on the model: with the placeholder on screen there is no
                // SplitContainer to render into, so a split would be invisible yet leave
                // shellSplitAxis non-nil, and the next ⌘W would "close" that phantom
                // instead of the window.
                Button("Split with Local Shell Right") { focusedModel?.shellSplitAxis = .vertical }
                    .keyboardShortcut("d", modifiers: [.control, .shift])
                    .disabled(focusedModel?.selectedAttachedEntry == nil)
                Button("Split with Local Shell Down") { focusedModel?.shellSplitAxis = .horizontal }
                    .keyboardShortcut("s", modifiers: [.control, .shift])
                    .disabled(focusedModel?.selectedAttachedEntry == nil)

                Divider()

                // The toggle is the Settings switch; Zoom Pane is herdr's pane.zoom,
                // so the TUI zooms too.
                Toggle("Show Tab Panes", isOn: $tabLayoutEnabled)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Zoom Pane") { focusedModel?.toggleSelectedPaneZoom() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(focusedModel == nil)
                // Control-shift arrows: no agent CLI binds them (pi takes ctrl-shift
                // up/down for prompt jumps), and they read as "move over" in a column
                // of workers, where directional focus would stop at the first one.
                Button("Next Pane") { focusedModel?.focusPane(offset: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.control, .shift])
                    .disabled(!tabLayoutActive)
                Button("Previous Pane") { focusedModel?.focusPane(offset: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .shift])
                    .disabled(!tabLayoutActive)
                // The sidebar's confirmed close, for the pane that has the keyboard.
                Button("Close Pane…") { focusedModel?.requestCloseSelectedPane() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(focusedModel?.selectedAttachedEntry == nil)

                Divider()

                // Eight items with FIXED shortcuts, enabled per axis — deliberately not
                // four items whose shortcut follows the axis. Measured: `.disabled` IS
                // revalidated when the menu opens, but a key equivalent already registered
                // in the NSMenu is NOT reassigned when the commands body re-evaluates, so
                // the arrows stayed frozen on the axis that was current at launch.
                // Labels name the direction so no two rows read the same.
                //
                // Focus is directional and idempotent: in the local-shell split the left/top
                // pane is always the agent, the right/bottom one always the shell.
                // Without that split, a tab layout moves to the neighbouring herdr pane.
                Button("Focus Left Pane") {
                    if let model = focusedModel { focusDirection(.left, splitSide: .agent, in: model) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!(focusedSplitAxis == .vertical || (focusedSplitAxis == nil && tabLayoutActive)))
                Button("Focus Right Pane") {
                    if let model = focusedModel { focusDirection(.right, splitSide: .shell, in: model) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!(focusedSplitAxis == .vertical || (focusedSplitAxis == nil && tabLayoutActive)))
                Button("Focus Top Pane") {
                    if let model = focusedModel { focusDirection(.up, splitSide: .agent, in: model) }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!(focusedSplitAxis == .horizontal || (focusedSplitAxis == nil && tabLayoutActive)))
                Button("Focus Bottom Pane") {
                    if let model = focusedModel { focusDirection(.down, splitSide: .shell, in: model) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!(focusedSplitAxis == .horizontal || (focusedSplitAxis == nil && tabLayoutActive)))

                Divider()

                // Resize moves the divider by 5% relative to the active pane.
                Button("Widen Active Pane") {
                    if let model = focusedModel { resizeSplit(grow: true, in: model) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(focusedSplitAxis != .vertical)
                Button("Narrow Active Pane") {
                    if let model = focusedModel { resizeSplit(grow: false, in: model) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(focusedSplitAxis != .vertical)
                Button("Grow Active Pane") {
                    if let model = focusedModel { resizeSplit(grow: true, in: model) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(focusedSplitAxis != .horizontal)
                Button("Shrink Active Pane") {
                    if let model = focusedModel { resizeSplit(grow: false, in: model) }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(focusedSplitAxis != .horizontal)
            }
            CommandGroup(replacing: .saveItem) {
                // ⌘W closes the most local thing first: the split, then the
                // selected standalone terminal, then the window. Server-owned
                // panes close from their confirmed sidebar action instead.
                Button(closeButtonTitle) {
                    if let model = focusedModel, model.shellSplitAxis != nil {
                        model.shellSplitAxis = nil
                    } else if let model = focusedModel, let shell = model.selectedShell {
                        model.closeShellSession(shell.id)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }

    private var closeButtonTitle: String {
        if focusedModel?.shellSplitAxis != nil { return String(localized: "Close Split") }
        if focusedModel?.selectedShell != nil { return String(localized: "Close Terminal") }
        return String(localized: "Close")
    }

    static func applyTheme(_ preference: String) {
        switch preference {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - Split commands

    private func focusDirection(_ direction: PaneNeighborDirection, splitSide: SplitSide, in model: AppModel) {
        if model.shellSplitAxis != nil {
            focusSplitSide(splitSide, in: model)
        } else {
            model.focusNeighbourPane(direction)
        }
    }

    private func focusSplitSide(_ side: SplitSide, in model: AppModel) {
        guard model.shellSplitAxis != nil else { return }
        let target = (side == .agent) ? model.splitAgentView : model.splitShellView
        guard let target, let window = target.window else { return }
        window.makeFirstResponder(target)
    }

    private func resizeSplit(grow: Bool, in model: AppModel) {
        guard model.shellSplitAxis != nil else { return }
        let step = 0.05
        let signed = (model.activeSplitSide == .agent) ? step : -step
        let delta = grow ? signed : -signed
        model.splitRatio = min(0.8, max(0.2, model.splitRatio + delta))
    }

    private static func runSSHAskPass() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let rawID = environment[SSHCredentialStore.authorizationIDEnvironmentKey],
              let authorizationID = UUID(uuidString: rawID),
              let password = try? SSHCredentialStore.consumePassword(authorizationID: authorizationID)
        else {
            Darwin.exit(EXIT_FAILURE)
        }
        FileHandle.standardOutput.write(Data("\(password)\n".utf8))
        Darwin.exit(EXIT_SUCCESS)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            AgentsSettingsView(model: model)
                .tabItem { Label("Agents", systemImage: "sparkles") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            TailcatSettingsView(model: model)
                .tabItem { Label("Tailcat", systemImage: "key") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420)
    }
}

struct AgentsSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var drafts: [String: String] = AgentBinaryOverrides.load()
    @State private var argDrafts: [String: String] = [:]
    @State private var yoloMode = AgentLaunchArgsStore.yoloMode()

    /// Kinds herdr ships manifests for (plus OMP, which starts through its
    /// lifecycle extension). Kinds a connected server advertises beyond these
    /// are appended with their raw name.
    private static let knownKinds: [(kind: String, label: String)] = [
        ("claude", "Claude"),
        ("codex", "Codex"),
        ("droid", "Droid"),
        ("agy", "Antigravity"),
        ("cursor", "Cursor"),
        ("gemini", "Gemini"),
        ("grok", "Grok"),
        ("kimi", "Kimi"),
        ("opencode", "OpenCode"),
        ("copilot", "Copilot"),
        ("devin", "Devin"),
        ("cline", "Cline"),
        ("kiro", "Kiro"),
        ("amp", "Amp"),
        ("hermes", "Hermes"),
        ("kilo", "Kilo"),
        ("qodercli", "Qoder"),
        ("qwen", "Qwen Code"),
        ("letta", "Letta"),
        ("maki", "Maki"),
        ("muse", "Muse"),
        ("pi", "Pi"),
        ("omp", "Oh My Pi"),
    ]

    private var kinds: [(kind: String, label: String)] {
        var rows = Self.knownKinds
        for session in model.sessions.values {
            for kind in session.agentCatalog.kinds where !rows.contains(where: { $0.kind == kind }) {
                rows.append((kind, kind))
            }
        }
        return rows
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: yoloBinding) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("YOLO mode")
                        Text("Pre-fills each agent’s permission-bypass flag (for example droid --auto high) into its launch arguments. Turning it off removes those flags and keeps your other arguments.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                ForEach(kinds, id: \.kind) { row in
                    LabeledContent(row.label) {
                        HStack(spacing: 6) {
                            TextField("", text: argBinding(row.kind), prompt: Text("No extra arguments"))
                                .labelsHidden()
                                .font(.system(size: 11.5).monospaced())
                                .help(String(localized: "Arguments appended to \(HerdrService.binaryName(for: row.kind)) when starting this agent."))
                            if AgentLaunchArgsStore.stored()[row.kind] != nil {
                                Button {
                                    AgentLaunchArgsStore.reset(row.kind)
                                    argDrafts[row.kind] = AgentLaunchArgsStore.resolved(for: row.kind)
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.borderless)
                                .help("Reset to default")
                            }
                        }
                    }
                }
            } header: {
                Text("Launch Arguments")
            } footer: {
                Text("Shell-style: quote values with spaces. The New Agent sheet starts from these and lets you edit them for one launch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(kinds, id: \.kind) { row in
                    LabeledContent(row.label) {
                        TextField("", text: binding(row.kind), prompt: Text("Automatic"))
                            .labelsHidden()
                            .font(.system(size: 11.5).monospaced())
                            .help(String(localized: "Command or path for \(HerdrService.binaryName(for: row.kind)). Leave empty to detect."))
                    }
                }
            } header: {
                Text("Binaries on This Mac")
            } footer: {
                Text("Finder-launched apps don’t inherit your terminal PATH. herdrm captures it once from a login + interactive shell, then looks up these names. A path here is an escape hatch when detection picks the wrong binary.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .onAppear {
            drafts = AgentBinaryOverrides.load()
            yoloMode = AgentLaunchArgsStore.yoloMode()
            reloadArgDrafts()
        }
        .onChange(of: drafts) { _, _ in commit() }
        .onDisappear(perform: commit)
        .onSubmit(commit)
    }

    private func commit() {
        AgentBinaryOverrides.save(drafts)
        model.reloadAgentCatalog(deviceID: Device.local.id)
    }

    private func reloadArgDrafts() {
        argDrafts = Dictionary(uniqueKeysWithValues: kinds.map {
            ($0.kind, AgentLaunchArgsStore.resolved(for: $0.kind))
        })
    }

    private var yoloBinding: Binding<Bool> {
        Binding(
            get: { yoloMode },
            set: { enabled in
                yoloMode = enabled
                AgentLaunchArgsStore.setYoloMode(enabled)
                reloadArgDrafts()
            }
        )
    }

    private func binding(_ kind: String) -> Binding<String> {
        Binding(
            get: { drafts[kind] ?? "" },
            set: { drafts[kind] = $0 }
        )
    }

    private func argBinding(_ kind: String) -> Binding<String> {
        Binding(
            get: { argDrafts[kind] ?? AgentLaunchArgsStore.resolved(for: kind) },
            set: { value in
                argDrafts[kind] = value
                // Typing the untouched default back keeps the kind following YOLO mode.
                if AgentLaunchArgsStore.stored()[kind] == nil,
                   value == AgentLaunchArgsStore.resolved(for: kind) { return }
                AgentLaunchArgsStore.save(value, for: kind)
            }
        )
    }
}

struct TerminalSettingsView: View {
    @AppStorage(TerminalDefaults.fontNameKey) private var fontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var fontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var thinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var fontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var lineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage("terminal.mouseReporting") private var mouseReporting = true
    @AppStorage("terminal.copyOnSelect") private var copyOnSelect = true
    @AppStorage(TerminalDefaults.tabLayoutKey) private var tabLayout = true

    @State private var importMessage: String?
    @State private var importSucceeded = false

    private let families = TerminalDefaults.monospacedFamilies()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("Font", selection: $fontName) {
                    Text("System Mono (SF Mono)").tag("")
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Slider(value: $fontSize, in: 9...22, step: 0.5) {
                        Text("Size")
                    }
                    Text(String(format: "%.1f pt", fontSize))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                    Stepper("", value: $fontSize, in: 9...22, step: 0.5)
                        .labelsHidden()
                }

                Picker("Weight", selection: $fontWeight) {
                    Text(String(localized: "font.weight.light", defaultValue: "Light"))
                        .tag(Double(NSFont.Weight.light.rawValue))
                    Text(String(localized: "font.weight.regular", defaultValue: "Regular"))
                        .tag(TerminalDefaults.defaultFontWeight)
                    Text(String(localized: "font.weight.medium", defaultValue: "Medium"))
                        .tag(Double(NSFont.Weight.medium.rawValue))
                }
                .pickerStyle(.segmented)
                .disabled(!fontName.isEmpty)
                .help("Only the system monospaced font has selectable weights.")

                HStack {
                    Slider(value: $lineSpacing, in: 1.0...1.4, step: 0.05) {
                        Text("Line spacing")
                    }
                    Text(String(format: "%.0f%%", lineSpacing * 100))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                Toggle(isOn: $thinStrokes) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Thin strokes")
                        Text("Turns off extra font thickening in the terminal, which can make agent output — especially Claude Code's bold text — look heavy and smudged.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $mouseReporting) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mouse reporting")
                        Text("Forwards clicks to TUI apps that ask for them, while a drag still selects text. Turn off to keep clicks local too — Shift-drag selects either way.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $copyOnSelect) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Copy on select")
                        Text("Copies text to the clipboard as soon as you finish selecting it with the mouse, like herdr's copy_on_select.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $tabLayout) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show every pane of the selected tab")
                        Text("When a herdr tab is split, lay its panes out like the herdr TUI does and attach to each one. Off shows one pane at a time.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Button("Reset to Defaults") {
                        fontName = ""
                        fontSize = TerminalDefaults.defaultFontSize
                        fontWeight = TerminalDefaults.defaultFontWeight
                        lineSpacing = TerminalDefaults.defaultLineSpacing
                        thinStrokes = true
                        mouseReporting = true
                        copyOnSelect = true
                        importMessage = nil
                    }
                    Button("Import from Ghostty…") { importFromGhostty() }
                        .help("Reads font-family and font-size from ~/.config/ghostty/config. A one-time copy — herdrm's settings stay in charge afterward.")
                }

                if let importMessage {
                    Text(importMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(importSucceeded ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Outside the Form: its two-column layout has no label for these
            // rows and would indent them by the whole label column.
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("❯ herdr agent attach w1:p1 — 中文 ABC 0123")
                    .font(Font(TerminalDefaults.font(name: fontName, size: fontSize, weight: fontWeight)))
                    .lineLimit(1)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(20)
    }

    /// One-time import of the terminal font from `~/.config/ghostty/config`, so a
    /// Ghostty user isn't jarred by a different face (#73). Only the family and
    /// size are copied; herdrm's settings own everything from then on.
    private func importFromGhostty() {
        guard let config = GhosttyConfigImporter.load() else {
            importSucceeded = false
            importMessage = String(
                localized: "ghostty.import.none",
                defaultValue: "No Ghostty config found at ~/.config/ghostty/config."
            )
            return
        }
        var applied: [String] = []
        var skipped: [String] = []

        if let family = config.fontFamily {
            let normalized = family.lowercased().replacingOccurrences(of: " ", with: "")
            if normalized == "sfmono" || normalized == "sfmono-regular" {
                // macOS doesn't expose SF Mono as a pickable family; it is
                // herdrm's built-in default (the empty selection).
                fontName = ""
                applied.append("font System Mono (SF Mono)")
            } else if let resolved = TerminalDefaults.resolveFamily(family) {
                fontName = resolved
                applied.append("font \(resolved)")
            } else {
                skipped.append("font “\(family)” isn't installed")
            }
        }
        if let size = config.fontSize {
            let clamped = min(max(size, 9), 22)
            fontSize = clamped
            applied.append(String(format: "size %.1f pt", clamped))
        }

        if applied.isEmpty && skipped.isEmpty {
            importSucceeded = false
            importMessage = String(
                localized: "ghostty.import.empty",
                defaultValue: "Ghostty config has no font settings to import."
            )
        } else if applied.isEmpty {
            importSucceeded = false
            importMessage = "Couldn't import: " + skipped.joined(separator: "; ") + "."
        } else {
            importSucceeded = true
            var message = "Imported " + applied.joined(separator: ", ")
            if !skipped.isEmpty { message += " (skipped: " + skipped.joined(separator: "; ") + ")" }
            importMessage = message + "."
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("app.theme") private var themePreference = "system"
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
    @AppStorage(SidebarDefaults.groupBySpaceKey) private var groupSidebarBySpace = false

    var body: some View {
        Form {
            Picker("Theme", selection: $themePreference) {
                Text(String(localized: "theme.system", defaultValue: "System")).tag("system")
                Text(String(localized: "theme.light", defaultValue: "Light")).tag("light")
                Text(String(localized: "theme.dark", defaultValue: "Dark")).tag("dark")
            }
            .pickerStyle(.segmented)
            Text("The terminal follows the app theme.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $groupSidebarBySpace) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Group sidebar by space")
                    Text("List each space's panes under it: a tab's first pane, then the panes split off it. Agents and Terminals stay as sections, collapsed.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledContent("Language") {
                HStack(spacing: 8) {
                    Picker("Language", selection: $language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(verbatim: option.displayName).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: language) { _, newValue in
                        AppLanguage.apply(AppLanguage(rawValue: newValue) ?? .system)
                    }
                    if AppLanguage.needsRelaunch(AppLanguage(rawValue: language) ?? .system) {
                        Button("Relaunch") {
                            AppLanguage.relaunch()
                        }
                        .help("Quit and reopen herdrm so the new language takes effect.")
                    }
                }
            }
        }
        .padding(20)
    }
}

struct NotificationSettingsView: View {
    @AppStorage("notifications.enabled") private var enabled = true
    @AppStorage("notifications.sound") private var sound = true
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        Form {
            Toggle("Notify when an agent finishes or needs input", isOn: $enabled)
            Toggle("Play a sound", isOn: $sound)
            Text("Finished agents only notify while you're not watching them — herdr reports panes you have open as idle, not done.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            switch authorization {
            case .denied:
                HStack(spacing: 8) {
                    Text("Notifications are disabled in System Settings.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            case .notDetermined:
                HStack(spacing: 8) {
                    Text("Notification permission hasn't been granted yet.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Button("Request Permission") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                            refreshAuthorization()
                        }
                    }
                    .controlSize(.small)
                }
            case .authorized, .provisional:
                Text("Notification permission granted.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .padding(20)
        .onAppear { refreshAuthorization() }
    }

    private func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { authorization = settings.authorizationStatus }
        }
    }
}

/// The install's tailcat client identity: the public key hosts allowlist, and
/// a way to rotate it.
struct TailcatSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmRegenerate = false

    var body: some View {
        Form {
            Section {
                TailcatClientKeyRow(publicKey: model.tailcatClientPublicKey)
            } header: {
                Text("Client Public Key")
            } footer: {
                Text("Every tailcat device connects with this key. On a host that uses an allow list, add it as one line in `allow.list` under `herdr plugin config-dir herdr.tailcat`, then run `herdr plugin action invoke herdr.tailcat.restart`.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
                Text("A new key locks this Mac out of every allowlisting host until you update it there.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Regenerate Key…") { confirmRegenerate = true }
                    .controlSize(.small)
            }
        }
        .padding(20)
        .onAppear { model.loadTailcatClientPublicKey() }
        .confirmationDialog(
            String(localized: "Regenerate the tailcat client key?"),
            isPresented: $confirmRegenerate
        ) {
            Button("Regenerate", role: .destructive) { model.regenerateTailcatClientKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every host's allow list must be updated with the new public key. Tailcat devices reconnect now and are rejected by hosts that still list the old key.")
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Text("herdrm — a native macOS console for herdr.")
                .font(.system(size: 12.5))
            Text("Devices are managed from the switcher in the sidebar footer.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
