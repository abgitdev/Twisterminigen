import Testing
@testable import Twisterminigen

@Suite("Inference coordinator")
@MainActor
struct InferenceCoordinatorTests {
    @Test("A lease owns the process until it finishes")
    func leaseRoundTrip() throws {
        let coordinator = InferenceCoordinator()
        #expect(coordinator.phase == .idle)
        #expect(!coordinator.blocksApplicationTermination)

        let lease = try #require(coordinator.begin(.generate))
        #expect(coordinator.isBusy)
        #expect(coordinator.blocksApplicationTermination)
        #expect(coordinator.activeOperation == .generate)
        #expect(coordinator.isActive(lease))

        let item = try #require(coordinator.beginWorkItem(lease))
        coordinator.transition(to: .encodingPrompt, lease: lease, workItem: item)
        #expect(coordinator.phase == .encodingPrompt)

        coordinator.finish(lease)
        #expect(!coordinator.isBusy)
        #expect(!coordinator.blocksApplicationTermination)
        #expect(coordinator.activeOperation == nil)
        #expect(coordinator.phase == .idle)
    }

    @Test("Every competing inference is rejected")
    func rejectsCompetingInference() throws {
        let coordinator = InferenceCoordinator()
        let first = try #require(coordinator.begin(.generate))

        #expect(coordinator.begin(.generate) == nil)
        #expect(coordinator.begin(.queue) == nil)
        #expect(coordinator.begin(.enhance) == nil)
        #expect(coordinator.begin(.describe) == nil)
        #expect(coordinator.begin(.upscale) == nil)
        #expect(coordinator.isActive(first))
    }

    @Test("A stale release cannot clear a newer lease")
    func staleReleaseCannotClearCurrentFlight() throws {
        let coordinator = InferenceCoordinator()
        let old = try #require(coordinator.begin(.generate))
        coordinator.finish(old)

        let current = try #require(coordinator.begin(.enhance))
        coordinator.finish(old)

        #expect(coordinator.isBusy)
        #expect(!coordinator.isActive(old))
        #expect(coordinator.isActive(current))
        #expect(coordinator.activeOperation == .enhance)
    }

    @Test("Stopping remains exclusive until the worker exits")
    func stoppingKeepsSingleFlightOccupied() throws {
        let coordinator = InferenceCoordinator()
        let lease = try #require(coordinator.begin(.queue))

        coordinator.markStopping(lease)
        #expect(coordinator.phase == .stopping)
        #expect(coordinator.begin(.generate) == nil)

        coordinator.finish(lease)
        #expect(coordinator.phase == .idle)
    }

    @Test("Model writes and inference exclude each other")
    func modelWritesAreMutuallyExclusiveWithInference() throws {
        let coordinator = InferenceCoordinator()
        let download = try #require(coordinator.beginModelMutation(key: "dit"))

        #expect(coordinator.isChangingModels)
        #expect(coordinator.blocksApplicationTermination)
        #expect(coordinator.begin(.generate) == nil)
        #expect(coordinator.beginModelMutation(key: "dit") == nil)
        let otherDownload = try #require(coordinator.beginModelMutation(key: "vae"))

        coordinator.finishModelMutation(download)
        coordinator.finishModelMutation(otherDownload)
        #expect(!coordinator.blocksApplicationTermination)
        let inference = try #require(coordinator.begin(.generate))
        #expect(coordinator.beginModelMutation(key: "delete:vae") == nil)
        coordinator.finish(inference)
    }

    @Test("Failure unlocks the next operation")
    func failureUnlocksCoordinator() throws {
        let coordinator = InferenceCoordinator()
        let failed = try #require(coordinator.begin(.enhance))

        coordinator.fail("synthetic failure", lease: failed)
        #expect(!coordinator.isBusy)
        #expect(coordinator.phase == .failed("synthetic failure"))

        let retry = try #require(coordinator.begin(.generate))
        #expect(coordinator.isActive(retry))
    }

    @Test("A deferred model change resumes only after inference releases its lease")
    func deferredModelChangeWaitsForInference() async throws {
        let coordinator = InferenceCoordinator()
        let inference = try #require(coordinator.begin(.queue))
        let waiter = Task { await coordinator.waitUntilModelChangesAreAllowed() }
        await Task.yield()

        #expect(coordinator.isActive(inference))
        coordinator.finish(inference)
        #expect(await waiter.value)
        #expect(coordinator.canChangeModels)
    }

    @Test("Termination cancels a deferred model change")
    func terminationCancelsDeferredModelChange() async throws {
        let coordinator = InferenceCoordinator()
        let inference = try #require(coordinator.begin(.generate))
        let waiter = Task { await coordinator.waitUntilModelChangesAreAllowed() }
        await Task.yield()

        coordinator.requestApplicationTermination()
        #expect(!(await waiter.value))
        #expect(coordinator.isActive(inference))
        coordinator.finish(inference)
    }

    @Test("Termination closes admission until AppKit cancels the quit attempt")
    func terminationClosesAdmission() throws {
        let coordinator = InferenceCoordinator()

        coordinator.requestApplicationTermination()
        #expect(coordinator.isTerminationRequested)
        #expect(!coordinator.canStartInference)
        #expect(!coordinator.canChangeModels)
        #expect(coordinator.begin(.generate) == nil)
        #expect(coordinator.beginModelMutation(key: "download:dit") == nil)

        coordinator.cancelApplicationTerminationRequest()
        #expect(!coordinator.isTerminationRequested)
        let inference = try #require(coordinator.begin(.generate))
        coordinator.finish(inference)
        let mutation = try #require(coordinator.beginModelMutation(key: "download:dit"))
        coordinator.finishModelMutation(mutation)
    }

    @Test("Late callbacks cannot move progress backwards")
    func ignoresOutOfOrderCallbacks() throws {
        let coordinator = InferenceCoordinator()
        let lease = try #require(coordinator.begin(.generate))
        let firstItem = try #require(coordinator.beginWorkItem(lease))

        coordinator.transition(to: .decoding, lease: lease, workItem: firstItem)
        coordinator.transition(to: .loadingTransformer, lease: lease, workItem: firstItem)
        #expect(coordinator.phase == .decoding)

        let nextItem = try #require(coordinator.beginWorkItem(lease))
        #expect(!coordinator.isActive(firstItem, lease: lease))
        #expect(coordinator.isActive(nextItem, lease: lease))
        coordinator.transition(to: .saving, lease: lease, workItem: firstItem)
        #expect(coordinator.phase == .preparing)
        coordinator.transition(to: .denoising(step: 4, total: 8), lease: lease, workItem: nextItem)
        coordinator.transition(to: .denoising(step: 2, total: 8), lease: lease, workItem: nextItem)
        #expect(coordinator.phase == .denoising(step: 4, total: 8))
    }

    @Test("Retiring a work item rejects late callbacks without releasing its queue lease")
    func retiredWorkItemRejectsLateCallbacks() throws {
        let coordinator = InferenceCoordinator()
        let lease = try #require(coordinator.begin(.queue))
        let completed = try #require(coordinator.beginWorkItem(lease))
        coordinator.transition(to: .saving, lease: lease, workItem: completed)

        coordinator.finishWorkItem(completed, lease: lease)
        #expect(coordinator.isActive(lease))
        #expect(!coordinator.isActive(completed, lease: lease))
        coordinator.transition(
            to: .denoising(step: 1, total: 8),
            lease: lease,
            workItem: completed)
        #expect(coordinator.phase == .saving)

        let next = try #require(coordinator.beginWorkItem(lease))
        #expect(coordinator.isActive(next, lease: lease))
        #expect(coordinator.phase == .preparing)
    }
}
