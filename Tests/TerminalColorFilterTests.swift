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

        var splitAdapter = LightTerminalANSIAdapter()
        let first = Array("before\u{1B}[48;2;30;".utf8)
        let second = Array("30;30mafter".utf8)
        let splitResult = splitAdapter.transform(first[...]) + splitAdapter.transform(second[...])
        expect(
            String(decoding: splitResult, as: UTF8.self) == "before\u{1B}[48;2;225;225;225mafter",
            "split escape sequences should be transformed without corruption"
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
