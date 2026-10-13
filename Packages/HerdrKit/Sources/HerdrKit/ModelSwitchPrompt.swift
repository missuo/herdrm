import Foundation

/// Claude Code's usage-credits dialog, read off a pane's visible screen.
///
/// When the week's Fable allowance is spent, Claude Code stops before the next
/// request and asks in the terminal: switch to its fallback model, or pay for
/// Fable with usage credits. No API call fails, so nothing reaches grazr (it
/// only hears about refused requests), and an unattended agent waits on the
/// dialog until someone answers it. herdr reports such a pane as blocked.
///
/// This recognises that dialog only when its focused option is the switch to
/// another model, the one choice that spends nothing. Pressing Enter on a
/// wrong match could approve a permission prompt, and the screen shows text
/// an agent controls (a command preview, a transcript), so the match is the
/// dialog's whole shape, not its words: the last bordered block on screen
/// (the live prompt) must start with the dialog's title, end with its exact
/// footer, hold exactly one focused line, and list only the dialog's own
/// options from there. A real prompt below a forged dialog adds its own
/// focused line or footer and fails the match.
public enum ModelSwitchPrompt {
    /// The model the focused option would switch to ("Opus 5.5"), or nil when
    /// the screen is not the dialog with that option focused.
    public static func switchTarget(in screen: String) -> String? {
        guard let region = liveRegion(screen),
              region.count <= maxDialogLines,
              isDialogTitle(region.first),
              region.last == confirmFooter
        else { return nil }
        let focusedLines = region.indices.filter { region[$0].hasPrefix("❯") }
        guard focusedLines.count == 1, let focused = focusedLines.first,
              let model = focusedSwitch(region[focused])
        else { return nil }
        // Between the focused switch and the footer: the dialog's second
        // option, and at most its upgrade row.
        let others = region[(focused + 1)..<(region.count - 1)]
        guard (1...2).contains(others.count),
              let second = others.first, isSecondOption(second),
              others.dropFirst().allSatisfy({ $0 == "Upgrade to Max" })
        else { return nil }
        return model
    }

    /// True while the live prompt is this dialog, focused option or not. Its
    /// first step only checks the balance, so the options come a moment later.
    public static func isShowing(in screen: String) -> Bool {
        guard let region = liveRegion(screen) else { return false }
        return isDialogTitle(region.first)
    }

    /// The trimmed, non-empty lines after the last horizontal rule. Claude
    /// draws one above every dialog and prompt it shows.
    private static func liveRegion(_ screen: String) -> [String]? {
        let lines = screen
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let rule = lines.lastIndex(where: isRule) else { return nil }
        let region = lines[(rule + 1)...].filter { !$0.isEmpty }
        return region.isEmpty ? nil : Array(region)
    }

    private static func isRule(_ line: String) -> Bool {
        line.count >= 8 && line.allSatisfy { $0 == "─" || $0 == "━" }
    }

    private static func isDialogTitle(_ line: String?) -> Bool {
        guard let line else { return false }
        return line.hasSuffix(" now uses usage credits") || line == "You've reached your Fable limit"
    }

    /// Title, a body that wraps in a narrow pane, two or three options, the
    /// footer. Generous on purpose: the shape checks are the guard.
    private static let maxDialogLines = 16
    private static let confirmFooter = "Enter to confirm · Esc to cancel"

    /// The option Claude Code lists after the switch, by credit state.
    private static let secondOptions: Set<String> = [
        "Yes, re-enable and continue",
        "Yes, buy usage credits",
        "Buy usage credits",
        "Set up usage credits on claude.ai",
        "Manage usage credits on claude.ai",
        "Request usage credits from your admin",
        "Request more from your admin",
    ]

    private static func isSecondOption(_ line: String) -> Bool {
        secondOptions.contains(line) || line.hasPrefix("Continue with ")
    }

    private static let focusedSwitchPattern = try! NSRegularExpression(
        pattern: #"^❯\s*Switch to (.+?) and continue$"#
    )

    private static func focusedSwitch(_ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = focusedSwitchPattern.firstMatch(in: line, range: range),
              let model = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[model])
    }
}
