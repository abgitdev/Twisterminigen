import Foundation
import Testing
@testable import Twisterminigen

@Suite("Queue recovery")
@MainActor
struct QueueRecoveryTests {
    @Test("An interrupted running job returns to the head exactly once")
    func interruptedJobReturnsToHead() {
        let vm = GenerateViewModel(
            store: GenerationStore(), coordinator: InferenceCoordinator(),
            memoryGovernor: healthyGovernor())
        let interrupted = QueueJob(
            prompt: "first", width: 512, height: 512, steps: 4, seedText: "1")
        let next = QueueJob(
            prompt: "second", width: 512, height: 512, steps: 4, seedText: "2")
        vm.queue = [next]
        vm.runningQueueJob = interrupted

        vm.restoreQueueJob(interrupted)
        vm.restoreQueueJob(interrupted)

        #expect(vm.runningQueueJob == nil)
        #expect(vm.queue.map(\.id) == [interrupted.id, next.id])
    }

    @Test("Restoring an already-pending job never duplicates it")
    func pendingJobIsNotDuplicated() {
        let vm = GenerateViewModel(
            store: GenerationStore(), coordinator: InferenceCoordinator(),
            memoryGovernor: healthyGovernor())
        let job = QueueJob(
            prompt: "retry", width: 512, height: 512, steps: 4, seedText: "")
        vm.queue = [job]
        vm.runningQueueJob = job

        vm.restoreQueueJob(job)

        #expect(vm.queue == [job])
        #expect(vm.runningQueueJob == nil)
    }

    @Test("A persisted job advances progress exactly once")
    func persistedJobCountsOnce() {
        let vm = GenerateViewModel(
            store: GenerationStore(), coordinator: InferenceCoordinator(),
            memoryGovernor: healthyGovernor())
        let job = QueueJob(
            prompt: "done", width: 512, height: 512, steps: 4, seedText: "3")
        vm.runningQueueJob = job

        vm.resolveQueueJob(job, as: .persisted)
        vm.resolveQueueJob(job, as: .persisted)

        #expect(vm.runningQueueJob == nil)
        #expect(vm.queueCompletedCount == 1)
        #expect(vm.queue.isEmpty)
    }

    @Test("A failed job is retryable and never advances progress")
    func failedJobIsRetryable() {
        let vm = GenerateViewModel(
            store: GenerationStore(), coordinator: InferenceCoordinator(),
            memoryGovernor: healthyGovernor())
        let job = QueueJob(
            prompt: "retry", width: 512, height: 512, steps: 4, seedText: "4")
        vm.runningQueueJob = job

        vm.resolveQueueJob(job, as: .retry)
        vm.resolveQueueJob(job, as: .retry)

        #expect(vm.runningQueueJob == nil)
        #expect(vm.queueCompletedCount == 0)
        #expect(vm.queue.map(\.id) == [job.id])
    }

    @Test("Queue ordering and pending edits survive a store restart")
    func viewModelOrderingPersists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenQueueVMTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let queueURL = root.appendingPathComponent("queue.json")
        let queueStore = try QueueStore(fileURL: queueURL)
        let vm = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: root.appendingPathComponent("Library"))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: healthyGovernor(),
            queueStore: queueStore)

        vm.prompt = "first"
        vm.width = 512
        vm.height = 512
        vm.steps = 4
        vm.seedText = "11"
        let firstCount = await vm.addCurrentToQueue()
        #expect(firstCount == 1)
        let firstID = try #require(vm.queue.first?.id)

        vm.prompt = "second"
        vm.seedText = ""
        let secondCount = await vm.addCurrentToQueue()
        #expect(secondCount == 2)
        let secondID = try #require(vm.queue.last?.id)

        await vm.duplicateQueueJob(id: firstID)
        let copyID = try #require(vm.queue.dropFirst().first?.id)
        #expect(Set(vm.queue.map(\.id)).count == 3)
        await vm.moveQueueJobUp(id: secondID)
        #expect(vm.queue.map(\.id) == [firstID, secondID, copyID])
        await vm.removeQueueJob(id: copyID)

        var editedRecipe = try #require(vm.queue.first?.recipe)
        editedRecipe.prompts.positive = "first edited"
        editedRecipe.canvas = .init(width: 768, height: 512)
        editedRecipe.sampler.steps = 9
        editedRecipe.sampler.seed = .fixed(22)
        #expect(await vm.updateQueueJob(id: firstID, recipe: editedRecipe))
        #expect(vm.queue.map(\.id) == [firstID, secondID])
        #expect(vm.queue.first?.recipe == editedRecipe)

        #expect(await vm.openQueueJobCopy(id: firstID))
        #expect(vm.prompt == "first edited")
        #expect(vm.width == 768)
        #expect(vm.steps == 9)
        #expect(vm.seedText == "22")

        let reopened = try QueueStore(fileURL: queueURL)
        let restoredVM = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: root.appendingPathComponent("RestoredLibrary"))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: healthyGovernor(),
            queueStore: reopened)
        await restoredVM.restorePersistedQueue()

        #expect(restoredVM.queue.map(\.id) == [firstID, secondID])
        #expect(restoredVM.queue.first?.recipe == editedRecipe)
    }

    @Test("The Generate form snapshots and duplicates the complete recipe")
    func completeRecipeSurvivesQueueCopies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenRecipeVMTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = ModelCatalog(root: root.appendingPathComponent("Models"))
        let queueStore = try QueueStore(fileURL: root.appendingPathComponent("queue.json"))
        let vm = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(root: root.appendingPathComponent("Library"))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: healthyGovernor(),
            queueStore: queueStore,
            weightsRootProvider: { root.appendingPathComponent("Models") })

        var recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "original",
            negativePrompt: "letters",
            width: 768,
            height: 512,
            steps: 9,
            seed: .fixed(123),
            catalog: catalog)
        // Regional sampling deliberately has no classifier-free guidance branch.
        recipe.sampler.guidance = 0
        recipe.prompts.exactText = "EXACT TITLE"
        recipe.loras = [.init(
            managedID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sha256: String(repeating: "a", count: 64),
            scale: 0.75)]
        recipe.regions = [.init(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            prompt: "left subject",
            rect: .init(x0: 0, y0: 0, x1: 0.5, y1: 1))]
        recipe.inputImage = .init(
            managedID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            sha256: String(repeating: "c", count: 64),
            strength: 0.4,
            resize: .fill)

        try vm.applyRecipe(recipe)
        vm.prompt = "edited"
        vm.seedText = "456"
        await vm.addCurrentToQueue()
        let queued = try #require(vm.queue.first)

        var expected = recipe
        expected.prompts.positive = "edited"
        expected.sampler.seed = .fixed(456)
        #expect(queued.recipe == expected)

        await vm.duplicateQueueJob(id: queued.id)
        #expect(vm.queue.count == 2)
        #expect(vm.queue[0].recipe == vm.queue[1].recipe)
        #expect(vm.queue[0].id != vm.queue[1].id)

        #expect(await vm.openQueueJobCopy(id: queued.id))
        #expect(vm.queue.count == 2)
        #expect(vm.currentRecipe(seed: .fixed(456), catalog: catalog) == expected)
        #expect(vm.letteringIsActive)
        #expect(vm.exactText == "EXACT TITLE")
    }

    private func healthyGovernor() -> MemoryGovernor {
        MemoryGovernor(snapshot: .init(swapUsedBytes: 0, pressure: .normal))
    }
}
