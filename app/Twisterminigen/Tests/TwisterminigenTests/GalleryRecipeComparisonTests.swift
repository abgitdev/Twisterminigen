import Foundation
import Testing
@testable import Twisterminigen

@Suite("Gallery recipe comparison")
struct GalleryRecipeComparisonTests {
    @Test("Identical recipes have no highlighted rows")
    func identicalRecipes() {
        let recipe = comparisonRecipe()
        let comparison = GalleryRecipeComparison(left: recipe, right: recipe)

        #expect(comparison.differenceCount == 0)
        #expect(comparison.rows.count == 19)
        #expect(Set(comparison.rows.map(\.label)).count == comparison.rows.count)
    }

    @Test("Schema, version, and region identity participate in the diff")
    func identityFieldsParticipate() {
        let left = comparisonRecipe()
        var right = left
        right.schema = "future.recipe"
        right.version = 99
        right.regions[0].id = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

        let comparison = GalleryRecipeComparison(left: left, right: right)
        let differences = Set(comparison.rows.filter { $0.isDifferent }.map(\.label))

        #expect(differences == ["Recipe schema", "Recipe version", "Regions"])
    }
}

private func comparisonRecipe() -> GenerationRecipe {
    var recipe = Generation.compatibilityRecipe(
        prompt: "compare",
        width: 512,
        height: 640,
        steps: 8,
        seed: 42)
    recipe.prompts.negative = "blur"
    recipe.prompts.exactText = "HELLO"
    recipe.regions = [.init(
        id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
        prompt: "subject",
        rect: .init(x0: 0, y0: 0, x1: 0.5, y1: 1))]
    return recipe
}
