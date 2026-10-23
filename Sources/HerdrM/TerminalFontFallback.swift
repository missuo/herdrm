import CoreText
import Foundation

/// Only map icons missing from the primary face. A blanket PUA mapping replaces
/// patched fonts' own icons (including Powerline separators) with different metrics.
enum TerminalFontFallback {
    static func ranges(primary: CFCharacterSet, symbols: CFCharacterSet) -> [ClosedRange<UInt32>] {
        var result: [ClosedRange<UInt32>] = []
        for area: ClosedRange<UInt32> in [0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD] {
            var start: UInt32?
            for scalar in area {
                let needsFallback = CFCharacterSetIsLongCharacterMember(symbols, scalar)
                    && !CFCharacterSetIsLongCharacterMember(primary, scalar)
                if needsFallback {
                    if start == nil { start = scalar }
                } else if let first = start {
                    result.append(first...(scalar - 1))
                    start = nil
                }
            }
            if let first = start { result.append(first...area.upperBound) }
        }
        return result
    }
}
