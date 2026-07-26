import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Twisterminigen

@Suite("Stage 5 workflows")
struct Stage5WorkflowTests {
    @Test("Typography QA comparison is punctuation tolerant and typo sensitive")
    func typographyComparison() {
        #expect(TypographyQAService.isExact(
            expected: "OPEN LATE!",
            recognized: "Poster — open late"))
        #expect(TypographyQAService.similarity(
            expected: "TWISTER",
            recognized: "TW1STER") > 0.8)
        #expect(TypographyQAService.similarity(
            expected: "TWISTER",
            recognized: "CYCLONE") < 0.4)

        let forged = TypographyQAResult(
            expectedText: "TWISTER",
            recognizedText: "CYCLONE",
            similarity: 1,
            exactMatch: false)
        #expect(throws: TypographyQAError.invalidResult) {
            try forged.validate(expectedRecipeText: "TWISTER")
        }
    }

    @Test("Vision OCR evaluates a simple saved Lettering image")
    func typographyVisionPath() throws {
        let png = try letteringPNG("OPEN DAY")
        let result = try TypographyQAService.evaluate(
            pngData: png,
            expectedText: "OPEN DAY")
        #expect(result.similarity >= 0.75)
        #expect(!result.recognizedText.isEmpty)
    }

    @Test("Lettering OCR failure is explicit instead of producing a missing QA record")
    func typographyVisionFailureIsExplicit() {
        #expect(throws: TypographyQAError.unreadableImage) {
            try TypographyQAService.evaluate(
                pngData: Data("not a PNG".utf8),
                expectedText: "TWISTER")
        }
    }

    @Test("Queue metadata carries the full recipe, provenance, and stable digest")
    func queueMetadataRoundTrip() throws {
        let recipe = GenerationRecipe.turbo(
            prompt: "one explorer",
            model: QueueJob.legacyModelReference,
            seed: .fixed(9))
        let job = QueueJob(
            recipe: recipe,
            provenance: .batch(
                groupID: UUID(uuidString: "00000000-0000-0000-0000-000000005001")!,
                itemIndex: 0,
                itemCount: 3))
        let document = try QueueRecipeMetadataDocument(
            job: job,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try document.validate()
        #expect(document.recipe == job.recipe)
        #expect(document.provenance == job.provenance)
        let recipeSHA256 = try QueueRecipeMetadataService.recipeSHA256(job.recipe)
        #expect(document.recipeSHA256 == recipeSHA256)
        #expect(try QueueRecipeMetadataService.encoded(document).count > 1_000)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-metadata-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try QueueRecipeMetadataService.write(document, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(throws: QueueRecipeMetadataError.self) {
            _ = try QueueRecipeMetadataService.write(document, to: destination)
        }
    }

    @Test("Official Krea style catalog is pinned and unambiguous")
    func officialKreaCatalogPins() {
        let styles = OfficialKreaStyleLoRACatalog.styles
        #expect(styles.count == 9)
        #expect(Set(styles.map(\.repository)).count == styles.count)
        #expect(Set(styles.map(\.sha256)).count == styles.count)
        #expect(styles.allSatisfy { $0.repository.hasPrefix("krea/Krea-2-LoRA-") })
        #expect(styles.allSatisfy { $0.revision.count == 40 && $0.sha256.count == 64 })
        #expect(styles.allSatisfy { $0.byteCount == 469_291_992 })
        #expect(styles.allSatisfy { !$0.trigger.isEmpty && $0.origin.kind == .officialKreaStyle })
    }

    @Test("Managed weight import checks full payload capacity before copying")
    func managedWeightImportPreflightsCapacity() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-import-capacity-\(UUID().uuidString)", isDirectory: true)
        let source = container.appendingPathComponent("source", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        do {
            _ = try ModelWeightsTransfer.importRoot(
                source,
                to: destination,
                capacityLookup: { _ in 0 },
                diskSafetyMarginBytes: 0)
            Issue.record("Expected an insufficient-space error")
        } catch ModelWeightsTransferError.insufficientSpace(let required, let available) {
            #expect(required > 17_000_000_000)
            #expect(available == 0)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Read-only model catalogs never mutate or delete linked files")
    func linkedModelStoreIsReadOnly() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("linked-model-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("external", isDirectory: true)
        let verification = container.appendingPathComponent("app-owned-verification")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data("pinned".utf8)
        let fileURL = root.appendingPathComponent("weights.safetensors")
        try payload.write(to: fileURL)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let file = ModelFile(
            remotePath: "weights.safetensors",
            localURL: fileURL,
            isMain: true,
            expectedBytes: Int64(payload.count),
            sha256: digest)
        let component = ModelComponent(
            id: "test",
            title: "Test",
            subtitle: "Read only",
            icon: "cube",
            repo: "test/repo",
            revision: String(repeating: "a", count: 40),
            files: [file])
        let catalog = ModelCatalog(root: root, manifest: .current, components: [component])
        let store = ModelStore(
            catalog: catalog,
            readOnly: true,
            downloader: { _, _ in Issue.record("Downloader must not run") },
            linkedStampDirectory: verification)

        let snapshot = await store.snapshot()
        #expect(snapshot.isReadOnly)
        #expect(snapshot.components.first?.state == .downloaded)
        let deletedBytes = await store.delete(id: component.id)
        #expect(deletedBytes == 0)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: file.verificationURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path)
                == ["weights.safetensors"])
        let cachedVerifier = ModelVerifier(
            manifest: catalog.manifest,
            stampDirectory: verification)
        #expect(cachedVerifier.isVerifiedFromCache(file))
        do {
            try await store.download(id: component.id) { _, _ in }
            Issue.record("Expected a read-only catalog error")
        } catch ModelStoreError.readOnlyCatalog {
            // Expected.
        }
    }

    @Test("Real Stage 5 model Link and managed Import preserve the source checkpoint")
    func realModelLinkAndManagedImport() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["TWISTER_STAGE5_WEIGHTS_SOURCE"],
              !sourcePath.isEmpty else { return }

        let source = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL
        let linked = try ModelWeightsTransfer.validateLinkedRoot(source)
        #expect(linked.defaultFiles.count == 8)

        guard let destinationPath = environment["TWISTER_STAGE5_WEIGHTS_IMPORT_DEST"],
              !destinationPath.isEmpty else {
            print("STAGE5 MODEL LINK PASS source=\(source.path) files=\(linked.defaultFiles.count)")
            return
        }
        let destination = URL(
            fileURLWithPath: destinationPath,
            isDirectory: true
        ).standardizedFileURL
        let before = try linked.defaultFiles.map { file in
            let values = try file.localURL.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ])
            return (file.localURL.path, values.fileSize, values.contentModificationDate)
        }

        let imported = try ModelWeightsTransfer.importRoot(
            source,
            to: destination,
            diskSafetyMarginBytes: 0)
        _ = try ModelWeightsTransfer.validateLinkedRoot(destination)

        #expect(imported.defaultFiles.count == linked.defaultFiles.count)
        for (sourceFile, importedFile) in zip(linked.defaultFiles, imported.defaultFiles) {
            #expect(sourceFile.expectedBytes == importedFile.expectedBytes)
            #expect(sourceFile.sha256 == importedFile.sha256)
            #expect(try ModelVerifier.sha256Hex(of: importedFile.localURL) == importedFile.sha256)
        }
        let after = try linked.defaultFiles.map { file in
            let values = try file.localURL.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ])
            return (file.localURL.path, values.fileSize, values.contentModificationDate)
        }
        let sourceIsUnchanged = before.elementsEqual(after, by: { lhs, rhs in
            lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2
        })
        #expect(sourceIsUnchanged)
        print("STAGE5 MODEL LINK+IMPORT PASS source=\(source.path) destination=\(destination.path) files=\(imported.defaultFiles.count)")
    }

    @Test("Real official Krea style uses the pinned downloader and managed LoRA import")
    func realOfficialKreaStyleManagedImport() async throws {
        guard ProcessInfo.processInfo.environment["TWISTER_STAGE5_OFFICIAL_LORA_REAL"] == "1"
        else { return }

        let style = try #require(OfficialKreaStyleLoRACatalog.styles.first {
            $0.slug == "neondrip"
        })
        let downloaded = try await OfficialKreaStyleLoRADownload.download(style)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        #expect(try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize
                == Int(style.byteCount))
        #expect(try ModelVerifier.sha256Hex(of: downloaded) == style.sha256)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "twister-stage5-official-lora-\(UUID().uuidString.lowercased())",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LoRAStore(root: root)
        let snapshot = try await store.importAdapter(
            from: downloaded,
            displayName: "Krea · \(style.title)",
            triggers: [style.trigger],
            origin: style.origin,
            expectedSHA256: style.sha256)
        let asset = try #require(snapshot.assets.first)
        let managed = root.appendingPathComponent(asset.managedFilename)

        #expect(snapshot.assets.count == 1)
        #expect(asset.name == "Krea · Neon Drip")
        #expect(asset.sha256 == style.sha256)
        #expect(asset.byteCount == style.byteCount)
        #expect(asset.origin.kind == .officialKreaStyle)
        #expect(asset.origin.repository == style.repository)
        #expect(asset.origin.revision == style.revision)
        #expect(asset.origin.weightFilename == style.weightFilename)
        #expect(asset.triggers == [style.trigger])
        #expect(asset.matchedTargets == asset.totalTargets)
        #expect(asset.matchedKeys == asset.totalKeys)
        #expect(try ModelVerifier.sha256Hex(of: managed) == style.sha256)
        #expect(snapshot.active == [.init(assetID: asset.id, scale: 1)])
        print("STAGE5 OFFICIAL LORA IMPORT PASS sha256=\(asset.sha256) targets=\(asset.matchedTargets)/\(asset.totalTargets) keys=\(asset.matchedKeys)/\(asset.totalKeys) origin=\(asset.origin.kind.rawValue)")
    }

    @Test("Real Lettering output is evaluated by local Vision OCR")
    func realLetteringVisionQA() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TWISTER_STAGE5_LETTERING_PATH"],
              let expected = environment["TWISTER_STAGE5_LETTERING_EXPECTED"],
              !path.isEmpty,
              !expected.isEmpty else { return }
        let png = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let result = try TypographyQAService.evaluate(pngData: png, expectedText: expected)
        try result.validate(expectedRecipeText: expected)
        #expect(!result.recognizedText.isEmpty)
        let minimum = environment["TWISTER_STAGE5_LETTERING_MIN_SIMILARITY"]
            .flatMap(Double.init) ?? 0.75
        #expect(result.similarity >= minimum)

        if let outputPath = environment["TWISTER_STAGE5_LETTERING_RESULT_OUT"],
           !outputPath.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(result).write(
                to: URL(fileURLWithPath: outputPath),
                options: .atomic)
        }
        print("STAGE5 LETTERING OCR PASS expected=\(result.expectedText.debugDescription) recognized=\(result.recognizedText.debugDescription) similarity=\(result.similarity) exact=\(result.exactMatch)")
    }

    @Test("Real immutable Queue recipe exports complete metadata")
    func realImmutableQueueRecipeExport() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["TWISTER_STAGE5_QUEUE_METADATA_DIR"],
              !outputPath.isEmpty else { return }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        let recipe = GenerationRecipe.turbo(
            prompt: "a fictional test pilot with a black bob, silver streak, and cobalt flight suit",
            model: QueueJob.legacyModelReference,
            seed: .fixed(505_202))
        let job = QueueJob(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000005211")!,
            recipe: recipe,
            provenance: .batch(
                groupID: UUID(uuidString: "00000000-0000-0000-0000-000000005210")!,
                itemIndex: 0,
                itemCount: 1))
        let exportedAt = Date(timeIntervalSince1970: 1_784_742_400)

        let document = try QueueRecipeMetadataDocument(job: job, exportedAt: exportedAt)
        try document.validate()
        let destination = output.appendingPathComponent("recipe.json")
        _ = try QueueRecipeMetadataService.write(document, to: destination)
        #expect(throws: QueueRecipeMetadataError.destinationExists(destination)) {
            try QueueRecipeMetadataService.write(document, to: destination)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            QueueRecipeMetadataDocument.self,
            from: Data(contentsOf: destination))
        try decoded.validate()
        #expect(decoded.recipe == job.recipe)
        #expect(decoded.provenance == job.provenance)
        print("STAGE5 IMMUTABLE QUEUE EXPORT PASS documents=1 directory=\(output.path)")
    }

    private func letteringPNG(_ text: String) throws -> Data {
        let width = 900
        let height = 300
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (text as NSString).draw(
            in: NSRect(x: 20, y: 80, width: width - 40, height: 150),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 96, weight: .bold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: style,
            ])
        image.unlockFocus()
        return try pngData(image)
    }

    private func pngData(_ image: NSImage) throws -> Data {
        let tiff = try #require(image.tiffRepresentation)
        let representation = try #require(NSBitmapImageRep(data: tiff))
        return try #require(representation.representation(using: .png, properties: [:]))
    }

}
