import Foundation
import Observation
import SwiftUI

/// The app's visual treatments. Dark remains the launch default; Light provides
/// an opaque high-contrast workspace, while Glass is the opt-in aurora treatment.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .glass: "Glass"
        }
    }

    var summary: String {
        switch self {
        case .dark:
            "The focused, high-contrast workspace used by default."
        case .light:
            "A bright, opaque workspace with dark, readable controls."
        case .glass:
            "A brighter Liquid Glass workspace over the aurora background."
        }
    }

    /// Glass intentionally uses dark system controls so its labels remain legible
    /// over the aurora backdrop. The opaque themes map directly to their names.
    var preferredColorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark, .glass: .dark
        }
    }
}

/// Persisted appearance choice shared by the window chrome and the System screen.
@MainActor
@Observable
final class AppThemePreferences {
    private enum Key {
        static let selection = "appearance.theme"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var selection: AppTheme {
        didSet { defaults.set(selection.rawValue, forKey: Key.selection) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Key.selection)
            .flatMap(AppTheme.init(rawValue:))
            ?? .dark
    }
}
