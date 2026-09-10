import Foundation

struct LightTerminalANSIAdapter {
    private var pending: [UInt8] = []

    mutating func transform(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        pending.append(contentsOf: bytes)
        var output: [UInt8] = []
        var index = 0

        while index < pending.count {
            guard pending[index] == 0x1B else {
                output.append(pending[index])
                index += 1
                continue
            }
            guard index + 1 < pending.count else { break }
            guard pending[index + 1] == 0x5B else {
                output.append(pending[index])
                index += 1
                continue
            }

            var end = index + 2
            while end < pending.count, !(0x40...0x7E).contains(pending[end]) {
                end += 1
            }
            guard end < pending.count else { break }

            let sequence = Array(pending[index...end])
            if pending[end] == 0x6D {
                // A Powerline separator is a foreground-colored shape painted
                // over the next segment's background.  Its foreground is not
                // ordinary text: it is deliberately the previous segment's
                // background.  Wait for the next scalar so the light-theme
                // contrast transform does not turn that join into a dark,
                // blended-looking arrow.
                if let preservesPowerlineForeground = powerlineFollowsSGR(after: end + 1) {
                    output.append(contentsOf: transformSGR(
                        sequence,
                        preservePowerlineForeground: preservesPowerlineForeground
                    ))
                } else if sequenceContainsForegroundColor(sequence) {
                    // Only a foreground SGR can be the color of a following
                    // separator. Do not hold resets/background-only updates at
                    // the end of a PTY read; otherwise typed echo can inherit
                    // the previous cell's style until another output arrives.
                    break
                } else {
                    output.append(contentsOf: transformSGR(sequence))
                }
            } else {
                output.append(contentsOf: sequence)
            }
            index = end + 1
        }

        if index > 0 {
            pending.removeFirst(index)
        }
        return output
    }

    /// WCAG contrast ratio of an sRGB color against a white background.
    static func contrastOnWhite(red: Int, green: Int, blue: Int) -> Double {
        func linear(_ value: Int) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return 1.05 / (luminance + 0.05)
    }

    static func lightRGB(red: Int, green: Int, blue: Int) -> (red: Int, green: Int, blue: Int) {
        let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        let offset = 255 - 2 * luminance
        return (
            clamp(Double(red) + offset),
            clamp(Double(green) + offset),
            clamp(Double(blue) + offset)
        )
    }

    /// Adapts one color for the light theme.
    ///
    /// Backgrounds flip only when they are dark: the adapter's job is "make
    /// this output suit a light terminal", and a light background already
    /// does. Flipping unconditionally double-inverted agents that are
    /// themselves in a light theme — Claude Code's pale user-message bar
    /// became a black strip, and since the foreground rule keeps dark text
    /// dark, the result was dark-on-black. Dark-themed output (Codex's
    /// `48;2;30;30;30` box, 256-color dark diff backgrounds) still flips.
    ///
    /// Foregrounds keep whichever variant reads better on white — same rule
    /// as the ANSI palette, so an already-dark foreground (diff red, syntax
    /// blue) doesn't wash out to a pastel.
    static func adapt(red: Int, green: Int, blue: Int, isBackground: Bool) -> (red: Int, green: Int, blue: Int) {
        let flipped = lightRGB(red: red, green: green, blue: blue)
        if isBackground {
            let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
            return luminance < 128 ? flipped : (red, green, blue)
        }
        let originalContrast = contrastOnWhite(red: red, green: green, blue: blue)
        let flippedContrast = contrastOnWhite(red: flipped.red, green: flipped.green, blue: flipped.blue)
        return originalContrast >= flippedContrast ? (red, green, blue) : flipped
    }

    /// The standard xterm 256-color palette above the 16 ANSI entries:
    /// 16–231 form a 6×6×6 cube, 232–255 a grayscale ramp.
    static func xterm256RGB(_ index: Int) -> (red: Int, green: Int, blue: Int) {
        if index >= 232 {
            let gray = 8 + 10 * (index - 232)
            return (gray, gray, gray)
        }
        let levels = [0, 95, 135, 175, 215, 255]
        let value = index - 16
        return (levels[value / 36], levels[(value / 6) % 6], levels[value % 6])
    }

    private func sequenceContainsForegroundColor(_ sequence: [UInt8]) -> Bool {
        guard sequence.count >= 3 else { return false }
        let parameters = sequence[2..<(sequence.count - 1)]
        let values = String(decoding: parameters, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
        return values.contains { $0 == "38" }
    }

    /// Looks past complete control sequences for the next UTF-8 scalar.
    /// `nil` means that the current chunk ends before the scalar (or its
    /// intervening CSI), so the caller must retain the SGR for the next feed.
    private func powerlineFollowsSGR(after start: Int) -> Bool? {
        var index = start
        while index < pending.count {
            // SGRs are sometimes split into separate writes by a prompt
            // renderer. Skip a complete CSI while looking for the glyph.
            if pending[index] == 0x1B {
                guard index + 1 < pending.count else { return nil }
                guard pending[index + 1] == 0x5B else { return false }
                var end = index + 2
                while end < pending.count, !(0x40...0x7E).contains(pending[end]) {
                    end += 1
                }
                guard end < pending.count else { return nil }
                index = end + 1
                continue
            }

            // Do not classify an incomplete UTF-8 sequence as an ordinary
            // character: dataReceived can split the glyph across chunks.
            let first = pending[index]
            let scalarLength: Int
            switch first {
            case 0xC2...0xDF: scalarLength = 2
            case 0xE0...0xEF: scalarLength = 3
            case 0xF0...0xF4: scalarLength = 4
            default:
                return false
            }
            guard index + scalarLength <= pending.count else { return nil }
            let scalarBytes = pending[index..<(index + scalarLength)]
            guard let scalar = String(decoding: scalarBytes, as: UTF8.self).unicodeScalars.first else {
                return false
            }
            // Include the thin and rounded Powerline variants as well as the
            // four shapes the renderer draws itself. All of them use the same
            // foreground/background layering contract.
            return (0xE0B0...0xE0D7).contains(scalar.value)
        }
        return nil
    }

    private func transformSGR(
        _ sequence: [UInt8],
        preservePowerlineForeground: Bool = false
    ) -> [UInt8] {
        guard sequence.count >= 3 else { return sequence }
        let parameters = sequence[2..<(sequence.count - 1)]
        let values = String(decoding: parameters, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        var output: [String] = []
        var index = 0

        while index < values.count {
            let isColor = values[index] == "38" || values[index] == "48"
            let isBackground = values[index] == "48"
            if isColor, index + 4 < values.count, values[index + 1] == "2",
               let red = Int(values[index + 2]),
               let green = Int(values[index + 3]),
               let blue = Int(values[index + 4]),
               (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue) {
                let light = preservePowerlineForeground && !isBackground
                    // Separator foregrounds are neighboring backgrounds, so
                    // use the background transform rather than the text
                    // contrast transform. This also keeps dark prompts
                    // internally consistent after their backgrounds flip.
                    ? Self.adapt(red: red, green: green, blue: blue, isBackground: true)
                    : Self.adapt(red: red, green: green, blue: blue, isBackground: isBackground)
                output += [values[index], "2", String(light.red), String(light.green), String(light.blue)]
                index += 5
            } else if isColor, index + 2 < values.count, values[index + 1] == "5",
                      let paletteIndex = Int(values[index + 2]),
                      // 0–15 resolve through the installed ANSI palette, which is
                      // already themed; rewriting them here would flip them twice.
                      (16...255).contains(paletteIndex) {
                let base = Self.xterm256RGB(paletteIndex)
                let light = preservePowerlineForeground && !isBackground
                    ? Self.adapt(red: base.red, green: base.green, blue: base.blue, isBackground: true)
                    : Self.adapt(red: base.red, green: base.green, blue: base.blue, isBackground: isBackground)
                output += [values[index], "2", String(light.red), String(light.green), String(light.blue)]
                index += 3
            } else {
                output.append(values[index])
                index += 1
            }
        }

        return [0x1B, 0x5B] + Array(output.joined(separator: ";").utf8) + [0x6D]
    }

    private static func clamp(_ value: Double) -> Int {
        min(255, max(0, Int(value.rounded())))
    }
}
