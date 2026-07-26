import Foundation
import Testing
@testable import Twisterminigen

@Suite("Queue immutable duplication and repetition")
struct QueuePolishTests {
    @Test("Seed strategies are explicit and experiment provenance never leaks to a copy")
    func duplicateSeedStrategies() throws {
        let source = queuePolishJob(seed: .fixed(100), provenance: .batch(
            groupID: UUID(),
            itemIndex: 0,
            itemCount: 2))

        let same = try source.duplicate(seedMode: .same)
        let random = try source.duplicate(seedMode: .random)
        let sequential = try source.duplicate(seedMode: .sequential, sequenceOffset: 5)

        #expect(same.recipe.sampler.seed == .fixed(100))
        #expect(random.recipe.sampler.seed == .random)
        #expect(sequential.recipe.sampler.seed == .fixed(105))
        #expect([same, random, sequential].allSatisfy { $0.id != source.id })
        #expect([same, random, sequential].allSatisfy { $0.provenance == nil })

        let unresolved = queuePolishJob(seed: .random)
        #expect(throws: QueueJobDuplicationError.sequentialSeedRequiresFixedSeed) {
            try unresolved.duplicate(seedMode: .sequential)
        }
        let maximum = queuePolishJob(seed: .fixed(.max))
        #expect(throws: QueueJobDuplicationError.self) {
            try maximum.duplicate(seedMode: .sequential)
        }
    }

    @Test("Generate Again is one durable ordered transaction")
    func durableGenerateAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterQueuePolish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let store = try QueueStore(fileURL: url)
        let source = queuePolishJob(seed: .fixed(200), provenance: .batch(
            groupID: UUID(),
            itemIndex: 0,
            itemCount: 2))
        try await store.enqueue(source)
        let ids = (0 ..< 3).map { _ in UUID() }

        let copies = try await store.duplicate(
            id: source.id,
            count: 3,
            seedMode: .sequential,
            newID: { ids[$0] })

        #expect(copies.map(\.id) == ids)
        #expect(copies.map(\.recipe.sampler.seed) == [.fixed(201), .fixed(202), .fixed(203)])
        #expect(copies.allSatisfy { $0.provenance == nil })
        let reopened = try QueueStore(fileURL: url)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.pending.map(\.id) == [source.id] + ids)
        #expect(snapshot.pending.map(\.recipe.sampler.seed) == [
            .fixed(200), .fixed(201), .fixed(202), .fixed(203),
        ])
    }

    private func queuePolishJob(
        seed: GenerationRecipe.Seed,
        provenance: GenerationProvenance? = nil
    ) -> QueueJob {
        var recipe = GenerationRecipe.turbo(
            prompt: "source prompt",
            negativePrompt: "no text",
            model: QueueJob.legacyModelReference,
            seed: seed)
        recipe.canvas = .init(width: 512, height: 512)
        recipe.sampler.steps = 8
        recipe.sampler.guidance = 1.25
        recipe.loras = [.init(
            managedID: UUID(),
            sha256: String(repeating: "a", count: 64),
            scale: 0.7)]
        recipe.regions = [.init(
            id: UUID(),
            prompt: "left",
            rect: .init(x0: 0, y0: 0, x1: 0.5, y1: 1))]
        recipe.inputImage = .init(
            managedID: UUID(),
            sha256: String(repeating: "b", count: 64),
            strength: 0.4,
            resize: .fill)
        return QueueJob(recipe: recipe, provenance: provenance)
    }
}
