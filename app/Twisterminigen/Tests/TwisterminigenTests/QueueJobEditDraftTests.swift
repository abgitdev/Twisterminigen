import Foundation
import Testing
@testable import Twisterminigen

@Suite("Queue job editing")
struct QueueJobEditDraftTests {
    @Test("Visible fields change while advanced recipe fields are preserved")
    func draftPreservesAdvancedRecipe() throws {
        var recipe = GenerationRecipe.turbo(
            prompt: "original",
            negativePrompt: "old negative",
            model: QueueJob.legacyModelReference,
            seed: .fixed(100))
        recipe.prompts.exactText = "OLD"
        recipe.canvas = .init(width: 512, height: 768)
        recipe.sampler.steps = 8
        recipe.sampler.guidance = 0
        recipe.loras = [.init(
            managedID: UUID(),
            sha256: String(repeating: "a", count: 64),
            scale: 0.75)]
        recipe.regions = [.init(
            id: UUID(),
            prompt: "left subject",
            rect: .init(x0: 0, y0: 0, x1: 0.5, y1: 1))]
        recipe.inputImage = .init(
            managedID: UUID(),
            sha256: String(repeating: "b", count: 64),
            strength: 0.45,
            resize: .fill)
        let job = QueueJob(recipe: recipe)
        var draft = QueueJobEditDraft(job: job)

        draft.prompt = "edited"
        draft.negativePrompt = "new negative"
        draft.exactText = "   "
        draft.width = 768
        draft.height = 512
        draft.steps = 10
        draft.seedText = "999"
        let edited = try draft.applying(to: job)

        #expect(edited.prompts.positive == "edited")
        #expect(edited.prompts.negative == "new negative")
        #expect(edited.prompts.exactText == nil)
        #expect(edited.canvas == .init(width: 768, height: 512))
        #expect(edited.sampler.steps == 10)
        #expect(edited.sampler.seed == .fixed(999))
        #expect(edited.model == recipe.model)
        #expect(edited.loras == recipe.loras)
        #expect(edited.regions == recipe.regions)
        #expect(edited.inputImage == recipe.inputImage)
        #expect(edited.sampler.guidance == recipe.sampler.guidance)
        #expect(edited.sampler.schedule == recipe.sampler.schedule)
        #expect(edited.sampler.precision == recipe.sampler.precision)
    }

    @Test("Blank seed means random and invalid seed fails before mutation")
    func seedEditingIsExplicit() throws {
        let job = QueueJob(prompt: "seed test", seedText: "7")
        var draft = QueueJobEditDraft(job: job)

        draft.seedText = " "
        #expect(try draft.applying(to: job).sampler.seed == .random)

        draft.seedText = "-1"
        #expect(!draft.seedIsValid)
        #expect(throws: QueueJobEditDraftError.invalidSeed("-1")) {
            try draft.applying(to: job)
        }
    }

    @Test("Replacing a recipe keeps identity and clears experiment provenance")
    func replacementClearsExperimentProvenance() {
        let id = UUID()
        let source = QueueJob(
            id: id,
            recipe: QueueJob(prompt: "before").recipe,
            provenance: .batch(groupID: UUID(), itemIndex: 0, itemCount: 2))
        var editedRecipe = source.recipe
        editedRecipe.prompts.positive = "after"

        let edited = source.replacingRecipe(editedRecipe)

        #expect(edited.id == id)
        #expect(edited.recipe == editedRecipe)
        #expect(edited.provenance == nil)
    }
}
