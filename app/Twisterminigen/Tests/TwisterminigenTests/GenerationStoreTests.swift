import Foundation
import CryptoKit
import Testing
@testable import Twisterminigen

@Suite("Transactional generation store")
struct GenerationStoreTests {
    @Test("Managed file names accept the existing canonical form and reject traversal")
    func managedFileNameValidation() throws {
        let identifier = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let canonical = "twist_01234567-89AB-CDEF-0123-456789ABCDEF_42.png"
        let parsed = try ManagedGenerationFileName(validating: canonical)

        #expect(parsed.identifier == identifier)
        #expect(parsed.seed == 42)
        #expect(ManagedGenerationFileName(identifier: identifier, seed: 42).rawValue == canonical)

        let invalid = [
            "../\(canonical)",
            "twist_../../victim_42.png",
            "twist_0123456789ABCDEF0123456789ABCDEF_42.png",
            "twist_01234567-89AB-CDEF-0123-456789ABCDEF_042.png",
            "twist_01234567-89AB-CDEF-0123-456789ABCDEF_42.PNG",
            "twist_01234567-89AB-CDEF-0123-456789ABCDEF_-1.png",
        ]
        for fileName in invalid {
            #expect((try? ManagedGenerationFileName(validating: fileName)) == nil)
        }

        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        #expect((try? fixture.paths.imageURL(for: "../../outside.png")) == nil)
    }

    @Test("Save recovery is idempotent at every durable crash window")
    func saveCrashWindows() async throws {
        for point in [
            GenerationStoreFailurePoint.saveAfterJournalWrite,
            .saveAfterImageWrite,
            .saveAfterSidecarWrite,
            .saveAfterIndexWrite,
        ] {
            try await exerciseSaveCrash(at: point)
        }
    }

    @Test("A completion id makes a retried queue save idempotent")
    func completionIDPreventsDuplicateSave() async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        let store = GenerationStore(paths: fixture.paths)
        let completionID = UUID()

        let first = try await store.save(
            pngData: Data("first".utf8),
            prompt: "queued",
            width: 512,
            height: 512,
            steps: 8,
            seed: 77,
            duration: 1,
            completionID: completionID)
        let retried = try await store.save(
            pngData: Data("different retry payload".utf8),
            prompt: "queued",
            width: 512,
            height: 512,
            steps: 8,
            seed: 77,
            duration: 2,
            completionID: completionID)

        #expect(retried.id == first.id)
        #expect(retried.completionID == completionID)
        #expect((await store.all()).map(\.id) == [first.id])
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.images,
            includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(try Data(contentsOf: files[0]) == Data("first".utf8))
    }

    @Test("Delete recovery never leaves a dangling record or orphaned image")
    func deleteCrashWindows() async throws {
        for point in [
            GenerationStoreFailurePoint.deleteAfterJournalWrite,
            .deleteAfterIndexWrite,
            .deleteAfterSidecarRemoval,
            .deleteAfterImageRemoval,
        ] {
            try await exerciseDeleteCrash(at: point)
        }
    }

    @Test("Delete-all recovery completes exactly once across every crash window")
    func deleteAllCrashWindows() async throws {
        for point in [
            GenerationStoreFailurePoint.deleteAllAfterJournalWrite,
            .deleteAllAfterIndexWrite,
            .deleteAllAfterSidecarRemoval,
            .deleteAllAfterImageRemoval,
        ] {
            try await exerciseDeleteAllCrash(at: point)
        }
    }

    @Test("Unsafe index paths are rejected without touching an outside file")
    func traversalRecordIsQuarantined() async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("GenerationStoreVictim-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outside) }
        let payload = Data("outside-data".utf8)
        try payload.write(to: outside)

        let unsafe = Generation(
            id: UUID(),
            prompt: "unsafe",
            width: 1,
            height: 1,
            steps: 1,
            seed: 9,
            durationSeconds: 0,
            imageFileName: "../../\(outside.lastPathComponent)")
        try fixture.writeIndex([unsafe])

        let store = GenerationStore(paths: fixture.paths)
        let records = await store.all()
        let report = await store.startupRecoveryReport()

        #expect(records.isEmpty)
        #expect(report.unsafeRecords.map(\.id).contains(unsafe.id))
        #expect(report.quarantinedItems.contains { $0.reason == .rejectedRecords })
        #expect(try Data(contentsOf: outside) == payload)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.journal.path))
    }

    @Test("Invalid persisted provenance is rejected during startup validation")
    func invalidProvenanceIsRejected() async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        let id = UUID()
        let seed: UInt64 = 91
        let record = Generation(
            id: id,
            prompt: "invalid provenance",
            width: 512,
            height: 512,
            steps: 4,
            seed: seed,
            durationSeconds: 0.1,
            imageFileName: ManagedGenerationFileName(identifier: id, seed: seed).rawValue,
            provenance: .batch(groupID: UUID(), itemIndex: 0, itemCount: 9))
        try fixture.writeIndex([record])

        let store = GenerationStore(paths: fixture.paths)
        let report = await store.startupRecoveryReport()

        #expect((await store.all()).isEmpty)
        #expect(report.unsafeRecords.map(\.id) == [record.id])
        #expect(report.quarantinedItems.contains { $0.reason == .rejectedRecords })
    }

    @Test("A canonical image symlink is quarantined without following its target")
    func symlinkEscapeIsQuarantined() async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.paths.images, withIntermediateDirectories: true)

        let target = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("GenerationStoreTarget-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: target) }
        let payload = Data("target-must-survive".utf8)
        try payload.write(to: target)

        let identifier = UUID()
        let fileName = ManagedGenerationFileName(identifier: identifier, seed: 17).rawValue
        let link = try fixture.paths.imageURL(for: fileName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let record = Generation(
            id: identifier,
            prompt: "symlink",
            width: 1,
            height: 1,
            steps: 1,
            seed: 17,
            durationSeconds: 0,
            imageFileName: fileName)
        try fixture.writeIndex([record])

        let store = GenerationStore(paths: fixture.paths)
        let report = await store.startupRecoveryReport()
        let quarantineItem = try #require(
            report.quarantinedItems.first { $0.reason == .unsafeImage })

        #expect((await store.all()).isEmpty)
        #expect(try Data(contentsOf: target) == payload)
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(
            atPath: quarantineItem.quarantineURL.path)) != nil)
    }

    @Test("A symlinked Images directory prevents all writes outside the library")
    func symlinkedImagesDirectoryIsRejected() async throws {
        let fixture = try GenerationStoreFixture(createRoot: true)
        defer { fixture.remove() }
        let outsideDirectory = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("GenerationStoreOutside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        try FileManager.default.createDirectory(
            at: outsideDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.images, withDestinationURL: outsideDirectory)

        let store = GenerationStore(paths: fixture.paths)
        do {
            _ = try await saveFixtureImage(in: store, seed: 22)
            Issue.record("A save crossed a symlinked Images directory")
        } catch {
            // The specific filesystem error is intentionally not part of the public contract.
        }

        let outsideContents = try FileManager.default.contentsOfDirectory(
            at: outsideDirectory, includingPropertiesForKeys: nil)
        #expect(outsideContents.isEmpty)
        #expect(!(await store.startupRecoveryReport()).errors.isEmpty)
    }

    @Test("Startup reconciliation reports and quarantines every unsafe library class")
    func reconciliationReport() async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.paths.images, withIntermediateDirectories: true)

        let kept = fixture.generation(seed: 31)
        try Data("kept".utf8).write(to: fixture.paths.imageURL(for: kept.imageFileName))
        let missing = fixture.generation(seed: 32)
        let unsafe = Generation(
            id: UUID(), prompt: "unsafe", width: 1, height: 1, steps: 1, seed: 33,
            durationSeconds: 0, imageFileName: "../unsafe.png")
        try fixture.writeIndex([kept, missing, unsafe])

        let orphanName = ManagedGenerationFileName(identifier: UUID(), seed: 34).rawValue
        try Data("orphan".utf8).write(to: fixture.paths.imageURL(for: orphanName))
        let suspiciousName = "twist_not-a-uuid_35.png"
        try Data("unsafe-name".utf8).write(
            to: fixture.paths.images.appendingPathComponent(suspiciousName))

        let store = GenerationStore(paths: fixture.paths)
        let records = await store.all()
        let report = await store.startupRecoveryReport()

        #expect(records.map(\.id) == [kept.id])
        #expect(report.missingImages.map(\.id).contains(missing.id))
        #expect(report.unsafeRecords.map(\.id).contains(unsafe.id))
        #expect(report.orphanedImages == [orphanName])
        #expect(report.unsafeImageEntries.contains(suspiciousName))
        #expect(report.missingThumbnails == [kept.imageFileName])
        #expect(report.indexWasRewritten)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.paths.images.appendingPathComponent(orphanName).path))
        #expect(report.quarantinedItems.allSatisfy {
            FileManager.default.fileExists(atPath: $0.quarantineURL.path)
                || (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: $0.quarantineURL.path)) != nil
        })
    }

    @Test("Exact saves round-trip every recipe field through index and sidecar")
    func exactRecipeRoundTrip() async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        let store = GenerationStore(paths: fixture.paths)
        var recipe = GenerationRecipe.turbo(
            prompt: "exact",
            negativePrompt: "letters",
            model: .init(
                modelID: "krea-2-turbo",
                variantID: "alis-mixed-4-8",
                manifestHash: String(repeating: "a", count: 64)),
            seed: .fixed(UInt64.max))
        recipe.canvas = .init(width: 768, height: 512)
        recipe.sampler.steps = 12
        recipe.sampler.guidance = 3.5
        recipe.sampler.precision = .float16
        recipe.loras = [.init(
            managedID: UUID(),
            sha256: String(repeating: "b", count: 64),
            scale: 0.75)]
        recipe.regions = [.init(
            id: UUID(),
            prompt: "left",
            rect: .init(x0: 0, y0: 0, x1: 0.5, y1: 1))]
        recipe.inputImage = .init(
            managedID: UUID(),
            sha256: String(repeating: "c", count: 64),
            strength: 0.4,
            resize: .fill)
        let provenance = GenerationProvenance.batch(
            groupID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            itemIndex: 0,
            itemCount: 2)

        let generation = try await store.save(
            pngData: Data("exact-png".utf8),
            recipe: recipe,
            duration: 2.5,
            provenance: provenance)
        let reopened = GenerationStore(paths: fixture.paths)
        let record = try #require((await reopened.all()).first)
        let sidecarURL = try fixture.paths.recipeURL(for: generation.imageFileName)
        let sidecar = try JSONDecoder().decode(
            GenerationSidecarEnvelope.self,
            from: Data(contentsOf: sidecarURL))

        #expect(record.recipeCapture == .exact)
        #expect(record.recipe == recipe)
        #expect(record.provenance == provenance)
        #expect(sidecar.generation == record)
        #expect(sidecar.pngByteCount == Int64(Data("exact-png".utf8).count))
    }

    @Test("Invalid saves fail before journal or image mutation")
    func invalidSaveIsPreflighted() async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        let store = GenerationStore(paths: fixture.paths)
        let recipe = GenerationRecipe.turbo(
            prompt: "valid",
            model: .init(
                modelID: "krea-2-turbo",
                variantID: "alis-mixed-4-8",
                manifestHash: String(repeating: "a", count: 64)),
            seed: .fixed(1))

        for duration in [-1, .nan, Generation.maximumDurationSeconds + 1] {
            await #expect(throws: GenerationStoreError.self) {
                _ = try await store.save(
                    pngData: Data("payload".utf8),
                    recipe: recipe,
                    duration: duration)
            }
        }
        await #expect(throws: Error.self) {
            _ = try await store.save(
                pngData: Data("payload".utf8),
                prompt: "invalid scalar",
                width: 8,
                height: 8,
                steps: 2,
                seed: 1,
                duration: 1)
        }
        await #expect(throws: GenerationStoreError.self) {
            _ = try await store.save(pngData: Data(), recipe: recipe, duration: 1)
        }

        #expect((await store.all()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.journal.path))
        #expect(try fixture.managedImageNames().isEmpty)
    }

    @Test("Future index and nested recipe versions remain byte-for-byte untouched")
    func futureIndexIsReadOnly() async throws {
        for futureKind in 0...1 {
            let fixture = try GenerationStoreFixture(createRoot: true)
            defer { fixture.remove() }
            try FileManager.default.createDirectory(
                at: fixture.paths.images,
                withIntermediateDirectories: true)
            var generation = fixture.generation(seed: UInt64(200 + futureKind))
            let imageURL = try fixture.paths.imageURL(for: generation.imageFileName)
            let imageData = Data("future-image-\(futureKind)".utf8)
            try imageData.write(to: imageURL)
            if futureKind == 1 {
                var recipe = generation.recipe
                recipe.version = GenerationRecipe.currentVersion + 1
                generation = Generation(
                    id: generation.id,
                    recipe: recipe,
                    recipeCapture: .exact,
                    createdAt: generation.createdAt,
                    durationSeconds: generation.durationSeconds,
                    imageFileName: generation.imageFileName)
            }
            let envelope = GenerationIndexEnvelope(
                version: futureKind == 0
                    ? GenerationIndexEnvelope.currentVersion + 1
                    : GenerationIndexEnvelope.currentVersion,
                generations: [generation])
            let indexData = try JSONEncoder().encode(envelope)
            try indexData.write(to: fixture.paths.generationsIndex)

            let store = GenerationStore(paths: fixture.paths)
            #expect((await store.all()).isEmpty)
            #expect(try Data(contentsOf: fixture.paths.generationsIndex) == indexData)
            #expect(try Data(contentsOf: imageURL) == imageData)
            await #expect(throws: GenerationStoreError.self) {
                _ = try await store.save(
                    pngData: Data("blocked".utf8),
                    prompt: "blocked",
                    width: 512,
                    height: 512,
                    steps: 8,
                    seed: 1,
                    duration: 1)
            }
            #expect(try Data(contentsOf: fixture.paths.generationsIndex) == indexData)
        }
    }

    @Test("A future sidecar is preserved and blocks mutation")
    func futureSidecarIsReadOnly() async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        let seeded = GenerationStore(paths: fixture.paths)
        let generation = try await saveFixtureImage(in: seeded, seed: 210)
        let sidecarURL = try fixture.paths.recipeURL(for: generation.imageFileName)
        let current = try JSONDecoder().decode(
            GenerationSidecarEnvelope.self,
            from: Data(contentsOf: sidecarURL))
        let future = GenerationSidecarEnvelope(
            version: GenerationSidecarEnvelope.currentVersion + 1,
            generation: current.generation,
            pngByteCount: current.pngByteCount,
            pngSHA256: current.pngSHA256)
        let futureData = try JSONEncoder().encode(future)
        try futureData.write(to: sidecarURL, options: .atomic)
        let imageURL = try fixture.paths.imageURL(for: generation.imageFileName)
        let imageData = try Data(contentsOf: imageURL)

        let reopened = GenerationStore(paths: fixture.paths)
        #expect((await reopened.all()).isEmpty)
        #expect(try Data(contentsOf: sidecarURL) == futureData)
        #expect(try Data(contentsOf: imageURL) == imageData)
        await #expect(throws: GenerationStoreError.self) {
            _ = try await reopened.repair()
        }
        #expect(try Data(contentsOf: sidecarURL) == futureData)
    }

    @Test("Sidecars detect PNG tampering and rebuild only when truly missing")
    func sidecarIntegrityAndBackfill() async throws {
        let tamperedFixture = try GenerationStoreFixture()
        defer { tamperedFixture.remove() }
        let seeded = GenerationStore(paths: tamperedFixture.paths)
        let generation = try await saveFixtureImage(in: seeded, seed: 220)
        let imageURL = try tamperedFixture.paths.imageURL(for: generation.imageFileName)
        try Data("tampered".utf8).write(to: imageURL, options: .atomic)

        let tampered = GenerationStore(paths: tamperedFixture.paths)
        #expect((await tampered.all()).isEmpty)
        let tamperReport = await tampered.startupRecoveryReport()
        let sidecarName = try tamperedFixture.paths.recipeURL(
            for: generation.imageFileName).lastPathComponent
        #expect(tamperReport.corruptSidecars.contains(sidecarName))
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))

        let missingFixture = try GenerationStoreFixture()
        defer { missingFixture.remove() }
        let missingStore = GenerationStore(paths: missingFixture.paths)
        let missingGeneration = try await saveFixtureImage(in: missingStore, seed: 221)
        let sidecarURL = try missingFixture.paths.recipeURL(for: missingGeneration.imageFileName)
        try FileManager.default.removeItem(at: sidecarURL)

        let rebuilt = GenerationStore(paths: missingFixture.paths)
        #expect((await rebuilt.all()).map(\.id) == [missingGeneration.id])
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        let envelope = try JSONDecoder().decode(
            GenerationSidecarEnvelope.self,
            from: Data(contentsOf: sidecarURL))
        #expect(envelope.generation.id == missingGeneration.id)
    }

    @Test("Completion IDs reject a different exact recipe")
    func completionIDConflict() async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        let store = GenerationStore(paths: fixture.paths)
        let completionID = UUID()
        var first = Generation.compatibilityRecipe(
            prompt: "first",
            width: 512,
            height: 512,
            steps: 8,
            seed: 1)
        first.prompts.negative = "negative"
        _ = try await store.save(
            pngData: Data("first".utf8),
            recipe: first,
            duration: 1,
            completionID: completionID)
        var second = first
        second.prompts.positive = "different"

        await #expect(throws: GenerationStoreError.completionIDConflict(completionID)) {
            _ = try await store.save(
                pngData: Data("second".utf8),
                recipe: second,
                duration: 1,
                completionID: completionID)
        }
        #expect((await store.all()).count == 1)
    }

    @Test("A real scalar v1 journal migrates and commits its durable image")
    func legacyJournalMigration() async throws {
        let fixture = try GenerationStoreFixture(createRoot: true)
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.paths.images,
            withIntermediateDirectories: true)
        let generation = fixture.generation(seed: 230)
        let legacy = LegacyGenerationRecord(generation)
        let imageData = Data("legacy-journal-image".utf8)
        let imageURL = try fixture.paths.imageURL(for: generation.imageFileName)
        try imageData.write(to: imageURL)
        let journal = LegacyJournalFixture(
            id: UUID(),
            createdAt: Date(),
            records: [legacy],
            fileNames: [generation.imageFileName],
            imageByteCount: imageData.count,
            imageSHA256: SHA256.hash(data: imageData)
                .map { String(format: "%02x", $0) }.joined())
        try JSONEncoder().encode(journal).write(to: fixture.paths.journal)

        let recovered = GenerationStore(paths: fixture.paths)
        let record = try #require((await recovered.all()).first)
        #expect(record.id == generation.id)
        #expect(record.recipeCapture == .legacy)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.journal.path))
        #expect(FileManager.default.fileExists(
            atPath: try fixture.paths.recipeURL(for: generation.imageFileName).path))
        #expect((await recovered.startupRecoveryReport()).recoveredTransactions == 1)
    }

    @Test("Duration formatting never traps on malformed historical values")
    func durationFormattingIsTotal() {
        let base = GenerationStoreFixture.uncheckedGeneration(duration: .greatestFiniteMagnitude)
        #expect(base.durationText == "525600m 0s")
        let invalid = GenerationStoreFixture.uncheckedGeneration(duration: .nan)
        #expect(invalid.durationText == "Unknown")
    }

    private func exerciseSaveCrash(at point: GenerationStoreFailurePoint) async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        let payload = Data("save-\(point.rawValue)".utf8)
        let crashing = fixture.store(crashingAt: point)

        await expectSimulatedCrash {
            _ = try await crashing.save(
                pngData: payload,
                prompt: "save crash",
                width: 512,
                height: 512,
                steps: 8,
                seed: 41,
                duration: 0.5)
        }

        let recovered = GenerationStore(paths: fixture.paths)
        let records = await recovered.all()
        let expectedCount = point == .saveAfterJournalWrite ? 0 : 1
        #expect(records.count == expectedCount)
        #expect(try fixture.managedImageNames().count == expectedCount)
        #expect(try fixture.managedSidecarNames().count == expectedCount)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.journal.path))
        #expect((await recovered.startupRecoveryReport()).recoveredTransactions == 1)
        if let record = records.first {
            #expect(try Data(contentsOf: fixture.paths.imageURL(for: record.imageFileName)) == payload)
        }

        let reopened = GenerationStore(paths: fixture.paths)
        #expect((await reopened.all()).map(\.id) == records.map(\.id))
        #expect((await reopened.startupRecoveryReport()).recoveredTransactions == 0)
    }

    private func exerciseDeleteCrash(at point: GenerationStoreFailurePoint) async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        let seeded = GenerationStore(paths: fixture.paths)
        let generation = try await saveFixtureImage(in: seeded, seed: 51)
        let imageURL = try fixture.paths.imageURL(for: generation.imageFileName)
        let recipeURL = try fixture.paths.recipeURL(for: generation.imageFileName)
        let crashing = fixture.store(crashingAt: point)

        await expectSimulatedCrash {
            _ = try await crashing.delete(id: generation.id)
        }

        let recovered = GenerationStore(paths: fixture.paths)
        #expect((await recovered.all()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
        #expect(!FileManager.default.fileExists(atPath: recipeURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.journal.path))
        #expect((await recovered.startupRecoveryReport()).recoveredTransactions == 1)

        let reopened = GenerationStore(paths: fixture.paths)
        #expect((await reopened.all()).isEmpty)
        #expect((await reopened.startupRecoveryReport()).recoveredTransactions == 0)
    }

    private func exerciseDeleteAllCrash(at point: GenerationStoreFailurePoint) async throws {
        let fixture = try GenerationStoreFixture()
        defer { fixture.remove() }
        let seeded = GenerationStore(paths: fixture.paths)
        _ = try await saveFixtureImage(in: seeded, seed: 61)
        _ = try await saveFixtureImage(in: seeded, seed: 62)
        let crashing = fixture.store(crashingAt: point)

        await expectSimulatedCrash {
            _ = try await crashing.removeAll()
        }

        let recovered = GenerationStore(paths: fixture.paths)
        #expect((await recovered.all()).isEmpty)
        #expect(try fixture.managedImageNames().isEmpty)
        #expect(try fixture.managedSidecarNames().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.journal.path))
        #expect((await recovered.startupRecoveryReport()).recoveredTransactions == 1)

        let reopened = GenerationStore(paths: fixture.paths)
        #expect((await reopened.all()).isEmpty)
        #expect((await reopened.startupRecoveryReport()).recoveredTransactions == 0)
    }
}

private enum SimulatedStoreCrash: Error, Sendable {
    case crash
}

private struct LegacyJournalFixture: Encodable {
    let version = 1
    let id: UUID
    let createdAt: Date
    let operation = "save"
    let records: [LegacyGenerationRecord]
    let fileNames: [String]
    let imageByteCount: Int
    let imageSHA256: String
}

private struct GenerationStoreFixture {
    let root: URL
    let paths: LibraryPaths

    init(createRoot: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenerationStoreTests-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        self.paths = LibraryPaths(root: root)
        if createRoot {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    func store(crashingAt point: GenerationStoreFailurePoint) -> GenerationStore {
        GenerationStore(paths: paths, failureInjector: { actualPoint in
            if actualPoint == point { throw SimulatedStoreCrash.crash }
        })
    }

    func generation(seed: UInt64) -> Generation {
        let identifier = UUID()
        return Generation(
            id: identifier,
            prompt: "fixture",
            width: 512,
            height: 512,
            steps: 8,
            seed: seed,
            durationSeconds: 0.5,
            imageFileName: ManagedGenerationFileName(
                identifier: identifier, seed: seed).rawValue)
    }

    static func uncheckedGeneration(duration: Double) -> Generation {
        let identifier = UUID()
        return Generation(
            id: identifier,
            prompt: "duration",
            width: 512,
            height: 512,
            steps: 8,
            seed: 1,
            durationSeconds: duration,
            imageFileName: ManagedGenerationFileName(
                identifier: identifier,
                seed: 1).rawValue)
    }

    func writeIndex(_ records: [Generation]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: paths.generationsIndex, options: .atomic)
    }

    func managedImageNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: paths.images.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: paths.images, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { (try? ManagedGenerationFileName(validating: $0)) != nil }
            .sorted()
    }

    func managedSidecarNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: paths.recipes.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: paths.recipes, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { (try? ManagedGenerationRecipeFileName(validating: $0)) != nil }
            .sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func saveFixtureImage(
    in store: GenerationStore,
    seed: UInt64
) async throws -> Generation {
    try await store.save(
        pngData: Data("fixture-\(seed)".utf8),
        prompt: "fixture",
        width: 512,
        height: 512,
        steps: 8,
        seed: seed,
        duration: 0.5)
}

private func expectSimulatedCrash(
    _ operation: @escaping @Sendable () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("The injected crash point was not reached")
    } catch SimulatedStoreCrash.crash {
        // Expected.
    } catch {
        Issue.record("Unexpected error at injected crash point: \(error)")
    }
}
