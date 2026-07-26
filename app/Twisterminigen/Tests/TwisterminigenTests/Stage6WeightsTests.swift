import Foundation
import Krea2DiT
import Testing
@testable import Twisterminigen

@Suite("Stage 6 additional weights")
struct Stage6WeightsTests {
    @Test("Quality tier cards reserve one equal action row")
    func qualityCardGeometry() {
        #expect(ModelsQualityCardLayout.actionRowMinimumHeight == 28)
        #expect(ModelsQualityCardLayout.minimumHeight
            > ModelsQualityCardLayout.actionRowMinimumHeight)
    }

    @Test("Default stays mixed-4/8 and Best Fidelity persists as q8")
    @MainActor
    func selectionPersistence() {
        let defaults = VolatileUserDefaults()

        let initial = ModelQualitySelection(defaults: defaults)
        #expect(initial.tier == .mixed4And8)

        initial.select(.q8)
        let restored = ModelQualitySelection(defaults: defaults)
        #expect(restored.tier == .q8)

        restored.resetToDefault()
        #expect(ModelQualitySelection(defaults: defaults).tier == .mixed4And8)
    }

    @Test("q8 recipe resolves the q8 artifact and engine recipe exactly")
    func q8RuntimeMapping() throws {
        let root = URL(fileURLWithPath: "/tmp/stage6-models", isDirectory: true)
        let catalog = ModelCatalog(root: root)
        let reference = catalog.generationReference(for: .q8)
        let recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "same-seed fidelity gate",
            width: 1_024,
            height: 1_024,
            steps: 8,
            seed: .fixed(6_008),
            catalog: catalog,
            quantizationTier: .q8)

        #expect(recipe.model == reference)
        try GenerationRecipeRuntime.validateConfiguration(for: recipe, catalog: catalog)

        let weights = GenerateViewModel.makeWeights(catalog: catalog, model: reference)
        #expect(weights.ditQuantization == Krea2DiTQuantization.q8)
        #expect(weights.ditQuantFile == root
            .appendingPathComponent("alis-q8", isDirectory: true)
            .appendingPathComponent("transformer_8bit.safetensors"))
        #expect(weights.verifiedModelIdentity == reference.manifestHash)
    }

    @Test("Default and q8 snapshots cannot share one resident Queue session")
    func quantizationSeparatesSessionIdentity() {
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/stage6-session"))
        let mixed = GenerationRecipe.turbo(
            prompt: "same",
            model: catalog.generationReference(for: .mixed4And8),
            seed: .fixed(44))
        var q8 = mixed
        q8.model = catalog.generationReference(for: .q8)

        #expect(mixed.model.quantizationTier == .mixed4And8)
        #expect(q8.model.quantizationTier == .q8)
        #expect(mixed.sessionKey != q8.sessionKey)
    }
}
