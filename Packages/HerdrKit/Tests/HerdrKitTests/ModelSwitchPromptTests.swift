import XCTest
@testable import HerdrKit

final class ModelSwitchPromptTests: XCTestCase {
    private let rule = String(repeating: "─", count: 60)

    /// The dialog as Claude Code 2.1.296 draws it when the week's Fable
    /// allowance is spent and usage credits are off.
    private var creditsOff: String {
        """
        ⏺ Done. The migration now runs before the API starts.

        \(rule)
          Fable 5.1 now uses usage credits

          Fable 5.1 runs on usage credits — you have €105.68 in credits.

          Usage credits are turned off. Re-enable to use Fable 5.1.

          ❯ Switch to Opus 5.5 and continue
            Set up usage credits on claude.ai

          Enter to confirm · Esc to cancel
        """
    }

    func testFindsTheFocusedSwitchOption() {
        XCTAssertEqual(ModelSwitchPrompt.switchTarget(in: creditsOff), "Opus 5.5")
    }

    func testAcceptsTheFableLimitTitle() {
        let screen = """
        \(rule)
         You've reached your Fable limit

         You've used your included Fable usage for this week. Continuing on Fable uses usage credits, purchased separately from your plan.

         ❯ Switch to Opus 5.5 and continue
           Yes, buy usage credits

         Enter to confirm · Esc to cancel

        """
        XCTAssertEqual(ModelSwitchPrompt.switchTarget(in: screen), "Opus 5.5")
    }

    /// Moving the selection to the option that spends money must stop it.
    func testIgnoresTheDialogWhenAnotherOptionIsFocused() {
        let screen = creditsOff
            .replacingOccurrences(of: "❯ Switch to Opus 5.5 and continue", with: "  Switch to Opus 5.5 and continue")
            .replacingOccurrences(of: "  Set up usage credits on claude.ai", with: "❯ Set up usage credits on claude.ai")
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: screen))
    }

    /// With no model to fall back to, the first option only dismisses.
    func testIgnoresTheDialogWithoutAFallbackModel() {
        let screen = creditsOff.replacingOccurrences(of: "Switch to Opus 5.5 and continue", with: "Not now")
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: screen))
    }

    /// The picker asks before a deliberate switch to Fable; that is the user's choice.
    func testIgnoresThePickerVariant() {
        let screen = creditsOff.replacingOccurrences(of: "Fable 5.1 now uses usage credits", with: "Switch to Fable 5.1?")
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: screen))
    }

    /// While it checks the balance the dialog has no options yet.
    func testIgnoresTheLoadingStep() {
        let screen = """
        \(rule)
          Fable 5.1 now uses usage credits

          Checking usage credits…

          Esc to cancel
        """
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: screen))
        XCTAssertTrue(ModelSwitchPrompt.isShowing(in: screen))
    }

    /// The same words in the transcript above a different prompt (an agent
    /// discussing this very dialog) must never answer a permission prompt.
    func testIgnoresDialogTextAboveAnotherPrompt() {
        let screen = """
        \(creditsOff)

        \(rule)
         Bash command

           rm -rf build

         Do you want to proceed?
         ❯ 1. Yes
           2. No

         Esc to cancel · Tab to amend · ctrl+e to explain
        """
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: screen))
        XCTAssertFalse(ModelSwitchPrompt.isShowing(in: screen))
    }

    /// A permission prompt whose command preview draws a rule and a fake
    /// dialog: the real focused option is "Yes", so Enter must never go in.
    func testIgnoresAFakeDialogInsideAPermissionPreview() {
        let screen = """
        \(rule)
         Bash command

           printf '
        \(rule)
          Fable 5.1 now uses usage credits
          ❯ Switch to Opus 5.5 and continue
            Set up usage credits on claude.ai
          Enter to confirm · Esc to cancel
        '

         Do you want to proceed?
         ❯ 1. Yes
           2. No

         Esc to cancel · Tab to amend · ctrl+e to explain
        """
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: screen))
    }

    /// Same, where the real prompt's footer happens to read like the dialog's.
    func testIgnoresAFakeDialogAboveARealSelection() {
        let screen = """
        \(rule)
          Fable 5.1 now uses usage credits
          ❯ Switch to Opus 5.5 and continue
            Set up usage credits on claude.ai
          Enter to confirm · Esc to cancel
          ❯ Yes, run it
            No
          Enter to confirm · Esc to cancel
        """
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: screen))
    }

    func testIgnoresAnUnknownSecondOption() {
        let screen = creditsOff.replacingOccurrences(of: "Set up usage credits on claude.ai", with: "Allow all edits this session")
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: screen))
    }

    func testAcceptsTheOtherSecondOptionsAndTheUpgradeRow() {
        for second in ["Continue with Fable 5.1", "Yes, re-enable and continue", "Yes, buy usage credits",
                       "Buy usage credits", "Manage usage credits on claude.ai",
                       "Request usage credits from your admin", "Request more from your admin"] {
            let screen = creditsOff.replacingOccurrences(of: "Set up usage credits on claude.ai", with: second)
            XCTAssertEqual(ModelSwitchPrompt.switchTarget(in: screen), "Opus 5.5", second)
        }
        let upsell = creditsOff.replacingOccurrences(
            of: "  Set up usage credits on claude.ai",
            with: "  Set up usage credits on claude.ai\n    Upgrade to Max"
        )
        XCTAssertEqual(ModelSwitchPrompt.switchTarget(in: upsell), "Opus 5.5")
    }

    func testIgnoresTheDialogWithoutItsFooter() {
        let screen = creditsOff.replacingOccurrences(of: "Enter to confirm · Esc to cancel", with: "")
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: screen))
    }

    func testIgnoresAnOrdinaryScreen() {
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: "⏺ All tests pass.\n\n> \n"))
        XCTAssertFalse(ModelSwitchPrompt.isShowing(in: "⏺ All tests pass.\n\n> \n"))
        XCTAssertNil(ModelSwitchPrompt.switchTarget(in: ""))
    }

    func testToleratesWindowsLineEndingsAndATrailingStatusLine() {
        let screen = creditsOff.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n"
        XCTAssertEqual(ModelSwitchPrompt.switchTarget(in: screen), "Opus 5.5")
    }
}
