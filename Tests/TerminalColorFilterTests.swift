import Darwin
import Foundation

@main
struct TerminalColorFilterTests {
    static func main() {
        var adapter = LightTerminalANSIAdapter()
        let source = Array("\u{1B}[38;2;230;230;230;48;2;30;30;30mCodex".utf8)
        let transformed = adapter.transform(source[...])
        let result = String(decoding: transformed, as: UTF8.self)

        expect(result.contains("38;2;25;25;25"), "light foreground should become dark")
        expect(result.contains("48;2;225;225;225"), "dark input background should become light")

        var resetAdapter = LightTerminalANSIAdapter()
        let resetResult = String(decoding: resetAdapter.transform(Array("\u{1B}[0m".utf8)[...]), as: UTF8.self)
        expect(resetResult == "\u{1B}[0m", "a trailing reset should not wait for another output chunk")

        var splitAdapter = LightTerminalANSIAdapter()
        let first = Array("before\u{1B}[48;2;30;".utf8)
        let second = Array("30;30mafter".utf8)
        let splitResult = splitAdapter.transform(first[...]) + splitAdapter.transform(second[...])
        expect(
            String(decoding: splitResult, as: UTF8.self) == "before\u{1B}[48;2;225;225;225mafter",
            "split escape sequences should be transformed without corruption"
        )

        // Agent TUI copy actions arrive through the PTY as OSC 52. The light
        // color adapter must preserve them, including when ESC ends one read.
        var clipboardAdapter = LightTerminalANSIAdapter()
        let clipboardSequence = "\u{1B}]52;c;Y29waWVkIHRleHQ=\u{07}"
        let clipboardFirst = Array(clipboardSequence.utf8.prefix(1))
        let clipboardSecond = Array(clipboardSequence.utf8.dropFirst())
        let clipboardResult = clipboardAdapter.transform(clipboardFirst[...])
            + clipboardAdapter.transform(clipboardSecond[...])
        expect(
            String(decoding: clipboardResult, as: UTF8.self) == clipboardSequence,
            "split OSC 52 clipboard writes should pass through unchanged"
        )

        // herdr passes 256-indexed SGR through verbatim (48;5;22 etc.), which is
        // what Claude Code's diff backgrounds arrive as — they must be resolved
        // through the xterm palette and adapted like truecolor.
        var indexedAdapter = LightTerminalANSIAdapter()
        let indexed = Array("\u{1B}[0;38;5;114;48;5;22mdiff".utf8)
        let indexedResult = String(decoding: indexedAdapter.transform(indexed[...]), as: UTF8.self)
        expect(indexedResult.contains("38;2;6;86;6"), "256-color light green foreground should become dark")
        expect(indexedResult.contains("48;2;119;214;119"), "256-color dark diff background should become light")

        // A light-themed agent's output must pass through untouched: light
        // backgrounds already suit a light terminal, and flipping them was
        // how Claude Code's pale user-message bar became a black strip.
        var lightThemeAdapter = LightTerminalANSIAdapter()
        let lightTheme = Array("\u{1B}[38;2;50;50;50;48;2;245;245;245mrow".utf8)
        let lightThemeResult = String(decoding: lightThemeAdapter.transform(lightTheme[...]), as: UTF8.self)
        expect(lightThemeResult.contains("48;2;245;245;245"), "light backgrounds must not flip dark")
        expect(lightThemeResult.contains("38;2;50;50;50"), "dark foregrounds on light rows must stay dark")

        // Powerline separators are layered: the separator foreground is the
        // previous segment's background, while the cell background is the next
        // segment's background. Do not run the foreground through the normal
        // contrast transform or the join turns into a dark blended arrow.
        var powerlineAdapter = LightTerminalANSIAdapter()
        let powerlineText = "\u{1B}[48;2;243;139;168;38;2;17;17;27muser"
            + "\u{1B}[48;2;250;179;135;38;2;243;139;168m\u{E0B0}"
            + "\u{1B}[38;2;17;17;27mpath"
        let powerline = Array(powerlineText.utf8)
        let powerlineResult = String(decoding: powerlineAdapter.transform(powerline[...]), as: UTF8.self)
        expect(
            powerlineResult.contains("48;2;250;179;135;38;2;243;139;168m\u{E0B0}"),
            "powerline foreground should retain the neighboring segment color"
        )
        expect(
            powerlineResult.contains("38;2;17;17;27mpath"),
            "ordinary foreground after a powerline separator should still adapt normally"
        )

        var darkPowerlineAdapter = LightTerminalANSIAdapter()
        let darkPowerline = Array(
            "\u{1B}[48;2;30;30;30;38;2;30;30;30m\u{E0B0}".utf8
        )
        let darkPowerlineResult = String(
            decoding: darkPowerlineAdapter.transform(darkPowerline[...]),
            as: UTF8.self
        )
        expect(
            darkPowerlineResult.contains("48;2;225;225;225;38;2;225;225;225m\u{E0B0}"),
            "a dark powerline separator should follow the flipped neighboring background"
        )

        // The separator and its UTF-8 bytes may arrive in separate PTY reads.
        var splitPowerlineAdapter = LightTerminalANSIAdapter()
        let splitPowerlineBytes = Array("\u{E0B0}next".utf8)
        let splitPowerlineFirst = Array("\u{1B}[48;2;250;179;135;38;2;243;139;168m".utf8)
            + [splitPowerlineBytes[0]]
        let splitPowerlineSecond = Array(splitPowerlineBytes[1...])
        let splitPowerlineResult = splitPowerlineAdapter.transform(splitPowerlineFirst[...])
            + splitPowerlineAdapter.transform(splitPowerlineSecond[...])
        expect(
            String(decoding: splitPowerlineResult, as: UTF8.self)
                == "\u{1B}[48;2;250;179;135;38;2;243;139;168m\u{E0B0}next",
            "split powerline glyphs should retain their layered foreground"
        )

        // Foregrounds that already read well on white keep their color;
        // only dark backgrounds flip.
        var keepAdapter = LightTerminalANSIAdapter()
        let darkRed = Array("\u{1B}[38;2;220;50;47merror".utf8)
        expect(
            String(decoding: keepAdapter.transform(darkRed[...]), as: UTF8.self).contains("38;2;220;50;47"),
            "an already-dark truecolor foreground should not wash out"
        )

        // The light palette keeps whichever variant reads better on white:
        // ANSI red is already dark and must not wash out to a pastel, while
        // bright white must flip to dark. Mirrors TerminalDefaults.lightPalette.
        let redOriginal = LightTerminalANSIAdapter.contrastOnWhite(red: 194, green: 54, blue: 33)
        let redFlipped = LightTerminalANSIAdapter.lightRGB(red: 194, green: 54, blue: 33)
        expect(
            redOriginal >= LightTerminalANSIAdapter.contrastOnWhite(
                red: redFlipped.red, green: redFlipped.green, blue: redFlipped.blue
            ),
            "ANSI red should survive the light palette unflipped"
        )
        let brightWhiteOriginal = LightTerminalANSIAdapter.contrastOnWhite(red: 233, green: 235, blue: 235)
        let brightWhiteFlipped = LightTerminalANSIAdapter.lightRGB(red: 233, green: 235, blue: 235)
        expect(
            LightTerminalANSIAdapter.contrastOnWhite(
                red: brightWhiteFlipped.red, green: brightWhiteFlipped.green, blue: brightWhiteFlipped.blue
            ) > brightWhiteOriginal,
            "ANSI bright white should flip to a dark color"
        )

        print("PASS: LightTerminalANSIAdapter")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
