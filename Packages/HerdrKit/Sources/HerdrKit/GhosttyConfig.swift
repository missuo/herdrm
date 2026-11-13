#if os(macOS)
import Foundation

/// The slice of a Ghostty configuration herdrm can adopt: the terminal font.
///
/// herdrm's terminal is libghostty but its settings are its own, so this is a
/// one-time *import* (a button in Settings), not a live bind to Ghostty's file —
/// herdrm's own settings stay the source of truth afterward. See issue #73.
public struct GhosttyConfig: Sendable, Equatable {
    /// The primary `font-family`. Ghostty repeats the key to build a fallback
    /// chain; the first entry is the face the user actually sees, so that is the
    /// one herdrm adopts.
    public var fontFamily: String?
    /// `font-size`, in points.
    public var fontSize: Double?
    /// The raw `theme` value: one name, or `light:<name>,dark:<name>`.
    public var theme: String?

    public init(fontFamily: String? = nil, fontSize: Double? = nil, theme: String? = nil) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.theme = theme
    }

    public var isEmpty: Bool { fontFamily == nil && fontSize == nil && theme == nil }

    /// The theme name Ghostty would show for an appearance. A single name serves
    /// both; the `light:…,dark:…` form picks its side, falling back to the other
    /// side when only one is given.
    public func themeName(dark: Bool) -> String? {
        guard let theme else { return nil }
        var sides: [String: String] = [:]
        for part in theme.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, ["light", "dark"].contains(pair[0].lowercased()), !pair[1].isEmpty {
                sides[pair[0].lowercased()] = pair[1]
            }
        }
        guard !sides.isEmpty else { return theme }
        return dark ? (sides["dark"] ?? sides["light"]) : (sides["light"] ?? sides["dark"])
    }
}

/// The colors of a Ghostty theme file (`~/.config/ghostty/themes/<name>`, the
/// iTerm2-Color-Schemes `ghostty/` exports): the same `key = value` syntax as the
/// config, limited to color keys. Colors are stored as lowercase six-digit hex
/// without `#`, the form libghostty-spm's theme catalog uses.
public struct GhosttyThemeColors: Sendable, Equatable {
    public var background: String
    public var foreground: String
    public var cursorColor: String?
    public var cursorText: String?
    public var selectionBackground: String?
    public var selectionForeground: String?
    public var palette: [Int: String]

    public init(
        background: String,
        foreground: String,
        cursorColor: String? = nil,
        cursorText: String? = nil,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        palette: [Int: String] = [:]
    ) {
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }

    /// Parses a theme file. Unknown keys, comments and colors that aren't hex
    /// (Ghostty also takes X11 names) are skipped; nil when the file sets no
    /// background or no foreground, since then it isn't a usable theme.
    public static func parse(_ text: String) -> GhosttyThemeColors? {
        var background: String?
        var foreground: String?
        var cursorColor: String?
        var cursorText: String?
        var selectionBackground: String?
        var selectionForeground: String?
        var palette: [Int: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=")
            else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = GhosttyConfigImporter.unquote(
                line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            )
            if key == "palette" {
                // `palette = 4=#5555ff`
                let entry = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if entry.count == 2, let index = Int(entry[0]), (0...255).contains(index),
                   let color = hexColor(entry[1]) {
                    palette[index] = color
                }
                continue
            }
            guard let color = hexColor(value) else { continue }
            switch key {
            case "background": background = color
            case "foreground": foreground = color
            case "cursor-color": cursorColor = color
            case "cursor-text": cursorText = color
            case "selection-background": selectionBackground = color
            case "selection-foreground": selectionForeground = color
            default: break
            }
        }
        guard let background, let foreground else { return nil }
        return GhosttyThemeColors(
            background: background,
            foreground: foreground,
            cursorColor: cursorColor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            palette: palette
        )
    }

    /// `#RRGGBB`, `RRGGBB` or `#RGB` → `rrggbb`; nil for anything else.
    static func hexColor(_ raw: String) -> String? {
        var hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 else { return nil }
        return hex.lowercased()
    }
}

public enum GhosttyConfigImporter {
    /// Ghostty's config location on macOS, honoring `XDG_CONFIG_HOME`. The App
    /// Support copy (`~/Library/Application Support/com.mitchellh.ghostty/config`)
    /// is deliberately *not* read: it is another app's data directory, so reading
    /// it would raise the very "access data from other apps" prompt herdrm just
    /// stopped triggering (#87). `~/.config/ghostty/config` is the path virtually
    /// everyone uses and is not TCC-protected.
    public static func configURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [URL] = []
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            candidates.append(URL(fileURLWithPath: xdg).appendingPathComponent("ghostty/config"))
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        candidates.append(URL(fileURLWithPath: home).appendingPathComponent(".config/ghostty/config"))
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Reads and parses the discovered config, or nil when there is none.
    public static func load(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GhosttyConfig? {
        guard let url = configURL(fileManager: fileManager, environment: environment),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return parse(text)
    }

    /// Parses Ghostty's `key = value` config text. Whole-line `#` comments are
    /// ignored; the first `font-family` wins (it is the primary face) while the
    /// last `font-size` wins (scalar keys take their final value). Surrounding
    /// quotes on a value are stripped. Unknown keys are ignored.
    public static func parse(_ text: String) -> GhosttyConfig {
        var config = GhosttyConfig()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=")
            else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            guard !value.isEmpty else { continue }
            switch key {
            case "font-family":
                if config.fontFamily == nil { config.fontFamily = value }
            case "font-size":
                if let size = Double(value) { config.fontSize = size }
            case "theme":
                config.theme = value
            default:
                break
            }
        }
        return config
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let quotes: [Character] = ["\"", "'"]
        if let first = value.first, quotes.contains(first), value.last == first {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
#endif
