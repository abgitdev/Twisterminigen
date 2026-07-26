import Foundation
import Testing
@testable import Twisterminigen

@Suite("Local render Shortcut", .serialized)
struct ShortcutRecipeTests {
    @Test("Stable JSON maps to one text-only generation recipe")
    func decodeAndMap() throws {
        let recipe = try ShortcutRecipe.decode(json: """
        {"prompt":"  a blue poster reading HELLO  ","width":1920,"height":1088,"steps":12,"seed":42}
        """)
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/shortcut-model"))
        let native = try recipe.generationRecipe(catalog: catalog)

        #expect(native.prompts.positive == "a blue poster reading HELLO")
        #expect(native.canvas == .init(width: 1_920, height: 1_088))
        #expect(native.sampler.steps == 12)
        #expect(native.sampler.seed == .fixed(42))
        #expect(native.model == catalog.generationReference)
        #expect(native.loras.isEmpty)
        #expect(native.regions.isEmpty)
        #expect(native.inputImage == nil)
    }

    @Test("Defaults are explicit and a random seed resolves before persistence")
    func defaults() throws {
        let recipe = try ShortcutRecipe.decode(json: #"{"prompt":"poster"}"#)
        let native = try recipe.generationRecipe(
            catalog: ModelCatalog(root: URL(fileURLWithPath: "/tmp/shortcut-defaults")))
        #expect(recipe.width == 1_024)
        #expect(recipe.height == 1_024)
        #expect(recipe.steps == 8)
        #expect(native.sampler.seed.fixedValue != nil)
    }

    @Test("Unknown capabilities, invalid grid and invalid step count fail closed")
    func invalidInputs() {
        #expect(throws: ShortcutRecipeError.unknownFields(["batch"])) {
            _ = try ShortcutRecipe.decode(json:
                #"{"prompt":"bird","width":1024,"height":1024,"batch":4}"#)
        }
        #expect(throws: ShortcutRecipeError.unknownFields(["url"])) {
            _ = try ShortcutRecipe.decode(json:
                #"{"prompt":"bird","url":"file:///tmp/private.png"}"#)
        }
        #expect(throws: ShortcutRecipeError.invalidSize(width: 1_001, height: 1_024)) {
            _ = try ShortcutRecipe.decode(json:
                #"{"prompt":"bird","width":1001,"height":1024}"#)
        }
        #expect(throws: ShortcutRecipeError.invalidSteps(48)) {
            _ = try ShortcutRecipe.decode(json:
                #"{"prompt":"bird","steps":48}"#)
        }
    }

    @Test("The App Intent reaches an injected headless renderer without inference")
    @MainActor
    func intentUsesInjectedRuntime() async throws {
        let expected = dummyGeneration()
        var received: ShortcutRecipe?
        ShortcutRenderRuntime.configure { recipe in
            received = recipe
            return expected
        }
        defer { ShortcutRenderRuntime.reset() }

        let intent = RenderRecipeIntent(recipeJSON:
            #"{"prompt":"headless contract","width":512,"height":512,"steps":8,"seed":7}"#)
        _ = try await intent.perform()

        #expect(received?.prompt == "headless contract")
        #expect(received?.seed == 7)
    }

    @Test("Intent validation happens before runtime lookup")
    @MainActor
    func invalidIntentDoesNotNeedRuntime() async {
        ShortcutRenderRuntime.reset()
        let intent = RenderRecipeIntent(recipeJSON:
            #"{"prompt":"poster","width":999,"height":1024}"#)
        do {
            _ = try await intent.perform()
            Issue.record("Invalid Shortcut input must not reach the renderer")
        } catch {
            #expect(error as? ShortcutRecipeError == .invalidSize(width: 999, height: 1_024))
        }
    }

    private func dummyGeneration() -> Generation {
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/shortcut-dummy"))
        let recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "headless contract",
            width: 512,
            height: 512,
            steps: 8,
            seed: .fixed(7),
            catalog: catalog)
        return Generation(
            recipe: recipe,
            durationSeconds: 1,
            imageFileName: "dummy.png")
    }
}
