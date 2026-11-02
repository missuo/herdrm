import XCTest
@testable import HerdrKit

/// Screens are synthetic, drawn the way Claude Code 2.1.3xx and Codex 0.16x lay
/// these prompts out; names and paths are fake (test1, test2, …).
final class AgentChoicePromptTests: XCTestCase {
    private let rule = String(repeating: "─", count: 60)

    private var bashPermission: String {
        """
        ⏺ I'll check the working tree first.

        \(rule)
         Bash command

           git status --short
           Show changed files

         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for git status commands in /Users/test1/test2
           3. No, and tell Claude what to do differently (esc)

         Esc to cancel · Tab to amend · ctrl+e to explain
        """
    }

    func testReadsClaudePermissionPrompt() throws {
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(bashPermission))
        XCTAssertEqual(choice.question, "Do you want to proceed?")
        XCTAssertEqual(choice.context, ["Bash command", "git status --short", "Show changed files"])
        XCTAssertEqual(choice.options.map(\.label), [
            "Yes",
            "Yes, and don't ask again for git status commands in /Users/test1/test2",
            "No, and tell Claude what to do differently",
        ])
        XCTAssertEqual(choice.options.map(\.isFocused), [true, false, false])
        XCTAssertEqual(choice.options[2].shortcut, "esc")
        XCTAssertEqual(choice.options.map(\.acceptsText), [false, false, true])
        XCTAssertTrue(choice.canCancel)
        XCTAssertFalse(choice.isMultiSelect)
    }

    func testClaudeAnswersWithTheOptionDigit() throws {
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(bashPermission))
        XCTAssertEqual(AgentChoiceKeys.select(choice.options[0], in: choice, agent: .claude), ["1"])
        XCTAssertEqual(AgentChoiceKeys.select(choice.options[2], in: choice, agent: .claude), ["3"])
        XCTAssertEqual(AgentChoiceKeys.cancel, ["esc"])
    }

    func testReadsBoxedDialogFromOlderClaude() throws {
        let screen = """
        ╭──────────────────────────────────────────────╮
        │ Edit file                                    │
        │   src/test1.swift                            │
        │                                              │
        │ Do you want to make this edit to test1.swift?│
        │ ❯ 1. Yes                                     │
        │   2. Yes, allow all edits during this session│
        │   3. No, and tell Claude what to do differently (esc) │
        ╰──────────────────────────────────────────────╯
        """
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(screen))
        XCTAssertEqual(choice.question, "Do you want to make this edit to test1.swift?")
        XCTAssertEqual(choice.options.count, 3)
        XCTAssertEqual(choice.options[1].label, "Yes, allow all edits during this session")
        XCTAssertEqual(choice.context, ["Edit file", "src/test1.swift"])
    }

    private var askUserQuestion: String {
        """
        \(rule)
         ←  ☐ Storage  ☐ Sync  ✔ Submit  →

        Where should test1 keep its cache?

        ❯ 1. On disk (Recommended)
             Survives restarts; uses a few MB.
          2. In memory
             Fastest; lost on quit.
          3. Type something.
        \(rule)
          4. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
    }

    func testReadsAskUserQuestionWithDescriptionsAndFreeText() throws {
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(askUserQuestion))
        XCTAssertEqual(choice.question, "Where should test1 keep its cache?")
        XCTAssertEqual(choice.options.map(\.label), ["On disk (Recommended)", "In memory", "Type something.", "Chat about this"])
        XCTAssertEqual(choice.options[0].detail, "Survives restarts; uses a few MB.")
        XCTAssertEqual(choice.options[1].detail, "Fastest; lost on quit.")
        XCTAssertNil(choice.options[2].detail)
        XCTAssertTrue(choice.options[2].acceptsText)
        XCTAssertTrue(choice.context.isEmpty, "the tab bar is not context")
    }

    func testReadsMultiSelectCheckboxesAndPlansSubmit() throws {
        let screen = """
        \(rule)
        Which checks should run?

          1. [✔] Lint
        ❯ 2. [ ] Unit tests
          3. [ ] UI tests
          Submit

        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(screen))
        XCTAssertTrue(choice.isMultiSelect)
        XCTAssertEqual(choice.options.map(\.isChecked), [true, false, false])
        XCTAssertEqual(choice.options.map(\.label), ["Lint", "Unit tests", "UI tests"])
        XCTAssertEqual(choice.focusedIndex, 1)
        // A digit toggles; Submit is one step past the last option.
        XCTAssertEqual(AgentChoiceKeys.select(choice.options[2], in: choice, agent: .claude), ["3"])
        XCTAssertEqual(AgentChoiceKeys.submit(choice, agent: .claude), ["down", "down", "enter"])
    }

    func testReadsPlanApproval() throws {
        let screen = """
        ╭\(rule)
         Ready to code?

         Here is Claude's plan:
         ╭\(rule)╮
         │ 1. Add the cache                                           │
         │ 2. Write tests                                             │
         ╰\(rule)╯
        \(rule)
         Claude has written up a plan and is ready to execute. Would you like to proceed?

         ❯ 1. Yes, and use auto mode
           2. Yes, manually approve edits
           3. No, keep planning

         ctrl+g to edit in Vim · shift+tab to approve with this feedback
        """
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(screen))
        XCTAssertEqual(choice.question, "Claude has written up a plan and is ready to execute. Would you like to proceed?")
        XCTAssertEqual(choice.options.map(\.label), ["Yes, and use auto mode", "Yes, manually approve edits", "No, keep planning"])
    }

    func testReadsCodexApprovalAndUsesShortcuts() throws {
        let screen = """
        • Running tests for test1

          Would you like to run the following command?

          $ swift test --filter Test1

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for this command in this session (a)
          3. No, and tell Codex what to do differently (esc)

          Press enter to confirm or esc to cancel
        """
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(screen))
        XCTAssertEqual(choice.options.map(\.shortcut), ["y", "a", "esc"])
        XCTAssertEqual(choice.options[0].label, "Yes, proceed")
        XCTAssertTrue(choice.options[0].isFocused)
        XCTAssertTrue(choice.options[2].acceptsText)
        XCTAssertEqual(choice.question, "Would you like to run the following command?")
        XCTAssertEqual(choice.context, ["$ swift test --filter Test1"])
        XCTAssertEqual(AgentChoiceKeys.select(choice.options[1], in: choice, agent: .codex), ["a"])
    }

    func testCodexWithoutShortcutsMovesTheCursor() throws {
        let screen = """
          Pick a test target?

          1. test1
        › 2. test2
          3. test3

          enter to submit answer · esc to cancel
        """
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(screen))
        XCTAssertEqual(AgentChoiceKeys.select(choice.options[0], in: choice, agent: .codex), ["up", "enter"])
        XCTAssertEqual(AgentChoiceKeys.select(choice.options[2], in: choice, agent: .codex), ["down", "enter"])
        XCTAssertEqual(AgentChoiceKeys.select(choice.options[1], in: choice, agent: .codex), ["enter"])
    }

    // MARK: - Screens as a live Claude Code 2.1.316 drew them through herdr (paths faked)

    private let dashes = String(repeating: "╌", count: 60)

    func testLiveBashPermissionWithDashedPreviewAndWrappedOption() throws {
        let screen = """
        ❯ Use the Bash tool to run exactly: touch b.txt

          Creating empty file b.txt with touch

          ⎿  $ touch b.txt

        \(rule)
         Bash command

         Tip: auto mode handles these prompts for you — choose "switch to auto mode" below

         Create empty file b.txt with touch
        \(dashes)
         touch b.txt
        \(dashes)

         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and always allow access to
              /Users/test1/test2 from
              this project
           3. Yes, and switch to auto mode · auto mode handles these prompts for you
           4. No

         Esc to cancel · Tab to amend

        """
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(screen))
        XCTAssertEqual(choice.question, "Do you want to proceed?")
        XCTAssertEqual(choice.context, [
            "Bash command",
            "Tip: auto mode handles these prompts for you — choose \"switch to auto mode\" below",
            "Create empty file b.txt with touch",
            "touch b.txt",
        ])
        XCTAssertEqual(choice.options.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(choice.options[1].label, "Yes, and always allow access to")
        XCTAssertEqual(choice.options[1].detail, "/Users/test1/test2 from this project")
        XCTAssertEqual(choice.options[3].label, "No")
        XCTAssertTrue(choice.canCancel)
    }

    func testLiveSingleQuestionHeaderIsNotContext() throws {
        let screen = """
        \(rule)
         ☐ Color

        Which color do you prefer?

        ❯ 1. Red
             A bold, warm color that stands out.
          2. Blue
             A calm, cool color that feels steady.
          3. Type something.
        \(rule)
          4. Chat about this

        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(screen))
        XCTAssertEqual(choice.question, "Which color do you prefer?")
        XCTAssertTrue(choice.context.isEmpty)
        XCTAssertEqual(choice.options.map(\.label), ["Red", "Blue", "Type something.", "Chat about this"])
        XCTAssertNil(choice.submitLabel)
    }

    func testLiveMultiSelectNextRowSitsBeforeChatAboutThis() throws {
        let screen = """
        \(rule)
        ←  ☐ Fruits  ☐ Size  ✔ Submit  →

        Which fruits?

          1. [ ] Apple
                 A crisp, sweet fruit.
          2. [✔] Pear
                 A soft, juicy fruit.
          3. [ ] Plum
                 A small, tart-sweet fruit.
          4. [ ] Type something
        ❯    Next
        \(rule)
          5. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(screen))
        XCTAssertTrue(choice.isMultiSelect)
        XCTAssertEqual(choice.options.map(\.isChecked), [false, true, false, false, nil])
        XCTAssertNil(choice.options[3].detail, "the Next row is not a description")
        XCTAssertEqual(choice.submitLabel, "Next")
        XCTAssertEqual(choice.submitAfter, 4)
        XCTAssertTrue(choice.isSubmitFocused)
        XCTAssertNil(choice.focusedIndex)
        XCTAssertEqual(AgentChoiceKeys.submit(choice, agent: .claude), ["enter"])

        let resting = screen.replacingOccurrences(of: "  1. [ ] Apple", with: "❯ 1. [ ] Apple")
            .replacingOccurrences(of: "❯    Next", with: "     Next")
        let fromTop = try XCTUnwrap(AgentChoicePrompt.parse(resting))
        XCTAssertEqual(AgentChoiceKeys.submit(fromTop, agent: .claude), ["down", "down", "down", "down", "enter"])
    }

    func testLiveReviewStepWithoutFooter() throws {
        let screen = """
        \(rule)
        ←  ☒ Fruits  ☒ Size  ✔ Submit  →

        Review your answers

         ● Which fruits?
           → Pear, Apple
         ● Which size?
           → Large

        Ready to submit your answers?

        ❯ 1. Submit answers
          2. Cancel
        """
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(screen))
        XCTAssertEqual(choice.question, "Ready to submit your answers?")
        XCTAssertEqual(choice.context, ["Review your answers", "● Which fruits?", "→ Pear, Apple", "● Which size?", "→ Large"])
        XCTAssertEqual(choice.options.map(\.label), ["Submit answers", "Cancel"])
    }

    func testLivePlanApproval() throws {
        let screen = """
          \(rule)
           Ready to code?

           Here is Claude's plan:
          \(dashes)
           Plan: create c.txt containing "hi"
           Steps
           1. Create c.txt in the working directory with the content hi.
           2. Verify that c.txt exists and contains hi.
          \(dashes)
          \(rule)
           Claude has written up a plan and is ready to execute. Would you like to proceed?

           ❯ 1. Yes, and use auto mode
             2. Yes, manually approve edits
             3. Tell Claude what to change
                shift+tab to approve with this feedback

           ctrl+g to edit in Vim · ~/.claude/plans/test1.md
        """
        let choice = try XCTUnwrap(AgentChoicePrompt.parse(screen))
        XCTAssertEqual(choice.question, "Claude has written up a plan and is ready to execute. Would you like to proceed?")
        XCTAssertEqual(choice.options.map(\.label), ["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"])
        XCTAssertNil(choice.options[2].detail)
        XCTAssertTrue(choice.options[2].acceptsText)
    }

    func testIdlePromptBoxWithSuggestionIsNotAChoice() {
        let screen = """
        ⏺ Which do you prefer?
          1. Red
          2. Blue

        \(rule)
        ❯ check that b.txt was created
        \(rule)
          ⏸ manual mode on
        """
        XCTAssertNil(AgentChoicePrompt.parse(screen))
    }

    // MARK: - Not a prompt

    func testIgnoresNumberedListInConversation() {
        let screen = """
        ⏺ Here is the plan:
          1. Add the cache
          2. Write tests
          3. Ship it

        \(rule)
        ❯
        \(rule)
          ? for shortcuts
        """
        // Without a footer hint or question the bottom list could be anything.
        let reply = """
        ⏺ Here is the plan:
          1. Add the cache
          2. Write tests
        """
        XCTAssertNil(AgentChoicePrompt.parse(reply))
        XCTAssertNil(AgentChoicePrompt.parse(screen), "the list is above the live prompt box, not a prompt")
    }

    func testIgnoresListFarAboveTheBottom() {
        var screen = bashPermission
        for index in 0..<12 { screen += "\n output line \(index)" }
        XCTAssertNil(AgentChoicePrompt.parse(screen))
    }

    func testRejectsTwoCursorLines() {
        let screen = bashPermission.replacingOccurrences(of: "   2. Yes, and", with: " ❯ 2. Yes, and")
        XCTAssertNil(AgentChoicePrompt.parse(screen))
    }

    func testRejectsGapsInNumbering() {
        let screen = bashPermission.replacingOccurrences(of: "   2. Yes, and", with: "   5. Yes, and")
        XCTAssertNil(AgentChoicePrompt.parse(screen))
    }

    func testFingerprintIgnoresCursorPosition() throws {
        let first = try XCTUnwrap(AgentChoicePrompt.parse(bashPermission))
        let moved = bashPermission
            .replacingOccurrences(of: " ❯ 1. Yes", with: "   1. Yes")
            .replacingOccurrences(of: "   2. Yes, and", with: " ❯ 2. Yes, and")
        let second = try XCTUnwrap(AgentChoicePrompt.parse(moved))
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(second.focusedIndex, 1)
    }

    func testEmptyScreen() {
        XCTAssertNil(AgentChoicePrompt.parse(""))
        XCTAssertNil(AgentChoicePrompt.parse("\n\n\n"))
    }
}
