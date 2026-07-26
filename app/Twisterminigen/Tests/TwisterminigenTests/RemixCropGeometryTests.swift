import Foundation
import Testing
@testable import Twisterminigen

@Suite("Remix crop geometry")
struct RemixCropGeometryTests {
    @Test("Out-of-range and reversed coordinates become a valid normalized rectangle")
    func clampingOrdersAndBoundsCoordinates() {
        let result = RemixCropGeometry.clamped(.init(
            x0: -0.3,
            y0: 0.9,
            x1: 0.4,
            y1: 0.2))

        #expect(result == .init(x0: 0, y0: 0.2, x1: 0.4, y1: 0.9))
        #expect(result.x0 >= 0 && result.y0 >= 0)
        #expect(result.x1 <= 1 && result.y1 <= 1)
        #expect(result.width > 0 && result.height > 0)
    }

    @Test("Moving preserves size and stops at source boundaries")
    func movingPreservesExtent() {
        let source = GenerationRecipe.NormalizedRect(x0: 0.2, y0: 0.3, x1: 0.6, y1: 0.8)
        let result = RemixCropGeometry.moved(source, deltaX: 1, deltaY: -1)

        #expect(close(result.x0, 0.6))
        #expect(close(result.y0, 0))
        #expect(close(result.x1, 1))
        #expect(close(result.y1, 0.5))
        #expect(close(result.width, source.width))
        #expect(close(result.height, source.height))
    }

    @Test("Resize handles stay clamped and cannot invert the crop")
    func resizingAnchorsOppositeCorner() {
        let source = GenerationRecipe.NormalizedRect(x0: 0.2, y0: 0.2, x1: 0.8, y1: 0.8)
        let contracted = RemixCropGeometry.resized(
            source,
            handle: .topLeft,
            deltaX: 0.9,
            deltaY: 0.9,
            minimumExtent: 0.1)
        let expanded = RemixCropGeometry.resized(
            contracted,
            handle: .bottomRight,
            deltaX: 1,
            deltaY: 1,
            minimumExtent: 0.1)

        #expect(close(contracted.x0, 0.7))
        #expect(close(contracted.y0, 0.7))
        #expect(close(contracted.x1, 0.8))
        #expect(close(contracted.y1, 0.8))
        #expect(close(expanded.x0, 0.7))
        #expect(close(expanded.y0, 0.7))
        #expect(close(expanded.x1, 1))
        #expect(close(expanded.y1, 1))
    }

    @Test("Exact inspector values are clamped as one normalized crop")
    func exactReplacementClampsAtFarEdge() {
        let result = RemixCropGeometry.replacing(
            RemixCropGeometry.fullImage,
            x: 0.95,
            y: -0.1,
            width: 0.4,
            height: 0.3)

        #expect(close(result.x, 0.6))
        #expect(close(result.y, 0))
        #expect(close(result.width, 0.4))
        #expect(close(result.height, 0.3))
    }

    @Test("Editing an origin from the full image keeps the opposite edge anchored")
    func exactOriginCreatesACrop() {
        let result = RemixCropGeometry.replacing(RemixCropGeometry.fullImage, x: 0.25, y: 0.1)

        #expect(close(result.x, 0.25))
        #expect(close(result.y, 0.1))
        #expect(close(result.x1, 1))
        #expect(close(result.y1, 1))
    }

    @Test("A visual crop round-trips exactly without changing Fit semantics")
    func cropRecipeRoundTrip() throws {
        let managedID = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let model = GenerationRecipe.ModelReference(
            modelID: "test-model",
            variantID: "test-variant",
            manifestHash: String(repeating: "a", count: 64))
        var recipe = GenerationRecipe.turbo(prompt: "crop round trip", model: model)
        let crop = RemixCropGeometry.resized(
            RemixCropGeometry.fullImage,
            handle: .bottomRight,
            deltaX: -0.25,
            deltaY: -0.4)
        recipe.inputImage = .init(
            managedID: managedID,
            sha256: String(repeating: "b", count: 64),
            strength: 0.55,
            resize: .fit,
            crop: crop)

        try recipe.validate(for: .request)
        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(GenerationRecipe.self, from: encoded)

        #expect(decoded == recipe)
        #expect(decoded.inputImage?.crop == crop)
        #expect(decoded.inputImage?.resize == .fit)
        #expect(decoded.inputImage?.strength == 0.55)
    }

    private func close(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-12) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
