import AppKit
import HerdrKit
import SwiftTerm
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
    static let darkBackground = NSColor(
        srgbRed: 0x10 / 255,
        green: 0x10 / 255,
        blue: 0x12 / 255,
        alpha: 1
    )
    static let darkForeground = NSColor(
        srgbRed: 0xD6 / 255,
        green: 0xD6 / 255,
        blue: 0xD6 / 255,
        alpha: 1
    )
    static let lightBackground = NSColor.white
    static let lightForeground = NSColor(
        srgbRed: 0x3A / 255,
        green: 0x3A / 255,
        blue: 0x3A / 255,
        alpha: 1
    )
    static let darkPalette = SwiftTerm.Color.terminalAppColors
    /// Per entry, keep whichever of the original and luminance-flipped color reads
    /// better on the light background: the flip rescues colors designed for dark
    /// backgrounds (white, the bright variants), but ANSI red/blue/magenta/black
    /// are already dark and would wash out to pastels.
    static let lightPalette = darkPalette.map { color in
        let original = (
            red: Int(color.red / 257),
            green: Int(color.green / 257),
            blue: Int(color.blue / 257)
        )
        let flipped = LightTerminalANSIAdapter.lightRGB(
            red: original.red,
            green: original.green,
            blue: original.blue
        )
        let originalContrast = LightTerminalANSIAdapter.contrastOnWhite(
            red: original.red, green: original.green, blue: original.blue
        )
        let flippedContrast = LightTerminalANSIAdapter.contrastOnWhite(
            red: flipped.red, green: flipped.green, blue: flipped.blue
        )
        let chosen = originalContrast >= flippedContrast ? original : flipped
        return SwiftTerm.Color(
            red8: UInt16(chosen.red),
            green8: UInt16(chosen.green),
            blue8: UInt16(chosen.blue)
        )
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
        case .unsupportedItem: return "Remote paste supports regular files, not folders or special files."
        case .imageEncodingFailed: return "The clipboard image could not be encoded as PNG."
        case .transferUnavailable: return "The remote file transfer service is unavailable."
        }
    }
}

/// Sends ESC CR for Shift+Return so agent TUIs insert a line break instead of
/// submitting: legacy terminal encoding sends the same bare `\r` for Enter and
/// Shift+Enter, so the modifier never reaches the TUI. SwiftTerm's `keyDown`
/// and `doCommand` are public, not open, so `interpretKeyEvents` is the only
/// hook a subclass can take — and it only sees Return in legacy mode, leaving
/// this inert when a TUI negotiates the kitty keyboard protocol.
final class LineBreakTerminalView: LocalProcessTerminalView {
    var usesLightColors = false
    var appliedDarkAppearance: Bool?
    private var lightColorAdapter = LightTerminalANSIAdapter()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // SwiftTerm drops the selection on every chunk of output and on every
        // linefeed while mouse reporting is on, so a selection made while an
        // agent is streaming vanishes as fast as it is made. Parking mouse
        // reporting for the feed is SwiftTerm's own "preserve the selection"
        // path; output is delivered on the main thread, like mouse events, so
        // nothing can observe the parked flag.
        let saved = allowMouseReporting
        allowMouseReporting = false
        defer { allowMouseReporting = saved }
        guard usesLightColors else {
            super.dataReceived(slice: slice)
            return
        }
        let transformed = lightColorAdapter.transform(slice)
        if !transformed.isEmpty {
            feed(byteArray: transformed[...])
        }
    }

    // Dragging always selects text locally, like a native text view. With mouse
    // reporting on, SwiftTerm forwards every mouse event to the process, leaving
    // no way to select or copy anything. Clicks and the wheel still go through:
    // a local shell app acts on them, while `herdr agent attach` (0.8.0) only
    // ever forwards the wheel to the pane app and swallows button presses. Drags
    // (and Shift/double/triple clicks, which only mean selection) are kept local
    // by parking mouse reporting for the event.
    private func withLocalSelection(_ event: NSEvent, _ forward: (NSEvent) -> Void) {
        let saved = allowMouseReporting
        allowMouseReporting = false
        forward(event)
        allowMouseReporting = saved
    }

    private func isSelectionGesture(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
            || event.clickCount > 1
    }

    override func mouseDown(with event: NSEvent) {
        // A plain click deactivates any selection. SwiftTerm's own branch for
        // that is unreachable while mouse reporting forwards the click, so do
        // it here — then let the click reach the TUI as usual.
        if !isSelectionGesture(event), selection.active {
            selection.selectNone()
            needsDisplay = true
        }
        if isSelectionGesture(event) {
            withLocalSelection(event) { super.mouseDown(with: $0) }
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        withLocalSelection(event) { super.mouseDragged(with: $0) }
    }

    override func mouseUp(with event: NSEvent) {
        if isSelectionGesture(event) {
            withLocalSelection(event) { super.mouseUp(with: $0) }
        } else {
            super.mouseUp(with: event)
        }
    }

    // Right-click context menu. SwiftTerm's link lookup is internal, so link
    // items key off the selected text instead — a double-click selects a whole
    // URL, which pairs naturally with right-click.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if selection.active {
            menu.addItem(makeItem("Copy", #selector(NSText.copy(_:))))
            if let url = Self.firstURL(in: selection.getSelectedText()) {
                menu.addItem(.separator())
                let open = makeItem("Open Link", #selector(openLinkFromMenu(_:)))
                open.representedObject = url
                menu.addItem(open)
                let copyLink = makeItem("Copy Link Address", #selector(copyLinkFromMenu(_:)))
                copyLink.representedObject = url
                menu.addItem(copyLink)
            }
            menu.addItem(.separator())
        }
        menu.addItem(makeItem("Paste", #selector(NSText.paste(_:))))
        menu.addItem(makeItem("Select All", #selector(NSText.selectAll(_:))))
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

    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        if let fileURLs = Self.fileURLs(in: pasteboard), !fileURLs.isEmpty {
            let action = AgentAttachmentDeliveryPolicy.action(
                capabilities: attachmentCapabilities,
                deviceKind: attachmentDeviceKind,
                source: .files(allImages: fileURLs.allSatisfy(Self.isImageFile))
            )
            handleFilePaste(action: action, fileURLs: fileURLs, sender: sender)
            return
        }

        guard Self.containsImageData(in: pasteboard) else {
            super.paste(sender)
            return
        }

        let action = AgentAttachmentDeliveryPolicy.action(
            capabilities: attachmentCapabilities,
            deviceKind: attachmentDeviceKind,
            source: .imageData
        )
        switch action {
        case .unsupported:
            super.paste(sender)
        case .nativeClipboard:
            forwardNativeClipboardPaste()
        case .devicePaths(let pathSyntax):
            do {
                guard let files = try Self.clipboardFiles(in: pasteboard) else {
                    super.paste(sender)
                    return
                }
                enqueuePathPaste(files, pathSyntax: pathSyntax)
            } catch {
                reportAttachmentError(error)
            }
        }
    }

    private func handleFilePaste(
        action: AgentAttachmentDeliveryAction,
        fileURLs: [URL],
        sender: Any
    ) {
        switch action {
        case .unsupported:
            super.paste(sender)
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

    private func forwardNativeClipboardPaste() {
        guard let controlV = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "\u{16}",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ) else {
            let bytes: [UInt8] = [0x16]
            send(source: self, data: bytes[...])
            return
        }
        super.keyDown(with: controlV)
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

    private func sendPastedText(_ text: String) {
        if terminal.bracketedPasteMode {
            let start = Array("\u{1B}[200~".utf8)
            send(source: self, data: start[...])
        }
        let bytes = Array(text.utf8)
        send(source: self, data: bytes[...])
        if terminal.bracketedPasteMode {
            let end = Array("\u{1B}[201~".utf8)
            send(source: self, data: end[...])
        }
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

/// Puts the keyboard in a specific terminal, one runloop pass later so it lands after
/// AppKit has finished its own first-responder bookkeeping for the current event.
func focusTerminal(_ view: LocalProcessTerminalView?) {
    DispatchQueue.main.async {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

/// Hands the keyboard back to whichever terminal is left after a split closes. The
/// shell view that held first responder is gone by then, and AppKit falls back to the
/// window itself, which reads as a dead keyboard until the user clicks.
func focusRemainingTerminal() {
    DispatchQueue.main.async {
        guard let window = NSApp.keyWindow,
              let terminal = window.contentView?.firstTerminalDescendant()
        else { return }
        // Only fill a focus vacuum. If the shell died on its own while the user was
        // typing in the sidebar filter or in Search, that field is still first
        // responder and yanking the keyboard into a live agent session is worse than
        // doing nothing.
        guard window.firstResponder === window else { return }
        window.makeFirstResponder(terminal)
    }
}

private extension NSView {
    func firstTerminalDescendant() -> LocalProcessTerminalView? {
        if let terminal = self as? LocalProcessTerminalView { return terminal }
        for subview in subviews {
            if let found = subview.firstTerminalDescendant() { return found }
        }
        return nil
    }
}

/// Embeds a SwiftTerm terminal running `herdr agent attach` (directly or over ssh).
struct AttachTerminalView: NSViewRepresentable {
    let device: Device
    let paneID: String
    /// The device's herdr server version, so attach picks a matching CLI binary.
    var serverVersion: String?
    /// nil when the server or active manifest does not advertise attachment support.
    let attachmentCapabilities: AgentAttachmentCapabilities?
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    /// macOS font smoothing dilates glyph stems, which reads as fake bold at
    /// terminal sizes. Off is SwiftTerm's `fontSmoothing = false` — iTerm2's
    /// "Thin strokes".
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
    var onViewReady: ((LocalProcessTerminalView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LineBreakTerminalView(frame: .zero)
        configurePasteHandling(view)
        view.processDelegate = context.coordinator
        context.coordinator.onExit = onExit
        configureAppearance(view)

        let service = HerdrService(device: device)
        view.attachmentService = service
        let command = service.attachCommand(paneID: paneID, serverVersion: serverVersion)
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

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if let view = nsView as? LineBreakTerminalView {
            configurePasteHandling(view)
        }
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

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        // A view being torn down must not report its own terminate() as an exit.
        coordinator.onExit = nil
        nsView.terminate()
    }

    private func configureAppearance(_ view: LocalProcessTerminalView) {
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

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var authorizationID: UUID?
        var onExit: ((Int32?) -> Void)?

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
            let callback = onExit
            onExit = nil  // report once
            DispatchQueue.main.async { callback?(exitCode) }
        }
    }
}

func applyTerminalAppearance(
    _ view: LocalProcessTerminalView,
    fontName: String, fontSize: Double, thinStrokes: Bool,
    fontWeight: Double, lineSpacing: Double, dark: Bool, mouseReporting: Bool
) {
    let font = TerminalDefaults.font(name: fontName, size: fontSize, weight: fontWeight)
    if view.font != font {
        view.font = font
    }
    view.allowMouseReporting = mouseReporting
    // Compared against the inverted value on purpose: thinStrokes on means
    // smoothing off. The setter only stores the flag, so repaint by hand.
    if view.fontSmoothing == thinStrokes {
        view.fontSmoothing = !thinStrokes
        view.needsDisplay = true
    }
    // This setter calls resetFont(), which recomputes metrics and resizes the
    // terminal, so it is only assigned when it actually changes.
    if view.lineSpacing != CGFloat(lineSpacing) {
        view.lineSpacing = CGFloat(lineSpacing)
    }
    // Everything below is theme-only and returns early; keep font work above it.
    guard let view = view as? LineBreakTerminalView,
          view.appliedDarkAppearance != dark
    else { return }
    view.appliedDarkAppearance = dark
    view.usesLightColors = !dark
    view.nativeBackgroundColor = dark ? TerminalDefaults.darkBackground : TerminalDefaults.lightBackground
    view.nativeForegroundColor = dark ? TerminalDefaults.darkForeground : TerminalDefaults.lightForeground
    view.installColors(dark ? TerminalDefaults.darkPalette : TerminalDefaults.lightPalette)
    view.needsDisplay = true
}

/// A local login shell, side by side with the agent attach — no herdr pane and no
/// attachment paste. It does take first responder when it appears, so splitting hands the
/// keyboard to the new shell; closing the split gives it back via `focusRemainingTerminal`.
/// Standalone shell views stay in the hierarchy while deselected (a local shell
/// has no server side to reattach to), so re-selecting one needs a way to hand
/// it the keyboard again — the registry maps session ids to their live views.
@MainActor
enum ShellViewRegistry {
    private struct WeakView { weak var view: LocalProcessTerminalView? }
    private static var views: [UUID: WeakView] = [:]

    static func register(_ view: LocalProcessTerminalView, for id: UUID) {
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
    var onViewReady: ((LocalProcessTerminalView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LineBreakTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        context.coordinator.onExit = onExit
        context.coordinator.sessionID = sessionID
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

        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("LANG=en_US.UTF-8")
        view.startProcess(
            executable: "/bin/sh",
            args: ["-c", "cd \"$HOME\"; exec \"${SHELL:-/bin/zsh}\" -l"],
            environment: environment
        )
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

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
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

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.onExit = nil
        if let sessionID = coordinator.sessionID {
            ShellViewRegistry.unregister(sessionID)
        }
        let shellPid = nsView.process?.shellPid ?? 0
        nsView.terminate()
        // terminate() sends SIGTERM, which interactive shells ignore — a closed
        // split left a live orphaned zsh, not the expected zombie. SIGHUP is the
        // "terminal went away" signal shells exit on; reap it, escalating to
        // SIGKILL if something (a stuck foreground job) holds the shell up.
        guard shellPid > 0 else { return }
        kill(shellPid, SIGHUP)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<20 {
                if waitpid(shellPid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(shellPid, SIGKILL)
            waitpid(shellPid, &status, 0)
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: ((Int32?) -> Void)?
        var sessionID: UUID?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let callback = onExit
            onExit = nil  // report once
            DispatchQueue.main.async { callback?(exitCode) }
        }
    }
}
