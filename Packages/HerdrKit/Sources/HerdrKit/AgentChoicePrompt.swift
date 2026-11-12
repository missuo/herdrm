import Foundation

/// A numbered choice an agent's TUI is waiting on, read off the pane's visible
/// screen (`pane.read`, source `visible`, plain text): Claude Code's permission
/// prompts ("Do you want to proceed?"), AskUserQuestion forms, plan approval, and
/// Codex's approval and question overlays all draw the same shape: a question,
/// then `1.` … `n.` options with one marked by the cursor (`❯` in Claude, `›` in
/// Codex), then a key hint footer.
public struct AgentPendingChoice: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        public let number: Int
        public let label: String
        /// Description lines drawn under the option (AskUserQuestion).
        public let detail: String?
        /// The single-key shortcut shown after the label, e.g. Codex's "(y)".
        public let shortcut: String?
        public let isFocused: Bool
        /// Checkbox state for multi-select questions; nil for single choice.
        public let isChecked: Bool?
        /// Picking it asks for words: "Type something.", "No, and tell Claude what to do differently".
        public let acceptsText: Bool
        public var id: Int { number }
    }

    /// The question line(s) right above the options.
    public let question: String
    /// What the question is about, drawn above it: the command, the file, the plan's last lines.
    public let context: [String]
    public let options: [Option]
    /// The footer offers Esc.
    public let canCancel: Bool
    /// A multi-select question's button row ("Next", "Submit"), and the option it follows.
    public var submitLabel: String? = nil
    public var submitAfter: Int? = nil
    public var isSubmitFocused = false

    public var isMultiSelect: Bool { options.contains { $0.isChecked != nil } }
    public var focusedIndex: Int? { options.firstIndex(where: \.isFocused) }

    /// Identity of the prompt for "is it still showing?": the question and the
    /// labels, not the cursor position or checkbox state.
    public var fingerprint: String {
        ([question] + options.map { "\($0.number). \($0.label)" }).joined(separator: "\n")
    }
}

public enum AgentChoicePrompt {
    /// Only the bottom of the screen is searched: a live prompt is drawn there,
    /// and numbered lists higher up are conversation, not controls.
    static let searchedLines = 60
    /// Non-empty lines allowed under the last option: its description, the
    /// footer and a status line. More means the list is not the live prompt.
    static let maxLinesBelow = 8
    /// Lines between two options: wrapped descriptions, a separator rule.
    static let maxGap = 8

    private static let cursorMarks: Set<Character> = ["❯", "›", "▶", "➤", ">"]

    /// The pending choice on `screen`, or nil when the bottom of the screen is not one.
    ///
    /// The screen shows text the agent controls (command previews, transcript), so a
    /// numbered list there could imitate a prompt. Only the bottom-most list counts,
    /// it must run 1…n with at most one cursor line, sit within a few lines of the
    /// bottom, and carry a key-hint footer or a question. The caller also requires
    /// herdr to report the agent blocked, and re-reads the screen before answering.
    public static func parse(_ screen: String) -> AgentPendingChoice? {
        let all = screen.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { clean(String($0)) }
        var end = all.count
        while end > 0, all[end - 1].isEmpty { end -= 1 }
        guard end > 0 else { return nil }
        let lines = Array(all[max(0, end - searchedLines)..<end])

        // The last option on screen, then walk up through n-1 … 1.
        guard let lastIndex = lines.lastIndex(where: { optionLine($0) != nil }),
              let last = optionLine(lines[lastIndex]) else { return nil }
        let below = lines[(lastIndex + 1)...].filter { !$0.isEmpty }
        // A `❯` line below that is not a short button (`❯ Next`) is the agent's own
        // input box: the list is conversation drawn above it, not a dialog.
        guard below.count <= maxLinesBelow, !below.contains(where: isInputBox) else { return nil }

        var found: [(index: Int, parsed: ParsedOption)] = [(lastIndex, last)]
        var expected = last.number - 1
        var cursor = lastIndex - 1
        var gap = 0
        while expected >= 1, cursor >= 0, gap <= maxGap {
            if let option = optionLine(lines[cursor]) {
                guard option.number == expected else { return nil }
                found.insert((cursor, option), at: 0)
                expected -= 1
                gap = 0
            } else {
                gap += 1
            }
            cursor -= 1
        }
        guard expected == 0, found.count >= 2 else { return nil }

        // Lines between options: the option's description, or a multi-select
        // question's Next / Submit row.
        var options: [AgentPendingChoice.Option] = []
        var submit: (label: String, after: Int, focused: Bool)?
        var focusedRows = 0
        for (position, entry) in found.enumerated() {
            let stop = position + 1 < found.count
                ? found[position + 1].index
                : lastIndex + 1 + trailingDetailCount(lines, after: lastIndex)
            var detailLines: [String] = []
            for line in lines[(entry.index + 1)..<max(entry.index + 1, stop)] {
                if line.isEmpty || isRule(line) || isFooter(line) || isCursorOnly(line) { continue }
                let (marked, text) = unmarked(line)
                if submitLabels.contains(text) {
                    submit = (text, entry.parsed.number, marked)
                    if marked { focusedRows += 1 }
                    continue
                }
                detailLines.append(text)
            }
            if entry.parsed.focused { focusedRows += 1 }
            options.append(AgentPendingChoice.Option(
                number: entry.parsed.number,
                label: entry.parsed.label,
                detail: detailLines.isEmpty ? nil : detailLines.joined(separator: " "),
                shortcut: entry.parsed.shortcut,
                isFocused: entry.parsed.focused,
                isChecked: entry.parsed.checked,
                acceptsText: acceptsText(entry.parsed.label)
            ))
        }
        guard focusedRows <= 1 else { return nil }

        let footer = below.filter(isFooter)
        let canCancel = footer.contains { $0.lowercased().contains("esc") }
            || options.contains { $0.shortcut == "esc" }

        // Question: the block of text right above option 1. Context: above that, up
        // to the dialog's top rule; the dashed rules inside the dialog are skipped.
        var row = found[0].index - 1
        while row >= 0, lines[row].isEmpty || isTabBar(lines[row]) { row -= 1 }
        var questionLines: [String] = []
        while row >= 0, !lines[row].isEmpty, !isRule(lines[row]), questionLines.count < 4 {
            questionLines.insert(lines[row].trimmingCharacters(in: .whitespaces), at: 0)
            row -= 1
        }
        var context: [String] = []
        while row >= 0, !isSolidRule(lines[row]), context.count < 12 {
            let line = lines[row].trimmingCharacters(in: .whitespaces)
            // A message bullet is the conversation above the dialog.
            if let first = line.first, "⏺•".contains(first) { break }
            if !line.isEmpty, !isTabBar(line), !isRule(line) { context.insert(line, at: 0) }
            row -= 1
        }
        var question = questionLines.joined(separator: " ")
        // Codex asks first and shows the command after: "Would you like to run
        // the following command?" then "$ …" right above the options.
        if !question.hasSuffix("?"), let asked = context.lastIndex(where: { $0.hasSuffix("?") }) {
            let shown = questionLines
            question = context[asked]
            context.remove(at: asked)
            context += shown
        }
        guard !footer.isEmpty || question.hasSuffix("?") else { return nil }
        return AgentPendingChoice(question: question, context: context, options: options, canCancel: canCancel,
                                  submitLabel: submit?.label, submitAfter: submit?.after,
                                  isSubmitFocused: submit?.focused ?? false)
    }

    /// The button row under a multi-select question's options.
    static let submitLabels: Set<String> = ["Next", "Submit", "Done", "Continue"]

    /// The line without a leading cursor mark, and whether it had one.
    static func unmarked(_ line: String) -> (marked: Bool, text: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, cursorMarks.contains(first) else { return (false, trimmed) }
        return (true, String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// `❯` alone, or `❯ some longer text`: the agent's prompt input, not a dialog button.
    static func isInputBox(_ line: String) -> Bool {
        let (marked, text) = unmarked(line)
        guard marked else { return false }
        return text.isEmpty || text.split(separator: " ").count > 3
    }

    // MARK: - Lines

    struct ParsedOption: Equatable {
        let number: Int
        let label: String
        let shortcut: String?
        let focused: Bool
        let checked: Bool?
    }

    /// `❯ 1. Yes`, `  2. Yes, and don't ask again for git:*`, `› 1. Yes, proceed (y)`,
    /// `❯ 3. [✔] Option`, `1) label`.
    static func optionLine(_ line: String) -> ParsedOption? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        var focused = false
        if let first = rest.first, cursorMarks.contains(first) {
            focused = true
            rest = rest.dropFirst().drop(while: { $0 == " " })
        }
        let digits = rest.prefix(while: \.isNumber)
        guard (1...2).contains(digits.count), let number = Int(digits), number >= 1 else { return nil }
        rest = rest.dropFirst(digits.count)
        guard let punctuation = rest.first, punctuation == "." || punctuation == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        var label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }

        var checked: Bool?
        for (box, state) in [("[ ]", false), ("[✔]", true), ("[✓]", true), ("[x]", true), ("[X]", true),
                             ("☐", false), ("☑", true), ("☒", true), ("◯", false), ("◉", true)]
        where label.hasPrefix(box) {
            checked = state
            label = String(label.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        var shortcut: String?
        if label.hasSuffix(")"), let open = label.lastIndex(of: "(") {
            let inner = String(label[label.index(after: open)..<label.index(before: label.endIndex)])
            if inner.lowercased() == "esc" || (inner.count == 1 && inner.first?.isLetter == true) {
                shortcut = inner.lowercased()
                label = String(label[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !label.isEmpty else { return nil }
        return ParsedOption(number: number, label: label, shortcut: shortcut, focused: focused, checked: checked)
    }

    /// Strips box borders Claude draws around older dialogs (`│ … │`) and trailing space.
    static func clean(_ line: String) -> String {
        var text = Substring(line)
        while let last = text.last, last == " " || last == "\t" { text = text.dropLast() }
        let trimmedLeading = text.drop(while: { $0 == " " })
        if trimmedLeading.first == "│" {
            text = trimmedLeading.dropFirst()
            if text.last == "│" { text = text.dropLast() }
            while let last = text.last, last == " " { text = text.dropLast() }
        }
        return String(text)
    }

    /// Any horizontal rule: a dialog's top border, or the dashed `╌` separators
    /// Claude draws inside one around a command preview.
    static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { "─━═╌┄▔-╭╮╰╯┌┐└┘".contains($0) }
    }

    /// A solid rule: where a dialog (or the conversation) begins.
    static func isSolidRule(_ line: String) -> Bool {
        isRule(line) && !line.contains("╌") && !line.contains("┄")
    }

    static func isFooter(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["esc to", "enter to", "to navigate", "to confirm", "to cancel", "to select", "to submit", "tab to"]
            .contains { lower.contains($0) }
    }

    private static func isCursorOnly(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count == 1 && trimmed.first.map(cursorMarks.contains) == true
    }

    /// AskUserQuestion's header row: `←  ☐ Scope  ☐ Style  ✔ Submit  →`, or ` ☐ Scope`
    /// alone for a single question.
    static func isTabBar(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("←") && trimmed.hasSuffix("→") { return true }
        guard let first = trimmed.first, "☐☒☑✔".contains(first) else { return false }
        return trimmed.split(separator: " ").count <= 6
    }

    private static func trailingDetailCount(_ lines: [String], after index: Int) -> Int {
        var count = 0
        var row = index + 1
        while row < lines.count, !lines[row].isEmpty, !isRule(lines[row]), !isFooter(lines[row]),
              lines[row].first == " " {
            count += 1
            row += 1
        }
        return count
    }

    static func acceptsText(_ label: String) -> Bool {
        let lower = label.lowercased()
        return ["type something", "tell claude", "tell codex", "what to do differently"].contains { lower.contains($0) }
            || lower == "other" || lower == "other…" || lower == "other..."
    }
}

/// The keys (herdr `pane.send_input` key names) that answer a pending choice.
/// Send each key in its own request: Claude Code reads input in chunks, and two
/// digits written together arrive as "13", which it ignores.
///
/// Claude Code (read from its 2.1.316 Select component and tried on a live
/// 2.1.316 session through herdr): a digit picks option N at once; on an option
/// that takes text ("Type something.", "Tell Claude what to change") it moves into
/// that option's input, where pasted text and Enter submit it. In a multi-select
/// question a digit toggles option N, and the Next row sits one step below the
/// last checkbox option.
///
/// Codex: options show their shortcut letter ("(y)", "(a)", "(esc)"); with no
/// shortcut the cursor is moved with arrows and Enter confirms. Not tried
/// against a live Codex session.
public enum AgentChoiceKeys {
    public static func select(_ option: AgentPendingChoice.Option, in choice: AgentPendingChoice,
                              agent: AgentChatKind) -> [String] {
        switch agent {
        case .claude:
            if option.number <= 9 { return [String(option.number)] }
            return moves(in: choice, to: option.number - 1) + (choice.isMultiSelect ? [] : ["enter"])
        case .codex:
            if let shortcut = option.shortcut { return [shortcut] }
            return moves(in: choice, to: option.number - 1) + ["enter"]
        }
    }

    /// Multi-select: move onto the Next / Submit row and press Enter.
    public static func submit(_ choice: AgentPendingChoice, agent: AgentChatKind) -> [String] {
        if choice.isSubmitFocused { return ["enter"] }
        switch agent {
        case .claude: return moves(in: choice, to: choice.submitAfter ?? choice.options.count) + ["enter"]
        case .codex: return ["enter"]
        }
    }

    public static let cancel = ["esc"]

    /// Arrow presses from the focused option (the first when none is marked) to `target`.
    static func moves(in choice: AgentPendingChoice, to target: Int) -> [String] {
        let from = choice.focusedIndex ?? 0
        let delta = target - from
        return Array(repeating: delta > 0 ? "down" : "up", count: abs(delta))
    }
}
