import Foundation
import Testing
@testable import Twisterminigen

@Suite("Queue Lab")
struct QueueLabTests {
    @Test("Seed previews are fixed, sequential, and deterministic")
    func deterministicSeedGrid() throws {
        let source = queueLabRecipe(seed: .random)
        let configuration = QueueLab.Configuration(seedStart: 40, seedCount: 4)

        let first = try QueueLab.preview(
            for: source,
            configuration: configuration)
        let second = try QueueLab.preview(
            for: source,
            configuration: configuration)

        #expect(first == second)
        #expect(first.jobCount == 4)
        #expect(try QueueLab.jobCount(
            for: source,
            configuration: configuration) == first.jobCount)
        #expect(first.seeds == [40, 41, 42, 43])
        #expect(first.entries.map(\.recipe.sampler.seed) == [
            .fixed(40), .fixed(41), .fixed(42), .fixed(43),
        ])
        #expect(first.entries.allSatisfy {
            $0.recipe.prompts == source.prompts
                && $0.recipe.canvas == source.canvas
                && $0.recipe.model == source.model
        })
    }

    @Test("Sweeps use stable seed, Y, X ordering")
    func xAndYSweepOrdering() throws {
        let source = queueLabRecipe(seed: .fixed(900), withInput: true)
        let configuration = QueueLab.Configuration(
            seedStart: 100,
            seedCount: 2,
            xAxis: .init(parameter: .steps, start: 4, end: 8, valueCount: 2),
            yAxis: .init(
                parameter: .imageToImageStrength,
                start: 0.25,
                end: 0.75,
                valueCount: 2))

        let preview = try QueueLab.preview(
            for: source,
            configuration: configuration)

        #expect(preview.jobCount == 8)
        #expect(preview.entries.map(\.seed) == [100, 100, 100, 100, 101, 101, 101, 101])
        #expect(preview.entries.map(\.recipe.sampler.steps) == [4, 8, 4, 8, 4, 8, 4, 8])
        #expect(preview.entries.map(\.recipe.inputImage?.strength) == [
            0.25, 0.25, 0.75, 0.75,
            0.25, 0.25, 0.75, 0.75,
        ])
        #expect(preview.entries.map(\.xIndex) == [0, 1, 0, 1, 0, 1, 0, 1])
        #expect(preview.entries.map(\.yIndex) == [0, 0, 1, 1, 0, 0, 1, 1])
    }

    @Test("First LoRA sweep changes no other adapter")
    func firstLoRASweep() throws {
        var source = queueLabRecipe(seed: .fixed(7))
        source.loras = [
            .init(
                managedID: queueLabUUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                sha256: queueLabHash("a"),
                scale: 0.8),
            .init(
                managedID: queueLabUUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
                sha256: queueLabHash("b"),
                scale: 1.1),
        ]
        let configuration = QueueLab.Configuration(
            seedStart: 7,
            xAxis: .init(
                parameter: .firstLoRAScale,
                start: 0.5,
                end: 1.5,
                valueCount: 3))

        let preview = try QueueLab.preview(
            for: source,
            configuration: configuration)

        #expect(preview.entries.map { $0.recipe.loras[0].scale } == [0.5, 1, 1.5])
        #expect(preview.entries.allSatisfy { $0.recipe.loras[1] == source.loras[1] })
    }

    @Test("Recipe assets gate the available sweep parameters")
    func unavailableSweepParameters() throws {
        let textToImage = queueLabRecipe(seed: .fixed(1))
        #expect(QueueLab.availableParameters(for: textToImage) == [
            .promptVariants, .canvasSize, .steps, .guidance,
        ])
        let configuration = QueueLab.Configuration(
            seedStart: 1,
            xAxis: .init(
                parameter: .imageToImageStrength,
                start: 0.2,
                end: 0.8,
                valueCount: 2))

        #expect(throws: QueueLab.ValidationError.unavailableParameter(
            .imageToImageStrength)) {
            try QueueLab.preview(
                for: textToImage,
                configuration: configuration)
        }

        var regional = textToImage
        regional.sampler.guidance = 0
        regional.regions = [.init(
            id: queueLabUUID("dddddddd-dddd-dddd-dddd-dddddddddddd"),
            prompt: "regional subject",
            rect: .init(x: 0, y: 0, width: 0.5, height: 0.5))]
        #expect(!QueueLab.availableParameters(for: regional).contains(.guidance))
        let guidanceSweep = QueueLab.Configuration(
            seedStart: 1,
            xAxis: .init(parameter: .guidance, start: 0, end: 2, valueCount: 2))
        #expect(throws: QueueLab.ValidationError.unavailableParameter(.guidance)) {
            try QueueLab.preview(for: regional, configuration: guidanceSweep)
        }
    }

    @Test("Wildcard prompt variants are safe, bounded, and deterministic")
    func wildcardExpansion() throws {
        let expansion = QueueLab.expandWildcards(
            "A {red|blue} subject in {day|night}")
        #expect(expansion.prompts == [
            "A red subject in day",
            "A red subject in night",
            "A blue subject in day",
            "A blue subject in night",
        ])
        #expect(!expansion.truncated)
        #expect(expansion.totalCombinations == 4)

        let malformed = QueueLab.expandWildcards("portrait {red|blue")
        #expect(malformed.prompts == ["portrait {red|blue"])
        #expect(!malformed.truncated)
        let nested = "a {x{y|z}}"
        #expect(QueueLab.expandWildcards(nested).prompts == [nested])

        let structured = #"{"caption":"keep {red|blue} literal"}"#
        #expect(QueueLab.expandWildcards(structured).prompts == [structured])

        let overflowing = QueueLab.expandWildcards(
            "{a|b|c}{d|e|f}{g|h|i}{j|k|l}")
        #expect(overflowing.prompts.count == QueueLab.maximumJobCount)
        #expect(overflowing.totalCombinations == 81)
        #expect(overflowing.truncated)

        let source = queueLabRecipe(seed: .fixed(1))
        let configuration = QueueLab.Configuration(
            seedStart: 1,
            xAxis: .init(
                parameter: .promptVariants,
                promptTemplate: "{a|b|c}{d|e|f}{g|h|i}{j|k|l}"))
        #expect(throws: QueueLab.ValidationError.jobLimitExceeded(
            actual: 81,
            maximum: QueueLab.maximumJobCount)) {
            try QueueLab.preview(for: source, configuration: configuration)
        }
    }

    @Test("Prompt and canvas axes keep stable seed, Y, X order")
    func promptAndCanvasAxes() throws {
        let source = queueLabRecipe(seed: .fixed(5))
        let square = GenerationRecipe.Canvas(width: 1_024, height: 1_024)
        let portrait = GenerationRecipe.Canvas(width: 832, height: 1_216)
        let configuration = QueueLab.Configuration(
            seedStart: 20,
            seedCount: 2,
            xAxis: .init(
                parameter: .promptVariants,
                promptTemplate: "A {red|blue} subject"),
            yAxis: .init(
                parameter: .canvasSize,
                canvasSizes: [square, portrait]))

        let preview = try QueueLab.preview(for: source, configuration: configuration)

        #expect(preview.jobCount == 8)
        #expect(preview.entries.map(\.seed) == [20, 20, 20, 20, 21, 21, 21, 21])
        #expect(preview.entries.map(\.recipe.prompts.positive) == [
            "A red subject", "A blue subject", "A red subject", "A blue subject",
            "A red subject", "A blue subject", "A red subject", "A blue subject",
        ])
        #expect(preview.entries.map(\.recipe.canvas) == [
            square, square, portrait, portrait,
            square, square, portrait, portrait,
        ])
        #expect(preview.entries.map(\.xIndex) == [0, 1, 0, 1, 0, 1, 0, 1])
        #expect(preview.entries.map(\.yIndex) == [0, 0, 1, 1, 0, 0, 1, 1])
    }

    @Test("Guidance and several Remix strengths are concrete recipe values")
    func guidanceAndRemixStrengths() throws {
        var source = queueLabRecipe(seed: .fixed(8), withInput: true)
        source.sampler.guidance = 2
        let configuration = QueueLab.Configuration(
            seedStart: 8,
            xAxis: .init(
                parameter: .guidance,
                start: 0,
                end: 4,
                valueCount: 3),
            yAxis: .init(
                parameter: .imageToImageStrength,
                start: 0.2,
                end: 0.8,
                valueCount: 3))

        let preview = try QueueLab.preview(for: source, configuration: configuration)
        #expect(preview.jobCount == 9)
        #expect(preview.entries.map(\.recipe.sampler.guidance) == [
            0, 2, 4, 0, 2, 4, 0, 2, 4,
        ])
        #expect(preview.entries.map { $0.recipe.inputImage?.strength } == [
            0.2, 0.2, 0.2, 0.5, 0.5, 0.5, 0.8, 0.8, 0.8,
        ])
    }

    @Test("A selected LoRA sweep changes only that adapter")
    func selectedLoRASweep() throws {
        let firstID = queueLabUUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let secondID = queueLabUUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        var source = queueLabRecipe(seed: .fixed(7))
        source.loras = [
            .init(managedID: firstID, sha256: queueLabHash("a"), scale: 0.8),
            .init(managedID: secondID, sha256: queueLabHash("b"), scale: 1.1),
        ]
        let configuration = QueueLab.Configuration(
            seedStart: 7,
            xAxis: .init(
                parameter: .firstLoRAScale,
                start: 0.5,
                end: 1.5,
                valueCount: 3,
                loRAID: secondID))

        let preview = try QueueLab.preview(for: source, configuration: configuration)
        #expect(preview.entries.allSatisfy { $0.recipe.loras[0].scale == 0.8 })
        #expect(preview.entries.map { $0.recipe.loras[1].scale } == [0.5, 1, 1.5])
        #expect(QueueLab.axisLabel(configuration.xAxis, in: source) == "LoRA 2 scale")
    }

    @Test("Experiment context round-trips and rebuilds the exact original table")
    func experimentContextRoundTrip() throws {
        let source = queueLabRecipe(seed: .random, withInput: true)
        let configuration = QueueLab.Configuration(
            seedStart: 700,
            seedCount: 2,
            xAxis: .init(
                parameter: .promptVariants,
                promptTemplate: "{macro|wide} photograph"),
            yAxis: .init(
                parameter: .imageToImageStrength,
                start: 0.3,
                end: 0.7,
                valueCount: 2))
        let preview = try QueueLab.preview(for: source, configuration: configuration)
        let groupID = queueLabUUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
        let jobs = preview.makeJobs(groupID: groupID, id: queueLabJobID)

        let context = try #require(jobs[0].provenance?.experimentContext)
        #expect(context == preview.context)
        #expect(try context.preview() == preview)
        #expect(try JSONDecoder().decode(
            QueueJob.self,
            from: JSONEncoder().encode(jobs[3])) == jobs[3])
        try jobs[3].provenance?.validate(recipe: jobs[3].recipe)
        var mismatchedRecipe = jobs[3].recipe
        mismatchedRecipe.prompts.positive = "not the experiment cell"
        #expect(throws: GenerationProvenance.ValidationError.inconsistentExperimentRecipe) {
            try jobs[3].provenance?.validate(recipe: mismatchedRecipe)
        }

        let rebuilt = try context.preview().makeJobs(
            groupID: queueLabUUID("ffffffff-ffff-ffff-ffff-ffffffffffff"),
            id: { queueLabJobID($0 + 20) })
        #expect(rebuilt.map(\.recipe) == jobs.map(\.recipe))
        #expect(rebuilt.map { $0.provenance?.experimentContext } == jobs.map {
            $0.provenance?.experimentContext
        })
        #expect(rebuilt.allSatisfy { $0.provenance?.groupID != groupID })
    }

    @Test("Legacy Queue Lab provenance and records decode without experiment context")
    func legacyProvenanceDecoding() throws {
        let provenance = GenerationProvenance.queueLab(
            groupID: queueLabUUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"),
            itemIndex: 0,
            itemCount: 1,
            grid: .init(
                seedIndex: 0,
                seedCount: 1,
                xIndex: 0,
                xCount: 1,
                xLabel: nil,
                yIndex: 0,
                yCount: 1,
                yLabel: nil))
        let job = QueueJob(
            id: queueLabJobID(0),
            recipe: queueLabRecipe(seed: .fixed(1)),
            provenance: provenance)
        let jobData = try JSONEncoder().encode(job)
        #expect(!String(decoding: jobData, as: UTF8.self).contains("experimentContext"))
        let decodedJob = try JSONDecoder().decode(QueueJob.self, from: jobData)
        #expect(decodedJob.provenance?.experimentContext == nil)
        try decodedJob.provenance?.validate()

        let generation = Generation(
            id: queueLabUUID("dddddddd-dddd-dddd-dddd-dddddddddddd"),
            recipe: queueLabRecipe(seed: .fixed(1)),
            durationSeconds: 1,
            imageFileName: "legacy.png",
            provenance: provenance)
        let generationData = try JSONEncoder().encode(generation)
        #expect(!String(decoding: generationData, as: UTF8.self).contains("experimentContext"))
        let decodedGeneration = try JSONDecoder().decode(
            Generation.self,
            from: generationData)
        #expect(decodedGeneration.provenance?.experimentContext == nil)
        #expect(decodedGeneration == generation)

        let withoutAnyProvenance = Generation(
            recipe: queueLabRecipe(seed: .fixed(2)),
            durationSeconds: 1,
            imageFileName: "pre-provenance.png")
        let oldestData = try JSONEncoder().encode(withoutAnyProvenance)
        #expect(try JSONDecoder().decode(
            Generation.self,
            from: oldestData).provenance == nil)
    }

    @Test("The 64 job cap is exact and checked before generation")
    func exactJobCap() throws {
        let source = queueLabRecipe(seed: .fixed(1))
        var configuration = QueueLab.Configuration(
            seedStart: 1,
            seedCount: 8,
            xAxis: .init(parameter: .steps, start: 4, end: 11, valueCount: 8))

        #expect(try QueueLab.jobCount(
            for: source,
            configuration: configuration) == 64)
        #expect(try QueueLab.preview(
            for: source,
            configuration: configuration).jobCount == 64)

        configuration.seedCount = 9
        #expect(throws: QueueLab.ValidationError.jobLimitExceeded(actual: 72, maximum: 64)) {
            try QueueLab.preview(for: source, configuration: configuration)
        }
    }

    @Test("Invalid axes and overflowing seeds fail deterministically")
    func invalidGridInputs() {
        let source = queueLabRecipe(seed: .fixed(1))
        let duplicateAxes = QueueLab.Configuration(
            seedStart: 1,
            xAxis: .init(parameter: .steps, start: 4, end: 8, valueCount: 2),
            yAxis: .init(parameter: .steps, start: 6, end: 10, valueCount: 2))
        #expect(throws: QueueLab.ValidationError.duplicateParameters(.steps)) {
            try QueueLab.jobCount(for: source, configuration: duplicateAxes)
        }

        let overflowingSeeds = QueueLab.Configuration(
            seedStart: UInt64.max,
            seedCount: 2)
        #expect(throws: QueueLab.ValidationError.seedRangeOverflow) {
            try QueueLab.preview(for: source, configuration: overflowingSeeds)
        }

        for steps in [3.0, 13.0] {
            let unsupportedSteps = QueueLab.Configuration(
                seedStart: 1,
                xAxis: .init(
                    parameter: .steps,
                    start: steps,
                    end: steps,
                    valueCount: 1))
            #expect(throws: QueueLab.ValidationError.outOfBounds(
                parameter: .steps,
                value: steps)) {
                try QueueLab.preview(for: source, configuration: unsupportedSteps)
            }
        }

        let remix = queueLabRecipe(seed: .fixed(1), withInput: true)
        let unsafeStrength = QueueLab.Configuration(
            seedStart: 1,
            xAxis: .init(
                parameter: .imageToImageStrength,
                start: 0.01,
                end: 0.01,
                valueCount: 1))
        #expect(throws: QueueLab.ValidationError.outOfBounds(
            parameter: .imageToImageStrength,
            value: 0.01)) {
            try QueueLab.preview(for: remix, configuration: unsafeStrength)
        }
    }

    @Test("Bulk enqueue persists one revision and preserves preview order")
    func bulkEnqueueIsOneDurableMutation() async throws {
        let fixture = try QueueLabStoreFixture()
        defer { fixture.remove() }
        let store = try QueueStore(fileURL: fixture.fileURL)
        let preview = try QueueLab.preview(
            for: queueLabRecipe(seed: .random),
            configuration: .init(seedStart: 50, seedCount: 4))
        let groupID = queueLabUUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
        let jobs = preview.makeJobs(groupID: groupID, id: queueLabJobID)

        let result = try await store.enqueue(jobs)

        #expect(result == jobs)
        #expect(jobs.allSatisfy { $0.provenance?.groupID == groupID })
        #expect(jobs.map { $0.provenance?.itemIndex } == [0, 1, 2, 3])
        #expect(jobs[0].provenance?.queueLabGrid == .init(
            seedIndex: 0,
            seedCount: 4,
            xIndex: 0,
            xCount: 1,
            xLabel: nil,
            yIndex: 0,
            yCount: 1,
            yLabel: nil))
        #expect(await store.snapshot().pending == jobs)
        #expect(try fixture.revision() == 1)
        let reopened = try QueueStore(fileURL: fixture.fileURL)
        #expect(await reopened.snapshot().pending == jobs)
    }

    @Test("Bulk enqueue rejects the complete batch without partial writes")
    func invalidBulkEnqueueIsAtomic() async throws {
        let fixture = try QueueLabStoreFixture()
        defer { fixture.remove() }
        let store = try QueueStore(fileURL: fixture.fileURL)
        let existing = QueueJob(
            id: queueLabJobID(0),
            recipe: queueLabRecipe(seed: .fixed(1)))
        try await store.enqueue(existing)
        let initialData = try Data(contentsOf: fixture.fileURL)

        var invalidRecipe = queueLabRecipe(seed: .fixed(2))
        invalidRecipe.prompts.positive = "   "
        let batch = [
            QueueJob(id: queueLabJobID(1), recipe: queueLabRecipe(seed: .fixed(2))),
            QueueJob(id: queueLabJobID(2), recipe: invalidRecipe),
        ]
        do {
            _ = try await store.enqueue(batch)
            Issue.record("Expected the invalid bulk enqueue to fail")
        } catch let QueueStoreError.invalidJob(id, _) {
            #expect(id == queueLabJobID(2))
        }

        #expect(await store.snapshot().pending == [existing])
        #expect(try Data(contentsOf: fixture.fileURL) == initialData)

        let duplicateBatch = [
            QueueJob(id: queueLabJobID(3), recipe: queueLabRecipe(seed: .fixed(3))),
            QueueJob(id: queueLabJobID(3), recipe: queueLabRecipe(seed: .fixed(4))),
        ]
        await #expect(throws: QueueStoreError.self) {
            try await store.enqueue(duplicateBatch)
        }
        #expect(await store.snapshot().pending == [existing])
        #expect(try Data(contentsOf: fixture.fileURL) == initialData)
    }

    @Test("Bulk enqueue enforces the Queue Lab cap")
    func bulkEnqueueCap() async throws {
        let fixture = try QueueLabStoreFixture()
        defer { fixture.remove() }
        let store = try QueueStore(fileURL: fixture.fileURL)
        let jobs = (0 ... QueueLab.maximumJobCount).map { index in
            QueueJob(
                id: queueLabJobID(index),
                recipe: queueLabRecipe(seed: .fixed(UInt64(index))))
        }

        do {
            _ = try await store.enqueue(jobs)
            Issue.record("Expected the bulk enqueue cap to fail")
        } catch let QueueStoreError.bulkEnqueueLimitExceeded(actual, maximum) {
            #expect(actual == 65)
            #expect(maximum == 64)
        }
        #expect(await store.snapshot().pending.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }
}

private struct QueueLabStoreFixture {
    let root: URL
    let fileURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TwisterminigenQueueLabTests-\(UUID().uuidString)",
            isDirectory: true)
        fileURL = root.appendingPathComponent("queue.json")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
    }

    func revision() throws -> UInt64 {
        struct Header: Decodable { let revision: UInt64 }
        return try JSONDecoder().decode(
            Header.self,
            from: Data(contentsOf: fileURL)).revision
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func queueLabRecipe(
    seed: GenerationRecipe.Seed,
    withInput: Bool = false
) -> GenerationRecipe {
    var recipe = GenerationRecipe.turbo(
        prompt: "Queue Lab source",
        negativePrompt: "artifacts",
        model: .init(
            modelID: "queue-lab-model",
            variantID: "queue-lab-variant",
            manifestHash: queueLabHash("f")),
        seed: seed)
    recipe.canvas = .init(width: 640, height: 512)
    if withInput {
        recipe.inputImage = .init(
            managedID: queueLabUUID("cccccccc-cccc-cccc-cccc-cccccccccccc"),
            sha256: queueLabHash("c"),
            strength: 0.5,
            resize: .fit)
    }
    return recipe
}

private func queueLabHash(_ digit: String) -> String {
    String(repeating: digit, count: 64)
}

private func queueLabUUID(_ value: String) -> UUID {
    guard let id = UUID(uuidString: value) else {
        preconditionFailure("Invalid Queue Lab UUID fixture: \(value)")
    }
    return id
}

private func queueLabJobID(_ index: Int) -> UUID {
    let suffix = String(format: "%012llx", Int64(index + 1))
    return queueLabUUID("10000000-0000-0000-0000-\(suffix)")
}
