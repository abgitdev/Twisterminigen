import Foundation
import Testing
@testable import Twisterminigen

@Suite("Render session planner")
struct RenderSessionPlannerTests {
    @Test("Direct batches keep every item in bounded groups and preserve wrapping seed order")
    func directBatchIsBounded() {
        let groups = RenderSessionPlanner.directGroups(
            prompt: "test",
            width: 512,
            height: 512,
            steps: 8,
            baseSeed: UInt64.max - 1,
            count: 8)
        let items = groups.flatMap { $0 }

        #expect(groups.map(\.count) == [4, 4])
        #expect(items.count == 8)
        #expect(Array(items.map(\.seed).prefix(4)) == [UInt64.max - 1, UInt64.max, 0, 1])
        #expect(items.allSatisfy { $0.prompt == "test" })
        #expect(items.allSatisfy { $0.recipe.sampler.seed.fixedValue != nil })
        #expect(items.allSatisfy { $0.recipe.model == QueueJob.legacyModelReference })
    }

    @Test("Queue groups preserve order and resolve each random seed once")
    func queueGroupResolvesSeeds() {
        let first = job(prompt: "first", seed: "")
        let explicit = job(prompt: "second", seed: "42")
        let random = job(prompt: "third", seed: "")
        let fourth = job(prompt: "fourth", seed: "")
        let fifth = job(prompt: "fifth", seed: "")
        var calls: [UUID] = []

        let items = RenderSessionPlanner.queueGroup(
            firstJob: first,
            firstSeed: 7,
            pending: [explicit, random, fourth, fifth],
            randomSeed: { job in
                calls.append(job.id)
                return UInt64(calls.count * 100)
            },
            canInclude: { _ in true })

        #expect(items.map(\.queueJobID) == [first.id, explicit.id, random.id, fourth.id])
        #expect(items.map(\.seed) == [7, 42, 100, 200])
        #expect(items.map(\.recipe.prompts.positive) == ["first", "second", "third", "fourth"])
        #expect(calls == [random.id, fourth.id])
    }

    @Test("Queue groups preserve full recipes and stop at a session key boundary")
    func queueGroupUsesRecipeSession() {
        let first = QueueJob(recipe: plannerRecipe(prompt: "first", seed: .random))
        let sameSession = QueueJob(recipe: plannerRecipe(prompt: "same", seed: .fixed(22)))
        var otherRecipe = plannerRecipe(prompt: "boundary", seed: .random)
        otherRecipe.model.manifestHash = plannerHash("b")
        let boundary = QueueJob(recipe: otherRecipe)
        let later = QueueJob(recipe: plannerRecipe(prompt: "later", seed: .random))
        var calls: [UUID] = []

        let items = RenderSessionPlanner.queueGroup(
            firstJob: first,
            firstSeed: 11,
            pending: [sameSession, boundary, later],
            randomSeed: { job in
                calls.append(job.id)
                return 99
            },
            canInclude: { _ in true })

        #expect(items.map(\.queueJobID) == [first.id, sameSession.id])
        #expect(items.map(\.seed) == [11, 22])
        #expect(items[0].recipe == first.recipe.resolvingRandomSeed(to: 11))
        #expect(items[1].recipe == sameSession.recipe)
        #expect(items[0].recipe.loras == first.recipe.loras)
        #expect(items[0].recipe.inputImage == first.recipe.inputImage)
        #expect(calls.isEmpty)
    }

    @Test("An unsafe or duplicate pending job ends the contiguous group")
    func queueGroupStopsAtBoundary() {
        let first = job(prompt: "first", seed: "1")
        let safe = job(prompt: "safe", seed: "2")
        let unsafe = job(prompt: "unsafe", seed: "3")
        let later = job(prompt: "later", seed: "4")

        let unsafeItems = RenderSessionPlanner.queueGroup(
            firstJob: first,
            firstSeed: 1,
            pending: [safe, unsafe, later],
            randomSeed: { _ in 0 },
            canInclude: { $0.id != unsafe.id })
        #expect(unsafeItems.map(\.queueJobID) == [first.id, safe.id])

        let duplicateItems = RenderSessionPlanner.queueGroup(
            firstJob: first,
            firstSeed: 1,
            pending: [first, later],
            randomSeed: { _ in 0 },
            canInclude: { _ in true })
        #expect(duplicateItems.map(\.queueJobID) == [first.id])
    }

    private func job(prompt: String, seed: String) -> QueueJob {
        QueueJob(
            prompt: prompt,
            width: 512,
            height: 512,
            steps: 8,
            seedText: seed)
    }
}

private func plannerRecipe(
    prompt: String,
    seed: GenerationRecipe.Seed
) -> GenerationRecipe {
    var recipe = GenerationRecipe.turbo(
        prompt: prompt,
        negativePrompt: "planner negative",
        model: .init(
            modelID: "planner-model",
            variantID: "planner-variant",
            manifestHash: plannerHash("a")),
        seed: seed)
    recipe.loras = [.init(
        managedID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        sha256: plannerHash("c"),
        scale: 0.5)]
    recipe.inputImage = .init(
        managedID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        sha256: plannerHash("d"),
        strength: 0.5,
        resize: .fill)
    return recipe
}

private func plannerHash(_ digit: String) -> String {
    String(repeating: digit, count: 64)
}
