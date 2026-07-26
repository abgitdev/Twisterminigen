import Foundation
import Testing
@testable import Twisterminigen

@Suite("Gallery Remix lineage")
struct GalleryLineageTests {
    @Test("Pre-lineage Remix recipes remain decodable")
    func legacyRecipeDecodesWithoutParent() throws {
        var recipe = lineageRecipe(parentID: UUID())
        let encoded = try JSONEncoder().encode(recipe)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var input = try #require(object["inputImage"] as? [String: Any])
        input.removeValue(forKey: "sourceGenerationID")
        object["inputImage"] = input
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        recipe = try JSONDecoder().decode(GenerationRecipe.self, from: legacyData)
        #expect(recipe.parentGenerationID == nil)
        #expect(recipe.inputImage != nil)
        try recipe.validate(for: .persistedResult)
    }

    @Test("Recipe, Queue job, and Generation Codable round trips preserve one parent ID")
    func durablePropagation() throws {
        let parentID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let recipe = lineageRecipe(parentID: parentID)
        let queue = QueueJob(recipe: recipe)
        let generation = Generation(
            recipe: recipe,
            durationSeconds: 2,
            imageFileName: "child.png")

        let decoder = JSONDecoder()
        let queuedAgain = try decoder.decode(
            QueueJob.self,
            from: JSONEncoder().encode(queue))
        let generationAgain = try decoder.decode(
            Generation.self,
            from: JSONEncoder().encode(generation))

        #expect(recipe.parentGenerationID == parentID)
        #expect(queue.parentGenerationID == parentID)
        #expect(queuedAgain.parentGenerationID == parentID)
        #expect(generation.parentGenerationID == parentID)
        #expect(generationAgain.parentGenerationID == parentID)
    }

    @Test("Queue duplication retains Remix lineage")
    func queueDuplicationRetainsParent() throws {
        let parentID = UUID()
        let source = QueueJob(recipe: lineageRecipe(parentID: parentID))
        let duplicated = try source.duplicate(seedMode: .same)

        #expect(duplicated.parentGenerationID == parentID)
    }

    @Test("QueueStore restart retains Remix lineage")
    func queueStoreRestartRetainsParent() async throws {
        let fixture = try LineageFixture()
        defer { fixture.remove() }
        let parentID = UUID()
        let job = QueueJob(recipe: lineageRecipe(parentID: parentID))
        let fileURL = fixture.container.appendingPathComponent("queue.json")
        let store = try QueueStore(fileURL: fileURL)

        try await store.enqueue(job)
        let reopened = try QueueStore(fileURL: fileURL)

        #expect(await reopened.snapshot().pending.first?.parentGenerationID == parentID)
    }

    @Test("GenerationStore restart retains Remix lineage")
    func generationStoreRestartRetainsParent() async throws {
        let fixture = try LineageFixture()
        defer { fixture.remove() }
        let parentID = UUID()
        let store = GenerationStore(paths: fixture.paths)

        let saved = try await store.save(
            pngData: Data("lineage image".utf8),
            recipe: lineageRecipe(parentID: parentID),
            duration: 1)
        let reopened = GenerationStore(paths: fixture.paths)
        let restored = await reopened.all()

        #expect(saved.parentGenerationID == parentID)
        #expect(restored.first?.id == saved.id)
        #expect(restored.first?.parentGenerationID == parentID)
    }

    @Test("Gallery resolves direct parent and all direct children")
    @MainActor
    func viewModelResolvesLineage() throws {
        let fixture = try LineageFixture()
        defer { fixture.remove() }
        let parentID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let firstChildID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let secondChildID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let parent = Generation(
            id: parentID,
            recipe: plainRecipe(seed: 1),
            durationSeconds: 1,
            imageFileName: "parent.png")
        let firstChild = Generation(
            id: firstChildID,
            recipe: lineageRecipe(parentID: parentID, seed: 2),
            durationSeconds: 1,
            imageFileName: "first.png")
        let secondChild = Generation(
            id: secondChildID,
            recipe: lineageRecipe(parentID: parentID, seed: 3),
            durationSeconds: 1,
            imageFileName: "second.png")
        let viewModel = GalleryViewModel(
            store: GenerationStore(paths: fixture.paths),
            annotations: GalleryAnnotationStore(fileURL: fixture.paths.galleryAnnotations))
        viewModel.generations = [secondChild, firstChild, parent]

        #expect(viewModel.parentGeneration(of: firstChild)?.id == parentID)
        #expect(viewModel.childGenerations(of: parent).map(\.id) == [secondChildID, firstChildID])
        #expect(viewModel.selectGeneration(id: parentID))
        #expect(viewModel.selected?.id == parentID)
        #expect(!viewModel.selectGeneration(id: UUID()))
        #expect(viewModel.selected?.id == parentID)
    }
}

private func lineageRecipe(parentID: UUID, seed: UInt64 = 9) -> GenerationRecipe {
    var recipe = plainRecipe(seed: seed)
    recipe.inputImage = .init(
        managedID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
        sha256: String(repeating: "d", count: 64),
        strength: 0.6,
        resize: .fill,
        sourceGenerationID: parentID)
    return recipe
}

private func plainRecipe(seed: UInt64) -> GenerationRecipe {
    GenerationRecipe.turbo(
        prompt: "lineage",
        model: .init(
            modelID: "test-model",
            variantID: "test-variant",
            manifestHash: String(repeating: "e", count: 64)),
        seed: .fixed(seed))
}

private struct LineageFixture {
    let container: URL
    let paths: LibraryPaths

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalleryLineageTests-\(UUID().uuidString)", isDirectory: true)
        paths = LibraryPaths(
            root: container.appendingPathComponent("Library", isDirectory: true),
            thumbnails: container.appendingPathComponent("Thumbnails", isDirectory: true))
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
