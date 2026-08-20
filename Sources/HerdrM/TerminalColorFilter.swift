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
            output.append(contentsOf: pending[end] == 0x6D ? transformSGR(sequence) : sequence)
            index = end + 1
        }

        if index > 0 {
            pending.removeFirst(index)
        }
        return output
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

    private func transformSGR(_ sequence: [UInt8]) -> [UInt8] {
        guard sequence.count >= 3 else { return sequence }
        let parameters = sequence[2..<(sequence.count - 1)]
        var values = String(decoding: parameters, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        var index = 0

        while index + 4 < values.count {
            guard (values[index] == "38" || values[index] == "48"),
                  values[index + 1] == "2",
                  let red = Int(values[index + 2]),
                  let green = Int(values[index + 3]),
                  let blue = Int(values[index + 4]),
                  (0...255).contains(red),
                  (0...255).contains(green),
                  (0...255).contains(blue)
            else {
                index += 1
                continue
            }

            let light = Self.lightRGB(red: red, green: green, blue: blue)
            values[index + 2] = String(light.red)
            values[index + 3] = String(light.green)
            values[index + 4] = String(light.blue)
            index += 5
        }

        return [0x1B, 0x5B] + Array(values.joined(separator: ";").utf8) + [0x6D]
    }

    private static func clamp(_ value: Double) -> Int {
        min(255, max(0, Int(value.rounded())))
    }
}
