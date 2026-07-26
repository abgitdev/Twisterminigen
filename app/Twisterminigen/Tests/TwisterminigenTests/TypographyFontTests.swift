import AppKit
import SwiftUI
import Testing
@testable import Twisterminigen

@Suite("Design-system font resolution")
struct TypographyFontTests {
    @Test("Every supported weight resolves to exact system and monospaced faces")
    func exactFontFacesResolve() {
        let weights: [Font.Weight] = [
            .ultraLight, .thin, .light, .regular, .medium,
            .semibold, .bold, .heavy, .black,
        ]

        for weight in weights {
            let systemName = FxFontResolver.systemFontName(for: weight)
            let monospacedName = FxFontResolver.monospacedFontName(for: weight)
            #expect(NSFont(name: systemName, size: 13)?.fontName == systemName)
            #expect(NSFont(name: monospacedName, size: 13)?.fontName == monospacedName)
        }
    }

    @Test("Weighted monospaced faces are resolved directly, not synthesized")
    func monospacedWeightFacesDiffer() {
        let regular = FxFontResolver.monospacedFontName(for: .regular)
        #expect(FxFontResolver.monospacedFontName(for: .medium) != regular)
        #expect(FxFontResolver.monospacedFontName(for: .semibold) != regular)
        #expect(FxFontResolver.monospacedFontName(for: .bold) != regular)
    }
}
