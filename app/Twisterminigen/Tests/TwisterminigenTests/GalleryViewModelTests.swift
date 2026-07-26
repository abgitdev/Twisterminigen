import Darwin
import Foundation
import Testing
@testable import Twisterminigen

@Suite("Gallery view model")
@MainActor
struct GalleryViewModelTests {
    @Test("Command toggles and Shift selects a visible range")
    func commandAndShiftSelection() throws {
        let fixture = try GalleryFixture()
        defer { fixture.remove() }
        let viewModel = GalleryViewModel(
            store: GenerationStore(paths: fixture.paths),
            annotations: GalleryAnnotationStore(fileURL: fixture.paths.galleryAnnotations))
        let generations = (0 ..< 5).map { galleryGeneration(index: $0) }

        viewModel.updateSelection(
            of: generations[0], visible: generations, command: true, shift: false)
        viewModel.updateSelection(
            of: generations[2], visible: generations, command: true, shift: false)
        #expect(viewModel.selectedIDs == [generations[0].id, generations[2].id])

        viewModel.updateSelection(
            of: generations[4], visible: generations, command: false, shift: true)
        #expect(viewModel.selectedIDs == [
            generations[2].id, generations[3].id, generations[4].id,
        ])

        viewModel.updateSelection(
            of: generations[0], visible: generations, command: true, shift: true)
        #expect(viewModel.selectedIDs == Set(generations.map(\.id)))
    }

    @Test("Provenance groups are contact sheets in stable item order")
    func provenanceGrouping() throws {
        let fixture = try GalleryFixture()
        defer { fixture.remove() }
        let viewModel = GalleryViewModel(
            store: GenerationStore(paths: fixture.paths),
            annotations: GalleryAnnotationStore(fileURL: fixture.paths.galleryAnnotations))
        let groupID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let first = galleryGeneration(
            index: 1,
            provenance: queueLabProvenance(groupID: groupID, itemIndex: 0, xIndex: 0))
        let second = galleryGeneration(
            index: 2,
            provenance: queueLabProvenance(groupID: groupID, itemIndex: 1, xIndex: 1))
        let leading = galleryGeneration(index: 0)
        let trailing = galleryGeneration(index: 3)

        let groups = viewModel.groups(
            for: [leading, second, first, trailing],
            enabled: true)

        #expect(groups.count == 3)
        #expect(groups[0].generations.map(\.id) == [leading.id])
        #expect(groups[1].id == .provenance(groupID))
        #expect(groups[1].generations.map(\.id) == [first.id, second.id])
        #expect(groups[1].summary == "2 images · 1 seed · 2×1 grid · Steps")
        #expect(groups[2].generations.map(\.id) == [trailing.id])
    }

    @Test("Bulk delete reconciles selection and user annotations")
    func bulkDeleteReconcilesAnnotations() async throws {
        let fixture = try GalleryFixture()
        defer { fixture.remove() }
        let store = GenerationStore(paths: fixture.paths)
        let first = try await store.save(
            pngData: Data("first".utf8), prompt: "first", width: 512, height: 512,
            steps: 4, seed: 20, duration: 0.1)
        let second = try await store.save(
            pngData: Data("second".utf8), prompt: "second", width: 512, height: 512,
            steps: 4, seed: 21, duration: 0.1)
        let annotations = GalleryAnnotationStore(fileURL: fixture.paths.galleryAnnotations)
        let viewModel = GalleryViewModel(store: store, annotations: annotations)
        _ = await viewModel.reloadAndWait()
        _ = await viewModel.toggleFavoriteAndWait(first)
        _ = await viewModel.toggleFavoriteAndWait(second)
        viewModel.selectAll([first, second])

        let result = await viewModel.deleteSelected([first, second])

        #expect(result.requestedCount == 2)
        #expect(result.deletedCount == 2)
        #expect(result.failures.isEmpty)
        #expect(viewModel.generations.isEmpty)
        #expect(viewModel.selectedIDs.isEmpty)
        #expect(try await annotations.favorites().isEmpty)
    }

    @Test("Delete failures stay visible and preserve the durable gallery state")
    func deleteFailureIsVisible() async throws {
        let fixture = try GalleryFixture()
        defer { fixture.remove() }

        let writer = GenerationStore(paths: fixture.paths)
        let generation = try await writer.save(
            pngData: Data("image".utf8),
            prompt: "failure test",
            width: 512,
            height: 512,
            steps: 4,
            seed: 11,
            duration: 0.1)
        let failingStore = GenerationStore(
            paths: fixture.paths,
            failureInjector: { point in
                if point == .deleteAfterJournalWrite { throw GalleryTestFailure.simulated }
            })
        let viewModel = GalleryViewModel(
            store: failingStore,
            annotations: GalleryAnnotationStore(fileURL: fixture.paths.galleryAnnotations))
        _ = await viewModel.reloadAndWait()
        viewModel.selected = generation

        #expect(!(await viewModel.deleteAndWait(generation)))
        #expect(viewModel.errorMessage?.hasPrefix("Delete failed:") == true)
        #expect(viewModel.generations.map(\.id) == [generation.id])
        #expect(viewModel.selected?.id == generation.id)
    }

    @Test("Maintenance uses injected library paths and throwing store mutations")
    func maintenanceUsesStorePaths() async throws {
        let fixture = try GalleryFixture()
        defer { fixture.remove() }

        let imageData = Data("store-relative-image".utf8)
        let store = GenerationStore(paths: fixture.paths)
        let generation = try await store.save(
            pngData: imageData,
            prompt: "path test",
            width: 512,
            height: 512,
            steps: 8,
            seed: 12,
            duration: 0.2)
        try FileManager.default.createDirectory(
            at: fixture.paths.thumbnails, withIntermediateDirectories: true)
        try Data("one".utf8).write(
            to: fixture.paths.thumbnails.appendingPathComponent("one.cache"))
        try Data("second".utf8).write(
            to: fixture.paths.thumbnails.appendingPathComponent("two.cache"))

        let viewModel = GalleryViewModel(
            store: store,
            annotations: GalleryAnnotationStore(fileURL: fixture.paths.galleryAnnotations))
        let loaded = await viewModel.reloadAndWait()
        #expect(loaded.map(\.id) == [generation.id])
        #expect(await viewModel.totalBytes(for: loaded) == Int64(imageData.count))

        let startupReport = await viewModel.consumeStartupRecoveryReport()
        #expect(startupReport != nil)
        #expect(await viewModel.consumeStartupRecoveryReport() == nil)

        let thumbnails = try await viewModel.clearThumbnails()
        #expect(thumbnails.count == 2)
        #expect(thumbnails.bytes == 9)
        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.thumbnails, includingPropertiesForKeys: nil).isEmpty)

        let repair = try await viewModel.repairLibrary()
        #expect(repair.errors.isEmpty)
        #expect(viewModel.generations.map(\.id) == [generation.id])

        let removed = try await viewModel.removeAll()
        #expect(removed.count == 1)
        #expect(removed.bytes == Int64(imageData.count))
        #expect(viewModel.generations.isEmpty)
    }

    @Test("Export with recipe writes the clean pair through the view-model seam")
    func exportWithRecipe() async throws {
        let fixture = try GalleryFixture()
        defer { fixture.remove() }
        let store = GenerationStore(paths: fixture.paths)
        let recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "portable gallery export",
            width: 512,
            height: 512,
            steps: 8,
            seed: .fixed(71),
            catalog: ModelCatalog(root: fixture.container.appendingPathComponent("Models")))
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let generation = try await store.save(
            pngData: png,
            recipe: recipe,
            duration: 0.1)
        let viewModel = GalleryViewModel(
            store: store,
            annotations: GalleryAnnotationStore(fileURL: fixture.paths.galleryAnnotations))
        let pngDestination = fixture.container.appendingPathComponent("portable.png")
        let recipeDestination = fixture.container.appendingPathComponent("portable.twisterrecipe")
        let output = try await store.reviewablePNG(for: generation)
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [output],
            kind: .galleryWithRecipe)

        let maybeResult = await viewModel.exportPNGWithRecipe(
            generation,
            pngDestination: pngDestination,
            recipeDestination: recipeDestination,
            receipt: receipt)
        let result = try #require(maybeResult)
        #expect(result.isComplete)
        #expect(result.publishedPNG == pngDestination)
        #expect(result.publishedRecipe == recipeDestination)
        #expect(viewModel.lastPNGRecipeExportResult == result)
        #expect(viewModel.publicationReport?.items.count == 2)
        #expect(viewModel.publicationReport?.items.allSatisfy(\.state.isConfirmedVisible) == true)
        let exportedPNG = try Data(contentsOf: pngDestination)
        #expect(exportedPNG != png)
        #expect(String(decoding: exportedPNG, as: UTF8.self).contains("AIGenerated\0true"))
        let document = try PortableRecipeService.read(from: recipeDestination).0
        #expect(document.recipe == recipe)
        #expect(document.outputProvenance?.pngByteCount == Int64(exportedPNG.count))
        #expect(viewModel.operationMessage ==
            "Exported a verified clean PNG and portable recipe.")
    }

    @Test("Finder actions reveal the original managed PNG and Images folder without copying")
    func finderActionsRevealManagedSources() async throws {
        let fixture = try GalleryFixture()
        defer { fixture.remove() }
        let store = GenerationStore(paths: fixture.paths)
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let generation = try await store.save(
            pngData: png,
            prompt: "original Finder source",
            width: 512,
            height: 512,
            steps: 8,
            seed: 72,
            duration: 0.1)
        var revealedURLs: [URL] = []
        var openedFolder: URL?
        let viewModel = GalleryViewModel(
            store: store,
            annotations: GalleryAnnotationStore(fileURL: fixture.paths.galleryAnnotations),
            revealFiles: { revealedURLs = $0 },
            openFolder: {
                openedFolder = $0
                return true
            })
        let managed = try await store.imageURL(for: generation)
            .standardizedFileURL
        let bytesBefore = try Data(contentsOf: managed)
        let imageDirectoryBefore = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.images,
            includingPropertiesForKeys: nil)

        #expect(await viewModel.revealInFinderAndWait(generation))
        #expect(await viewModel.revealFolder())

        #expect(revealedURLs == [managed])
        #expect(openedFolder == fixture.paths.images.standardizedFileURL)
        #expect(try Data(contentsOf: managed) == bytesBefore)
        #expect(bytesBefore == png)
        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.images,
            includingPropertiesForKeys: nil) == imageDirectoryBefore)
    }

    @Test("Publication report preserves every simultaneous batch state and destination")
    func publicationReportPreservesAllBatchStates() {
        let destinations = (1 ... 5).map {
            URL(fileURLWithPath: "/Exports/item-\($0).png")
        }
        let generations = (0 ..< 5).map { galleryGeneration(index: $0) }
        let result = BulkGenerationExportResult(items: [
            .init(
                generationID: generations[0].id,
                destination: destinations[0],
                state: .publishedDurable),
            .init(
                generationID: generations[1].id,
                destination: destinations[1],
                state: .publishedDurabilityWarning(code: EIO)),
            .init(
                generationID: generations[2].id,
                destination: destinations[2],
                state: .stateUnknown(.writeFailed(ESTALE))),
            .init(
                generationID: generations[3].id,
                destination: destinations[3],
                state: .failedBeforeVisibility(.writeFailed(ENOTSUP))),
            .init(
                generationID: generations[4].id,
                destination: destinations[4],
                state: .unattemptedDueToEarlierFailure),
        ])

        let report = GalleryPublicationReport.bulk(result)

        #expect(report.items.map(\.destination) == destinations)
        #expect(report.items.map(\.state.headline) == [
            "Published · durable",
            "Published · durability not confirmed",
            "Publication not confirmed",
            "Failed before visibility",
            "Not attempted",
        ])
        #expect(report.summary ==
            "5 destinations: 1 durable, 1 visible with warning, 1 failed before visibility, 1 not confirmed, 1 unattempted.")
        #expect(report.items[2].state.detail.contains("Inspect this destination before retrying"))
    }

    @Test("PNG and recipe report retains a visible warning beside a recipe failure")
    func pngRecipeReportPreservesWarningAndFailure() {
        let png = URL(fileURLWithPath: "/Exports/result.png")
        let recipe = URL(fileURLWithPath: "/Exports/result.twisterrecipe")
        let result = PNGRecipeExportResult(
            pngOutcome: .publishedDurabilityWarning(png, code: EIO),
            recipeOutcome: .failedBeforeVisibility(
                recipe,
                error: .destinationExists(recipe)))

        let report = GalleryPublicationReport.pngAndRecipe(
            result,
            recipeDestination: recipe)

        #expect(report.items.map(\.destination) == [png, recipe])
        #expect(report.items[0].state == .publishedDurabilityWarning(code: EIO))
        #expect(report.items[1].state == .failedBeforeVisibility(
            message: ExternalPublishError.destinationExists(recipe).localizedDescription))
        #expect(report.summary ==
            "2 destinations: 0 durable, 1 visible with warning, 1 failed before visibility, 0 not confirmed, 0 unattempted.")
    }

    @Test("Repair status includes every finding category")
    func repairStatusIsComplete() {
        let generation = Generation(
            prompt: "report",
            width: 1,
            height: 1,
            steps: 1,
            seed: 13,
            durationSeconds: 0,
            imageFileName: ManagedGenerationFileName(identifier: UUID(), seed: 13).rawValue)
        var report = LibraryRepairReport()
        report.recoveredTransactions = 2
        report.orphanedImages = ["orphan.png"]
        report.missingImages = [generation]
        report.unsafeRecords = [generation]
        report.duplicateRecords = [generation]
        report.unsafeImageEntries = ["unsafe.png"]
        report.missingThumbnails = ["missing.png"]
        report.staleThumbnails = ["stale.png"]
        report.unsafeThumbnailEntries = ["unsafe-thumbnail.png"]
        report.quarantinedItems = [LibraryQuarantinedItem(
            originalURL: URL(fileURLWithPath: "/original"),
            quarantineURL: URL(fileURLWithPath: "/quarantine"),
            reason: .orphanedImage)]
        report.indexWasRewritten = true
        report.errors = ["disk error"]

        #expect(report.hasActivity)
        #expect(report.conciseStatus(prefix: "Library repair") ==
            "Library repair: recovered 2; orphaned 1; missing 1; unsafe 2; "
            + "duplicates 1; thumbnails 3; quarantined 1; errors 1; index rewritten.")
    }
}

private func galleryGeneration(
    index: Int,
    provenance: GenerationProvenance? = nil
) -> Generation {
    let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
    let seed = UInt64(index + 1)
    return Generation(
        id: id,
        prompt: "image \(index)",
        width: 512,
        height: 512,
        steps: 4,
        seed: seed,
        createdAt: Date(timeIntervalSince1970: Double(index)),
        durationSeconds: 0.1,
        imageFileName: ManagedGenerationFileName(identifier: id, seed: seed).rawValue,
        provenance: provenance)
}

private func queueLabProvenance(
    groupID: UUID,
    itemIndex: Int,
    xIndex: Int
) -> GenerationProvenance {
    .queueLab(
        groupID: groupID,
        itemIndex: itemIndex,
        itemCount: 2,
        grid: .init(
            seedIndex: 0,
            seedCount: 1,
            xIndex: xIndex,
            xCount: 2,
            xLabel: "Steps",
            yIndex: 0,
            yCount: 1,
            yLabel: nil))
}

private enum GalleryTestFailure: Error {
    case simulated
}

private struct GalleryFixture {
    let container: URL
    let paths: LibraryPaths

    init() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalleryViewModelTests-\(UUID().uuidString)", isDirectory: true)
        self.container = container
        self.paths = LibraryPaths(
            root: container.appendingPathComponent("Library", isDirectory: true),
            thumbnails: container.appendingPathComponent("PreviewCache", isDirectory: true))
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
