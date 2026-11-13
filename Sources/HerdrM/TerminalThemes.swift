import AppKit
import GhosttyTheme
import HerdrKit
import SwiftUI

/// Terminal color themes (issue #77). The stored selection is a string:
/// `""` is HerdrM's own palette, which follows the app's light/dark appearance;
/// otherwise a source prefix and a theme name:
/// - `builtin:<name>` — libghostty-spm's catalog (iTerm2-Color-Schemes' Ghostty exports)
/// - `ghostty:<name>` — a file in the user's `~/.config/ghostty/themes/`
/// - `custom:<name>` — a file imported into Application Support/HerdrM/Themes
///
/// A chosen theme is one palette for both appearances, as in Ghostty with a
/// single `theme = …`.
enum TerminalThemeID {
    static let defaultsKey = "terminal.theme"
    static let `default` = ""

    enum Source: String, CaseIterable {
        case custom, ghostty, builtin
    }

    static func make(_ source: Source, _ name: String) -> String { "\(source.rawValue):\(name)" }

    static func parse(_ id: String) -> (source: Source, name: String)? {
        guard let colon = id.firstIndex(of: ":"),
              let source = Source(rawValue: String(id[..<colon]))
        else { return nil }
        let name = String(id[id.index(after: colon)...])
        return name.isEmpty ? nil : (source, name)
    }
}

/// One selectable theme: its stored id and colors.
struct TerminalThemeEntry: Identifiable, Hashable {
    let id: String
    let source: TerminalThemeID.Source
    let definition: GhosttyThemeDefinition
    var name: String { definition.name }
}

/// Resolves stored theme ids to colors. Every terminal view update asks for the
/// active theme, so lookups are cached; file-backed themes are read once and the
/// cache is dropped when the set of files changes (import, remove).
enum TerminalThemeLibrary {
    /// Read from SwiftUI bodies and from `Theme`, which isn't actor-bound.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: GhosttyThemeDefinition?] = [:]
    private static let builtInByName: [String: GhosttyThemeDefinition] = Dictionary(
        GhosttyThemeCatalog.allThemes.map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// Test seams: tests point these at temporary directories so they never
    /// read or write the user's real theme folders.
    nonisolated(unsafe) static var customDirectoryOverride: URL?
    nonisolated(unsafe) static var ghosttyDirectoryOverride: URL?

    /// Application Support/HerdrM/Themes — where imported theme files live.
    static var customDirectory: URL {
        customDirectoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM/Themes", isDirectory: true)
    }

    /// Ghostty's own user themes directory, honoring `XDG_CONFIG_HOME` like
    /// `GhosttyConfigImporter`. Not TCC-protected (see #87).
    static var ghosttyDirectory: URL {
        if let ghosttyDirectoryOverride { return ghosttyDirectoryOverride }
        let environment = ProcessInfo.processInfo.environment
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("ghostty/themes", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/ghostty/themes", isDirectory: true)
    }

    static func directory(for source: TerminalThemeID.Source) -> URL? {
        switch source {
        case .custom: customDirectory
        case .ghostty: ghosttyDirectory
        case .builtin: nil
        }
    }

    /// The theme a stored id names; nil for the default palette and for an id
    /// whose theme is gone (a removed file), which then falls back to the default.
    static func definition(for id: String) -> GhosttyThemeDefinition? {
        guard !id.isEmpty else { return nil }
        lock.lock()
        let cached = cache[id]
        lock.unlock()
        if let cached { return cached }
        let resolved = resolve(id)
        lock.lock()
        cache[id] = resolved
        lock.unlock()
        return resolved
    }

    private static func resolve(_ id: String) -> GhosttyThemeDefinition? {
        guard let (source, name) = TerminalThemeID.parse(id) else { return nil }
        switch source {
        case .builtin:
            return builtInByName[name]
        case .custom, .ghostty:
            guard let directory = directory(for: source) else { return nil }
            return loadFile(directory.appendingPathComponent(name), name: name)
        }
    }

    static func loadFile(_ url: URL, name: String) -> GhosttyThemeDefinition? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let colors = GhosttyThemeColors.parse(text)
        else { return nil }
        return GhosttyThemeDefinition(colors, name: name)
    }

    /// Every selectable theme: imported first, then the user's Ghostty themes,
    /// then the built-in catalog, each sorted by name.
    static func allEntries() -> [TerminalThemeEntry] {
        var entries: [TerminalThemeEntry] = []
        for source in [TerminalThemeID.Source.custom, .ghostty] {
            guard let directory = directory(for: source),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            else { continue }
            for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
            where !name.hasPrefix(".") {
                let id = TerminalThemeID.make(source, name)
                guard let definition = definition(for: id) else { continue }
                entries.append(TerminalThemeEntry(id: id, source: source, definition: definition))
            }
        }
        entries += GhosttyThemeCatalog.allThemes.map {
            TerminalThemeEntry(id: TerminalThemeID.make(.builtin, $0.name), source: .builtin, definition: $0)
        }
        return entries
    }

    /// Copies a Ghostty theme file into the custom directory and returns its id.
    /// The theme takes the file's name without a config-ish extension, like
    /// Ghostty, where a theme's name is its file name.
    static func importTheme(from url: URL) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ThemeImportError.unreadable
        }
        guard GhosttyThemeColors.parse(text) != nil else { throw ThemeImportError.notATheme }
        let name = themeName(forFileNamed: url.lastPathComponent)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { throw ThemeImportError.notATheme }
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: customDirectory.appendingPathComponent(name), options: .atomic)
        invalidate()
        return TerminalThemeID.make(.custom, name)
    }

    static func themeName(forFileNamed fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let known = ["conf", "config", "ghostty", "theme", "txt"]
        return known.contains(url.pathExtension.lowercased())
            ? url.deletingPathExtension().lastPathComponent
            : fileName
    }

    static func removeImported(_ id: String) {
        guard let (source, name) = TerminalThemeID.parse(id), source == .custom else { return }
        try? FileManager.default.removeItem(at: customDirectory.appendingPathComponent(name))
        invalidate()
    }

    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// The id a Ghostty config's `theme = …` maps to: the user's Ghostty themes
    /// directory first, then the catalog — Ghostty's own lookup order.
    static func id(forGhosttyThemeNamed name: String) -> String? {
        let ghostty = TerminalThemeID.make(.ghostty, name)
        if definition(for: ghostty) != nil { return ghostty }
        let builtin = TerminalThemeID.make(.builtin, name)
        if definition(for: builtin) != nil { return builtin }
        // Ghostty matches catalog names case-insensitively too.
        if let match = GhosttyThemeCatalog.allThemes.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return TerminalThemeID.make(.builtin, match.name)
        }
        return nil
    }

    /// The background a terminal shows and whether it is dark, which decides the
    /// light ANSI adapter: HerdrM's palette switches with the appearance, a chosen
    /// theme is light or dark by its own background.
    static func effectiveBackground(theme: GhosttyThemeDefinition?, dark: Bool) -> (hex: String, isDark: Bool) {
        if let theme { return ("#\(theme.background.uppercased())", theme.isDark) }
        return (dark ? TerminalDefaults.darkBackgroundHex : TerminalDefaults.lightBackgroundHex, dark)
    }

    /// The selected theme from preferences, for views outside the terminal
    /// plumbing (backgrounds around the terminal, the settings preview).
    static var selected: GhosttyThemeDefinition? {
        definition(for: UserDefaults.standard.string(forKey: TerminalThemeID.defaultsKey) ?? "")
    }
}

enum ThemeImportError: LocalizedError {
    case unreadable, notATheme

    var errorDescription: String? {
        switch self {
        case .unreadable:
            String(localized: "The file couldn't be read as text.")
        case .notATheme:
            String(localized: "This isn't a Ghostty theme file: it needs at least a background and a foreground color.")
        }
    }
}

extension GhosttyThemeDefinition {
    init(_ colors: GhosttyThemeColors, name: String) {
        self.init(
            name: name,
            background: colors.background,
            foreground: colors.foreground,
            cursorColor: colors.cursorColor,
            cursorText: colors.cursorText,
            selectionBackground: colors.selectionBackground,
            selectionForeground: colors.selectionForeground,
            palette: colors.palette
        )
    }

    var backgroundColor: NSColor { NSColor(themeHex: background) }
    var foregroundColor: NSColor { NSColor(themeHex: foreground) }

    /// Palette colors for a swatch: the six hues (1–6), as the theme defines them.
    var swatchColors: [NSColor] {
        (1...6).compactMap { palette[$0].map(NSColor.init(themeHex:)) }
    }
}

extension NSColor {
    /// `rrggbb` or `#rrggbb` (the catalog's form) to an sRGB color; black if malformed.
    convenience init(themeHex: String) {
        let hex = themeHex.hasPrefix("#") ? String(themeHex.dropFirst()) : themeHex
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Settings UI

/// A small preview of a theme: its background, "Aa" in its foreground, and its
/// six hues. nil previews HerdrM's default palette (light/dark adaptive).
struct TerminalThemeSwatch: View {
    let theme: GhosttyThemeDefinition?

    private var background: Color {
        theme.map { Color(nsColor: $0.backgroundColor) } ?? Theme.defaultTerminalBackground
    }

    private var foreground: Color {
        theme.map { Color(nsColor: $0.foregroundColor) } ?? Theme.defaultTerminalForeground
    }

    private var hues: [Color] {
        if let theme { return theme.swatchColors.map { Color(nsColor: $0) } }
        return TerminalDefaults.darkPalette[1...6].map {
            Color(nsColor: NSColor(srgbRed: CGFloat($0.red) / 255, green: CGFloat($0.green) / 255,
                                   blue: CGFloat($0.blue) / 255, alpha: 1))
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: "Aa")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(foreground)
            ForEach(Array(hues.enumerated()), id: \.offset) { _, hue in
                Circle().fill(hue).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(background, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline))
        .accessibilityHidden(true)
    }
}

/// Searchable list of every theme. Picking one applies it at once, so the
/// terminal behind the settings window previews it live.
struct TerminalThemePickerSheet: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var entries: [TerminalThemeEntry] = []
    @State private var importError: String?

    private var filtered: [TerminalThemeEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var showsDefault: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || String(localized: "HerdrM Default").localizedCaseInsensitiveContains(trimmed)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(String(localized: "Search themes"), text: $query)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Import…")) { importTheme() }
                    .help(String(localized: "Add a Ghostty theme file, such as one from iterm2colorschemes.com or ~/.config/ghostty/themes."))
            }
            .padding(12)
            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if showsDefault {
                            row(id: TerminalThemeID.default, name: String(localized: "HerdrM Default"),
                                detail: String(localized: "Follows the app's light or dark appearance"),
                                theme: nil, removable: false)
                        }
                        ForEach(TerminalThemeID.Source.allCases, id: \.self) { source in
                            let group = filtered.filter { $0.source == source }
                            if !group.isEmpty {
                                Text(title(for: source))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 10)
                                    .padding(.bottom, 2)
                                ForEach(group) { entry in
                                    row(id: entry.id, name: entry.name, detail: nil,
                                        theme: entry.definition, removable: source == .custom)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .onAppear {
                    entries = TerminalThemeLibrary.allEntries()
                    DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .center) }
                }
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack {
                if let importError {
                    Text(importError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 520)
    }

    private func title(for source: TerminalThemeID.Source) -> String {
        switch source {
        case .custom: String(localized: "Imported")
        case .ghostty: String(localized: "From ~/.config/ghostty/themes")
        case .builtin: String(localized: "Built-in")
        }
    }

    private func row(id: String, name: String, detail: String?, theme: GhosttyThemeDefinition?, removable: Bool) -> some View {
        let selected = selection == id
        return Button {
            selection = id
        } label: {
            HStack(spacing: 10) {
                TerminalThemeSwatch(theme: theme)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name).font(.system(size: 12))
                    if let detail {
                        Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(selected ? Theme.itemWashSelected : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if removable {
                Button(String(localized: "Remove Theme")) { remove(id) }
            }
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a Ghostty theme file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            selection = try TerminalThemeLibrary.importTheme(from: url)
            importError = nil
            entries = TerminalThemeLibrary.allEntries()
        } catch {
            importError = error.localizedDescription
        }
    }

    private func remove(_ id: String) {
        TerminalThemeLibrary.removeImported(id)
        if selection == id { selection = TerminalThemeID.default }
        entries = TerminalThemeLibrary.allEntries()
    }
}
