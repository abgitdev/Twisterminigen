import Darwin
import Foundation
import Testing
@testable import Twisterminigen

@Suite("Validated external publication")
@MainActor
struct ValidatedExternalPublisherTests {
    @Test("Multi-output checklist cannot skip or substitute an exact output")
    func orderedReviewChecklist() throws {
        let first = try makeOutput(seed: 101)
        let second = try makeOutput(seed: 102)
        var checklist = OutputReviewGate.ReviewChecklist(outputs: [first, second])

        #expect(checklist.currentOutput == first)
        #expect(throws: OutputReviewGate.ReceiptError.outputBindingMismatch) {
            try checklist.confirmVisibleOutput(second)
        }
        #expect(checklist.reviewedCount == 0)
        #expect(!checklist.isComplete)
        #expect(OutputReviewGate.receiptForTesting(
            after: checklist,
            outputs: [first, second],
            kind: .galleryBulk) == nil)
        try checklist.confirmVisibleOutput(first)
        #expect(checklist.currentOutput == second)
        #expect(!checklist.isComplete)
        try checklist.confirmVisibleOutput(second)
        #expect(checklist.currentOutput == nil)
        #expect(checklist.isComplete)
        let receipt = try #require(OutputReviewGate.receiptForTesting(
            after: checklist,
            outputs: [first, second],
            kind: .galleryBulk))
        try OutputReviewGate.consume(
            receipt,
            outputs: [first, second],
            kind: .galleryBulk)
    }

    @Test("A digest-bound receipt publishes once and copied values cannot publish twice")
    func singleUseReceipt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeOutput(seed: 1)
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryImage)
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")

        _ = try await ValidatedExternalPublisher.publishReviewedPNG(
            output,
            to: first,
            receipt: receipt,
            kind: .galleryImage)
        await #expect(throws: OutputReviewGate.ReceiptError.invalidOrAlreadyUsed) {
            _ = try await ValidatedExternalPublisher.publishReviewedPNG(
                output,
                to: second,
                receipt: receipt,
                kind: .galleryImage)
        }
        #expect(try Data(contentsOf: first) == output.data)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test("Digest, derivation, kind, and count mismatches fail before any file is visible")
    func exactBindingIsMandatory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeOutput(seed: 2)
        let changed = try makeOutput(seed: 3)

        var receipt = OutputReviewGate.reviewedForTesting(
            outputs: [first],
            kind: .galleryImage)
        await #expect(throws: OutputReviewGate.ReceiptError.outputBindingMismatch) {
            _ = try await ValidatedExternalPublisher.publishReviewedPNG(
                changed,
                to: root.appendingPathComponent("changed.png"),
                receipt: receipt,
                kind: .galleryImage)
        }

        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [first],
            kind: .galleryImage)
        await #expect(throws: OutputReviewGate.ReceiptError.outputBindingMismatch) {
            _ = try await ValidatedExternalPublisher.publishReviewedPNG(
                first,
                to: root.appendingPathComponent("kind.png"),
                receipt: receipt,
                kind: .saveCopy)
        }

        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [first, changed],
            kind: .galleryBulk)
        await #expect(throws: OutputReviewGate.ReceiptError.outputBindingMismatch) {
            _ = try await ValidatedExternalPublisher.publishReviewedPNG(
                first,
                to: root.appendingPathComponent("count.png"),
                receipt: receipt,
                kind: .galleryBulk)
        }
        #expect(try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil).isEmpty)
    }

    @Test("Reviewable PNG accepts only structural provenance chunks with the exact derivation")
    func provenanceStructureAndDerivationAreMandatory() throws {
        let raw = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let generation = Generation(
            prompt: "structural provenance",
            width: 1,
            height: 1,
            steps: 8,
            seed: 31,
            durationSeconds: 1,
            imageFileName: "fixture.png")
        let tagged = try PNGOutputProvenance.embedding(
            in: raw,
            generations: [generation],
            derivation: .foregroundCutout)

        #expect(throws: GenerationExportError.invalidPNGProvenance) {
            _ = try ReviewablePNG(
                provenancePNGData: tagged,
                derivation: .generatedImage)
        }
        var forgedTrailingBytes = raw
        forgedTrailingBytes.append(Data(
            "AIGenerated\0true\(PNGOutputProvenance.disclosure)SourceGenerationIDs\0\(generation.id.uuidString)Transformation\0\(PNGOutputProvenance.Derivation.generatedImage.rawValue)".utf8))
        #expect(throws: GenerationExportError.invalidPNGProvenance) {
            _ = try ReviewablePNG(
                provenancePNGData: forgedTrailingBytes,
                derivation: .generatedImage)
        }
    }

    @Test("Managed, symlinked, wrong-extension, and existing destinations are rejected")
    func destinationPolicy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeOutput(seed: 4)
        let managed = root.appendingPathComponent("Managed", isDirectory: true)
        let external = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        var receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryImage)
        let managedDestination = managed.appendingPathComponent("blocked.png")
        await #expect(throws: ExternalPublishError.managedDestination(managedDestination)) {
            _ = try await ValidatedExternalPublisher.publishReviewedPNG(
                output,
                to: managedDestination,
                receipt: receipt,
                kind: .galleryImage,
                protectedRoots: [managed])
        }

        let managedNested = managed.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: managedNested, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("ManagedAlias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: managed)
        let resolvedThroughIntermediateLink = alias
            .appendingPathComponent("Nested", isDirectory: true)
            .appendingPathComponent("blocked-through-link.png")
        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryImage)
        await #expect(throws: ExternalPublishError.managedDestination(
            resolvedThroughIntermediateLink)) {
            _ = try await ValidatedExternalPublisher.publishReviewedPNG(
                output,
                to: resolvedThroughIntermediateLink,
                receipt: receipt,
                kind: .galleryImage,
                protectedRoots: [managed])
        }

        let existing = external.appendingPathComponent("existing.png")
        let original = Data("do-not-replace".utf8)
        try original.write(to: existing)
        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryImage)
        await #expect(throws: ExternalPublishError.destinationExists(existing)) {
            _ = try await ValidatedExternalPublisher.publishReviewedPNG(
                output,
                to: existing,
                receipt: receipt,
                kind: .galleryImage)
        }
        #expect(try Data(contentsOf: existing) == original)

        let linkedParent = root.appendingPathComponent("LinkedExternal", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: external)
        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryImage)
        await #expect(throws: ExternalPublishError.invalidDestination(
            linkedParent.appendingPathComponent("linked.png"))) {
            _ = try await ValidatedExternalPublisher.publishReviewedPNG(
                output,
                to: linkedParent.appendingPathComponent("linked.png"),
                receipt: receipt,
                kind: .galleryImage)
        }

        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryImage)
        await #expect(throws: ExternalPublishError.wrongExtension(expected: "png")) {
            _ = try await ValidatedExternalPublisher.publishReviewedPNG(
                output,
                to: external.appendingPathComponent("wrong.jpg"),
                receipt: receipt,
                kind: .galleryImage)
        }
    }

    @Test("Successful publication leaves no sibling staging file")
    func stagingIsRemoved() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeOutput(seed: 5)
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .saveCopy)
        let destination = root.appendingPathComponent("safe.png")

        let outcome = try await ValidatedExternalPublisher.publishReviewedPNG(
            output,
            to: destination,
            receipt: receipt,
            kind: .saveCopy)

        #expect(outcome == .publishedDurable(destination))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names == ["safe.png"])
    }

    @Test("Sequential batch failure returns every published URL and consumes the receipt")
    func partialBatchResultIsExplicit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeOutput(seed: 111)
        let second = try makeOutput(seed: 112)
        let firstURL = root.appendingPathComponent("first.png")
        let secondURL = root.appendingPathComponent("second.png")
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [first, second],
            kind: .galleryBulk)
        let racedBytes = Data("competing file".utf8)

        let result = try await ValidatedExternalPublisher.publishReviewedPNGsForTesting(
            [
                .init(output: first, destination: firstURL),
                .init(output: second, destination: secondURL),
            ],
            receipt: receipt,
            kind: .galleryBulk,
            beforeEachPublication: { index, url in
                if index == 1 {
                    try racedBytes.write(to: url, options: .withoutOverwriting)
                }
            })

        #expect(result.published == [firstURL])
        #expect(result.failure == .init(
            destination: secondURL,
            error: .destinationExists(secondURL),
            stateUnknown: false))
        #expect(result.unattempted.isEmpty)
        #expect(try Data(contentsOf: firstURL) == first.data)
        #expect(try Data(contentsOf: secondURL) == racedBytes)

        let retryURL = root.appendingPathComponent("retry.png")
        await #expect(throws: OutputReviewGate.ReceiptError.invalidOrAlreadyUsed) {
            _ = try await ValidatedExternalPublisher.publishReviewedPNG(
                first,
                to: retryURL,
                receipt: receipt,
                kind: .galleryBulk)
        }
        #expect(!FileManager.default.fileExists(atPath: retryURL.path))
    }

    @Test("A directory fsync failure never rolls back a destination that is already visible")
    func directorySyncFailurePreservesVisibleDestination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeOutput(seed: 113)
        let destination = root.appendingPathComponent("visible-warning.png")
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .saveCopy)

        let outcome = try await ValidatedExternalPublisher.publishReviewedPNGForTesting(
            output,
            to: destination,
            receipt: receipt,
            kind: .saveCopy,
            fault: .directorySyncFailure(EIO))

        #expect(outcome == .publishedDurabilityWarning(destination, code: EIO))
        #expect(try Data(contentsOf: destination) == output.data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [
            destination.lastPathComponent,
        ])
    }

    @Test("Unsupported exclusive rename fails before visibility and leaves no staged content")
    func unsupportedRenameHasNoPartialDestination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeOutput(seed: 114)
        let destination = root.appendingPathComponent("unsupported.png")
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .saveCopy)

        let outcome = try await ValidatedExternalPublisher.publishReviewedPNGForTesting(
            output,
            to: destination,
            receipt: receipt,
            kind: .saveCopy,
            fault: .exclusiveRenameUnsupported)

        #expect(outcome == .failedBeforeVisibility(
            destination,
            error: .writeFailed(ENOTSUP)))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let staging = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey])
        #expect(staging.count == 1)
        #expect(staging.allSatisfy {
            $0.lastPathComponent.hasPrefix(".twister-private-stage-")
                && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == 0
        })
    }

    @Test("A swapped staging pathname can never publish unreviewed bytes as success")
    func stagingPathSwapIsStateUnknown() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try makeOutput(seed: 118)
        let replacement = Data("unreviewed replacement".utf8)
        let destination = root.appendingPathComponent("swapped.png")
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .saveCopy)

        let outcome = try await ValidatedExternalPublisher.publishReviewedPNGForTesting(
            output,
            to: destination,
            receipt: receipt,
            kind: .saveCopy,
            fault: .replaceStagingBeforeRename(replacement))

        #expect(outcome == .stateUnknown(destination, error: .writeFailed(ESTALE)))
        #expect(outcome.confirmedVisibleURL == nil)
        #expect(try Data(contentsOf: destination) == replacement)
        let displaced = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix(".twister-test-displaced-") }
        #expect(displaced.count == 1)
        #expect(try displaced[0].resourceValues(forKeys: [.fileSizeKey]).fileSize == 0)
    }

    @Test("A rebound parent pathname can never produce a confirmed destination URL")
    func reboundParentIsStateUnknown() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Publication", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let output = try makeOutput(seed: 119)
        let destination = parent.appendingPathComponent("rebound.png")
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .saveCopy)

        let outcome = try await ValidatedExternalPublisher.publishReviewedPNGForTesting(
            output,
            to: destination,
            receipt: receipt,
            kind: .saveCopy,
            fault: .rebindParentBeforeRename)

        #expect(outcome == .stateUnknown(
            destination,
            error: .invalidDestination(destination)))
        #expect(outcome.confirmedVisibleURL == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let displacedParents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix(".twister-test-displaced-parent-") }
        #expect(displacedParents.count == 1)
        #expect(try Data(contentsOf: displacedParents[0]
            .appendingPathComponent(destination.lastPathComponent)) == output.data)
    }

    @Test("Batch states preserve a visible warning, a previsibility failure, and unattempted URLs")
    func mixedBatchStatesAreExact() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outputs = try [UInt64(115), 116, 117].map { try makeOutput(seed: $0) }
        let destinations = ["first.png", "second.png", "third.png"].map {
            root.appendingPathComponent($0)
        }
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: outputs,
            kind: .galleryBulk)

        let result = try await ValidatedExternalPublisher.publishReviewedPNGsForTesting(
            zip(outputs, destinations).map {
                .init(output: $0.0, destination: $0.1)
            },
            receipt: receipt,
            kind: .galleryBulk,
            beforeEachPublication: { _, _ in },
            faultForPublication: { index, _ in
                index == 0 ? .directorySyncFailure(EIO) : .exclusiveRenameUnsupported
            })

        #expect(result.outcomes == [
            .publishedDurabilityWarning(destinations[0], code: EIO),
            .failedBeforeVisibility(destinations[1], error: .writeFailed(ENOTSUP)),
        ])
        #expect(result.published == [destinations[0]])
        #expect(result.failure == .init(
            destination: destinations[1],
            error: .writeFailed(ENOTSUP),
            stateUnknown: false))
        #expect(result.unattempted == [destinations[2]])
        #expect(try Data(contentsOf: destinations[0]) == outputs[0].data)
        #expect(!FileManager.default.fileExists(atPath: destinations[1].path))
        #expect(!FileManager.default.fileExists(atPath: destinations[2].path))
    }

    @Test("Portable recipe and Queue metadata services share managed-path and no-overwrite policy")
    func documentServicesUseValidatedPublisher() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("Managed", isDirectory: true)
        let external = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let recipe = GenerationRecipe.turbo(
            prompt: "safe document publication",
            model: QueueJob.legacyModelReference,
            seed: .fixed(8))
        let portable = PortableRecipeDocument(recipe: recipe)
        let queue = try QueueRecipeMetadataDocument(job: QueueJob(recipe: recipe))

        let managedRecipe = managed.appendingPathComponent("blocked.twisterrecipe")
        #expect(throws: PortableRecipeError.managedDestination(managedRecipe)) {
            try PortableRecipeService.write(
                portable,
                to: managedRecipe,
                protectedRoots: [managed])
        }
        let managedQueue = managed.appendingPathComponent("blocked.json")
        #expect(throws: QueueRecipeMetadataError.managedDestination(managedQueue)) {
            try QueueRecipeMetadataService.write(
                queue,
                to: managedQueue,
                protectedRoots: [managed])
        }

        let recipeDestination = external.appendingPathComponent("recipe.twisterrecipe")
        let queueDestination = external.appendingPathComponent("queue.json")
        #expect(try PortableRecipeService.write(
            portable,
            to: recipeDestination) == .publishedDurable(recipeDestination))
        #expect(try QueueRecipeMetadataService.write(
            queue,
            to: queueDestination) == .publishedDurable(queueDestination))
        let recipeBytes = try Data(contentsOf: recipeDestination)
        let queueBytes = try Data(contentsOf: queueDestination)
        #expect(throws: PortableRecipeError.destinationExists(recipeDestination)) {
            try PortableRecipeService.write(portable, to: recipeDestination)
        }
        #expect(throws: QueueRecipeMetadataError.destinationExists(queueDestination)) {
            try QueueRecipeMetadataService.write(queue, to: queueDestination)
        }
        #expect(try Data(contentsOf: recipeDestination) == recipeBytes)
        #expect(try Data(contentsOf: queueDestination) == queueBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).sorted() == [
            "queue.json", "recipe.twisterrecipe",
        ])
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ValidatedExternalPublisherTests-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeOutput(
        seed: UInt64,
        derivation: PNGOutputProvenance.Derivation = .generatedImage
    ) throws -> ReviewablePNG {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let generation = Generation(
            prompt: "binding \(seed)",
            width: 512,
            height: 512,
            steps: 8,
            seed: seed,
            durationSeconds: 1,
            imageFileName: "fixture-\(seed).png")
        let tagged = try PNGOutputProvenance.embedding(
            in: png,
            generations: [generation],
            derivation: derivation)
        return try ReviewablePNG(
            provenancePNGData: tagged,
            derivation: derivation)
    }
}
