import Foundation
import Testing
@testable import Twisterminigen

@Suite("Persistent queue store")
struct QueueStoreTests {
    @Test("Queue jobs preserve identity and source-compatible defaults")
    func queueJobCodableRoundTrip() throws {
        let id = uuid("00000000-0000-0000-0000-000000000001")
        let job = QueueJob(id: id, prompt: "default settings")

        #expect(job.id == id)
        #expect(job.width == 1_024)
        #expect(job.height == 1_024)
        #expect(job.steps == 8)
        #expect(job.seedText.isEmpty)
        #expect(job.recipe.model == QueueJob.legacyModelReference)

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(QueueJob.self, from: data)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded == job)
        #expect(Set(object.keys) == ["id", "recipe"])
    }

    @Test("Ordered immutable snapshots persist across store instances")
    func orderedMutationsPersist() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let first = job(
            id: "00000000-0000-0000-0000-000000000011",
            prompt: "first")
        let second = job(
            id: "00000000-0000-0000-0000-000000000012",
            prompt: "second")
        let third = job(
            id: "00000000-0000-0000-0000-000000000013",
            prompt: "third")
        let copyID = uuid("00000000-0000-0000-0000-000000000014")
        let store = try QueueStore(fileURL: fixture.fileURL)

        try await store.enqueue(first)
        try await store.enqueue(second)
        try await store.enqueue(third)

        try await store.move(id: third.id, to: 0)
        let copy = try await store.duplicate(id: second.id, newID: copyID)
        let removed = try await store.remove(id: first.id)

        #expect(copy.id == copyID)
        #expect(copy.prompt == second.prompt)
        #expect(removed == first)
        let expected = [third, second, copy]
        #expect(await store.snapshot().pending == expected)

        let reloaded = try QueueStore(fileURL: fixture.fileURL)
        #expect(await reloaded.snapshot().pending == expected)
        let persisted = try fixture.readDocument()
        #expect(persisted.schema == QueueStore.schema)
        #expect(persisted.version == QueueStore.version)
        #expect(persisted.pending == expected)
        #expect(persisted.running.isEmpty)
    }

    @Test("Full immutable recipes survive duplicate and restart")
    func fullRecipeMutationsPersist() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let source = QueueJob(
            id: uuid("00000000-0000-0000-0000-000000000015"),
            recipe: recipe(prompt: "full source", seed: .random))
        let copyID = uuid("00000000-0000-0000-0000-000000000016")
        let store = try QueueStore(fileURL: fixture.fileURL)

        try await store.enqueue(source)
        let copy = try await store.duplicate(id: source.id, newID: copyID)
        #expect(copy.recipe == source.recipe)

        let expected = [source, copy]
        #expect(await store.snapshot().pending == expected)
        #expect(try fixture.permissions() == 0o600)

        let reopened = try QueueStore(fileURL: fixture.fileURL)
        #expect(await reopened.snapshot().pending == expected)
        #expect(await reopened.snapshot().pending[1].recipe == copy.recipe)
        #expect(try fixture.readDocument().pending == expected)
    }

    @Test("A pending recipe edit is atomic, stays in place, and survives restart")
    func pendingRecipeEditPersistsInPlace() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let first = job(
            id: "00000000-0000-0000-0000-000000000017",
            prompt: "before")
        let second = job(
            id: "00000000-0000-0000-0000-000000000018",
            prompt: "untouched")
        let source = QueueJob(
            id: first.id,
            recipe: first.recipe,
            provenance: .batch(
                groupID: uuid("10000000-0000-0000-0000-000000000017"),
                itemIndex: 0,
                itemCount: 2))
        let store = try QueueStore(fileURL: fixture.fileURL)
        try await store.enqueue([source, second])

        var editedRecipe = source.recipe
        editedRecipe.prompts.positive = "after"
        editedRecipe.canvas = .init(width: 768, height: 512)
        editedRecipe.sampler.steps = 9
        let edited = try await store.update(id: source.id, recipe: editedRecipe)

        #expect(edited.id == source.id)
        #expect(edited.recipe == editedRecipe)
        #expect(edited.provenance == nil)
        #expect(await store.snapshot().pending == [edited, second])

        let reopened = try QueueStore(fileURL: fixture.fileURL)
        #expect(await reopened.snapshot().pending == [edited, second])
        #expect(try fixture.readDocument().pending == [edited, second])
    }

    @Test("Malformed JSON is quarantined and surfaced")
    func corruptJSONIsQuarantined() throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let payload = Data("{ definitely-not-json".utf8)
        try payload.write(to: fixture.fileURL)
        let quarantineID = uuid("ffffffff-ffff-ffff-ffff-fffffffffff1")
        var reportedQuarantine: URL?

        do {
            _ = try QueueStore(
                fileURL: fixture.fileURL,
                quarantineID: { quarantineID })
            Issue.record("Expected corrupt queue data to fail initialization")
        } catch let error as QueueStoreError {
            switch error {
            case let .corruptFiles(originals, quarantined, reason):
                #expect(originals == [fixture.fileURL])
                #expect(quarantined.count == 1)
                #expect(!reason.isEmpty)
                reportedQuarantine = quarantined.first
            default:
                Issue.record("Expected corruptFiles, received \(error)")
            }
        } catch {
            Issue.record("Expected QueueStoreError, received \(error)")
        }

        let quarantine = try #require(reportedQuarantine)
        #expect(quarantine.lastPathComponent ==
            "queue.corrupt.\(quarantineID.uuidString.lowercased()).json")
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(try Data(contentsOf: quarantine) == payload)
    }

    @Test("A newer staged document wins after an interrupted atomic replacement")
    func recoversAtomicStagingFile() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let first = job(
            id: "00000000-0000-0000-0000-000000000021",
            prompt: "committed first")
        let second = job(
            id: "00000000-0000-0000-0000-000000000022",
            prompt: "staged second")
        let store = try QueueStore(fileURL: fixture.fileURL)

        try await store.enqueue(first)
        let olderData = try Data(contentsOf: fixture.fileURL)
        try await store.enqueue(second)
        let newerData = try Data(contentsOf: fixture.fileURL)

        try olderData.write(to: fixture.fileURL, options: .atomic)
        try newerData.write(to: fixture.stagingURL, options: .atomic)

        let recovered = try QueueStore(fileURL: fixture.fileURL)
        #expect(recovered.startupReport.recoveredAtomicWrite)
        #expect(await recovered.snapshot().pending == [first, second])
        #expect(try Data(contentsOf: fixture.fileURL) == newerData)
        #expect(!FileManager.default.fileExists(atPath: fixture.stagingURL.path))

        let reloaded = try QueueStore(fileURL: fixture.fileURL)
        #expect(!reloaded.startupReport.recoveredAtomicWrite)
        #expect(await reloaded.snapshot().pending == [first, second])
    }

    @Test("Duplicate ids invalidate the complete document")
    func duplicateIDsAreRejected() throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let duplicate = job(
            id: "00000000-0000-0000-0000-000000000031",
            prompt: "duplicate")
        try fixture.writeDocument(QueueFile(
            revision: 7,
            pending: [duplicate, duplicate]))
        let quarantineID = uuid("ffffffff-ffff-ffff-ffff-fffffffffff2")
        var reportedReason = ""
        var reportedQuarantine: URL?

        do {
            _ = try QueueStore(
                fileURL: fixture.fileURL,
                quarantineID: { quarantineID })
            Issue.record("Expected duplicate ids to fail initialization")
        } catch let error as QueueStoreError {
            switch error {
            case let .corruptFiles(_, quarantined, reason):
                reportedReason = reason
                reportedQuarantine = quarantined.first
            default:
                Issue.record("Expected corruptFiles, received \(error)")
            }
        } catch {
            Issue.record("Expected QueueStoreError, received \(error)")
        }

        #expect(reportedReason.contains("duplicate job id"))
        let quarantine = try #require(reportedQuarantine)
        let quarantined = try JSONDecoder().decode(
            QueueFile.self,
            from: Data(contentsOf: quarantine))
        #expect(quarantined.pending == [duplicate, duplicate])
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test("Interrupted running work returns to the head once with the same seed")
    func interruptedClaimRestoresExactlyOnce() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let interrupted = job(
            id: "00000000-0000-0000-0000-000000000041",
            prompt: "interrupted",
            seedText: "")
        let next = job(
            id: "00000000-0000-0000-0000-000000000042",
            prompt: "next",
            seedText: "73")
        let claimID = uuid("10000000-0000-0000-0000-000000000041")
        let store = try QueueStore(fileURL: fixture.fileURL)
        try await store.enqueue(interrupted)
        try await store.enqueue(next)

        let maybeClaim = try await store.claimNext(
            randomSeed: 4_242,
            claimID: claimID)
        let claim = try #require(maybeClaim)
        #expect(claim.job.id == interrupted.id)
        #expect(claim.recipe == interrupted.recipe.resolvingRandomSeed(to: 4_242))
        #expect(claim.resolvedSeed == 4_242)
        let claimedDocument = try fixture.readDocument()
        #expect(claimedDocument.pending == [next])
        #expect(claimedDocument.running == [claim])

        let firstRecovery = try QueueStore(fileURL: fixture.fileURL)
        #expect(firstRecovery.startupReport.restoredInterruptedClaim == claim)
        #expect(firstRecovery.startupReport.restoredInterruptedClaims == [claim])
        let recoveredSnapshot = await firstRecovery.snapshot()
        #expect(recoveredSnapshot.running == nil)
        #expect(recoveredSnapshot.pending.map(\.id) == [interrupted.id, next.id])
        #expect(recoveredSnapshot.pending.first?.seedText == "4242")
        let onceRecoveredData = try Data(contentsOf: fixture.fileURL)

        let secondRecovery = try QueueStore(fileURL: fixture.fileURL)
        #expect(secondRecovery.startupReport.restoredInterruptedClaim == nil)
        #expect(!secondRecovery.startupReport.hasRecovery)
        let secondSnapshot = await secondRecovery.snapshot()
        #expect(secondSnapshot.pending.map(\.id) == [interrupted.id, next.id])
        #expect(Set(secondSnapshot.pending.map(\.id)).count == 2)
        #expect(try Data(contentsOf: fixture.fileURL) == onceRecoveredData)
    }

    @Test("Retry retains a random seed and stale completion cannot advance the queue")
    func claimAcknowledgementIsExact() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let pending = job(
            id: "00000000-0000-0000-0000-000000000051",
            prompt: "retry me")
        let firstClaimID = uuid("10000000-0000-0000-0000-000000000051")
        let secondClaimID = uuid("10000000-0000-0000-0000-000000000052")
        let staleClaimID = uuid("10000000-0000-0000-0000-000000000053")
        let store = try QueueStore(fileURL: fixture.fileURL)
        try await store.enqueue(pending)
        _ = try await store.claimNext(randomSeed: 8_888, claimID: firstClaimID)

        do {
            try await store.completeClaim(staleClaimID)
            Issue.record("Expected a stale claim to be rejected")
        } catch let QueueStoreError.staleClaim(expected, received) {
            #expect(expected == firstClaimID)
            #expect(received == staleClaimID)
        }
        #expect(await store.snapshot().running?.id == firstClaimID)

        try await store.retryClaim(firstClaimID)
        let retrySnapshot = await store.snapshot()
        #expect(retrySnapshot.running == nil)
        #expect(retrySnapshot.pending.count == 1)
        #expect(retrySnapshot.pending.first?.seedText == "8888")

        let retried = try await store.claimNext(
            randomSeed: 9_999,
            claimID: secondClaimID)
        #expect(retried?.resolvedSeed == 8_888)
        try await store.completeClaim(secondClaimID)
        #expect(await store.snapshot().isEmpty)
    }

    @Test("Claims resolve random recipes once and never duplicate the seed field")
    func claimResolvesRecipeSeedOnce() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let random = QueueJob(
            id: uuid("00000000-0000-0000-0000-000000000055"),
            recipe: recipe(prompt: "random full recipe", seed: .random))
        let fixed = QueueJob(
            id: uuid("00000000-0000-0000-0000-000000000056"),
            recipe: recipe(prompt: "fixed full recipe", seed: .fixed(56)))
        let recorder = SeedRecorder(seed: 55)
        let store = try QueueStore(fileURL: fixture.fileURL)
        try await store.enqueue(random)
        try await store.enqueue(fixed)

        let firstClaims = try await store.claimNextGroup(
            randomSeed: recorder.record)

        #expect(recorder.indices == [0])
        #expect(firstClaims.map(\.resolvedSeed) == [55, 56])
        #expect(firstClaims[0].recipe == random.recipe.resolvingRandomSeed(to: 55))
        #expect(firstClaims[1].recipe == fixed.recipe)
        let persistedJSON = try #require(String(
            data: Data(contentsOf: fixture.fileURL),
            encoding: .utf8))
        #expect(!persistedJSON.contains("resolvedSeed"))

        try await store.retryClaim(firstClaims[0].id)
        let retried = try await store.claimNextGroup(randomSeed: recorder.record)
        #expect(recorder.indices == [0])
        #expect(retried.map(\.resolvedSeed) == [55, 56])
        #expect(retried.map(\.recipe) == firstClaims.map(\.recipe))
    }

    @Test("A group atomically claims at most four contiguous jobs with all seeds")
    func groupedClaimPersistsBeforeReturning() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let jobs = [
            job(
                id: "00000000-0000-0000-0000-000000000061",
                prompt: "one"),
            job(
                id: "00000000-0000-0000-0000-000000000062",
                prompt: "two",
                seedText: "202"),
            job(
                id: "00000000-0000-0000-0000-000000000063",
                prompt: "three"),
            job(
                id: "00000000-0000-0000-0000-000000000064",
                prompt: "four"),
            job(
                id: "00000000-0000-0000-0000-000000000065",
                prompt: "five"),
        ]
        let randomSeeds: [UInt64] = [101, 999, 303, 404]
        let claimIDs = (61...64).map {
            uuid(String(format: "10000000-0000-0000-0000-%012d", $0))
        }
        let store = try QueueStore(fileURL: fixture.fileURL)
        for queued in jobs {
            try await store.enqueue(queued)
        }

        let claims = try await store.claimNextGroup(
            maximumCount: 99,
            randomSeed: { randomSeeds[$0] },
            claimID: { claimIDs[$0] })

        #expect(claims.count == QueueStore.maximumClaimGroupSize)
        #expect(claims.map(\.job.id) == Array(jobs.prefix(4)).map(\.id))
        #expect(claims.map(\.recipe.prompts) == Array(jobs.prefix(4)).map(\.recipe.prompts))
        #expect(claims.map(\.resolvedSeed) == [101, 202, 303, 404])
        let snapshot = await store.snapshot()
        #expect(snapshot.running == claims.first)
        #expect(snapshot.runningClaims == claims)
        #expect(snapshot.pending == [jobs[4]])

        let persisted = try fixture.readDocument()
        #expect(persisted.revision == 6)
        #expect(persisted.running == claims)
        #expect(persisted.pending == [jobs[4]])
    }

    @Test("A claim group stops at the first session key boundary")
    func groupedClaimStopsAtSessionBoundary() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let first = QueueJob(
            id: uuid("00000000-0000-0000-0000-000000000066"),
            recipe: recipe(prompt: "first session", seed: .random))
        let sameSession = QueueJob(
            id: uuid("00000000-0000-0000-0000-000000000067"),
            recipe: recipe(prompt: "same session", seed: .fixed(67)))
        var boundaryRecipe = recipe(prompt: "new session", seed: .random)
        boundaryRecipe.model.manifestHash = queueHash("b")
        let boundary = QueueJob(
            id: uuid("00000000-0000-0000-0000-000000000068"),
            recipe: boundaryRecipe)
        let later = QueueJob(
            id: uuid("00000000-0000-0000-0000-000000000069"),
            recipe: recipe(prompt: "later old session", seed: .random))
        let store = try QueueStore(fileURL: fixture.fileURL)
        for job in [first, sameSession, boundary, later] {
            try await store.enqueue(job)
        }

        let firstGroup = try await store.claimNextGroup(randomSeed: { _ in 66 })

        #expect(firstGroup.map(\.job.id) == [first.id, sameSession.id])
        #expect(firstGroup.map(\.resolvedSeed) == [66, 67])
        #expect(await store.snapshot().pending.map(\.id) == [boundary.id, later.id])
        try await store.completeClaim(firstGroup[0].id)
        try await store.completeClaim(firstGroup[1].id)

        let secondGroup = try await store.claimNextGroup(randomSeed: { _ in 68 })
        #expect(secondGroup.map(\.job.id) == [boundary.id])
        #expect(await store.snapshot().pending.map(\.id) == [later.id])
    }

    @Test("Grouped completion is durable and strictly ordered")
    func groupedCompletionIsOrdered() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let jobs = (71...73).map {
            job(
                id: String(format: "00000000-0000-0000-0000-%012d", $0),
                prompt: "job \($0)",
                seedText: String($0))
        }
        let claimIDs = (71...73).map {
            uuid(String(format: "10000000-0000-0000-0000-%012d", $0))
        }
        let store = try QueueStore(fileURL: fixture.fileURL)
        for queued in jobs {
            try await store.enqueue(queued)
        }
        let claims = try await store.claimNextGroup(
            maximumCount: 3,
            claimID: { claimIDs[$0] })

        do {
            try await store.completeClaim(claims[1].id)
            Issue.record("Expected out-of-order completion to be rejected")
        } catch let QueueStoreError.staleClaim(expected, received) {
            #expect(expected == claims[0].id)
            #expect(received == claims[1].id)
        }
        #expect(await store.snapshot().runningClaims == claims)
        #expect(try fixture.readDocument().running == claims)

        try await store.completeClaim(claims[0].id)
        #expect(await store.snapshot().runningClaims == Array(claims.dropFirst()))
        #expect(try fixture.readDocument().running == Array(claims.dropFirst()))
        try await store.completeClaim(claims[1].id)
        try await store.completeClaim(claims[2].id)
        #expect(await store.snapshot().isEmpty)
    }

    @Test("Retry and cancel restore the current grouped suffix with stable seeds")
    func groupedRetryAndCancelRestoreSuffix() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let jobs = (81...85).map {
            job(
                id: String(format: "00000000-0000-0000-0000-%012d", $0),
                prompt: "job \($0)")
        }
        let firstClaimIDs = (81...84).map {
            uuid(String(format: "10000000-0000-0000-0000-%012d", $0))
        }
        let secondClaimIDs = (81...84).map {
            uuid(String(format: "20000000-0000-0000-0000-%012d", $0))
        }
        let firstSeeds: [UInt64] = [11, 12, 13, 14]
        let secondSeeds: [UInt64] = [91, 92, 93, 94]
        let store = try QueueStore(fileURL: fixture.fileURL)
        for queued in jobs {
            try await store.enqueue(queued)
        }
        let firstClaims = try await store.claimNextGroup(
            randomSeed: { firstSeeds[$0] },
            claimID: { firstClaimIDs[$0] })

        try await store.completeClaim(firstClaims[0].id)
        try await store.retryClaim(firstClaims[1].id)
        var snapshot = await store.snapshot()
        #expect(snapshot.runningClaims.isEmpty)
        #expect(snapshot.pending.map(\.id) == Array(jobs.dropFirst()).map(\.id))
        #expect(snapshot.pending.map(\.seedText) == ["12", "13", "14", ""])

        let secondClaims = try await store.claimNextGroup(
            randomSeed: { secondSeeds[$0] },
            claimID: { secondClaimIDs[$0] })
        #expect(secondClaims.map(\.resolvedSeed) == [12, 13, 14, 94])
        try await store.cancelClaim(secondClaims[0].id)

        snapshot = await store.snapshot()
        #expect(snapshot.runningClaims.isEmpty)
        #expect(snapshot.pending.map(\.id) == Array(jobs.dropFirst()).map(\.id))
        #expect(snapshot.pending.map(\.seedText) == ["12", "13", "14", "94"])
        #expect(try fixture.readDocument().running.isEmpty)
    }

    @Test("Startup restores an interrupted group exactly once")
    func interruptedGroupRestoresExactlyOnce() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let jobs = (91...95).map {
            job(
                id: String(format: "00000000-0000-0000-0000-%012d", $0),
                prompt: "job \($0)")
        }
        let claimIDs = (91...94).map {
            uuid(String(format: "10000000-0000-0000-0000-%012d", $0))
        }
        let randomSeeds: [UInt64] = [31, 32, 33, 34]
        let store = try QueueStore(fileURL: fixture.fileURL)
        for queued in jobs {
            try await store.enqueue(queued)
        }
        let claims = try await store.claimNextGroup(
            randomSeed: { randomSeeds[$0] },
            claimID: { claimIDs[$0] })

        let firstRecovery = try QueueStore(fileURL: fixture.fileURL)
        #expect(firstRecovery.startupReport.restoredInterruptedClaims == claims)
        #expect(firstRecovery.startupReport.restoredInterruptedClaim == claims.first)
        let recovered = await firstRecovery.snapshot()
        #expect(recovered.runningClaims.isEmpty)
        #expect(recovered.pending.map(\.id) == jobs.map(\.id))
        #expect(recovered.pending.map(\.seedText) == ["31", "32", "33", "34", ""])
        let recoveredData = try Data(contentsOf: fixture.fileURL)

        let secondRecovery = try QueueStore(fileURL: fixture.fileURL)
        #expect(secondRecovery.startupReport.restoredInterruptedClaims.isEmpty)
        #expect(secondRecovery.startupReport.restoredInterruptedClaim == nil)
        let secondSnapshot = await secondRecovery.snapshot()
        #expect(secondSnapshot.pending.map(\.id) == jobs.map(\.id))
        #expect(Set(secondSnapshot.pending.map(\.id)).count == jobs.count)
        #expect(try Data(contentsOf: fixture.fileURL) == recoveredData)
    }

    @Test("Version 1 running claim migrates without losing pending jobs")
    func legacyRunningClaimMigrates() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let interrupted = job(
            id: "00000000-0000-0000-0000-000000000101",
            prompt: "legacy running")
        let pending = [
            job(
                id: "00000000-0000-0000-0000-000000000102",
                prompt: "legacy pending one"),
            job(
                id: "00000000-0000-0000-0000-000000000103",
                prompt: "legacy pending two"),
        ]
        let claimID = uuid("10000000-0000-0000-0000-000000000101")
        let legacyClaim = LegacyQueueClaim(
            id: claimID,
            job: LegacyScalarQueueJob(interrupted),
            resolvedSeed: 4_242)
        let recoveredClaim = QueueStore.Claim(
            id: claimID,
            job: interrupted,
            resolvedSeed: 4_242)
        try fixture.writeDocument(LegacyVersion1QueueFile(
            revision: 7,
            pending: pending.map(LegacyScalarQueueJob.init),
            running: legacyClaim))

        let migratedStore = try QueueStore(fileURL: fixture.fileURL)
        #expect(migratedStore.startupReport.restoredInterruptedClaim == recoveredClaim)
        #expect(migratedStore.startupReport.restoredInterruptedClaims == [recoveredClaim])
        let snapshot = await migratedStore.snapshot()
        #expect(snapshot.pending.map(\.id) == [interrupted.id] + pending.map(\.id))
        #expect(snapshot.pending.first?.seedText == "4242")
        #expect(snapshot.pending.allSatisfy {
            $0.recipe.model == QueueJob.legacyModelReference
        })
        #expect(snapshot.runningClaims.isEmpty)

        let migrated = try fixture.readDocument()
        #expect(migrated.version == QueueStore.version)
        #expect(migrated.revision == 8)
        #expect(migrated.pending.map(\.id) == [interrupted.id] + pending.map(\.id))
        #expect(migrated.running.isEmpty)
        let migratedData = try Data(contentsOf: fixture.fileURL)

        let reopened = try QueueStore(fileURL: fixture.fileURL)
        #expect(reopened.startupReport.restoredInterruptedClaims.isEmpty)
        #expect(await reopened.snapshot().pending.map(\.id)
            == [interrupted.id] + pending.map(\.id))
        #expect(try Data(contentsOf: fixture.fileURL) == migratedData)
    }

    @Test("Version 1 pending-only document migrates without loss")
    func legacyPendingOnlyDocumentMigrates() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let pending = [
            job(
                id: "00000000-0000-0000-0000-000000000111",
                prompt: "legacy one"),
            job(
                id: "00000000-0000-0000-0000-000000000112",
                prompt: "legacy two",
                seedText: "112"),
        ]
        try fixture.writeDocument(LegacyVersion1QueueFile(
            revision: 12,
            pending: pending.map(LegacyScalarQueueJob.init)))

        let store = try QueueStore(fileURL: fixture.fileURL)
        #expect(store.startupReport.restoredInterruptedClaims.isEmpty)
        #expect(await store.snapshot().pending == pending)
        let migrated = try fixture.readDocument()
        #expect(migrated.version == QueueStore.version)
        #expect(migrated.revision == 13)
        #expect(migrated.pending == pending)
        #expect(migrated.pending.map(\.recipe.sampler.seed) == [.random, .fixed(112)])
        #expect(migrated.running.isEmpty)
        #expect(try fixture.permissions() == 0o600)
    }

    @Test("Version 2 grouped running claims migrate to the head exactly once")
    func version2GroupedClaimsMigrate() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let runningJobs = [
            job(
                id: "00000000-0000-0000-0000-000000000121",
                prompt: "v2 random running"),
            job(
                id: "00000000-0000-0000-0000-000000000122",
                prompt: "v2 fixed running",
                seedText: "122"),
        ]
        let pending = [
            job(
                id: "00000000-0000-0000-0000-000000000123",
                prompt: "v2 random pending"),
            job(
                id: "00000000-0000-0000-0000-000000000124",
                prompt: "v2 fixed pending",
                seedText: "124"),
        ]
        let claimIDs = [
            uuid("10000000-0000-0000-0000-000000000121"),
            uuid("10000000-0000-0000-0000-000000000122"),
        ]
        let legacyClaims = zip(claimIDs, runningJobs).map { claimID, job in
            LegacyQueueClaim(
                id: claimID,
                job: LegacyScalarQueueJob(job),
                resolvedSeed: job.id == runningJobs[0].id ? 1_221 : 122)
        }
        try fixture.writeDocument(LegacyVersion2QueueFile(
            revision: 20,
            pending: pending.map(LegacyScalarQueueJob.init),
            running: legacyClaims))

        let store = try QueueStore(fileURL: fixture.fileURL)
        let expectedClaims = [
            QueueStore.Claim(id: claimIDs[0], job: runningJobs[0], resolvedSeed: 1_221),
            QueueStore.Claim(id: claimIDs[1], job: runningJobs[1], resolvedSeed: 122),
        ]
        #expect(store.startupReport.restoredInterruptedClaims == expectedClaims)
        let snapshot = await store.snapshot()
        #expect(snapshot.runningClaims.isEmpty)
        #expect(snapshot.pending.map(\.id) == (runningJobs + pending).map(\.id))
        #expect(snapshot.pending.map(\.recipe.sampler.seed) == [
            .fixed(1_221), .fixed(122), .random, .fixed(124),
        ])
        #expect(snapshot.pending.allSatisfy {
            $0.recipe.model.modelID == "krea-2-turbo"
                && $0.recipe.model.variantID == "alis-mixed-4-8"
                && $0.recipe.model == QueueJob.legacyModelReference
        })

        let migrated = try fixture.readDocument()
        #expect(migrated.version == 3)
        #expect(migrated.revision == 21)
        #expect(migrated.running.isEmpty)
        let migratedData = try Data(contentsOf: fixture.fileURL)

        let reopened = try QueueStore(fileURL: fixture.fileURL)
        #expect(reopened.startupReport.restoredInterruptedClaims.isEmpty)
        #expect(await reopened.snapshot().pending == snapshot.pending)
        #expect(try Data(contentsOf: fixture.fileURL) == migratedData)
    }

    @Test("Unsupported versions are preserved for a compatible app")
    func unsupportedVersionIsNotQuarantined() throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let future = QueueFile(
            version: QueueStore.version + 1,
            revision: 1,
            pending: [])
        try fixture.writeDocument(future)
        let original = try Data(contentsOf: fixture.fileURL)

        do {
            _ = try QueueStore(fileURL: fixture.fileURL)
            Issue.record("Expected an unsupported queue version")
        } catch let QueueStoreError.unsupportedVersion(expected, found) {
            #expect(expected == QueueStore.version)
            #expect(found == QueueStore.version + 1)
        }

        #expect(try Data(contentsOf: fixture.fileURL) == original)
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.root,
            includingPropertiesForKeys: nil)
        #expect(files.map { $0.resolvingSymlinksInPath() }
            == [fixture.fileURL.resolvingSymlinksInPath()])
    }

    @Test("A future embedded recipe is preserved as incompatible data")
    func futureRecipeIsNotQuarantined() throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        var futureRecipe = recipe(prompt: "future recipe", seed: .random)
        futureRecipe.version = GenerationRecipe.currentVersion + 1
        try fixture.writeDocument(QueueFile(
            revision: 9,
            pending: [QueueJob(recipe: futureRecipe)]))
        let original = try Data(contentsOf: fixture.fileURL)

        do {
            _ = try QueueStore(fileURL: fixture.fileURL)
            Issue.record("Expected an unsupported embedded recipe version")
        } catch let QueueStoreError.unsupportedVersion(expected, found) {
            #expect(expected == GenerationRecipe.currentVersion)
            #expect(found == GenerationRecipe.currentVersion + 1)
        }

        #expect(try Data(contentsOf: fixture.fileURL) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.stagingURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            == [fixture.fileURL.lastPathComponent])
    }

    @Test("Queue files that are symlinks are refused without following them")
    func symlinkIsNeverFollowed() throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenQueueOutside-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        let payload = Data("outside stays unchanged".utf8)
        try payload.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.fileURL,
            withDestinationURL: outside)

        #expect(throws: QueueStoreError.self) {
            _ = try QueueStore(fileURL: fixture.fileURL)
        }
        #expect(try Data(contentsOf: outside) == payload)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.fileURL.path) == outside.path)
    }

    @Test("Equal revisions with different contents are preserved for manual recovery")
    func equalRevisionConflictIsNonMutating() throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let main = QueueFile(
            revision: 12,
            pending: [job(
                id: "00000000-0000-0000-0000-000000000201",
                prompt: "main")])
        let staged = QueueFile(
            revision: 12,
            pending: [job(
                id: "00000000-0000-0000-0000-000000000202",
                prompt: "staged")])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let mainData = try encoder.encode(main)
        let stagedData = try encoder.encode(staged)
        try mainData.write(to: fixture.fileURL)
        try stagedData.write(to: fixture.stagingURL)

        #expect(throws: QueueStoreError.self) {
            _ = try QueueStore(fileURL: fixture.fileURL)
        }
        #expect(try Data(contentsOf: fixture.fileURL) == mainData)
        #expect(try Data(contentsOf: fixture.stagingURL) == stagedData)
    }

    @Test("Queue storage keeps its parent and document private")
    func privatePermissions() async throws {
        let fixture = try QueueStoreFixture()
        defer { fixture.remove() }
        let store = try QueueStore(fileURL: fixture.fileURL)
        try await store.enqueue(job(
            id: "00000000-0000-0000-0000-000000000203",
            prompt: "private"))

        #expect(try fixture.permissions() == 0o600)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.root.path)
        let parentPermissions = try #require(
            (attributes[.posixPermissions] as? NSNumber)?.intValue)
        #expect(parentPermissions & 0o777 == 0o700)
        #expect(!FileManager.default.fileExists(atPath: fixture.stagingURL.path))
    }
}

private struct QueueFile: Codable {
    var schema: String = QueueStore.schema
    var version: Int = QueueStore.version
    var revision: UInt64
    var pending: [QueueJob]
    var running: [QueueStore.Claim] = []
}

private struct LegacyVersion1QueueFile: Codable {
    var schema: String = QueueStore.schema
    var version: Int = 1
    var revision: UInt64
    var pending: [LegacyScalarQueueJob]
    var running: LegacyQueueClaim? = nil
}

private struct LegacyVersion2QueueFile: Codable {
    var schema: String = QueueStore.schema
    var version: Int = 2
    var revision: UInt64
    var pending: [LegacyScalarQueueJob]
    var running: [LegacyQueueClaim]
}

private struct LegacyQueueClaim: Codable {
    let id: UUID
    let job: LegacyScalarQueueJob
    let resolvedSeed: UInt64
}

private struct LegacyScalarQueueJob: Codable {
    let id: UUID
    var prompt: String
    var width: Int
    var height: Int
    var steps: Int
    var seedText: String

    init(_ job: QueueJob) {
        id = job.id
        prompt = job.prompt
        width = job.width
        height = job.height
        steps = job.steps
        seedText = job.seedText
    }
}

private struct QueueStoreFixture {
    let root: URL
    let fileURL: URL

    var stagingURL: URL { fileURL.appendingPathExtension("pending") }

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TwisterminigenQueueStoreTests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        self.root = root
        self.fileURL = root.appendingPathComponent("queue.json")
    }

    func writeDocument<Document: Encodable>(_ document: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }

    func readDocument() throws -> QueueFile {
        try JSONDecoder().decode(QueueFile.self, from: Data(contentsOf: fileURL))
    }

    func permissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func job(id: String, prompt: String, seedText: String = "") -> QueueJob {
    QueueJob(
        id: uuid(id),
        prompt: prompt,
        width: 512,
        height: 512,
        steps: 8,
        seedText: seedText)
}

private func recipe(
    prompt: String,
    seed: GenerationRecipe.Seed
) -> GenerationRecipe {
    var recipe = GenerationRecipe.turbo(
        prompt: prompt,
        negativePrompt: "queue negative",
        model: .init(
            modelID: "queue-model",
            variantID: "queue-variant",
            manifestHash: queueHash("a")),
        seed: seed)
    recipe.canvas = .init(width: 640, height: 512)
    recipe.sampler.guidance = 1.5
    recipe.sampler.precision = .float16
    recipe.loras = [.init(
        managedID: uuid("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
        sha256: queueHash("c"),
        scale: 0.75)]
    recipe.regions = [.init(
        id: uuid("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
        prompt: "queue region",
        rect: .init(x0: 0, y0: 0, x1: 0.5, y1: 1))]
    recipe.inputImage = .init(
        managedID: uuid("cccccccc-cccc-cccc-cccc-cccccccccccc"),
        sha256: queueHash("d"),
        strength: 0.5,
        resize: .fit)
    return recipe
}

private func queueHash(_ digit: String) -> String {
    String(repeating: digit, count: 64)
}

private final class SeedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let seed: UInt64
    private var recordedIndices: [Int] = []

    init(seed: UInt64) {
        self.seed = seed
    }

    var indices: [Int] {
        lock.withLock { recordedIndices }
    }

    func record(_ index: Int) -> UInt64 {
        lock.withLock { recordedIndices.append(index) }
        return seed
    }
}

private func uuid(_ value: String) -> UUID {
    guard let id = UUID(uuidString: value) else {
        preconditionFailure("Invalid UUID fixture: \(value)")
    }
    return id
}
