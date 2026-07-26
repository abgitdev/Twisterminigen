import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Twisterminigen

@Suite("Preset library store", .serialized)
struct PresetLibraryStoreTests {
    @Test("Personal cards persist complete recipes and restart cleanly")
    func persistsCompleteRecipe() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        let catalog = ModelCatalog(root: fixture.root.appendingPathComponent("Models"))
        var recipe = Self.recipe(catalog: catalog)
        recipe.prompts.negative = "flat lighting"
        recipe.prompts.exactText = "HELLO"
        recipe.loras = [.init(
            managedID: UUID(),
            sha256: String(repeating: "a", count: 64),
            scale: 0.7)]
        recipe.regions = [.init(
            id: UUID(),
            prompt: "small glowing object",
            rect: .init(x0: 0.1, y0: 0.1, x1: 0.4, y1: 0.5))]
        recipe.inputImage = .init(
            managedID: UUID(),
            sha256: String(repeating: "b", count: 64),
            strength: 0.65,
            resize: .fill)

        let store = try PresetLibraryStore(root: fixture.library)
        let saved = try await store.save(
            draft: .init(
                categoryID: "art",
                title: "Full recipe",
                summary: "Preserves every connected setting.",
                recipe: recipe),
            coverData: try fixture.png(width: 18, height: 12))
        #expect(saved.origin == .personal)
        #expect(saved.recipe == recipe)
        #expect(saved.coverFilename?.hasSuffix(".jpg") == true)

        let reopened = try PresetLibraryStore(root: fixture.library)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.cards == [saved])
        let url = try #require(await reopened.coverURL(for: saved))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Corrupt indexes are isolated and personal data recovers empty")
    func corruptIndexRecovery() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.library.appendingPathComponent("presets.json"))

        let store = try PresetLibraryStore(root: fixture.library)
        let snapshot = await store.snapshot()
        #expect(snapshot.cards.isEmpty)
        #expect(snapshot.categories.isEmpty)
        #expect(snapshot.startupWarning != nil)
        let recovered = try FileManager.default.contentsOfDirectory(atPath: fixture.library.path)
        #expect(recovered.contains { $0.hasPrefix("presets.corrupt-") && $0.hasSuffix(".json") })
    }

    @Test("Cover import is bounded and canonical JPEG")
    func coverImportIsBounded() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        let store = try PresetLibraryStore(
            root: fixture.library,
            limits: .init(maximumDimension: 8))
        let saved = try await store.save(
            draft: .init(
                categoryID: "product",
                title: "Small cover",
                summary: "",
                recipe: Self.recipe(catalog: ModelCatalog(root: fixture.root.appendingPathComponent("Models")))),
            coverData: try fixture.png(width: 32, height: 16))
        let cover = try #require(await store.coverURL(for: saved))
        let data = try Data(contentsOf: cover)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try #require(CGImageSourceGetType(source))
        #expect((type as String) == UTType.jpeg.identifier)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyPixelWidth] as? Int ?? .max) <= 8)
        #expect((props?[kCGImagePropertyPixelHeight] as? Int ?? .max) <= 8)
    }

    @Test("Deleting a personal category removes its cards and covers")
    func categoryDeletionRemovesCardsAndCovers() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        let store = try PresetLibraryStore(root: fixture.library)
        let category = try await store.createCategory(title: "Lighting experiments")
        let saved = try await store.save(
            draft: .init(
                categoryID: category.id,
                title: "Private card",
                summary: "",
                recipe: Self.recipe(catalog: ModelCatalog(root: fixture.root.appendingPathComponent("Models")))),
            coverData: try fixture.png(width: 8, height: 8))
        let cover = try #require(await store.coverURL(for: saved))
        _ = try await store.removeCategory(id: category.id)
        #expect(!FileManager.default.fileExists(atPath: cover.path))

        let reopened = try PresetLibraryStore(root: fixture.library)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.categories.isEmpty)
        #expect(snapshot.cards.isEmpty)
    }

    @Test("Editing and deleting a personal card replaces then removes its managed cover")
    func cardEditingAndDeletionArePermanent() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        let catalog = ModelCatalog(root: fixture.root.appendingPathComponent("Models"))
        let store = try PresetLibraryStore(root: fixture.library)
        let first = try await store.save(
            draft: .init(
                categoryID: "art",
                title: "Editable card",
                summary: "First version",
                recipe: Self.recipe(catalog: catalog)),
            coverData: try fixture.png(width: 20, height: 12))
        let firstCover = try #require(await store.coverURL(for: first))

        var changedRecipe = first.recipe
        changedRecipe.prompts.positive = "A changed personal recipe."
        let updated = try await store.save(
            draft: .init(
                id: first.id,
                categoryID: "product",
                title: "Edited card",
                summary: "Second version",
                recipe: changedRecipe),
            coverData: try fixture.png(width: 12, height: 20))
        let secondCover = try #require(await store.coverURL(for: updated))
        #expect(updated.id == first.id)
        #expect(updated.title == "Edited card")
        #expect(updated.categoryID == "product")
        #expect(updated.recipe == changedRecipe)
        #expect(secondCover != firstCover)
        #expect(!FileManager.default.fileExists(atPath: firstCover.path))
        #expect(FileManager.default.fileExists(atPath: secondCover.path))

        _ = try await store.removeCard(id: updated.id)
        #expect(!FileManager.default.fileExists(atPath: secondCover.path))
        let reopened = try PresetLibraryStore(root: fixture.library)
        #expect((await reopened.snapshot()).cards.isEmpty)
    }

    @Test("Deleting a built-in card and section persists local tombstones")
    func builtInDeletionPersists() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        let store = try PresetLibraryStore(root: fixture.library)
        let oneArtID = try #require(BuiltinPresetCatalog.stableIDs(in: "art").sorted().first)

        try await store.removeBuiltinCard(id: oneArtID)
        var reopened = try PresetLibraryStore(root: fixture.library)
        var snapshot = await reopened.snapshot()
        #expect(snapshot.removedBuiltinPresetIDs.contains(oneArtID))
        #expect(snapshot.removedBuiltinCategoryIDs.isEmpty)

        _ = try await reopened.removeCategory(id: "art")
        reopened = try PresetLibraryStore(root: fixture.library)
        snapshot = await reopened.snapshot()
        #expect(snapshot.removedBuiltinCategoryIDs.contains("art"))
        #expect(BuiltinPresetCatalog.stableIDs(in: "art").isSubset(
            of: snapshot.removedBuiltinPresetIDs))

        let replacement = try await reopened.createCategory(title: "Art")
        #expect(replacement.isPersonal)
        #expect(replacement.title == "Art")
    }

    @Test("Deleting a built-in section also deletes personal cards stored inside it")
    func builtInSectionDeletionRemovesPersonalContents() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        let store = try PresetLibraryStore(root: fixture.library)
        let card = try await store.save(
            draft: .init(
                categoryID: "interiors",
                title: "My interior",
                summary: "",
                recipe: Self.recipe(catalog: ModelCatalog(
                    root: fixture.root.appendingPathComponent("Models")))),
            coverData: try fixture.png(width: 16, height: 10))
        let cover = try #require(await store.coverURL(for: card))

        let deletedCards = try await store.removeCategory(id: "interiors")
        #expect(deletedCards.map(\.id) == [card.id])
        #expect(!FileManager.default.fileExists(atPath: cover.path))
        let snapshot = await store.snapshot()
        #expect(snapshot.cards.isEmpty)
        #expect(snapshot.removedBuiltinCategoryIDs.contains("interiors"))
    }

    @Test("Delete everything empties personal data and removes every built-in section")
    func deleteEverythingEmptiesLibrary() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        let store = try PresetLibraryStore(root: fixture.library)
        let category = try await store.createCategory(title: "Only mine")
        let card = try await store.save(
            draft: .init(
                categoryID: category.id,
                title: "Only card",
                summary: "",
                recipe: Self.recipe(catalog: ModelCatalog(
                    root: fixture.root.appendingPathComponent("Models")))),
            coverData: try fixture.png(width: 8, height: 8))
        let cover = try #require(await store.coverURL(for: card))

        try await store.removeEverything()
        #expect(!FileManager.default.fileExists(atPath: cover.path))
        let reopened = try PresetLibraryStore(root: fixture.library)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.cards.isEmpty)
        #expect(snapshot.categories.isEmpty)
        #expect(snapshot.removedBuiltinPresetIDs == BuiltinPresetCatalog.stableIDs)
        #expect(snapshot.removedBuiltinCategoryIDs
            == Set(BuiltinPresetCatalog.categories.map(\.id)))

        let rebuilt = try await reopened.createCategory(title: "Only mine")
        #expect(rebuilt.isPersonal)
    }

    @Test("Favorites and removed built-ins persist without changing schema 1")
    func preferencesPersistAndOldDocumentsRemainReadable() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
        let legacyDocument = Data(#"{"cards":[],"categories":[],"schemaVersion":1}"#.utf8)
        try legacyDocument.write(to: fixture.library.appendingPathComponent("presets.json"))

        let builtInIDs = BuiltinPresetCatalog.stableIDs.sorted()
        let favoriteID = try #require(builtInIDs.first)
        let removedID = try #require(builtInIDs.dropFirst().first)
        let store = try PresetLibraryStore(root: fixture.library)
        var initial = await store.snapshot()
        #expect(initial.favoritePresetIDs.isEmpty)
        #expect(initial.removedBuiltinPresetIDs.isEmpty)
        #expect(initial.removedBuiltinCategoryIDs.isEmpty)

        try await store.setFavorite(id: favoriteID, isFavorite: true)
        try await store.removeBuiltinCard(id: removedID)
        let reopened = try PresetLibraryStore(root: fixture.library)
        initial = await reopened.snapshot()
        #expect(initial.favoritePresetIDs == [favoriteID])
        #expect(initial.removedBuiltinPresetIDs == [removedID])

        #expect(try await reopened.toggleFavorite(id: favoriteID) == false)
        #expect(try await reopened.toggleFavorite(id: favoriteID) == true)

        let persisted = try PresetLibraryStore(root: fixture.library)
        let persistedSnapshot = await persisted.snapshot()
        #expect(persistedSnapshot.favoritePresetIDs == [favoriteID])
        #expect(persistedSnapshot.removedBuiltinPresetIDs == [removedID])
    }

    @Test("Preferences for retired built-ins are ignored without disabling the library")
    func retiredBuiltinPreferencesAreIgnored() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
        let document = Data(#"{"cards":[],"categories":[],"favoritePresetIDs":["builtin.retired"],"hiddenBuiltinPresetIDs":["builtin.retired"],"schemaVersion":1}"#.utf8)
        try document.write(to: fixture.library.appendingPathComponent("presets.json"))

        let store = try PresetLibraryStore(root: fixture.library)
        let snapshot = await store.snapshot()

        #expect(snapshot.cards.isEmpty)
        #expect(snapshot.favoritePresetIDs.isEmpty)
        #expect(snapshot.removedBuiltinPresetIDs.isEmpty)
        #expect(snapshot.removedBuiltinCategoryIDs.isEmpty)
    }

    @Test("Built-in IDs and future cover filenames are stable and unique")
    func builtInIdentityContract() throws {
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/preset-identity-catalog"))
        let cards = BuiltinPresetCatalog.cards(catalog: catalog)
        let ids = cards.map(\.id)
        let filenames = try cards.map { try #require($0.coverFilename) }

        #expect(Set(ids).count == cards.count)
        #expect(Set(ids) == BuiltinPresetCatalog.stableIDs)
        #expect(Set(filenames).count == cards.count)
        #expect(Set(filenames) == BuiltinPresetCatalog.expectedCoverFilenames)
        for card in cards {
            #expect(card.id.hasPrefix("builtin."))
            #expect(card.coverFilename == "\(card.id.dropFirst("builtin.".count)).jpg")
        }
    }

    @Test("Any bundled preset covers satisfy the production asset contract")
    func bundledCoverContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(
            "Sources/Twisterminigen/Resources/PresetCovers",
            isDirectory: true)
        let jpegURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "jpg" }

        // A production bundle is all-or-nothing: every card has one sealed local cover.
        if !jpegURLs.isEmpty {
            #expect(Set(jpegURLs.map(\.lastPathComponent)) == BuiltinPresetCatalog.expectedCoverFilenames)
            let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/preset-cover-catalog"))
            let cards = BuiltinPresetCatalog.cards(catalog: catalog)
            let manifest = try BuiltinPresetCoverContract.validate(
                directory: directory,
                expectedCards: cards)
            #expect(manifest.covers.count == cards.count)
            #expect(manifest.covers.filter {
                $0.crop == BuiltinPresetCoverContract.fullFrameLetterboxPolicy
            }.count == 10)
        }
        for url in jpegURLs {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            #expect((values.fileSize ?? .max) <= BuiltinPresetCatalog.maximumCoverBytes)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let type = try #require(CGImageSourceGetType(source))
            #expect((type as String) == UTType.jpeg.identifier)
            let properties = try #require(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect((properties[kCGImagePropertyPixelWidth] as? Int) == BuiltinPresetCatalog.coverPixelSize)
            #expect((properties[kCGImagePropertyPixelHeight] as? Int) == BuiltinPresetCatalog.coverPixelSize)
        }
    }

    @Test("Bundled preset manifests contain no local Gallery provenance")
    func bundledPresetManifestsArePrivacySafe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(
            "Sources/Twisterminigen/Resources/PresetCovers",
            isDirectory: true)
        let forbiddenKeys = [
            "sourceGenerationID",
            "sourceImageFilename",
            "sourcePNG_SHA256",
        ]

        let coverData = try Data(contentsOf: directory.appendingPathComponent(
            BuiltinPresetCoverContract.manifestFilename))
        let coverRoot = try #require(
            JSONSerialization.jsonObject(with: coverData) as? [String: Any])
        #expect(coverRoot["version"] as? Int == 2)
        let covers = try #require(coverRoot["covers"] as? [[String: Any]])
        #expect(covers.count == BuiltinPresetCatalog.stableIDs.count)
        #expect(covers.allSatisfy { entry in
            forbiddenKeys.allSatisfy { entry[$0] == nil }
        })

        let supplementalData = try Data(contentsOf: directory.appendingPathComponent(
            "supplemental-builtin-presets.json"))
        let supplementalRoot = try #require(
            JSONSerialization.jsonObject(with: supplementalData) as? [String: Any])
        #expect(supplementalRoot["version"] as? Int == 2)
        let presets = try #require(supplementalRoot["presets"] as? [[String: Any]])
        #expect(presets.count == 219)
        #expect(presets.allSatisfy { entry in
            forbiddenKeys.allSatisfy { entry[$0] == nil }
        })
    }

    @Test("Every built-in card is a valid current Turbo recipe")
    func builtinsUseCurrentTurboRecipe() throws {
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/preset-catalog"))
        let cards = BuiltinPresetCatalog.cards(catalog: catalog)
        #expect(BuiltinPresetCatalog.categories.count == 17)
        #expect(cards.count == 243)
        #expect(Set(cards.map(\.categoryID)).count == 17)
        #expect(cards.filter { $0.categoryID == "interiors" }.count == 35)
        #expect(cards.filter { $0.categoryID == "exteriors" }.count == 33)
        #expect(cards.filter { $0.categoryID == "portrait" }.count == 12)
        #expect(cards.filter { $0.categoryID == "selfie" }.count == 14)
        #expect(cards.filter { $0.categoryID == "moments" }.count == 12)
        #expect(cards.filter { $0.categoryID == "industry" }.count == 11)
        #expect(cards.filter { $0.categoryID == "automotive" }.count == 10)
        #expect(cards.filter { $0.categoryID == "fantasy" }.count == 10)
        #expect(cards.filter { $0.categoryID == "sports" }.count == 10)
        #expect(cards.filter { $0.categoryID == "art" }.count == 10)
        for card in cards {
            #expect(card.origin == .builtIn)
            #expect(card.recipe.sampler.seed.fixedValue != nil)
            #expect(card.recipe.sampler.steps == 8)
            #expect(card.recipe.model.checkpointFamily == .turbo)
            #expect(card.recipe.model.quantizationTier == .mixed4And8)
            try GenerationRecipeRuntime.validateConfiguration(for: card.recipe, catalog: catalog)
        }
    }

    @Test("Character Sheet exposes ten wide single-render presets")
    func characterSheetSectionHasWidePresets() throws {
        let category = try #require(BuiltinPresetCatalog.categories.first {
            $0.id == BuiltinPresetCatalog.characterSheetCategoryID
        })
        #expect(category.title == "Character Sheet")
        #expect(category.systemImage == "person.crop.rectangle.stack")
        #expect(category.isPersonal == false)

        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/preset-catalog"))
        let cards = BuiltinPresetCatalog.cards(catalog: catalog)
            .filter { $0.categoryID == category.id }
        #expect(cards.count == 10)
        #expect(Set(cards.map(\.id)) == [
            "builtin.character-sheet-combat-robot",
            "builtin.character-sheet-cyberpunk-hybrid",
            "builtin.character-sheet-female-mercenary",
            "builtin.character-sheet-firefighter",
            "builtin.character-sheet-male-mercenary",
            "builtin.character-sheet-medical-professional",
            "builtin.character-sheet-office-cleaner",
            "builtin.character-sheet-parcel-courier",
            "builtin.character-sheet-police-officer",
            "builtin.character-sheet-zombie",
        ])
        #expect(cards.allSatisfy {
            $0.prefersFullFrameCover
                && $0.recipe.canvas.width == 1_280
                && $0.recipe.canvas.height == 720
                && $0.recipe.sampler.steps == 8
                && BuiltinPresetCoverContract.cropPolicy(for: $0)
                    == BuiltinPresetCoverContract.fullFrameLetterboxPolicy
        })
    }

    @MainActor
    @Test("A missing managed Remix source cannot mutate Generate")
    func failedApplyLeavesGenerateUntouched() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        let modelRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let catalog = ModelCatalog(root: modelRoot)
        let inputStore = try InputImageStore(root: fixture.root.appendingPathComponent("InputImages"))
        let queueStore = try QueueStore(fileURL: fixture.root.appendingPathComponent("queue.json"))
        let generate = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(root: fixture.root.appendingPathComponent("Gallery"))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: MemoryGovernor(snapshot: .init(swapUsedBytes: 0, pressure: .normal)),
            inputImageStore: inputStore,
            queueStore: queueStore,
            weightsRootProvider: { modelRoot })
        generate.prompt = "Do not replace this"
        var recipe = Self.recipe(catalog: catalog)
        recipe.prompts.positive = "This should never enter the form"
        recipe.inputImage = .init(
            managedID: UUID(),
            sha256: String(repeating: "d", count: 64),
            strength: 0.5,
            resize: .fit)

        do {
            try await generate.applyPresetRecipe(recipe)
            Issue.record("Expected missing managed input image")
        } catch let error as InputImageStoreError {
            if case .assetNotFound = error {
                #expect(generate.prompt == "Do not replace this")
                #expect(generate.inputImageReference == nil)
            } else {
                Issue.record("Unexpected input error: \(error)")
            }
        }

        do {
            try await generate.enqueuePresetRecipe(recipe)
            Issue.record("Expected Quick Add to reject the same missing managed input image")
        } catch let error as InputImageStoreError {
            if case .assetNotFound = error {
                #expect(generate.prompt == "Do not replace this")
            } else {
                Issue.record("Unexpected Quick Add input error: \(error)")
            }
        }
        let queueSnapshot = await queueStore.snapshot()
        #expect(queueSnapshot.pending.isEmpty)
        #expect(generate.queue.isEmpty)
    }

    @MainActor
    @Test("Quick add queues the exact preset recipe without mutating Generate")
    func quickAddQueuesExactRecipe() async throws {
        let fixture = try PresetFixture()
        defer { fixture.remove() }
        let queueStore = try QueueStore(fileURL: fixture.root.appendingPathComponent("queue.json"))
        let catalog = ModelCatalog(root: fixture.root.appendingPathComponent("Models"))
        var recipe = Self.recipe(catalog: catalog)
        recipe.prompts.negative = "no flat light"
        recipe.regions = [.init(
            id: UUID(),
            prompt: "blue glass",
            rect: .init(x0: 0.1, y0: 0.2, x1: 0.6, y1: 0.8))]
        let generate = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(root: fixture.root.appendingPathComponent("Gallery"))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: MemoryGovernor(snapshot: .init(swapUsedBytes: 0, pressure: .normal)),
            queueStore: queueStore,
            weightsRootProvider: { fixture.root.appendingPathComponent("Models") })
        generate.prompt = "Keep this draft unchanged"

        try await generate.enqueuePresetRecipe(recipe)

        let snapshot = await queueStore.snapshot()
        #expect(snapshot.pending.count == 1)
        #expect(snapshot.pending.first?.recipe == recipe)
        #expect(generate.queue.first?.recipe == recipe)
        #expect(generate.prompt == "Keep this draft unchanged")
        #expect(generate.runningQueueJob == nil)
    }

    private static func recipe(catalog: ModelCatalog) -> GenerationRecipe {
        GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "A precise test image.",
            width: 512,
            height: 512,
            steps: 8,
            seed: .fixed(42),
            catalog: catalog)
    }
}

private struct PresetFixture {
    let root: URL
    let library: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterPresetTests-\(UUID().uuidString)", isDirectory: true)
        library = root.appendingPathComponent("Presets", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func png(width: Int, height: Int) throws -> Data {
        let bytesPerRow = width * 4
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 1)
        defer { pixels.deallocate() }
        pixels.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerRow * height)
        let context = try #require(CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.55, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PresetLibraryStoreError.coverEncodeFailed
        }
        return data as Data
    }
}
