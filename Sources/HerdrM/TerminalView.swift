import AppKit
import GhosttyTerminal
import HerdrKit
import SwiftUI
import UniformTypeIdentifiers

enum TerminalDefaults {
    static let fontNameKey = "terminal.fontName"   // "" = system monospaced
    static let fontSizeKey = "terminal.fontSize"
    static let thinStrokesKey = "terminal.thinStrokes"
    static let fontWeightKey = "terminal.fontWeight"
    static let lineSpacingKey = "terminal.lineSpacing"
    static let defaultFontSize: Double = 12.5
    /// `NSFont.Weight` rawValue; 0 is `.regular`. Only the system monospaced font
    /// has selectable weights — named families ship fixed faces and ignore this.
    static let defaultFontWeight: Double = 0
    static let defaultLineSpacing: Double = 1.0
    static let darkBackgroundHex = "#101012"
    static let darkForegroundHex = "#D6D6D6"
    static let lightBackgroundHex = "#FFFFFF"
    static let lightForegroundHex = "#3A3A3A"

    /// The 16-color ANSI palette used by Apple's Terminal.app (formerly
    /// `SwiftTerm.Color.terminalAppColors`, inlined with the renderer switch).
    static let darkPalette: [(red: Int, green: Int, blue: Int)] = [
        (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
        (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
        (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
        (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
    ]

    /// Per entry, keep whichever of the original and luminance-flipped color reads
    /// better on the light background: the flip rescues colors designed for dark
    /// backgrounds (white, the bright variants), but ANSI red/blue/magenta/black
    /// are already dark and would wash out to pastels.
    static let lightPalette: [(red: Int, green: Int, blue: Int)] = darkPalette.map { color in
        let flipped = LightTerminalANSIAdapter.lightRGB(
            red: color.red,
            green: color.green,
            blue: color.blue
        )
        let originalContrast = LightTerminalANSIAdapter.contrastOnWhite(
            red: color.red, green: color.green, blue: color.blue
        )
        let flippedContrast = LightTerminalANSIAdapter.contrastOnWhite(
            red: flipped.red, green: flipped.green, blue: flipped.blue
        )
        return originalContrast >= flippedContrast ? color : flipped
    }

    /// Bundled Nerd Font symbols (MIT, github.com/ryanoasis/nerd-fonts), used
    /// as a fallback for the icon glyphs agent TUIs draw.
    static let symbolFallbackFamily = "Symbols Nerd Font Mono"

    /// Registers the bundled symbols font for this process. Call once at launch.
    static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func font(name: String, size: Double, weight: Double = defaultFontWeight) -> NSFont {
        let base: NSFont
        if !name.isEmpty, let custom = NSFont(name: name, size: size) {
            base = custom
        } else {
            base = NSFont.monospacedSystemFont(ofSize: size, weight: NSFont.Weight(weight))
        }
        return withSymbolFallback(base, size: size)
    }

    /// Nerd Font icons live in Unicode's Private Use Area, which CoreText's
    /// default cascade never resolves — agent TUIs like pi's powerfooter came
    /// out as tofu boxes unless the user's chosen terminal font happened to be
    /// a patched Nerd Font. A cascade entry pointing at the bundled symbols
    /// font resolves PUA glyphs for every terminal font; the system cascade
    /// still runs after it, so emoji and CJK fallback stay untouched.
    private static func withSymbolFallback(_ base: NSFont, size: Double) -> NSFont {
        let fallback = NSFontDescriptor(fontAttributes: [.family: symbolFallbackFamily])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? base
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

/// The process-wide Ghostty app object: every terminal surface shares it, so
/// appearance settings land once here instead of per view. Ghostty owns the
/// light/dark switch itself — the theme below carries both palettes and the
/// view forwards the effective appearance.
@MainActor
enum GhosttyRuntime {
    static let controller = TerminalController(
        configSource: .none,
        theme: makeTheme()
    )

    /// Font settings are hot-applied; surfaces pick the change up without a
    /// rebuild, so this runs from every view update — the controller dedupes.
    static func applyFontSettings(fontName: String, fontSize: Double, fontWeight: Double, lineSpacing: Double) {
        controller.setTerminalConfiguration(
            fontConfiguration(fontName: fontName, fontSize: fontSize, fontWeight: fontWeight, lineSpacing: lineSpacing)
        )
    }

    private static func fontConfiguration(
        fontName: String,
        fontSize: Double,
        fontWeight: Double,
        lineSpacing: Double
    ) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontSize(Float(fontSize))
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            // The controller's base config is TerminalConfiguration.default,
            // which enables font-thicken — counter it; fake bold at terminal
            // sizes is what the "thin strokes" default exists to avoid.
            builder.withFontThicken(false)
            // Option-as-Meta: matches what the SwiftTerm embed did, and the
            // readline chords below (⌥⌫ → ESC DEL etc.) assume it.
            builder.withCustom("macos-option-as-alt", "true")
            // HerdrM owns copy only while Ghostty has a local selection. With
            // no local selection, Command-C must reach a mouse-aware pane app.
            builder.withCustom("keybind", "super+c=unbind")
            // Shift is HerdrM's unconditional local-selection escape hatch.
            // Plain TUI gestures have Shift removed before reaching Ghostty,
            // so disabling application shift capture cannot affect them.
            builder.withCustom("mouse-shift-capture", "never")
            if !fontName.isEmpty {
                builder.withFontFamily(fontName)
            } else {
                builder.withFontFamily("SF Mono")
                if let face = fontFaceName(forWeight: fontWeight) {
                    // Weight selection only exists for the system font; named
                    // families ship fixed faces and ignore the picker.
                    builder.withCustom("font-style", face)
                }
            }
            // Nerd Font icons live in Unicode's Private Use Area, which
            // CoreText's default cascade never resolves. A second font-family
            // entry would be Ghostty's fallback list, but Ghostty then derives
            // cell metrics from the symbols font (square advance == line height),
            // wrecking the grid — so the PUA ranges are codepoint-mapped instead.
            builder.withCustom("font-codepoint-map", "U+E000-U+F8FF=\(TerminalDefaults.symbolFallbackFamily)")
            builder.withCustom("font-codepoint-map", "U+F0000-U+FFFFD=\(TerminalDefaults.symbolFallbackFamily)")
            builder.withCustom("font-codepoint-map", "U+100000-U+10FFFD=\(TerminalDefaults.symbolFallbackFamily)")
            if lineSpacing != TerminalDefaults.defaultLineSpacing {
                let percent = Int(((lineSpacing - 1.0) * 100).rounded())
                builder.withCustom("adjust-cell-height", "\(percent)%")
            }
        }
    }

    /// `NSFont.Weight` rawValue → SF Mono face name (Ghostty's `font-style`).
    private static func fontFaceName(forWeight weight: Double) -> String? {
        switch weight {
        case ..<(-0.3): return "Light"
        case ..<0.15: return nil
        case ..<0.27: return "Medium"
        case ..<0.35: return "Semibold"
        case ..<0.5: return "Bold"
        default: return "Heavy"
        }
    }

    private static func makeTheme() -> TerminalTheme {
        let dark = TerminalConfiguration { builder in
            builder.withBackground(TerminalDefaults.darkBackgroundHex)
            builder.withForeground(TerminalDefaults.darkForegroundHex)
            for (index, color) in TerminalDefaults.darkPalette.enumerated() {
                builder.withPalette(index, color: hex(color))
            }
        }
        let light = TerminalConfiguration { builder in
            builder.withBackground(TerminalDefaults.lightBackgroundHex)
            builder.withForeground(TerminalDefaults.lightForegroundHex)
            for (index, color) in TerminalDefaults.lightPalette.enumerated() {
                builder.withPalette(index, color: hex(color))
            }
        }
        return TerminalTheme(light: light, dark: dark)
    }

    private static func hex(_ color: (red: Int, green: Int, blue: Int)) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }
}

/// The child's complete environment: TERM/COLORTERM/LANG plus the few user
/// variables terminal programs expect, with the command's own variables
/// winning. Matches what `Terminal.getEnvironmentVariables` produced for the
/// SwiftTerm embed — the child deliberately does NOT inherit the app's sparse
/// launch environment; HerdrService supplies PATH & friends itself.
private func terminalEnvironment(_ commandEnvironment: [String: String]) -> [String] {
    var environment = ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8"]
    let launch = ProcessInfo.processInfo.environment
    for key in ["LOGNAME", "USER", "DISPLAY", "LC_TYPE", "HOME"] {
        if let value = launch[key] {
            environment.append("\(key)=\(value)")
        }
    }
    for (key, value) in commandEnvironment {
        environment.removeAll { $0.hasPrefix("\(key)=") }
        environment.append("\(key)=\(value)")
    }
    return environment
}

/// Owns the local PTY child and the host-managed Ghostty session that renders
/// it: process output flows through the light-theme ANSI adapter into the
/// surface, and bytes the surface produces (keyboard input, DA/OSC replies)
/// are written to the PTY verbatim.
final class TerminalProcessHost {
    let session: InMemoryTerminalSession
    let process = TerminalProcess()
    /// Guards `lightAdapter`: written on the main thread (theme switch), read on
    /// the process's IO queue.
    private let adapterLock = NSLock()
    private var lightAdapter: LightTerminalANSIAdapter?

    /// Called on the main queue with the child's real exit status.
    var onExit: ((Int32?) -> Void)?

    init() {
        let process = self.process
        session = InMemoryTerminalSession(
            write: { data in process.write(data) },
            resize: { viewport in
                process.resize(
                    columns: viewport.columns,
                    rows: viewport.rows,
                    widthPixels: viewport.widthPixels,
                    heightPixels: viewport.heightPixels
                )
            },
            // Only grid changes reach the PTY; pixel-only updates would just
            // re-report the same winsize.
            suppressesPixelOnlyResizes: true
        )
        process.onOutput = { [weak self] data in self?.receiveOutput(data) }
        process.onExit = { [weak self] code in self?.onExit?(code) }
    }

    func start(command: TerminalCommand) {
        process.start(
            executable: command.executable,
            args: command.args,
            environment: terminalEnvironment(command.environment)
        )
    }

    func terminate() {
        process.terminate()
    }

    /// The light theme rewrites program-emitted colors for contrast on white.
    /// Switching themes installs a fresh adapter so a partial SGR retained at a
    /// chunk boundary cannot prepend stale bytes to the other theme's output.
    func setLightColorsEnabled(_ enabled: Bool) {
        adapterLock.lock()
        lightAdapter = enabled ? LightTerminalANSIAdapter() : nil
        adapterLock.unlock()
    }

    private func receiveOutput(_ data: Data) {
        adapterLock.lock()
        var adapter = lightAdapter
        let bytes = [UInt8](data)
        let transformed = adapter?.transform(bytes[...])
        if adapter != nil { lightAdapter = adapter }
        adapterLock.unlock()

        if let transformed {
            if !transformed.isEmpty {
                session.receive(Data(transformed))
            }
        } else {
            session.receive(data)
        }
    }
}

private struct ClipboardFile: Sendable {
    let localURL: URL
    let removeAfterUpload: Bool
}

private struct PendingAttachmentPaste: Sendable {
    let files: [ClipboardFile]
    let pathSyntax: AgentAttachmentPathSyntax
}

private enum ClipboardFileError: LocalizedError {
    case unsupportedItem
    case imageEncodingFailed
    case transferUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedItem: return String(localized: "Remote paste supports regular files, not folders or special files.")
        case .imageEncodingFailed: return String(localized: "The clipboard image could not be encoded as PNG.")
        case .transferUnavailable: return String(localized: "The remote file transfer service is unavailable.")
        }
    }
}

/// The terminal view: Ghostty's `AppTerminalView` plus herdrm's local behavior.
///
/// Keyboard: Shift+Return sends ESC CR so agent TUIs insert a line break instead
/// of submitting (legacy encoding sends a bare `\r` for both, so the modifier
/// never reaches the TUI), and the ⌘/⌥ text-editing chords send readline bytes —
/// Ghostty / VS Code / iTerm Natural Text Editing. Both go through the session's
/// raw input path, bypassing key translation, and stay local while an IME
/// composition is open.
///
/// Mouse: one side owns each complete gesture. Plain gestures follow Ghostty's
/// negotiated mouse capture and reach the TUI; Shift gestures stay local for
/// terminal selection. Turning Mouse Reporting off also keeps the complete
/// gesture local.
///
/// IME: Ghostty implements `NSTextInputClient` itself and renders the marked
/// text in the grid; the only hook needed here is keeping ⌘/⌃ chords off the
/// PTY while `hasMarkedText()`.
final class LineBreakTerminalView: AppTerminalView {
    /// When false, mouse button events always stay local even if the TUI
    /// requested mouse reporting (Shift bypasses it either way).
    var mouseReportingEnabled = true
    var appliedDarkAppearance: Bool?
    /// The live surface, captured by the coordinator's lifecycle delegate —
    /// `AppTerminalView.surface` is internal, so selection queries come in here.
    weak var attachedSurface: TerminalSurface?
    weak var processHost: TerminalProcessHost?

    /// Fixed at mouse-down so press, motion and release cannot split between
    /// the TUI and Ghostty's local selection.
    private var gestureIsLocal = false
    /// A locally handled Command-C must consume its matching release too;
    /// kitty report-events applications otherwise receive a release-only key.
    private var locallyConsumedCopyKeyCode: UInt16?

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        locallyConsumedCopyKeyCode = nil
        if hasMarkedText() {
            // Command/Control chords must stay with the IME until composition
            // ends; other keys still reach Ghostty so preedit can update.
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command) || modifiers.contains(.control) { return }
            super.keyDown(with: event)
            return
        }
        if let payload = Self.ptyBytes(forMacEditingKey: event) {
            processHost?.session.sendInput(Data(payload.utf8))
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if locallyConsumedCopyKeyCode == event.keyCode {
            locallyConsumedCopyKeyCode = nil
            return
        }
        super.keyUp(with: event)
    }

    /// Mac Delete is Backspace (keyCode 51). ⌥⌘ arrows move split focus and
    /// are left alone; ⌘A/⌘E/⌘W and the other app chords never match here.
    private static func ptyBytes(forMacEditingKey event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandOnly = modifiers.contains(.command)
            && modifiers.isDisjoint(with: [.option, .control])
        let optionOnly = modifiers.contains(.option)
            && modifiers.isDisjoint(with: [.command, .control])

        if commandOnly {
            switch event.keyCode {
            case 51:  return "\u{15}"  // ⌘⌫ → ^U
            case 123: return "\u{01}"  // ⌘← → ^A
            case 124: return "\u{05}"  // ⌘→ → ^E
            case 117: return "\u{0b}"  // ⌘⌦ → ^K
            default: break
            }
        }
        if optionOnly {
            switch event.keyCode {
            case 51:  return "\u{1b}\u{7f}"  // ⌥⌫ → ESC DEL
            case 123: return "\u{1b}b"       // ⌥← → ESC b
            case 124: return "\u{1b}f"       // ⌥→ → ESC f
            case 117: return "\u{1b}d"       // ⌥⌦ → ESC d
            default: break
            }
        }
        if event.keyCode == 36 || event.keyCode == 76,  // Return, keypad Enter
           modifiers.contains(.shift),
           modifiers.isDisjoint(with: [.command, .control, .option]) {
            return "\u{1b}\r"
        }
        return nil
    }

    // MARK: Mouse

    private func isSelectionGesture(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
    }

    private func routedMouseEvent(_ event: NSEvent) -> NSEvent {
        guard isMouseCaptured else { return event }
        return gestureIsLocal
            ? event.addingShiftModifier()
            : event.removingShiftModifier()
    }

    override func mouseDown(with event: NSEvent) {
        gestureIsLocal = !mouseReportingEnabled
            || isSelectionGesture(event)
            || !isMouseCaptured
        super.mouseDown(with: routedMouseEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: routedMouseEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        defer { gestureIsLocal = false }
        super.mouseUp(with: routedMouseEvent(event))
    }

    // MARK: Context menu

    // The right mouse button always opens the context menu and never reaches
    // the TUI. Link items key off the selected text; while mouse reporting is
    // active, Shift-double-click selects a whole URL locally.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func rightMouseUp(with event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        contextMenu()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if attachedSurface?.hasSelection() == true,
           let selection = attachedSurface?.readSelection(),
           !selection.isEmpty {
            menu.addItem(makeItem(String(localized: "Copy"), #selector(copy(_:))))
            if let url = Self.firstURL(in: selection) {
                menu.addItem(.separator())
                let open = makeItem(String(localized: "Open Link"), #selector(openLinkFromMenu(_:)))
                open.representedObject = url
                menu.addItem(open)
                let copyLink = makeItem(String(localized: "Copy Link Address"), #selector(copyLinkFromMenu(_:)))
                copyLink.representedObject = url
                menu.addItem(copyLink)
            }
            menu.addItem(.separator())
        }
        menu.addItem(makeItem(String(localized: "Paste"), #selector(performPaste(_:))))
        menu.addItem(makeItem(String(localized: "Select All"), #selector(selectAll(_:))))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector?.firstMatch(in: text, range: range),
              let url = match.url,
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    // MARK: Paste and attachments

    var attachmentCapabilities: AgentAttachmentCapabilities?
    var attachmentDeviceKind: Device.Kind = .local
    var attachmentService: HerdrService?
    var onAttachmentError: ((String) -> Void)?
    var onAttachmentUploadingChanged: ((Bool) -> Void)?
    private var pendingUploads: [PendingAttachmentPaste] = []
    private var uploadTask: Task<Void, Never>?

    deinit {
        uploadTask?.cancel()
    }

    // ⌘C/⌘V are intercepted here because the app has no Edit menu. Copy stays
    // local only when Ghostty owns a selection; otherwise the physical key is
    // sent to the TUI now that its global copy binding is unbound above.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self
        else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            if attachedSurface?.hasSelection() == true {
                locallyConsumedCopyKeyCode = event.keyCode
                copy(self)
            } else {
                keyDown(with: event)
            }
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            handlePaste()
            return true
        }
        // Ghostty consumes its default bindings before AppKit reaches the menu.
        // Give HerdrM's commands priority over those standalone-terminal actions.
        if modifiers.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // `AppTerminalView`'s own `paste(_:)` is internal and cannot be overridden,
    // so the attachment flow is reached through ⌘V (performKeyEquivalent) and
    // this context-menu action. The app has no Edit menu, so those are the only
    // two paste entry points.
    @objc private func performPaste(_: Any?) {
        handlePaste()
    }

    private func handlePaste() {
        let pasteboard = NSPasteboard.general
        if let fileURLs = Self.fileURLs(in: pasteboard), !fileURLs.isEmpty {
            let action = AgentAttachmentDeliveryPolicy.action(
                capabilities: attachmentCapabilities,
                deviceKind: attachmentDeviceKind,
                source: .files(allImages: fileURLs.allSatisfy(Self.isImageFile))
            )
            handleFilePaste(action: action, fileURLs: fileURLs)
            return
        }

        guard Self.containsImageData(in: pasteboard) else {
            pastePasteboardText()
            return
        }

        let action = AgentAttachmentDeliveryPolicy.action(
            capabilities: attachmentCapabilities,
            deviceKind: attachmentDeviceKind,
            source: .imageData
        )
        switch action {
        case .unsupported:
            pastePasteboardText()
        case .nativeClipboard:
            forwardNativeClipboardPaste()
        case .devicePaths(let pathSyntax):
            do {
                guard let files = try Self.clipboardFiles(in: pasteboard) else {
                    pastePasteboardText()
                    return
                }
                enqueuePathPaste(files, pathSyntax: pathSyntax)
            } catch {
                reportAttachmentError(error)
            }
        }
    }

    private func pastePasteboardText() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        paste(text: text)
    }

    private func handleFilePaste(
        action: AgentAttachmentDeliveryAction,
        fileURLs: [URL]
    ) {
        switch action {
        case .unsupported:
            pastePasteboardText()
        case .nativeClipboard:
            forwardNativeClipboardPaste()
        case .devicePaths(let pathSyntax):
            if case .local = attachmentDeviceKind {
                sendPastedText(fileURLs.map { pathSyntax.format($0.path) }.joined(separator: " "))
                return
            }
            do {
                let files = try Self.clipboardFiles(from: fileURLs)
                enqueuePathPaste(files, pathSyntax: pathSyntax)
            } catch {
                reportAttachmentError(error)
            }
        }
    }

    /// Ask the remote program to paste from its own clipboard with a literal
    /// ^V byte — the "native clipboard" delivery path.
    private func forwardNativeClipboardPaste() {
        processHost?.session.sendInput(Data([0x16]))
    }

    private func enqueuePathPaste(
        _ files: [ClipboardFile],
        pathSyntax: AgentAttachmentPathSyntax
    ) {
        guard let attachmentService else {
            discardTemporaries(in: files)
            reportAttachmentError(ClipboardFileError.transferUnavailable)
            return
        }
        pendingUploads.append(PendingAttachmentPaste(files: files, pathSyntax: pathSyntax))
        guard uploadTask == nil else { return }
        onAttachmentUploadingChanged?(true)
        uploadTask = Task { [weak self] in
            await self?.drainPathPastes(using: attachmentService)
        }
    }

    /// Materializes one paste at a time so paths reach the agent in paste order.
    @MainActor
    private func drainPathPastes(using service: HerdrService) async {
        while !pendingUploads.isEmpty {
            let paste = pendingUploads.removeFirst()
            let files = paste.files
            defer { discardTemporaries(in: files) }
            do {
                var devicePaths: [String] = []
                for file in files {
                    try Task.checkCancellation()
                    devicePaths.append(try await service.stageAttachment(from: file.localURL))
                }
                try Task.checkCancellation()
                sendPastedText(devicePaths.map(paste.pathSyntax.format).joined(separator: " "))
            } catch is CancellationError {
                break
            } catch {
                reportAttachmentError(error)
            }
        }
        pendingUploads.forEach { discardTemporaries(in: $0.files) }
        pendingUploads.removeAll()
        uploadTask = nil
        onAttachmentUploadingChanged?(false)
    }

    private func discardTemporaries(in files: [ClipboardFile]) {
        for file in files where file.removeAfterUpload {
            try? FileManager.default.removeItem(at: file.localURL)
        }
    }

    /// Ghostty's text path wraps the payload in bracketed-paste markers when
    /// the program asked for them.
    private func sendPastedText(_ text: String) {
        paste(text: text)
    }

    private func reportAttachmentError(_ error: Error) {
        onAttachmentError?(error.localizedDescription)
    }

    private static func clipboardFiles(in pasteboard: NSPasteboard) throws -> [ClipboardFile]? {
        if let fileURLs = fileURLs(in: pasteboard), !fileURLs.isEmpty {
            return try clipboardFiles(from: fileURLs)
        }

        guard !hasText(in: pasteboard),
              let image = pasteboard.readObjects(
                  forClasses: [NSImage.self],
                  options: nil
              )?.first as? NSImage
        else {
            return nil
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw ClipboardFileError.imageEncodingFailed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-clipboard", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let localURL = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
        try png.write(to: localURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: localURL.path
        )
        return [ClipboardFile(localURL: localURL, removeAfterUpload: true)]
    }

    private static func clipboardFiles(from fileURLs: [URL]) throws -> [ClipboardFile] {
        try fileURLs.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw ClipboardFileError.unsupportedItem
            }
            return ClipboardFile(localURL: url, removeAfterUpload: false)
        }
    }

    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    private static func containsImageData(in pasteboard: NSPasteboard) -> Bool {
        !hasText(in: pasteboard)
            && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let contentType = values.contentType
        else { return false }
        return contentType.conforms(to: .image)
    }

    /// Keynote, Excel and Preview attach a TIFF snapshot to copied text, so a
    /// pasteboard only counts as an image when it carries no text at all.
    private static func hasText(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSString.self], options: nil)
    }
}

private extension NSEvent {
    func addingShiftModifier() -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: modifierFlags.union(.shift),
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: pressure
        ) ?? self
    }

    func removingShiftModifier() -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: modifierFlags.subtracting(.shift),
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: pressure
        ) ?? self
    }
}

/// Puts the keyboard in a specific terminal, one runloop pass later so it lands after
/// AppKit has finished its own first-responder bookkeeping for the current event.
func focusTerminal(_ view: LineBreakTerminalView?) {
    DispatchQueue.main.async {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

/// Hands the keyboard back to whichever terminal is left after a split closes. The
/// shell view that held first responder is gone by then, and AppKit falls back to the
/// window itself, which reads as a dead keyboard until the user clicks.
///
/// `preferred` is the selected agent's attach view. It matters now that kept-alive
/// attaches stay in the hierarchy while hidden: a blind depth-first search could land
/// on an invisible terminal and strand the keyboard there, so the visible selected one
/// is focused instead.
func focusRemainingTerminal(preferring preferred: LineBreakTerminalView? = nil) {
    DispatchQueue.main.async {
        guard let window = NSApp.keyWindow else { return }
        // Only fill a focus vacuum. If the shell died on its own while the user was
        // typing in the sidebar filter or in Search, that field is still first
        // responder and yanking the keyboard into a live agent session is worse than
        // doing nothing.
        guard window.firstResponder === window else { return }
        guard let terminal = preferred ?? window.contentView?.firstTerminalDescendant()
        else { return }
        window.makeFirstResponder(terminal)
    }
}

private extension NSView {
    func firstTerminalDescendant() -> LineBreakTerminalView? {
        if let terminal = self as? LineBreakTerminalView { return terminal }
        for subview in subviews {
            if let found = subview.firstTerminalDescendant() { return found }
        }
        return nil
    }
}

/// Embeds a Ghostty terminal running a direct agent or ordinary-terminal attach
/// (locally or over SSH).
struct AttachTerminalView: NSViewRepresentable {
    let device: Device
    let target: TerminalAttachTarget
    /// Registry identity (the `AttachedEntry.id`), so the view stays addressable for
    /// focus while kept alive in the background. nil when not tracked.
    var sessionID: String? = nil
    /// The device's herdr server version, so attach picks a matching CLI binary.
    var serverVersion: String?
    /// nil when the server or active manifest does not advertise attachment support.
    let attachmentCapabilities: AgentAttachmentCapabilities?
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    /// No longer maps to anything: Ghostty's renderer has no font-smoothing
    /// toggle. The setting stays so existing preferences keep syncing.
    var thinStrokes: Bool = true
    var fontWeight: Double = TerminalDefaults.defaultFontWeight
    var lineSpacing: Double = TerminalDefaults.defaultLineSpacing
    /// From SwiftUI's environment so theme switches re-render immediately.
    var dark: Bool = false
    /// When false, mouse drags always select text locally even if the TUI
    /// requested mouse reporting (Shift+drag bypasses it either way).
    var mouseReporting: Bool = true
    var onAttachmentError: (String) -> Void = { _ in }
    var onAttachmentUploadingChanged: (Bool) -> Void = { _ in }
    /// Called on the main queue when the attach process exits: the pane was taken
    /// over by another client, the SSH connection dropped, or herdr went away. A
    /// dead session otherwise keeps its last frame and silently eats every
    /// keystroke, which reads as a freeze.
    var onExit: ((Int32?) -> Void)? = nil
    /// Delivers the created view so a focus tracker can observe its window's
    /// first responder without retaining the terminal itself.
    var onViewReady: ((LineBreakTerminalView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LineBreakTerminalView {
        let host = TerminalProcessHost()
        let view = LineBreakTerminalView(frame: .zero)
        view.processHost = host
        configurePasteHandling(view)
        context.coordinator.view = view
        context.coordinator.host = host
        context.coordinator.sessionID = sessionID
        context.coordinator.onExit = onExit
        host.onExit = { [weak coordinator = context.coordinator] code in
            coordinator?.processDidExit(code)
        }
        view.delegate = context.coordinator
        view.controller = GhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
        configureAppearance(view)

        let service = HerdrService(device: device)
        view.attachmentService = service
        let command = service.attachCommand(target: target, serverVersion: serverVersion)
        context.coordinator.authorizationID = command.authorizationID
        context.coordinator.scheduleAuthorizationCleanup()
        host.start(command: command)
        if let sessionID {
            AttachViewRegistry.register(view, for: sessionID)
        }
        // SwiftUI throws this view away and builds a new one whenever the selected
        // agent changes (the `.id("attach-…")` in ContentView), and a fresh NSView is
        // never first responder — so keystrokes went nowhere until the user clicked.
        // The hop to the next runloop pass is required: while `makeNSView` runs the
        // view has no `window` yet.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: LineBreakTerminalView, context: Context) {
        configurePasteHandling(nsView)
        context.coordinator.onExit = onExit
        configureAppearance(nsView)
    }

    /// Re-applied on update because capabilities can arrive after the terminal
    /// view is created, without changing its identity.
    private func configurePasteHandling(_ view: LineBreakTerminalView) {
        view.attachmentCapabilities = attachmentCapabilities
        view.attachmentDeviceKind = device.kind
        view.onAttachmentError = onAttachmentError
        view.onAttachmentUploadingChanged = onAttachmentUploadingChanged
    }

    static func dismantleNSView(_ nsView: LineBreakTerminalView, coordinator: Coordinator) {
        // A view being torn down must not report its own teardown as an exit.
        coordinator.onExit = nil
        if let sessionID = coordinator.sessionID {
            AttachViewRegistry.unregister(sessionID)
        }
        coordinator.host?.terminate()
    }

    private func configureAppearance(_ view: LineBreakTerminalView) {
        applyTerminalAppearance(
            view,
            fontName: fontName,
            fontSize: fontSize,
            thinStrokes: thinStrokes,
            fontWeight: fontWeight,
            lineSpacing: lineSpacing,
            dark: dark,
            mouseReporting: mouseReporting
        )
    }

    final class Coordinator: NSObject, TerminalSurfaceLifecycleDelegate {
        /// Written on the main actor; read from `deinit`, which is nonisolated.
        nonisolated(unsafe) var authorizationID: UUID?
        var sessionID: String?
        var onExit: ((Int32?) -> Void)?
        weak var view: LineBreakTerminalView?
        var host: TerminalProcessHost?

        deinit {
            if let authorizationID {
                try? SSHCredentialStore.removeAuthorization(authorizationID)
            }
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

        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            view?.attachedSurface = surface
        }

        func terminalDidDetachSurface() {
            view?.attachedSurface = nil
        }

        func processDidExit(_ code: Int32?) {
            discardAuthorization()
            let callback = onExit
            onExit = nil  // report once
            callback?(code)
        }
    }
}

@MainActor
func applyTerminalAppearance(
    _ view: LineBreakTerminalView,
    fontName: String, fontSize: Double, thinStrokes _: Bool,
    fontWeight: Double, lineSpacing: Double, dark: Bool, mouseReporting: Bool
) {
    GhosttyRuntime.applyFontSettings(
        fontName: fontName,
        fontSize: fontSize,
        fontWeight: fontWeight,
        lineSpacing: lineSpacing
    )
    view.mouseReportingEnabled = mouseReporting
    // Colors are theme-only; keep the rest above this early return.
    guard view.appliedDarkAppearance != dark else { return }
    view.appliedDarkAppearance = dark
    view.processHost?.setLightColorsEnabled(!dark)
}

/// A kept-alive agent/terminal attach, registered by its `AttachedEntry.id`. Unlike a
/// standalone shell, an attached pane's view stays in the hierarchy (hidden) when
/// deselected so its content survives a switch away and back; the registry lets focus
/// commands and the split focus tracker resolve the currently selected entry's view.
///
/// Lock-guarded rather than actor-isolated: register/unregister run on the main thread
/// (make/dismantleNSView), but `liveViews` is also read from `SplitFocusTracker`'s KVO
/// callbacks, which are nonisolated even though AppKit delivers them on the main thread.
enum AttachViewRegistry {
    private struct WeakView { weak var view: LineBreakTerminalView? }
    private static let lock = NSLock()
    private static var views: [String: WeakView] = [:]

    static func register(_ view: LineBreakTerminalView, for id: String) {
        lock.lock()
        views[id] = WeakView(view: view)
        lock.unlock()
    }

    static func unregister(_ id: String) {
        lock.lock()
        views[id] = nil
        lock.unlock()
    }

    static func view(for id: String) -> LineBreakTerminalView? {
        lock.lock()
        defer { lock.unlock() }
        return views[id]?.view
    }

    /// Every live attach view. Only the selected one is visible/focusable, so "the
    /// responder is inside any of these" is equivalent to "the agent side has focus".
    static var liveViews: [LineBreakTerminalView] {
        lock.lock()
        defer { lock.unlock() }
        return views.values.compactMap { $0.view }
    }

    static func focus(_ id: String) {
        DispatchQueue.main.async {
            guard let view = view(for: id), let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

/// A standalone local or SSH login shell, or the local login shell beside an
/// agent attach. Standalone views stay alive while deselected, so re-selecting
/// one uses the registry to restore keyboard focus.
@MainActor
enum ShellViewRegistry {
    private struct WeakView { weak var view: LineBreakTerminalView? }
    private static var views: [UUID: WeakView] = [:]

    static func register(_ view: LineBreakTerminalView, for id: UUID) {
        views[id] = WeakView(view: view)
    }

    static func unregister(_ id: UUID) {
        views[id] = nil
    }

    static func focus(_ id: UUID) {
        DispatchQueue.main.async {
            guard let view = views[id]?.view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

struct ShellTerminalView: NSViewRepresentable {
    /// Session identity for the registry; nil for the ⌘D split shell.
    var sessionID: UUID?
    var device: Device = .local
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    var thinStrokes: Bool = true
    var fontWeight: Double = TerminalDefaults.defaultFontWeight
    var lineSpacing: Double = TerminalDefaults.defaultLineSpacing
    var dark: Bool = false
    var mouseReporting: Bool = true
    var onExit: ((Int32?) -> Void)? = nil
    /// Delivers the created view so a focus tracker can observe its window's
    /// first responder without retaining the terminal itself.
    var onViewReady: ((LineBreakTerminalView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LineBreakTerminalView {
        let host = TerminalProcessHost()
        let view = LineBreakTerminalView(frame: .zero)
        view.processHost = host
        context.coordinator.view = view
        context.coordinator.host = host
        context.coordinator.onExit = onExit
        context.coordinator.sessionID = sessionID
        host.onExit = { [weak coordinator = context.coordinator] code in
            coordinator?.processDidExit(code)
        }
        view.delegate = context.coordinator
        view.controller = GhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
        applyTerminalAppearance(
            view,
            fontName: fontName,
            fontSize: fontSize,
            thinStrokes: thinStrokes,
            fontWeight: fontWeight,
            lineSpacing: lineSpacing,
            dark: dark,
            mouseReporting: mouseReporting
        )

        let command = HerdrService(device: device, autoStartLocalServer: false)
            .terminalCommand()
        context.coordinator.authorizationID = command.authorizationID
        context.coordinator.scheduleAuthorizationCleanup()
        host.start(command: command)
        if let sessionID {
            ShellViewRegistry.register(view, for: sessionID)
        }
        // Opening a shell hands it the keyboard: `makeNSView` runs once per shell
        // (the `.id` is stable across theme changes), so this never steals focus
        // back afterwards. The hop to the next runloop pass is required — the
        // view has no `window` yet while this runs.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: LineBreakTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        applyTerminalAppearance(
            nsView,
            fontName: fontName,
            fontSize: fontSize,
            thinStrokes: thinStrokes,
            fontWeight: fontWeight,
            lineSpacing: lineSpacing,
            dark: dark,
            mouseReporting: mouseReporting
        )
    }

    static func dismantleNSView(_ nsView: LineBreakTerminalView, coordinator: Coordinator) {
        coordinator.onExit = nil
        coordinator.discardAuthorization()
        if let sessionID = coordinator.sessionID {
            ShellViewRegistry.unregister(sessionID)
        }
        // terminate() sends SIGHUP and escalates to SIGKILL — see
        // TerminalProcess.terminate for why SIGTERM is not enough.
        coordinator.host?.terminate()
    }

    final class Coordinator: NSObject, TerminalSurfaceLifecycleDelegate {
        var onExit: ((Int32?) -> Void)?
        var sessionID: UUID?
        /// Written on the main actor; read from `deinit`, which is nonisolated.
        nonisolated(unsafe) var authorizationID: UUID?
        weak var view: LineBreakTerminalView?
        var host: TerminalProcessHost?

        deinit {
            if let authorizationID {
                try? SSHCredentialStore.removeAuthorization(authorizationID)
            }
        }

        func scheduleAuthorizationCleanup() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.discardAuthorization()
            }
        }

        func discardAuthorization() {
            guard let authorizationID else { return }
            try? SSHCredentialStore.removeAuthorization(authorizationID)
            self.authorizationID = nil
        }

        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            view?.attachedSurface = surface
        }

        func terminalDidDetachSurface() {
            view?.attachedSurface = nil
        }

        func processDidExit(_ code: Int32?) {
            discardAuthorization()
            let callback = onExit
            onExit = nil  // report once
            callback?(code)
        }
    }
}
