import AppKit
import HerdrKit
import SwiftTerm
import SwiftUI

enum TerminalDefaults {
    static let fontNameKey = "terminal.fontName"   // "" = system monospaced
    static let fontSizeKey = "terminal.fontSize"
    static let defaultFontSize: Double = 12.5

    static func font(name: String, size: Double) -> NSFont {
        if !name.isEmpty, let custom = NSFont(name: name, size: size) {
            return custom
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Fixed-pitch font families available on this Mac, for the settings picker.
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }
}

/// Sends ESC CR for Shift+Return so agent TUIs insert a line break instead of
/// submitting: legacy terminal encoding sends the same bare `\r` for Enter and
/// Shift+Enter, so the modifier never reaches the TUI. SwiftTerm's `keyDown`
/// and `doCommand` are public, not open, so `interpretKeyEvents` is the only
/// hook a subclass can take — and it only sees Return in legacy mode, leaving
/// this inert when a TUI negotiates the kitty keyboard protocol.
final class LineBreakTerminalView: LocalProcessTerminalView {
    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        if eventArray.count == 1,
           let event = eventArray.first,
           event.type == .keyDown,
           event.keyCode == 36 || event.keyCode == 76,  // Return, keypad Enter
           !hasMarkedText() {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.shift),
               modifiers.isDisjoint(with: [.command, .control, .option]) {
                send(txt: "\u{1b}\r")
                return
            }
        }
        super.interpretKeyEvents(eventArray)
    }
}

/// Embeds a SwiftTerm terminal running `herdr agent attach` (directly or over ssh).
struct AttachTerminalView: NSViewRepresentable {
    let device: Device
    let paneID: String
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    /// From SwiftUI's environment so theme switches re-render immediately.
    var dark: Bool = false
    /// When false, mouse drags always select text locally even if the TUI
    /// requested mouse reporting (Shift+drag bypasses it either way).
    var mouseReporting: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LineBreakTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        configureAppearance(view)

        let service = HerdrService(device: device)
        let command = service.attachCommand(paneID: paneID)
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("LANG=en_US.UTF-8")
        for (key, value) in command.environment {
            environment.removeAll { $0.hasPrefix("\(key)=") }
            environment.append("\(key)=\(value)")
        }
        context.coordinator.authorizationID = command.authorizationID
        context.coordinator.scheduleAuthorizationCleanup()
        view.startProcess(
            executable: command.executable,
            args: command.args,
            environment: environment
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        configureAppearance(nsView)
    }

    private func configureAppearance(_ view: LocalProcessTerminalView) {
        let font = TerminalDefaults.font(name: fontName, size: fontSize)
        if view.font != font {
            view.font = font
        }
        view.allowMouseReporting = mouseReporting
        let background: NSColor = dark
            ? NSColor(srgbRed: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
            : .white
        let foreground: NSColor = dark
            ? NSColor(srgbRed: 0xD6 / 255, green: 0xD6 / 255, blue: 0xD6 / 255, alpha: 1)
            : NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3A / 255, alpha: 1)
        if view.nativeBackgroundColor != background {
            view.nativeBackgroundColor = background
            view.nativeForegroundColor = foreground
            view.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var authorizationID: UUID?

        deinit {
            discardAuthorization()
        }

        func scheduleAuthorizationCleanup() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.discardAuthorization()
            }
        }

        private func discardAuthorization() {
            guard let authorizationID else { return }
            try? SSHCredentialStore.removeAuthorization(authorizationID)
            self.authorizationID = nil
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            discardAuthorization()
        }
    }
}
