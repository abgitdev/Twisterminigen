import Darwin
import Foundation
import Testing
@testable import Twisterminigen

@Suite("Clean gallery export")
@MainActor
struct GenerationExportTests {
    @Test("Export preserves verified pixels and attaches AI provenance metadata")
    func verifiedExport() async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        let generation = try await fixture.save()

        let output = try await fixture.store.reviewablePNG(for: generation)
        let bytes = output.data
        let destination = fixture.root.appendingPathComponent("outside.png")
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryImage)
        let publication = try await fixture.store.exportPNG(
            for: generation,
            to: destination,
            receipt: receipt,
            kind: .galleryImage)

        #expect(publication == .publishedDurable(destination))
        #expect(bytes != fixture.png)
        #expect(bytes.starts(with: fixture.png.prefix(8)))
        #expect(String(decoding: bytes, as: UTF8.self).contains("AIGenerated\0true"))
        #expect(String(decoding: bytes, as: UTF8.self).contains(PNGOutputProvenance.disclosure))
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(
            atPath: destination.deletingPathExtension().appendingPathExtension("recipe.json").path))
    }

    @Test("Reviewed derived PNGs preserve source provenance and transformation identity")
    func reviewedDerivedExport() async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        let generation = try await fixture.save()
        let destination = fixture.root.appendingPathComponent("cutout.png")

        let output = try ReviewablePNGFactory.data(
            from: fixture.png,
            sourceGeneration: generation,
            derivation: .foregroundCutout)
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .foregroundCutout)
        _ = try await ValidatedExternalPublisher.publishReviewedPNG(
            output,
            to: destination,
            receipt: receipt,
            kind: .foregroundCutout,
            protectedRoots: [fixture.root.appendingPathComponent("Library")])

        let exported = try Data(contentsOf: destination)
        let text = String(decoding: exported, as: UTF8.self)
        #expect(exported != fixture.png)
        #expect(text.contains("AIGenerated\0true"))
        #expect(text.contains(PNGOutputProvenance.disclosure))
        #expect(text.contains("SourceGenerationIDs\0\(generation.id.uuidString)"))
        #expect(text.contains("Transformation\0\(PNGOutputProvenance.Derivation.foregroundCutout.rawValue)"))
    }

    @Test("A modified managed PNG is never re-baselined during export")
    func tamperingIsRejected() async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        let generation = try await fixture.save()
        let imageURL = try await fixture.store.imageURL(for: generation)
        try Data(fixture.png + [0xFF]).write(to: imageURL, options: .atomic)

        await #expect(throws: GenerationExportError.self) {
            try await fixture.store.pngDataForExport(for: generation)
        }
    }

    @Test("Export cannot overwrite the managed library")
    func managedDestinationIsRejected() async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        let generation = try await fixture.save()
        let managedURL = try await fixture.store.imageURL(for: generation)
        let output = try await fixture.store.reviewablePNG(for: generation)
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryImage)

        await #expect(throws: ExternalPublishError.managedDestination(managedURL)) {
            try await fixture.store.exportPNG(
                for: generation,
                to: managedURL,
                receipt: receipt,
                kind: .galleryImage)
        }
    }

    @Test("Bulk export reserves collision-free clean PNG names")
    func bulkExportAvoidsCollisions() async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.save()
        let second = try await fixture.save()
        let destination = fixture.root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("Twisterminigen-7.png")
        let existingBytes = Data("keep-me".utf8)
        try existingBytes.write(to: existing)

        let outputs = try await [first, second].asyncReviewablePNGs(in: fixture.store)
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: outputs,
            kind: .galleryBulk)
        let result = try await fixture.store.exportPNGs(
            for: [first, second],
            toDirectory: destination,
            receipt: receipt)

        #expect(result.failures.isEmpty)
        #expect(result.exported.map(\.lastPathComponent) == [
            "Twisterminigen-7-2.png", "Twisterminigen-7-3.png",
        ])
        #expect(try Data(contentsOf: existing) == existingBytes)
        for url in result.exported {
            let exported = try Data(contentsOf: url)
            #expect(exported != fixture.png)
            #expect(String(decoding: exported, as: UTF8.self).contains("AIGenerated\0true"))
        }
        let exportedNames = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(!exportedNames.contains { $0.hasSuffix(".recipe.json") })
    }

    @Test("Bulk review fails closed before publishing when any managed source is tampered")
    func bulkExportFailsClosedForTampering() async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        let valid = try await fixture.save()
        let tampered = try await fixture.save()
        let tamperedURL = try await fixture.store.imageURL(for: tampered)
        try Data(fixture.png + [0xFF]).write(to: tamperedURL, options: .atomic)
        let destination = fixture.root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await #expect(throws: GenerationExportError.self) {
            _ = try await fixture.store.reviewablePNG(for: valid)
            _ = try await fixture.store.reviewablePNG(for: tampered)
        }
        #expect(try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil).isEmpty)
    }

    @Test("Bulk export preserves published URLs and marks every unattempted item after a race")
    func bulkExportReportsPartialPublication() async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        let generations = try await [fixture.save(), fixture.save(), fixture.save()]
        let destination = fixture.root.appendingPathComponent("Partial", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outputs = try await generations.asyncReviewablePNGs(in: fixture.store)
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: outputs,
            kind: .galleryBulk)
        let racedBytes = Data("competing file".utf8)

        let result = try await fixture.store.exportPNGsForTesting(
            for: generations,
            toDirectory: destination,
            receipt: receipt,
            beforeEachPublication: { index, url in
                if index == 1 {
                    try racedBytes.write(to: url, options: .withoutOverwriting)
                }
            })

        #expect(result.exported.count == 1)
        #expect(result.failures.map(\.generationID) == [
            generations[1].id, generations[2].id,
        ])
        #expect(result.failures.map(\.destination.lastPathComponent) == [
            "Twisterminigen-7-2.png", "Twisterminigen-7-3.png",
        ])
        #expect(result.failures[0].message.contains("already exists"))
        #expect(result.failures[1].message.contains("earlier batch destination failed"))
        #expect(try Data(contentsOf: result.exported[0]) == outputs[0].data)
        #expect(try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil).count == 2)
    }

    @Test("Bulk export keeps visible durability warnings distinct from failed and unattempted items")
    func bulkExportMapsEveryPublicationState() async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        let generations = try await [fixture.save(), fixture.save(), fixture.save()]
        let destination = fixture.root.appendingPathComponent("States", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outputs = try await generations.asyncReviewablePNGs(in: fixture.store)
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: outputs,
            kind: .galleryBulk)

        let result = try await fixture.store.exportPNGsForTesting(
            for: generations,
            toDirectory: destination,
            receipt: receipt,
            beforeEachPublication: { _, _ in },
            faultForPublication: { index, _ in
                index == 0 ? .directorySyncFailure(EIO) : .exclusiveRenameUnsupported
            })

        #expect(result.items.count == 3)
        #expect(result.items[0].state == .publishedDurabilityWarning(code: EIO))
        #expect(result.items[1].state == .failedBeforeVisibility(.writeFailed(ENOTSUP)))
        #expect(result.items[2].state == .unattemptedDueToEarlierFailure)
        #expect(result.exported == [result.items[0].destination])
        #expect(result.durabilityWarnings == [result.items[0]])
        #expect(result.failures.map(\.stateUnknown) == [false, false])
        #expect(try Data(contentsOf: result.items[0].destination) == outputs[0].data)
        #expect(!FileManager.default.fileExists(atPath: result.items[1].destination.path))
        #expect(!FileManager.default.fileExists(atPath: result.items[2].destination.path))
    }
}

private extension Array where Element == Generation {
    func asyncReviewablePNGs(in store: GenerationStore) async throws -> [ReviewablePNG] {
        var outputs: [ReviewablePNG] = []
        for generation in self {
            outputs.append(try await store.reviewablePNG(for: generation))
        }
        return outputs
    }
}

private final class ExportFixture: @unchecked Sendable {
    let root: URL
    let store: GenerationStore
    let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenExportTests-\(UUID().uuidString)", isDirectory: true)
        store = GenerationStore(paths: LibraryPaths(root: root.appendingPathComponent("Library")))
    }

    func save() async throws -> Generation {
        let catalog = ModelCatalog(root: root.appendingPathComponent("Models"))
        let recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "private prompt",
            width: 512,
            height: 512,
            steps: 8,
            seed: .fixed(7),
            catalog: catalog)
        return try await store.save(pngData: png, recipe: recipe, duration: 1)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
