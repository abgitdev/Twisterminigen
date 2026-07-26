import Foundation
import Krea2Core
import Krea2Pipeline
import Krea2Sampler
import Krea2TextEncoder
import MLX

enum GenerationRecipeRuntime {
    enum RuntimeError: Error, Equatable, Sendable {
        case modelMismatch(
            expected: GenerationRecipe.ModelReference,
            actual: GenerationRecipe.ModelReference)
        case unresolvedSeed
        case regionalGuidanceUnsupported
        case unresolvedInputImage
        case contentPolicyViolation(ReasonableContentFilter.Category)
    }

    static func currentTurboRecipe(
        prompt: String,
        negativePrompt: String = "",
        width: Int,
        height: Int,
        steps: Int,
        seed: GenerationRecipe.Seed,
        catalog: ModelCatalog,
        quantizationTier: GenerationRecipe.QuantizationTier = .mixed4And8
    ) -> GenerationRecipe {
        var recipe = GenerationRecipe.turbo(
            prompt: prompt,
            negativePrompt: negativePrompt,
            model: catalog.generationReference(for: quantizationTier),
            seed: seed)
        recipe.canvas = .init(width: width, height: height)
        recipe.sampler.steps = steps
        return recipe
    }

    static func plannedRequest(
        for recipe: GenerationRecipe,
        catalog: ModelCatalog,
        inputImage: Krea2Pipeline.ImageInput? = nil
    ) throws -> Krea2Pipeline.PlannedRequest {
        try validateConfiguration(for: recipe, catalog: catalog)
        guard let seed = recipe.sampler.seed.fixedValue else {
            throw RuntimeError.unresolvedSeed
        }

        var params = Krea2Sampler.Params()
        params.width = recipe.canvas.width
        params.height = recipe.canvas.height
        params.steps = recipe.sampler.steps
        params.seed = seed
        params.guidance = Float(recipe.sampler.guidance)
        params.mu = recipe.sampler.schedule.mu
        params.minres = recipe.sampler.schedule.minres
        params.maxres = recipe.sampler.schedule.maxres
        params.y1 = recipe.sampler.schedule.y1
        params.y2 = recipe.sampler.schedule.y2
        params.dtype = dtype(for: recipe.sampler.precision)

        let regions = recipe.regions.map { region in
            Krea2Region(
                prompt: region.prompt,
                bbox: Krea2RegionBBox(
                    x0: region.rect.x0,
                    y0: region.rect.y0,
                    x1: region.rect.x1,
                    y1: region.rect.y1))
        }

        if recipe.inputImage != nil, inputImage == nil {
            throw RuntimeError.unresolvedInputImage
        }

        let renderedPrompt = try ExactTextPrompt.compose(
            basePrompt: recipe.prompts.positive,
            exactText: recipe.prompts.exactText)
        return Krea2Pipeline.PlannedRequest(
            prompt: renderedPrompt,
            negativePrompt: recipe.prompts.negative,
            params: params,
            regions: regions,
            inputImage: inputImage,
            imageStrength: Float(recipe.inputImage?.strength ?? 1))
    }

    static func validateConfiguration(
        for recipe: GenerationRecipe,
        catalog: ModelCatalog
    ) throws {
        try recipe.validate(for: .request)
        do {
            try ReasonableContentFilter.validate(recipe: recipe)
        } catch let finding as ReasonableContentFilter.Finding {
            throw RuntimeError.contentPolicyViolation(finding.category)
        }
        let expectedModel = catalog.generationReference(for: recipe.model.quantizationTier)
        guard recipe.model == expectedModel else {
            throw RuntimeError.modelMismatch(expected: expectedModel, actual: recipe.model)
        }
        if !recipe.regions.isEmpty, recipe.sampler.guidance != 0 {
            throw RuntimeError.regionalGuidanceUnsupported
        }
    }

    private static func dtype(for precision: GenerationRecipe.Precision) -> DType {
        switch precision {
        case .bfloat16: .bfloat16
        case .float16: .float16
        case .float32: .float32
        }
    }
}

extension GenerationRecipeRuntime.RuntimeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .modelMismatch:
            return "This recipe targets a different model build. Restore its exact weights before replaying it."
        case .unresolvedSeed:
            return "The recipe seed must be resolved before rendering."
        case .regionalGuidanceUnsupported:
            return "Regional prompts require Turbo CFG 0."
        case .unresolvedInputImage:
            return "The Remix source is missing or no longer matches its managed copy."
        case .contentPolicyViolation(let category):
            return ReasonableContentFilter.Finding(category: category).localizedDescription
        }
    }
}
