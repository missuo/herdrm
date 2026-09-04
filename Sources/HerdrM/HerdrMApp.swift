import AppKit
import Darwin
import HerdrKit
import Sparkle
import SwiftTerm
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

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }

    var splitAxis: SplitAxis? {
        get { self[SplitAxisFocusedValueKey.self] }
        set { self[SplitAxisFocusedValueKey.self] = newValue }
    }
}

@main
struct HerdrMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("app.theme") private var themePreference = "system"
    @FocusedValue(\.appModel) private var focusedModel
    @FocusedValue(\.splitAxis) private var focusedSplitAxis

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

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }

            CommandMenu("Terminal") {
                // Guarded on selectedAttachedEntry, not just on the model: with the placeholder
                // on screen there is no SplitContainer to render into, so a split would
                // be invisible yet leave shellSplitAxis non-nil — and the next ⌘W would
                // "close" that phantom instead of the window.
                Button("Split Vertically") { focusedModel?.shellSplitAxis = .vertical }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(focusedModel?.selectedAttachedEntry == nil)
                Button("Split Horizontally") { focusedModel?.shellSplitAxis = .horizontal }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(focusedModel?.selectedAttachedEntry == nil)

                Divider()

                // Eight items with FIXED shortcuts, enabled per axis — deliberately not
                // four items whose shortcut follows the axis. Measured: `.disabled` IS
                // revalidated when the menu opens, but a key equivalent already registered
                // in the NSMenu is NOT reassigned when the commands body re-evaluates, so
                // the arrows stayed frozen on the axis that was current at launch.
                // Labels name the direction so no two rows read the same.
                //
                // Focus is directional and idempotent: the left/top pane is always the
                // agent, the right/bottom one always the shell.
                Button("Focus Left Pane") {
                    if let model = focusedModel { focusSplitSide(.agent, in: model) }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(focusedSplitAxis != .vertical)
                Button("Focus Right Pane") {
                    if let model = focusedModel { focusSplitSide(.shell, in: model) }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(focusedSplitAxis != .vertical)
                Button("Focus Top Pane") {
                    if let model = focusedModel { focusSplitSide(.agent, in: model) }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(focusedSplitAxis != .horizontal)
                Button("Focus Bottom Pane") {
                    if let model = focusedModel { focusSplitSide(.shell, in: model) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(focusedSplitAxis != .horizontal)

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
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420)
    }
}

struct AgentsSettingsView: View {
    var model: AppModel
    @State private var drafts: [String: String] = AgentBinaryOverrides.load()

    /// Kinds the picker knows how to start. The lookup command is `kind`,
    /// except Cursor which installs as `cursor-agent`.
    private static let kinds: [(kind: String, label: String, hint: String)] = [
        ("claude", "Claude", "claude"),
        ("codex", "Codex", "codex"),
        ("cursor", "Cursor", "cursor-agent"),
        ("gemini", "Gemini", "gemini"),
        ("grok", "Grok", "grok"),
        ("kimi", "Kimi", "kimi"),
        ("opencode", "OpenCode", "opencode"),
        ("pi", "Pi", "pi"),
        ("omp", "Oh My Pi", "omp"),
        ("copilot", "Copilot", "copilot"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.kinds, id: \.kind) { row in
                    TextField(row.label, text: binding(row.kind), prompt: Text("Automatic"))
                        .font(.system(size: 12).monospaced())
                        .help(String(localized: "Command or path for \(row.hint). Leave empty to detect."))
                }
            } footer: {
                Text("Finder-launched apps don’t inherit your terminal PATH. herdrm captures it once from a login + interactive shell, then looks up these names. A path here is an escape hatch when detection picks the wrong binary.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear { drafts = AgentBinaryOverrides.load() }
        .onChange(of: drafts) { _, _ in commit() }
        .onDisappear(perform: commit)
        .onSubmit(commit)
    }

    private func commit() {
        AgentBinaryOverrides.save(drafts)
        model.reloadAgentCatalog(deviceID: Device.local.id)
    }

    private func binding(_ kind: String) -> Binding<String> {
        Binding(
            get: { drafts[kind] ?? "" },
            set: { drafts[kind] = $0 }
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
                        Text("Turns off macOS font smoothing, which thickens glyph stems and makes agent output — Claude Code's bold text especially — look heavy and smudged.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $mouseReporting) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mouse reporting")
                        Text("Forwards clicks and drags to TUI apps that ask for them. Turn off to always select text with the mouse — Shift-drag selects either way.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button("Reset to Defaults") {
                    fontName = ""
                    fontSize = TerminalDefaults.defaultFontSize
                    fontWeight = TerminalDefaults.defaultFontWeight
                    lineSpacing = TerminalDefaults.defaultLineSpacing
                    thinStrokes = true
                    mouseReporting = true
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
}

struct AppearanceSettingsView: View {
    @AppStorage("app.theme") private var themePreference = "system"
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

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

            Picker("Language", selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(verbatim: option.displayName).tag(option.rawValue)
                }
            }
            .onChange(of: language) { _, newValue in
                AppLanguage.apply(AppLanguage(rawValue: newValue) ?? .system)
            }
            // Changing AppleLanguages only takes effect on the next process start.
            Text("Changing language takes effect after you quit and reopen herdrm.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
