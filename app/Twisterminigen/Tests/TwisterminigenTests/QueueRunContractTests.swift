import Foundation
import Testing
@testable import Twisterminigen

@Suite("Queue run durability contract")
@MainActor
struct QueueRunContractTests {
    @Test("Run All saves and acknowledges each image before rendering the next job")
    func runAllPersistsBeforeStartingNextJob() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(prompt: "first", width: 512, height: 512, steps: 4, seedText: "")
        let second = QueueJob(prompt: "second", width: 512, height: 512, steps: 4, seedText: "22")
        try await fixture.queueStore.enqueue([first, second])

        let probe = QueueRunProbe()
        let gallery = fixture.gallery
        let galleryPaths = fixture.paths
        let queueStore = fixture.queueStore
        let viewModel = fixture.makeViewModel { job, _ in
            let reopened = GenerationStore(paths: galleryPaths)
            let completions = Set(await reopened.all().compactMap(\.completionID))
            let queueSnapshot = await queueStore.snapshot()
            await probe.recordStart(
                job: job,
                galleryCompletions: completions,
                queueSnapshot: queueSnapshot)
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let starts = await probe.starts()
        let records = await gallery.all()
        let queue = await fixture.queueStore.snapshot()
        let imageFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.images,
            includingPropertiesForKeys: nil)
        let sidecars = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.recipes,
            includingPropertiesForKeys: nil)

        #expect(starts.count == 2)
        #expect(starts[0].jobID == first.id)
        #expect(starts[0].galleryCompletions.isEmpty)
        #expect(starts[0].queuePendingJobIDs == [second.id])
        #expect(starts[0].queueRunningJobIDs == [first.id])
        #expect(starts[1].jobID == second.id)
        #expect(starts[1].galleryCompletions == [first.id])
        #expect(starts[1].queuePendingJobIDs.isEmpty)
        #expect(starts[1].queueRunningJobIDs == [second.id])
        #expect(Set(records.compactMap(\.completionID)) == [first.id, second.id])
        for start in starts {
            let record = try #require(records.first { $0.completionID == start.jobID })
            let imageURL = try await gallery.imageURL(for: record)
            #expect(record.recipe == start.recipe)
            #expect(record.recipe.sampler.seed.fixedValue != nil)
            #expect(try Data(contentsOf: imageURL) == Data("render-\(start.jobID.uuidString)".utf8))
        }
        #expect(imageFiles.count == 2)
        #expect(sidecars.count == 2)
        #expect(queue.isEmpty)
        #expect(viewModel.queueCompletedCount == 2)
        #expect(viewModel.savedImageCount == 2)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Each Queue job resolves the current live preview mode")
    func nextQueueJobUsesUpdatedPreviewMode() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(
            prompt: "first preview cadence",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "21")
        let second = QueueJob(
            prompt: "second preview cadence",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "22")
        try await fixture.queueStore.enqueue([first, second])

        let viewModel = fixture.makeViewModel { job, _ in
            QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }
        let probe = QueuePreviewIntervalProbe()
        probe.attach(viewModel)
        viewModel.setLivePreviewMode(.everyFourSteps)
        viewModel.queuePreviewIntervalDidResolveForTesting = { jobID, interval in
            probe.record(jobID: jobID, interval: interval)
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        #expect(probe.jobIDs == [first.id, second.id])
        #expect(probe.intervals == [4, 1])
        #expect((await fixture.queueStore.snapshot()).isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A Gallery save failure retries that job and never starts the queue suffix")
    func saveFailureNeverStartsSuffix() async throws {
        let failure = ArmedGalleryFailure()
        let fixture = try QueueRunFixture(failureInjector: failure.inject)
        defer { fixture.remove() }
        let first = QueueJob(prompt: "first", width: 512, height: 512, steps: 4, seedText: "31")
        let second = QueueJob(prompt: "second", width: 512, height: 512, steps: 4, seedText: "32")
        let third = QueueJob(prompt: "third", width: 512, height: 512, steps: 4, seedText: "33")
        try await fixture.queueStore.enqueue([first, second, third])

        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            if job.id == second.id { failure.arm() }
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let starts = await probe.starts()
        let records = await fixture.gallery.all()
        let queue = await fixture.queueStore.snapshot()

        #expect(starts.map(\.jobID) == [first.id, second.id])
        #expect(Set(records.compactMap(\.completionID)) == [first.id])
        #expect(queue.pending.map(\.id) == [second.id, third.id])
        #expect(queue.runningClaims.isEmpty)
        #expect(viewModel.queueCompletedCount == 1)
        #expect(viewModel.savedImageCount == 1)
        #expect(viewModel.errorMessage?.contains("couldn't write it to the gallery") == true)
    }

    @Test("Stop after current commits that image and leaves the untouched suffix pending")
    func stopAfterCurrentPersistsBeforeStopping() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(prompt: "first", width: 512, height: 512, steps: 4, seedText: "41")
        let second = QueueJob(prompt: "second", width: 512, height: 512, steps: 4, seedText: "42")
        try await fixture.queueStore.enqueue([first, second])

        let probe = QueueRunProbe()
        let control = QueueRunControl()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            if job.id == first.id { await control.requestStopAfterCurrent() }
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }
        control.attach(viewModel)

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let starts = await probe.starts()
        let records = await fixture.gallery.all()
        let queue = await fixture.queueStore.snapshot()

        #expect(starts.map(\.jobID) == [first.id])
        #expect(Set(records.compactMap(\.completionID)) == [first.id])
        #expect(queue.pending.map(\.id) == [second.id])
        #expect(queue.runningClaims.isEmpty)
        #expect(viewModel.queueCompletedCount == 1)
        #expect(viewModel.savedImageCount == 1)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.stopAfterCurrentQueueJob)
    }

    @Test("A stop request at the second claim boundary cannot claim or render job two")
    func stopImmediatelyBeforeSecondClaimLeavesSuffixUntouched() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(
            prompt: "first",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "43")
        let second = QueueJob(
            prompt: "second",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "44")
        try await fixture.queueStore.enqueue([first, second])

        let probe = QueueRunProbe()
        let control = QueueRunControl()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }
        control.attach(viewModel)
        viewModel.queueBeforeClaimForTesting = {
            control.requestStopAtSecondClaimBoundary()
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let records = await fixture.gallery.all()
        let queue = await fixture.queueStore.snapshot()
        #expect(await probe.starts().map(\.jobID) == [first.id])
        #expect(Set(records.compactMap(\.completionID)) == [first.id])
        #expect(queue.pending.map(\.id) == [second.id])
        #expect(queue.runningClaims.isEmpty)
        #expect(control.claimBoundaryCount == 2)
        #expect(viewModel.queueCompletedCount == 1)
        #expect(viewModel.savedImageCount == 1)
        #expect(!viewModel.stopAfterCurrentQueueJob)
    }

    @Test("Cancellation after a decoded frame still saves and acknowledges that image")
    func cancellationAfterFrameExistsPersistsIt() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(prompt: "first", width: 512, height: 512, steps: 4, seedText: "51")
        let second = QueueJob(prompt: "second", width: 512, height: 512, steps: 4, seedText: "52")
        try await fixture.queueStore.enqueue([first, second])

        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            withUnsafeCurrentTask { task in task?.cancel() }
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let records = await fixture.gallery.all()
        let queue = await fixture.queueStore.snapshot()
        #expect(await probe.starts().map(\.jobID) == [first.id])
        #expect(Set(records.compactMap(\.completionID)) == [first.id])
        #expect(queue.pending.map(\.id) == [second.id])
        #expect(queue.runningClaims.isEmpty)
        #expect(viewModel.queueCompletedCount == 1)
        #expect(viewModel.savedImageCount == 1)
    }

    @Test("Cancel during rendering restores exactly that job and leaves Gallery untouched")
    func cancellationDuringRenderRestoresCurrentJob() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(prompt: "first", width: 512, height: 512, steps: 4, seedText: "")
        let second = QueueJob(prompt: "second", width: 512, height: 512, steps: 4, seedText: "62")
        try await fixture.queueStore.enqueue([first, second])

        let gate = QueueRenderCancellationGate()
        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            try await gate.blockUntilCancelled()
            return QueueRenderedOutput(pngData: Data("unreachable".utf8), seconds: 1)
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await gate.waitUntilEntered()
        viewModel.cancel()
        await viewModel.waitForQueueCompletionForTesting()

        let queue = await fixture.queueStore.snapshot()
        #expect(await probe.starts().map(\.jobID) == [first.id])
        #expect((await fixture.gallery.all()).isEmpty)
        #expect(queue.pending.map(\.id) == [first.id, second.id])
        #expect(queue.pending.first?.recipe.sampler.seed.fixedValue != nil)
        #expect(queue.runningClaims.isEmpty)
        #expect(viewModel.queueCompletedCount == 0)
        #expect(viewModel.savedImageCount == 0)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A renderer failure retries only the current job and never starts the suffix")
    func rendererFailureRestoresCurrentJobAndStops() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(prompt: "first", width: 512, height: 512, steps: 4, seedText: "63")
        let second = QueueJob(prompt: "second", width: 512, height: 512, steps: 4, seedText: "64")
        try await fixture.queueStore.enqueue([first, second])

        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            throw QueueRunTestError.injectedRendererFailure
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let queue = await fixture.queueStore.snapshot()
        #expect(await probe.starts().map(\.jobID) == [first.id])
        #expect((await fixture.gallery.all()).isEmpty)
        #expect(queue.pending.map(\.id) == [first.id, second.id])
        #expect(queue.runningClaims.isEmpty)
        #expect(viewModel.queueCompletedCount == 0)
        #expect(viewModel.savedImageCount == 0)
        #expect(viewModel.errorMessage == "Queue job failed: Injected renderer failure.")
    }

    @Test("A durable Gallery commit retries exactly once across the pre-ack crash window")
    func durableSaveBeforeAckIsExactlyOnceOnRetry() async throws {
        let failure = ArmedGalleryFailure(failurePoint: .saveAfterIndexWrite)
        failure.arm()
        let fixture = try QueueRunFixture(failureInjector: failure.inject)
        defer { fixture.remove() }
        let job = QueueJob(prompt: "durable retry", width: 512, height: 512, steps: 4, seedText: "71")
        try await fixture.queueStore.enqueue(job)

        let calls = LockedRenderCounter()
        let viewModel = fixture.makeViewModel { job, _ in
            let call = calls.next()
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)-call-\(call)".utf8),
                seconds: Double(call))
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let firstRecords = await fixture.gallery.all()
        let firstRecord = try #require(firstRecords.first)
        let firstURL = try await fixture.gallery.imageURL(for: firstRecord)
        let firstBytes = try Data(contentsOf: firstURL)
        let interrupted = await fixture.queueStore.snapshot()
        #expect(firstRecords.count == 1)
        #expect(firstRecord.completionID == job.id)
        #expect(interrupted.pending.map(\.id) == [job.id])
        #expect(interrupted.runningClaims.isEmpty)
        #expect(viewModel.queueCompletedCount == 0)

        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let retriedRecords = await fixture.gallery.all()
        let completed = await fixture.queueStore.snapshot()
        let imageFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.images,
            includingPropertiesForKeys: nil)
        #expect(retriedRecords.count == 1)
        #expect(retriedRecords.first?.id == firstRecord.id)
        #expect(try Data(contentsOf: firstURL) == firstBytes)
        #expect(imageFiles.count == 1)
        #expect(completed.isEmpty)
        #expect(viewModel.queueCompletedCount == 1)
        #expect(calls.value == 2)
    }

    @Test("Unsafe immutable recipes are blocked before Queue claims or renderer entry")
    func contentPolicyBlocksQueueBeforeRendering() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let blocked = QueueJob(
            prompt: "bypass content filter",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "81")
        let safe = QueueJob(prompt: "safe landscape", width: 512, height: 512, steps: 4, seedText: "82")
        try await fixture.queueStore.enqueue([blocked, safe])

        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            return QueueRenderedOutput(pngData: Data("unexpected".utf8), seconds: 1)
        }

        await viewModel.restorePersistedQueue()
        #expect(viewModel.runQueueUnavailableReason?.contains("safety filter blocked") == true)
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let queue = await fixture.queueStore.snapshot()
        #expect(await probe.starts().isEmpty)
        #expect((await fixture.gallery.all()).isEmpty)
        #expect(queue.pending.map(\.id) == [blocked.id, safe.id])
        #expect(queue.runningClaims.isEmpty)
        #expect(viewModel.errorMessage?.contains("safety filter blocked") == true)
    }

    @Test("Queue ETA excludes warm-up and reports the current image")
    func queueETAWiringUsesSteadyMonotonicIntervals() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let jobs = (0 ..< 4).map { index in
            QueueJob(
                prompt: "eta \(index)",
                width: 512,
                height: 512,
                steps: 8,
                seedText: String(90 + index))
        }
        try await fixture.queueStore.enqueue(jobs)

        let clock = ManualMonotonicClock()
        let control = QueueRunControl()
        let etaProbe = QueueETAProbe()
        let viewModel = fixture.makeViewModel(monotonicNow: clock.now) { _, progress in
            clock.set(63)
            await progress(1, 8)
            await etaProbe.record(await control.etaSnapshot())
            clock.set(71)
            await progress(2, 8)
            await etaProbe.record(await control.etaSnapshot())
            await control.requestStopAfterCurrent()
            return QueueRenderedOutput(pngData: Data("eta-result".utf8), seconds: 80)
        }
        control.attach(viewModel)

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let snapshots = await etaProbe.snapshots()
        #expect(snapshots.count == 2)
        #expect(snapshots[0].etaText == "Estimating…")
        #expect(snapshots[0].secondsPerStep == nil)
        #expect(snapshots[1].secondsPerStep == 8)
        #expect(snapshots[1].etaText == "~48 s left")
        #expect(snapshots[1].busySubline == "8.0 s/step · queue 1 of 4")
        #expect((await fixture.queueStore.snapshot()).pending.count == 3)
    }

    @Test("A pending job remains editable while the current job renders")
    func pendingJobCanBeEditedDuringQueueRun() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(
            prompt: "currently rendering",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "95")
        let second = QueueJob(
            prompt: "edit me",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "96")
        try await fixture.queueStore.enqueue([first, second])

        let gate = QueueRenderCancellationGate()
        let viewModel = fixture.makeViewModel { _, _ in
            try await gate.blockUntilCancelled()
            throw CancellationError()
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await gate.waitUntilEntered()

        var editedRecipe = second.recipe
        editedRecipe.prompts.positive = "edited while rendering"
        #expect(await viewModel.updateQueueJob(id: second.id, recipe: editedRecipe))

        viewModel.cancel()
        await viewModel.waitForQueueCompletionForTesting()

        let pending = (await fixture.queueStore.snapshot()).pending
        #expect(pending.first(where: { $0.id == second.id })?.recipe == editedRecipe)
    }

    @Test("Pending jobs can be reordered and removed while another Queue job renders")
    func pendingJobsRemainMutableDuringActiveRun() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(
            prompt: "currently rendering",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "120")
        let second = QueueJob(
            prompt: "remove while pending",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "121")
        let third = QueueJob(
            prompt: "move ahead",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "122")
        let fourth = QueueJob(
            prompt: "also move ahead",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "123")
        try await fixture.queueStore.enqueue([first, second, third, fourth])

        let gate = QueueRenderGate()
        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            if job.id == first.id {
                await gate.blockUntilReleased()
            }
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await gate.waitUntilEntered()

        await viewModel.moveQueueJobDown(id: second.id)
        await viewModel.moveQueueJobUp(id: fourth.id)
        await viewModel.removeQueueJob(id: second.id)

        #expect(viewModel.runningQueueJob?.id == first.id)
        #expect(viewModel.queue.map(\.id) == [third.id, fourth.id])
        #expect((await fixture.queueStore.snapshot()).pending.map(\.id) == [third.id, fourth.id])
        #expect(viewModel.queueTotalCount == 3)
        #expect(viewModel.errorMessage == nil)

        viewModel.stopAfterCurrentQueueJob = true
        await gate.release()
        await viewModel.waitForQueueCompletionForTesting()

        #expect(await probe.starts().map(\.jobID) == [first.id])
        #expect((await fixture.queueStore.snapshot()).pending.map(\.id) == [third.id, fourth.id])
        #expect(viewModel.queueCompletedCount == 1)
        #expect(viewModel.queueTotalCount == 3)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Generate and Queue submissions append behind an active run and update its live total")
    func activeQueueAcceptsTailSubmissionsInOrder() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(
            prompt: "already running",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "97")
        let second = QueueJob(
            prompt: "already queued",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "98")
        try await fixture.queueStore.enqueue([first, second])

        let gate = QueueRenderGate()
        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            if job.id == first.id {
                await gate.blockUntilReleased()
            }
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await gate.waitUntilEntered()

        viewModel.prompt = "submitted with Queue"
        #expect(viewModel.canAddToQueue)
        #expect(viewModel.canSubmitCurrentRecipe)
        #expect(await viewModel.addCurrentToQueue() == 2)

        viewModel.prompt = "submitted with Generate next"
        #expect(viewModel.canSubmitCurrentRecipe)
        #expect(await viewModel.addCurrentToQueue() == 3)
        #expect(viewModel.queueTotalCount == 4)
        #expect(viewModel.busySubline == "queue 1 of 4")

        await gate.release()
        await viewModel.waitForQueueCompletionForTesting()

        let starts = await probe.starts()
        #expect(starts.map(\.recipe.prompts.positive) == [
            "already running",
            "already queued",
            "submitted with Queue",
            "submitted with Generate next",
        ])
        #expect(Set(starts.map(\.jobID)).count == 4)
        #expect((await fixture.queueStore.snapshot()).isEmpty)
        #expect(viewModel.queueCompletedCount == 4)
        #expect(viewModel.savedImageCount == 4)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A submission during direct Generate hands off to Queue after that lease succeeds")
    func directGenerateSubmissionRunsAfterSuccessfulHandoff() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }
        await viewModel.restorePersistedQueue()

        let generateLease = try #require(fixture.coordinator.begin(.generate))
        viewModel.prompt = "created while a direct batch renders"
        #expect(viewModel.canSubmitCurrentRecipe)
        #expect(await viewModel.addCurrentToQueue() == 1)
        #expect(fixture.coordinator.activeOperation == .generate)

        fixture.coordinator.finish(generateLease)
        viewModel.continueQueuedWorkAfterSuccessfulRender()
        await viewModel.waitForQueueCompletionForTesting()

        #expect(await probe.starts().map(\.recipe.prompts.positive) == [
            "created while a direct batch renders",
        ])
        #expect((await fixture.queueStore.snapshot()).isEmpty)
        #expect(viewModel.queueCompletedCount == 1)
        #expect(viewModel.savedImageCount == 1)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Stopping direct Generate keeps a newly queued recipe pending instead of auto-running it")
    func directGenerateStopCancelsAutomaticHandoff() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            return QueueRenderedOutput(
                pngData: Data("unexpected-\(job.id.uuidString)".utf8),
                seconds: 1)
        }
        await viewModel.restorePersistedQueue()

        let generateLease = try #require(fixture.coordinator.begin(.generate))
        viewModel.prompt = "keep pending after Stop"
        #expect(await viewModel.addCurrentToQueue() == 1)
        viewModel.cancel()
        fixture.coordinator.finish(generateLease)
        viewModel.continueQueuedWorkAfterSuccessfulRender()
        await Task.yield()

        #expect(await probe.starts().isEmpty)
        #expect((await fixture.queueStore.snapshot()).pending.map(\.recipe.prompts.positive) == [
            "keep pending after Stop",
        ])
        #expect(!viewModel.isBusy)
        #expect(viewModel.queueCompletedCount == 0)
        #expect(viewModel.savedImageCount == 0)
    }

    @Test("An append at the final empty boundary stays in the same Queue run")
    func finalBoundaryRecheckKeepsLateAppendInCurrentRun() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(
            prompt: "only original job",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "101")
        try await fixture.queueStore.enqueue(first)

        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }
        viewModel.queueBeforeNaturalFinishForTesting = { [weak viewModel] in
            guard let viewModel else { return }
            viewModel.queueBeforeNaturalFinishForTesting = nil
            viewModel.prompt = "arrived at final boundary"
            _ = await viewModel.addCurrentToQueue()
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        #expect(await probe.starts().map(\.recipe.prompts.positive) == [
            "only original job",
            "arrived at final boundary",
        ])
        #expect(viewModel.queueTotalCount == 2)
        #expect(viewModel.queueCompletedCount == 2)
        #expect(viewModel.savedImageCount == 2)
        #expect((await fixture.queueStore.snapshot()).isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Stop after current wins over an appended job and leaves the complete suffix pending")
    func stopAfterCurrentDoesNotAutoRestartAppendedWork() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let first = QueueJob(
            prompt: "finish me",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "99")
        let second = QueueJob(
            prompt: "original suffix",
            width: 512,
            height: 512,
            steps: 4,
            seedText: "100")
        try await fixture.queueStore.enqueue([first, second])

        let gate = QueueRenderGate()
        let probe = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, _ in
            await probe.recordStart(job: job, galleryCompletions: [])
            if job.id == first.id {
                await gate.blockUntilReleased()
            }
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await gate.waitUntilEntered()
        viewModel.prompt = "appended before stop"
        #expect(await viewModel.addCurrentToQueue() == 2)
        viewModel.stopAfterCurrentQueueJob = true
        await gate.release()
        await viewModel.waitForQueueCompletionForTesting()

        let pending = (await fixture.queueStore.snapshot()).pending
        #expect(await probe.starts().map(\.jobID) == [first.id])
        #expect(pending.map(\.recipe.prompts.positive) == [
            "original suffix",
            "appended before stop",
        ])
        #expect(viewModel.queueCompletedCount == 1)
        #expect(viewModel.savedImageCount == 1)
        #expect(!viewModel.isBusy)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A delayed callback from an acknowledged job cannot recreate a phantom retry")
    func delayedProgressCannotRestoreCompletedJob() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let job = QueueJob(prompt: "late callback", width: 512, height: 512, steps: 4, seedText: "101")
        try await fixture.queueStore.enqueue(job)
        let delayed = DelayedProgressDriver()

        let viewModel = fixture.makeViewModel { job, progress in
            Task {
                await delayed.waitForRelease()
                await progress(1, job.steps)
                await delayed.markDelivered()
            }
            return QueueRenderedOutput(
                pngData: Data("render-\(job.id.uuidString)".utf8),
                seconds: 1)
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()
        let completedStep = viewModel.currentStep
        let completedETA = viewModel.etaText
        let completedSecondsPerStep = viewModel.secondsPerStep
        await delayed.release()
        await delayed.waitUntilDelivered()

        #expect(completedStep == job.steps)
        #expect(completedETA == nil)
        #expect(completedSecondsPerStep == nil)
        #expect(viewModel.currentStep == completedStep)
        #expect(viewModel.etaText == completedETA)
        #expect(viewModel.secondsPerStep == completedSecondsPerStep)
        #expect(viewModel.runningQueueJob == nil)
        #expect(viewModel.queue.isEmpty)
        #expect(viewModel.queueCompletedCount == 1)
        #expect((await fixture.queueStore.snapshot()).isEmpty)
        #expect(Set((await fixture.gallery.all()).compactMap(\.completionID)) == [job.id])
    }

    @Test("Thirty sequential mixed-seed jobs leave no queue claims or duplicate Gallery commits")
    func thirtySequentialJobsRemainExactlyOnce() async throws {
        let fixture = try QueueRunFixture()
        defer { fixture.remove() }
        let jobs = (0 ..< 30).map { index in
            QueueJob(
                prompt: "stage 3 soak \(index)",
                width: index.isMultiple(of: 2) ? 512 : 768,
                height: index.isMultiple(of: 3) ? 768 : 512,
                steps: 4 + (index % 5),
                seedText: index.isMultiple(of: 4) ? "" : String(10_000 + index))
        }
        try await fixture.queueStore.enqueue(jobs)
        let starts = QueueRunProbe()
        let viewModel = fixture.makeViewModel { job, progress in
            await starts.recordStart(job: job, galleryCompletions: [])
            await progress(1, job.steps)
            await progress(job.steps, job.steps)
            return QueueRenderedOutput(
                pngData: Data("stage-3-\(job.id.uuidString)".utf8),
                seconds: Double(job.steps))
        }

        await viewModel.restorePersistedQueue()
        viewModel.runQueue()
        await viewModel.waitForQueueCompletionForTesting()

        let renderedIDs = await starts.starts().map(\.jobID)
        let galleryIDs = (await fixture.gallery.all()).compactMap(\.completionID)
        let queue = await fixture.queueStore.snapshot()
        #expect(renderedIDs == jobs.map(\.id))
        #expect(Set(renderedIDs).count == 30)
        #expect(Set(galleryIDs) == Set(jobs.map(\.id)))
        #expect(galleryIDs.count == 30)
        #expect(queue.isEmpty)
        #expect(queue.runningClaims.isEmpty)
        #expect(viewModel.queueCompletedCount == 30)
        #expect(viewModel.savedImageCount == 30)
        #expect(viewModel.errorMessage == nil)
    }
}

private actor QueueRunProbe {
    struct Start: Sendable {
        let jobID: UUID
        let recipe: GenerationRecipe
        let galleryCompletions: Set<UUID>
        let queuePendingJobIDs: [UUID]
        let queueRunningJobIDs: [UUID]
    }

    private var values: [Start] = []

    func recordStart(
        job: QueueJob,
        galleryCompletions: Set<UUID>,
        queueSnapshot: QueueStore.Snapshot? = nil
    ) {
        values.append(Start(
            jobID: job.id,
            recipe: job.recipe,
            galleryCompletions: galleryCompletions,
            queuePendingJobIDs: queueSnapshot?.pending.map(\.id) ?? [],
            queueRunningJobIDs: queueSnapshot?.runningClaims.map(\.job.id) ?? []))
    }

    func starts() -> [Start] { values }
}

@MainActor
private final class QueuePreviewIntervalProbe {
    private weak var viewModel: GenerateViewModel?
    private(set) var jobIDs: [UUID] = []
    private(set) var intervals: [Int] = []

    func attach(_ viewModel: GenerateViewModel) {
        self.viewModel = viewModel
    }

    func record(jobID: UUID, interval: Int) {
        jobIDs.append(jobID)
        intervals.append(interval)
        if intervals.count == 1 {
            viewModel?.setLivePreviewMode(.everyStep)
        }
    }
}

private actor QueueRenderCancellationGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilCancelled() async throws {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        try await Task.sleep(for: .seconds(3_600))
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }
}

private actor QueueRenderGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilReleased() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor DelayedProgressDriver {
    private var isReleased = false
    private var isDelivered = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func markDelivered() {
        isDelivered = true
        let waiters = deliveryWaiters
        deliveryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilDelivered() async {
        if isDelivered { return }
        await withCheckedContinuation { continuation in
            deliveryWaiters.append(continuation)
        }
    }
}

private final class LockedRenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class ManualMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    func set(_ value: Double) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct QueueETASnapshot: Sendable {
    let etaText: String?
    let secondsPerStep: Double?
    let busySubline: String
}

private actor QueueETAProbe {
    private var values: [QueueETASnapshot] = []

    func record(_ snapshot: QueueETASnapshot) {
        values.append(snapshot)
    }

    func snapshots() -> [QueueETASnapshot] { values }
}

private final class ArmedGalleryFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let failurePoint: GenerationStoreFailurePoint
    private var isArmed = false

    init(failurePoint: GenerationStoreFailurePoint = .saveAfterJournalWrite) {
        self.failurePoint = failurePoint
    }

    func arm() {
        lock.lock()
        isArmed = true
        lock.unlock()
    }

    func inject(_ point: GenerationStoreFailurePoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard isArmed, point == failurePoint else { return }
        isArmed = false
        throw QueueRunTestError.injectedGalleryFailure
    }
}

private enum QueueRunTestError: Error, LocalizedError {
    case injectedGalleryFailure
    case injectedRendererFailure

    var errorDescription: String? {
        switch self {
        case .injectedGalleryFailure:
            "Injected Gallery failure."
        case .injectedRendererFailure:
            "Injected renderer failure."
        }
    }
}

@MainActor
private final class QueueRunControl {
    private weak var viewModel: GenerateViewModel?
    private(set) var claimBoundaryCount = 0

    func attach(_ viewModel: GenerateViewModel) {
        self.viewModel = viewModel
    }

    func requestStopAfterCurrent() {
        viewModel?.stopAfterCurrentQueueJob = true
    }

    func requestStopAtSecondClaimBoundary() {
        claimBoundaryCount += 1
        if claimBoundaryCount == 2 {
            viewModel?.stopAfterCurrentQueueJob = true
        }
    }

    func etaSnapshot() -> QueueETASnapshot {
        QueueETASnapshot(
            etaText: viewModel?.etaText,
            secondsPerStep: viewModel?.secondsPerStep,
            busySubline: viewModel?.busySubline ?? "")
    }
}

@MainActor
private final class QueueRunFixture {
    let root: URL
    let paths: LibraryPaths
    let gallery: GenerationStore
    let queueStore: QueueStore
    let coordinator: InferenceCoordinator

    init(
        failureInjector: @escaping GenerationStoreFailureInjector = { _ in }
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenQueueRunTests-\(UUID().uuidString)")
        paths = LibraryPaths(root: root.appendingPathComponent("Gallery"))
        gallery = GenerationStore(paths: paths, failureInjector: failureInjector)
        queueStore = try QueueStore(fileURL: root.appendingPathComponent("queue.json"))
        coordinator = InferenceCoordinator()
    }

    func makeViewModel(
        monotonicNow: RenderMonotonicNow? = nil,
        renderer: @escaping QueueJobRenderer
    ) -> GenerateViewModel {
        let governor = MemoryGovernor(snapshot: .init(
            swapUsedBytes: 0,
            pressure: .normal))
        if let monotonicNow {
            return GenerateViewModel(
                store: gallery,
                coordinator: coordinator,
                memoryGovernor: governor,
                queueStore: queueStore,
                queueJobRenderer: renderer,
                monotonicNow: monotonicNow)
        }
        return GenerateViewModel(
            store: gallery,
            coordinator: coordinator,
            memoryGovernor: governor,
            queueStore: queueStore,
            queueJobRenderer: renderer)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
