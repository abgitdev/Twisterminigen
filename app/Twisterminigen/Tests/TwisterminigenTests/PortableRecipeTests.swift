import Darwin
import Foundation
import CryptoKit
import Testing
@testable import Twisterminigen

@Suite("Portable Twister recipe")
struct PortableRecipeTests {
    @Test("A complete portable document round-trips without paths or asset payloads")
    func fullRoundTrip() throws {
        let fixture = try fixture()
        let document = PortableRecipeDocument(
            recipe: fixture.recipe,
            loraSnapshot: fixture.loras,
            inputImageSnapshot: fixture.inputs)
        let data = try PortableRecipeService.encode(document)
        let decoded = try PortableRecipeService.decode(data)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(decoded.document == document)
        #expect(!decoded.legacy)
        #expect(document.dependencies.loras[0].displayName == "Paper Grain")
        #expect(document.dependencies.remix?.pixelWidth == 640)
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("managedFilename"))
        #expect(!text.contains("safetensors"))
        #expect(!text.contains("bookmark"))
    }

    @Test("Import reports every missing model, LoRA and Remix dependency")
    func missingDependencyReport() throws {
        let fixture = try fixture()
        let document = PortableRecipeDocument(
            recipe: fixture.recipe,
            loraSnapshot: fixture.loras,
            inputImageSnapshot: fixture.inputs)
        let otherCatalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/other-model-build"))
        var mismatchedRecipe = document
        mismatchedRecipe.recipe.model.manifestHash = hash("f")
        mismatchedRecipe.dependencies.model.reference = mismatchedRecipe.recipe.model

        let report = try PortableRecipeService.inspect(
            mismatchedRecipe,
            catalog: otherCatalog,
            loraSnapshot: .empty,
            inputImageSnapshot: .empty,
            modelWeightsReady: false)

        #expect(!report.canApply)
        #expect(report.issues.count == 3)
        #expect(report.issues.contains {
            if case .modelBuildMissing = $0 { true } else { false }
        })
        #expect(report.issues.contains {
            if case .loraMissing(let id, let name) = $0 {
                id == fixture.loraID && name == "Paper Grain"
            } else { false }
        })
        #expect(report.issues.contains {
            if case .remixMissing(let id) = $0 { id == fixture.inputID } else { false }
        })
    }

    @Test("Hash mismatches are distinct from missing dependencies")
    func dependencyHashMismatch() throws {
        let fixture = try fixture()
        let document = PortableRecipeDocument(
            recipe: fixture.recipe,
            loraSnapshot: fixture.loras,
            inputImageSnapshot: fixture.inputs)
        let wrongLoRA = LoRAAsset(
            id: fixture.loraID,
            name: "Paper Grain",
            managedFilename: "private.safetensors",
            sha256: hash("a"),
            byteCount: 1,
            matchedTargets: 1,
            totalTargets: 1,
            matchedKeys: 1,
            totalKeys: 1,
            tensorBytes: 1,
            importedAt: .distantPast)
        let wrongInput = InputImageAsset(
            id: fixture.inputID,
            managedFilename: "private.png",
            sha256: hash("b"),
            byteCount: 1,
            width: 640,
            height: 480,
            importedAt: .distantPast)
        let report = try PortableRecipeService.inspect(
            document,
            catalog: fixture.catalog,
            loraSnapshot: .init(assets: [wrongLoRA], active: []),
            inputImageSnapshot: .init(assets: [wrongInput]),
            modelWeightsReady: true)

        #expect(report.issues.contains {
            if case .loraHashMismatch(let id, _) = $0 { id == fixture.loraID } else { false }
        })
        #expect(report.issues.contains {
            if case .remixHashMismatch(let id) = $0 { id == fixture.inputID } else { false }
        })
    }

    @Test("A legacy raw GenerationRecipe remains importable")
    func legacyRecipeImport() throws {
        let fixture = try fixture()
        let data = try JSONEncoder().encode(fixture.recipe)
        let decoded = try PortableRecipeService.decode(data)

        #expect(decoded.legacy)
        #expect(decoded.document.recipe == fixture.recipe)
        #expect(decoded.document.dependencies.loras[0].displayName == nil)
    }

    @Test("Unknown envelope fields and inconsistent manifests fail closed")
    func invalidEnvelopeRejected() throws {
        let fixture = try fixture()
        let document = PortableRecipeDocument(recipe: fixture.recipe)
        let encoded = try PortableRecipeService.encode(document)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["downloadURL"] = "https://example.invalid/model"
        let unknown = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: PortableRecipeError.unknownTopLevelFields(["downloadURL"])) {
            _ = try PortableRecipeService.decode(unknown)
        }

        var inconsistent = document
        inconsistent.dependencies.loras.removeAll()
        #expect(throws: PortableRecipeError.inconsistentDependencies("LoRA count")) {
            try inconsistent.validate()
        }
    }

    @Test("Document-open dependency failures stay on the current section and become root alerts")
    func documentOpenMissingDependencies() throws {
        let document = PortableRecipeDocument(recipe: try fixture().recipe)
        let report = PortableRecipeImportReport(
            document: document,
            issues: [.modelWeightsMissing],
            importedLegacyRecipe: false)

        let resolution = PortableRecipeOpenResolution.completed(report)

        #expect(resolution.destination == nil)
        #expect(resolution.notice.kind == .dependenciesMissing)
        #expect(resolution.notice.title == "Recipe dependencies missing")
        #expect(resolution.notice.message.contains("Generate settings were not changed"))
    }

    @Test("Document-open success routes to Generate while parse errors remain modal")
    func documentOpenSuccessAndFailure() throws {
        let document = PortableRecipeDocument(recipe: try fixture().recipe)
        let success = PortableRecipeOpenResolution.completed(.init(
            document: document,
            issues: [],
            importedLegacyRecipe: false))
        let failure = PortableRecipeOpenResolution.failed(errorDescription: "Unsafe file")

        #expect(success.destination == .generate)
        #expect(success.notice.kind == .loaded)
        #expect(success.notice.message.contains("No render was started"))
        #expect(failure.destination == nil)
        #expect(failure.notice.kind == .failed)
        #expect(failure.notice.message == "Unsafe file")
    }

    @Test("File boundary rejects wrong extensions, symlinks, oversized input and overwrite races")
    func secureFileBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PortableRecipeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = PortableRecipeDocument(recipe: try fixture().recipe)
        let destination = root.appendingPathComponent("recipe.twisterrecipe")
        _ = try PortableRecipeService.write(document, to: destination)

        #expect(try permissions(destination) == 0o600)
        #expect(throws: PortableRecipeError.destinationExists(destination)) {
            try PortableRecipeService.write(document, to: destination)
        }
        #expect(throws: PortableRecipeError.wrongExtension(root.appendingPathComponent("recipe.json"))) {
            _ = try PortableRecipeService.read(from: root.appendingPathComponent("recipe.json"))
        }

        let link = root.appendingPathComponent("link.twisterrecipe")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        #expect(throws: PortableRecipeError.self) {
            _ = try PortableRecipeService.read(from: link)
        }

        let oversized = root.appendingPathComponent("oversized.twisterrecipe")
        try Data(repeating: 0x20, count: PortableRecipeService.maximumDocumentBytes + 1)
            .write(to: oversized)
        #expect(throws: PortableRecipeError.fileTooLarge(
            maximumBytes: PortableRecipeService.maximumDocumentBytes)) {
            _ = try PortableRecipeService.read(from: oversized)
        }
    }

    @Test("Export with recipe writes a verified PNG pair and preflights collisions")
    @MainActor
    func exportWithRecipePair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PortableRecipePairTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GenerationStore(paths: LibraryPaths(
            root: root.appendingPathComponent("Library", isDirectory: true)))
        let catalog = ModelCatalog(root: root.appendingPathComponent("Models", isDirectory: true))
        let recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "paired export",
            width: 512,
            height: 512,
            steps: 8,
            seed: .fixed(17),
            catalog: catalog)
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let generation = try await store.save(
            pngData: png,
            recipe: recipe,
            duration: 1)
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let pngURL = exports.appendingPathComponent("paired.png")
        let recipeURL = exports.appendingPathComponent("paired.twisterrecipe")

        let output = try await store.reviewablePNG(for: generation)
        var receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryWithRecipe)
        let pairResult = try await store.exportPNGWithRecipe(
            for: generation,
            pngDestination: pngURL,
            recipeDestination: recipeURL,
            receipt: receipt)
        #expect(pairResult.isComplete)
        #expect(pairResult.pngOutcome == .publishedDurable(pngURL))
        #expect(pairResult.recipeOutcome == .publishedDurable(recipeURL))
        #expect(pairResult.publishedPNG == pngURL)
        #expect(pairResult.publishedRecipe == recipeURL)
        let exportedPNG = try Data(contentsOf: pngURL)
        #expect(exportedPNG != png)
        #expect(String(decoding: exportedPNG, as: UTF8.self).contains("AIGenerated\0true"))
        let exportedDocument = try PortableRecipeService.read(from: recipeURL).0
        #expect(exportedDocument.recipe == recipe)
        #expect(exportedDocument.outputProvenance?.aiGenerated == true)
        #expect(exportedDocument.outputProvenance?.generationID == generation.id)
        #expect(exportedDocument.outputProvenance?.model == recipe.model)
        #expect(exportedDocument.outputProvenance?.generator == "Twisterminigen")
        #expect(exportedDocument.outputProvenance?.generatorVersion == generation.producerAppVersion)
        #expect(exportedDocument.outputProvenance?.generatorBuild == generation.producerAppBuild)
        #expect(exportedDocument.outputProvenance?.disclosure.contains("AI-generated") == true)
        #expect(exportedDocument.outputProvenance?.pngByteCount == Int64(exportedPNG.count))
        #expect(exportedDocument.outputProvenance?.pngSHA256 == SHA256.hash(data: exportedPNG)
            .map { String(format: "%02x", $0) }.joined())

        let collisionPNG = exports.appendingPathComponent("collision.png")
        let collisionRecipe = exports.appendingPathComponent("collision.twisterrecipe")
        let original = Data("keep".utf8)
        try original.write(to: collisionPNG)
        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryWithRecipe)
        await #expect(throws: GenerationExportError.destinationExists(collisionPNG)) {
            _ = try await store.exportPNGWithRecipe(
                for: generation,
                pngDestination: collisionPNG,
                recipeDestination: collisionRecipe,
                receipt: receipt)
        }
        #expect(try Data(contentsOf: collisionPNG) == original)
        #expect(!FileManager.default.fileExists(atPath: collisionRecipe.path))

        let orphanPNG = exports.appendingPathComponent("reviewed-without-recipe.png")
        let racedRecipe = exports.appendingPathComponent("raced.twisterrecipe")
        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryWithRecipe)
        let racedBytes = Data("created by a competing writer".utf8)
        let partial = try await store.exportPNGWithRecipeForTesting(
            for: generation,
            pngDestination: orphanPNG,
            recipeDestination: racedRecipe,
            receipt: receipt,
            beforeRecipePublication: {
                try racedBytes.write(to: racedRecipe, options: .withoutOverwriting)
            })
        #expect(!partial.isComplete)
        #expect(partial.publishedPNG == orphanPNG)
        #expect(partial.publishedRecipe == nil)
        #expect(partial.failure?.destination == racedRecipe)
        #expect(partial.failure?.stateUnknown == false)
        #expect(partial.recipeOutcome == .failedBeforeVisibility(
            racedRecipe,
            error: .destinationExists(racedRecipe)))
        #expect(FileManager.default.fileExists(atPath: orphanPNG.path))
        #expect(try Data(contentsOf: racedRecipe) == racedBytes)

        let pngWarningURL = exports.appendingPathComponent("png-warning.png")
        let pngWarningRecipeURL = exports.appendingPathComponent("png-warning.twisterrecipe")
        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryWithRecipe)
        let pngWarning = try await store.exportPNGWithRecipeForTesting(
            for: generation,
            pngDestination: pngWarningURL,
            recipeDestination: pngWarningRecipeURL,
            receipt: receipt,
            beforeRecipePublication: {},
            pngFault: .directorySyncFailure(EIO))
        #expect(pngWarning.isComplete)
        #expect(pngWarning.pngOutcome == .publishedDurabilityWarning(
            pngWarningURL,
            code: EIO))
        #expect(pngWarning.recipeOutcome == .publishedDurable(pngWarningRecipeURL))
        #expect(pngWarning.durabilityWarnings == [pngWarning.pngOutcome])
        #expect(FileManager.default.fileExists(atPath: pngWarningURL.path))
        #expect(FileManager.default.fileExists(atPath: pngWarningRecipeURL.path))

        let recipeWarningPNGURL = exports.appendingPathComponent("recipe-warning.png")
        let recipeWarningURL = exports.appendingPathComponent("recipe-warning.twisterrecipe")
        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryWithRecipe)
        let recipeWarning = try await store.exportPNGWithRecipeForTesting(
            for: generation,
            pngDestination: recipeWarningPNGURL,
            recipeDestination: recipeWarningURL,
            receipt: receipt,
            beforeRecipePublication: {},
            recipeFault: .directorySyncFailure(ENOSPC))
        #expect(recipeWarning.isComplete)
        #expect(recipeWarning.pngOutcome == .publishedDurable(recipeWarningPNGURL))
        #expect(recipeWarning.recipeOutcome == .publishedDurabilityWarning(
            recipeWarningURL,
            code: ENOSPC))
        #expect(recipeWarning.durabilityWarnings == [recipeWarning.recipeOutcome!])
        #expect(FileManager.default.fileExists(atPath: recipeWarningPNGURL.path))
        #expect(FileManager.default.fileExists(atPath: recipeWarningURL.path))

        let unsupportedPNGURL = exports.appendingPathComponent("unsupported-recipe.png")
        let unsupportedRecipeURL = exports.appendingPathComponent("unsupported-recipe.twisterrecipe")
        receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryWithRecipe)
        let unsupportedRecipe = try await store.exportPNGWithRecipeForTesting(
            for: generation,
            pngDestination: unsupportedPNGURL,
            recipeDestination: unsupportedRecipeURL,
            receipt: receipt,
            beforeRecipePublication: {},
            recipeFault: .exclusiveRenameUnsupported)
        #expect(!unsupportedRecipe.isComplete)
        #expect(unsupportedRecipe.pngOutcome == .publishedDurable(unsupportedPNGURL))
        #expect(unsupportedRecipe.recipeOutcome == .failedBeforeVisibility(
            unsupportedRecipeURL,
            error: .writeFailed(ENOTSUP)))
        #expect(unsupportedRecipe.publishedPNG == unsupportedPNGURL)
        #expect(unsupportedRecipe.publishedRecipe == nil)
        #expect(FileManager.default.fileExists(atPath: unsupportedPNGURL.path))
        #expect(!FileManager.default.fileExists(atPath: unsupportedRecipeURL.path))
        let tombstones = try FileManager.default.contentsOfDirectory(
            at: exports,
            includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix(".twister-private-stage-") }
        #expect(!tombstones.isEmpty)
        #expect(tombstones.allSatisfy {
            ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == 0
        })
    }

    private struct Fixture {
        let catalog: ModelCatalog
        let recipe: GenerationRecipe
        let loras: LoRALibrarySnapshot
        let inputs: InputImageLibrarySnapshot
        let loraID: UUID
        let inputID: UUID
    }

    private func fixture() throws -> Fixture {
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/portable-model"))
        let loraID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let inputID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let sourceID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let loraHash = hash("1")
        let inputHash = hash("2")
        var recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "portable poster",
            width: 1_024,
            height: 768,
            steps: 8,
            seed: .fixed(42),
            catalog: catalog)
        recipe.loras = [.init(managedID: loraID, sha256: loraHash, scale: 0.8)]
        recipe.inputImage = .init(
            managedID: inputID,
            sha256: inputHash,
            strength: 0.55,
            resize: .fill,
            sourceGenerationID: sourceID)
        let lora = LoRAAsset(
            id: loraID,
            name: "Paper Grain",
            managedFilename: "private.safetensors",
            sha256: loraHash,
            byteCount: 1,
            matchedTargets: 1,
            totalTargets: 1,
            matchedKeys: 1,
            totalKeys: 1,
            tensorBytes: 1,
            importedAt: .distantPast)
        let input = InputImageAsset(
            id: inputID,
            managedFilename: "private.png",
            sha256: inputHash,
            byteCount: 1,
            width: 640,
            height: 480,
            importedAt: .distantPast)
        return Fixture(
            catalog: catalog,
            recipe: recipe,
            loras: .init(assets: [lora], active: [.init(assetID: loraID, scale: 0.8)]),
            inputs: .init(assets: [input]),
            loraID: loraID,
            inputID: inputID)
    }

    private func hash(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func permissions(_ url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return UInt16((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0)
    }
}
