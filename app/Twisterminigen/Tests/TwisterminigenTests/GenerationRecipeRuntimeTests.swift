import Foundation
import Krea2Pipeline
import Testing
@testable import Twisterminigen

@Suite("Generation recipe runtime")
struct GenerationRecipeRuntimeTests {
    @Test("Current Turbo recipes use the pinned catalog identity")
    func currentRecipeUsesPinnedCatalog() throws {
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/runtime-models"))
        let recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "  lighthouse in rain  ",
            negativePrompt: "letters",
            width: 1_280,
            height: 720,
            steps: 9,
            seed: .fixed(42),
            catalog: catalog)

        #expect(recipe.model == catalog.generationReference)
        #expect(recipe.prompts.positive == "  lighthouse in rain  ")
        #expect(recipe.prompts.negative == "letters")
        #expect(recipe.canvas == .init(width: 1_280, height: 720))
        #expect(recipe.sampler.steps == 9)
        #expect(recipe.sampler.seed == .fixed(42))
        try recipe.validate(for: .persistedResult)
    }

    @Test("The adapter maps every sampler and prompt field")
    func mapsAllSupportedFields() throws {
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/runtime-models"))
        var recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "positive",
            negativePrompt: "negative",
            width: 768,
            height: 512,
            steps: 12,
            seed: .fixed(UInt64.max),
            catalog: catalog)
        recipe.sampler.guidance = 3.5
        recipe.sampler.schedule = .init(
            mu: 1.25,
            minres: 512,
            maxres: 2_048,
            y1: 0.6,
            y2: 1.4)
        recipe.sampler.precision = .float16
        recipe.prompts.exactText = "OPEN \"LATE\""

        let request = try GenerationRecipeRuntime.plannedRequest(for: recipe, catalog: catalog)

        #expect(request.prompt == "positive\n\nLettering to appear (exact spelling is not guaranteed):\nOPEN \"LATE\"")
        #expect(request.negativePrompt == "negative")
        #expect(request.params.width == 768)
        #expect(request.params.height == 512)
        #expect(request.params.steps == 12)
        #expect(request.params.seed == UInt64.max)
        #expect(request.params.guidance == 3.5)
        #expect(request.params.mu == 1.25)
        #expect(request.params.minres == 512)
        #expect(request.params.maxres == 2_048)
        #expect(request.params.y1 == 0.6)
        #expect(request.params.y2 == 1.4)
        #expect(String(describing: request.params.dtype) == "float16")
    }

    @Test("The adapter maps connected LoRA, region, and image resources without fallback")
    func mapsConnectedResources() throws {
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/runtime-models"))
        let base = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "test",
            width: 512,
            height: 512,
            steps: 8,
            seed: .fixed(1),
            catalog: catalog)

        var wrongModel = base
        wrongModel.model.manifestHash = String(repeating: "a", count: 64)
        #expect(throws: GenerationRecipeRuntime.RuntimeError.self) {
            try GenerationRecipeRuntime.plannedRequest(for: wrongModel, catalog: catalog)
        }

        var lora = base
        lora.loras = [.init(managedID: UUID(), sha256: String(repeating: "b", count: 64), scale: 1)]
        let loraRequest = try GenerationRecipeRuntime.plannedRequest(for: lora, catalog: catalog)
        #expect(loraRequest.prompt == "test")

        var regional = base
        regional.regions = [.init(
            id: UUID(),
            prompt: "left",
            rect: .init(x0: 0, y0: 0, x1: 0.5, y1: 1))]
        let regionalRequest = try GenerationRecipeRuntime.plannedRequest(
            for: regional,
            catalog: catalog)
        #expect(regionalRequest.regions.count == 1)
        #expect(regionalRequest.regions[0].prompt == "left")

        var image = base
        image.inputImage = .init(
            managedID: UUID(),
            sha256: String(repeating: "c", count: 64),
            strength: 0.5,
            resize: .fit)
        #expect(throws: GenerationRecipeRuntime.RuntimeError.unresolvedInputImage) {
            try GenerationRecipeRuntime.plannedRequest(for: image, catalog: catalog)
        }
        let pixels = [Float](repeating: 0, count: 3 * 512 * 512)
        let input = try Krea2Pipeline.ImageInput(
            width: 512,
            height: 512,
            planarRGB: pixels)
        let imageRequest = try GenerationRecipeRuntime.plannedRequest(
            for: image,
            catalog: catalog,
            inputImage: input)
        #expect(imageRequest.inputImage?.width == 512)
        #expect(imageRequest.imageStrength == 0.5)
    }
}
