import Foundation
import Testing
@testable import Twisterminigen

@Suite("App theme preferences")
@MainActor
struct AppThemePreferencesTests {
    @Test("Dark is the default theme")
    func darkIsDefault() {
        let fixture = ThemeDefaultsFixture()

        let preferences = AppThemePreferences(defaults: fixture.defaults)

        #expect(preferences.selection == .dark)
    }

    @Test("Theme catalog exposes Dark, Light, and Glass")
    func completeThemeCatalog() {
        #expect(AppTheme.allCases == [.dark, .light, .glass])
    }

    @Test("Every theme selection persists between preference instances", arguments: AppTheme.allCases)
    func everySelectionPersists(theme: AppTheme) {
        let fixture = ThemeDefaultsFixture()

        let preferences = AppThemePreferences(defaults: fixture.defaults)
        preferences.selection = theme

        let restored = AppThemePreferences(defaults: fixture.defaults)
        #expect(restored.selection == theme)
    }

    @Test("Themes request a readable system color scheme")
    func preferredColorSchemes() {
        #expect(AppTheme.light.preferredColorScheme == .light)
        #expect(AppTheme.dark.preferredColorScheme == .dark)
        #expect(AppTheme.glass.preferredColorScheme == .dark)
    }

    @Test("An invalid persisted theme safely falls back to dark")
    func invalidSelectionFallsBackToDark() throws {
        let fixture = ThemeDefaultsFixture()

        let preferences = AppThemePreferences(defaults: fixture.defaults)
        preferences.selection = .glass

        let themeKey = try #require(fixture.defaults.dictionaryRepresentation().first(
            where: { _, value in
            value as? String == AppTheme.glass.rawValue
        })?.key)
        fixture.defaults.set("unsupported-theme", forKey: themeKey)

        let restored = AppThemePreferences(defaults: fixture.defaults)
        #expect(restored.selection == .dark)
    }
}

private struct ThemeDefaultsFixture {
    let defaults: UserDefaults = VolatileUserDefaults()
}
