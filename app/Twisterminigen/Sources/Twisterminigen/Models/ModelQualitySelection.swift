import Foundation
import Observation

/// Shared, persisted selection between Models and Generate.
///
/// Only the two validated Turbo representations are legal here. Raw and in-app model training are
/// intentionally outside the product scope and cannot be smuggled into this quality selector.
@MainActor
@Observable
final class ModelQualitySelection {
    private static let defaultsKey = "modelQuality.turbo.v1"

    private let defaults: UserDefaults
    var tier: GenerationRecipe.QuantizationTier {
        didSet { defaults.set(tier.rawValue, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.defaultsKey),
           let restored = GenerationRecipe.QuantizationTier(rawValue: raw) {
            tier = restored
        } else {
            tier = .mixed4And8
        }
    }

    func select(_ tier: GenerationRecipe.QuantizationTier) {
        self.tier = tier
    }

    func resetToDefault() {
        tier = .mixed4And8
    }
}
