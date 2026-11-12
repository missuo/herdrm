import AppKit
import CoreText
import Testing
@testable import herdrm

@Suite(.serialized) @MainActor
struct TerminalFontResolutionTests {
    @Test(arguments: [Double(NSFont.Weight.regular.rawValue), Double(NSFont.Weight.medium.rawValue)])
    func systemMonoUsesADiscoverableSystemFamily(weight: Double) throws {
        let family = TerminalDefaults.systemMonospacedFamily(
            fontSize: 14, fontWeight: weight
        )
        let expected = NSFont.monospacedSystemFont(
            ofSize: 14, weight: NSFont.Weight(rawValue: CGFloat(weight))
        )

        // Match the family through CoreText's collection API, as Ghostty does.
        // CTFontCreateWithName alone silently returns a substitute for a miss.
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
        ] as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        let matches = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        #expect(!matches.isEmpty, "The configured System Mono family must resolve instead of using Ghostty's fallback.")
        #expect(family == expected.familyName)
        #expect(matches.contains { descriptor in
            let font = CTFontCreateWithFontDescriptor(descriptor, 14, nil)
            return CTFontCopyPostScriptName(font) as String == expected.fontName
        })
    }

    @Test func fontConfigurationPreservesSizeWeightSpacingAndExplicitFamily() {
        let weight = Double(NSFont.Weight.medium.rawValue)
        for family in ["", "Menlo"] {
            let configuration = GhosttyRuntime.fontConfiguration(
                fontName: family, fontSize: 14, fontWeight: weight,
                thinStrokes: false, lineSpacing: 1.2, copyOnSelect: false
            )
            let lines = configuration.rendered.split(separator: "\n")

            #expect(lines.contains("font-size = 14"))
            #expect(lines.contains("adjust-cell-height = 20%"))
            if family.isEmpty {
                let systemFamily = TerminalDefaults.systemMonospacedFamily(fontSize: 14, fontWeight: weight)
                #expect(lines.contains(Substring("font-family = \(systemFamily)")))
                #expect(lines.contains("font-style = Medium"))
            } else {
                #expect(lines.contains("font-family = Menlo"))
                #expect(!lines.contains { $0.hasPrefix("font-style = ") })
            }
        }
    }
}
