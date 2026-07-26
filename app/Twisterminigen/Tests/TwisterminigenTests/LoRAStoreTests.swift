import Foundation
import Krea2DiT
import MLX
import Testing
@testable import Twisterminigen

@Suite(.serialized) struct LoRAStoreTests {
    @Test func schemaOneAssetWithoutTriggersDecodesAsEmptyMetadata() throws {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Legacy adapter",
          "managedFilename": "\(id.uuidString.lowercased()).safetensors",
          "sha256": "\(String(repeating: "a", count: 64))",
          "byteCount": 1024,
          "matchedTargets": 1,
          "totalTargets": 1,
          "matchedKeys": 2,
          "totalKeys": 2,
          "tensorBytes": 512,
          "importedAt": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        let asset = try decoder.decode(LoRAAsset.self, from: Data(json.utf8))

        #expect(asset.triggers.isEmpty)
        #expect(!asset.automaticallyInsertTriggers)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let encoded = try #require(JSONSerialization.jsonObject(
            with: encoder.encode(asset)) as? [String: Any])
        #expect(encoded["triggers"] as? [String] == [])
        #expect(encoded["automaticallyInsertTriggers"] as? Bool == false)
    }

    @Test func importPersistsPrivateManagedStackAndResolvesExactRecipe() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstSource = try fixture.makeAdapter(name: "first", value: 1)
        let secondSource = try fixture.makeAdapter(name: "second", value: 2)
        let store = try LoRAStore(root: fixture.library)

        var snapshot = try await store.importAdapter(from: firstSource)
        snapshot = try await store.importAdapter(from: secondSource)
        #expect(snapshot.assets.count == 2)
        #expect(snapshot.active.count == 2)

        let second = try #require(snapshot.assets.first { $0.name == "second" })
        snapshot = try await store.setScale(id: second.id, scale: 0.65)
        snapshot = try await store.moveActive(id: second.id, offset: -1)
        snapshot = try await store.updateTriggers(
            id: second.id,
            triggers: ["neon rain", "wet glass"])
        snapshot = try await store.setAutomaticallyInsertTriggers(id: second.id, enabled: true)
        #expect(snapshot.active.first == .init(assetID: second.id, scale: 0.65))
        #expect(snapshot.assets.first { $0.id == second.id }?.triggers == ["neon rain", "wet glass"])
        #expect(snapshot.assets.first { $0.id == second.id }?.automaticallyInsertTriggers == true)
        await Self.expectStoreError({
            _ = try await store.updateTriggers(
                id: second.id,
                triggers: ["café", "cafe"])
        }) {
            if case .invalidMetadata = $0 { return true }
            return false
        }
        snapshot = try await store.setActive(id: second.id, enabled: false)
        snapshot = try await store.setActive(id: second.id, enabled: true)
        #expect(snapshot.active.last == .init(assetID: second.id, scale: 0.65))

        let references = snapshot.active.map { selection in
            let asset = snapshot.assets.first { $0.id == selection.assetID }!
            return GenerationRecipe.LoRAReference(
                managedID: asset.id,
                sha256: asset.sha256,
                scale: selection.scale)
        }
        let resolved = try await store.resolve(references)
        #expect(resolved.map(\.reference) == references)
        #expect(resolved.allSatisfy { $0.url.deletingLastPathComponent() == fixture.library })
        #expect(resolved.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })

        let rootMode = try Self.permissions(fixture.library)
        let catalogMode = try Self.permissions(fixture.library.appendingPathComponent("catalog.json"))
        #expect(rootMode == 0o700)
        #expect(catalogMode == 0o600)
        for item in resolved { #expect(try Self.permissions(item.url) == 0o600) }

        let reopened = try LoRAStore(root: fixture.library)
        #expect(await reopened.snapshot() == snapshot)
        #expect(try await reopened.resolve(references).map(\.reference) == references)
    }

    @Test func duplicateAndTamperedContentAreRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeAdapter(name: "adapter", value: 1)
        let store = try LoRAStore(root: fixture.library)
        let snapshot = try await store.importAdapter(from: source)
        let asset = try #require(snapshot.assets.first)

        await Self.expectStoreError({
            _ = try await store.importAdapter(from: source)
        }) {
            if case .duplicateContent(let id) = $0 { return id == asset.id }
            return false
        }

        let reference = GenerationRecipe.LoRAReference(
            managedID: asset.id,
            sha256: asset.sha256,
            scale: 1)
        let managed = fixture.library.appendingPathComponent(asset.managedFilename)
        let handle = try FileHandle(forWritingTo: managed)
        try handle.seek(toOffset: 16)
        try handle.write(contentsOf: Data([0xAA]))
        try handle.close()
        await Self.expectStoreError({
            _ = try await store.resolve([reference])
        }) {
            if case .tamperedAsset(let id) = $0 { return id == asset.id }
            return false
        }
    }

    @Test func invalidAndSymlinkImportsLeaveNoManagedOrphans() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let invalid = fixture.sources.appendingPathComponent("invalid.safetensors")
        try MLX.save(arrays: ["unrelated": MLXArray.ones([2, 2])], url: invalid)
        let store = try LoRAStore(root: fixture.library)

        do {
            _ = try await store.importAdapter(from: invalid)
            Issue.record("Expected incompatible adapter rejection")
        } catch let error as Krea2DiTLoRAError {
            if case .noMatchedTargets = error {} else {
                Issue.record("Unexpected loader error: \(error)")
            }
        }
        #expect(await store.snapshot() == .empty)
        #expect(try Self.managedSafeTensorFiles(in: fixture.library).isEmpty)

        let valid = try fixture.makeAdapter(name: "valid", value: 1)
        let link = fixture.sources.appendingPathComponent("link.safetensors")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        await Self.expectStoreError({
            _ = try await store.importAdapter(from: link)
        }) {
            if case .unsafeSource = $0 { return true }
            return false
        }
        #expect(try Self.managedSafeTensorFiles(in: fixture.library).isEmpty)
    }

    @Test func futureCatalogIsReadOnlyAndCompatibleStartupQuarantinesManagedOrphans() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.library,
            withIntermediateDirectories: true)
        let catalog = fixture.library.appendingPathComponent("catalog.json")
        let futureData = Data("{\"schemaVersion\":999,\"sentinel\":\"keep\"}".utf8)
        try futureData.write(to: catalog)
        let orphan = fixture.library.appendingPathComponent(
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.safetensors")
        try Data([1, 2, 3]).write(to: orphan)

        do {
            _ = try LoRAStore(root: fixture.library)
            Issue.record("Expected future catalog rejection")
        } catch let error as LoRAStoreError {
            #expect(error == .unsupportedCatalogVersion(999))
        }
        #expect(try Data(contentsOf: catalog) == futureData)
        #expect(try Data(contentsOf: orphan) == Data([1, 2, 3]))

        try FileManager.default.removeItem(at: catalog)
        _ = try LoRAStore(root: fixture.library)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: fixture.library
            .appendingPathComponent("Orphans", isDirectory: true)
            .appendingPathComponent(orphan.lastPathComponent).path))
    }

    @Test func interruptedRemovalRecoversBeforeOrphanCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeAdapter(name: "recover", value: 1)
        let store = try LoRAStore(root: fixture.library)
        let snapshot = try await store.importAdapter(from: source)
        let asset = try #require(snapshot.assets.first)
        let reference = GenerationRecipe.LoRAReference(
            managedID: asset.id,
            sha256: asset.sha256,
            scale: 1)
        let managed = fixture.library.appendingPathComponent(asset.managedFilename)
        let trash = fixture.library.appendingPathComponent(
            ".trash-\(asset.id.uuidString.lowercased()).safetensors")
        try FileManager.default.moveItem(at: managed, to: trash)

        let recovered = try LoRAStore(root: fixture.library)
        #expect(FileManager.default.fileExists(atPath: managed.path))
        #expect(!FileManager.default.fileExists(atPath: trash.path))
        #expect(try await recovered.resolve([reference]).count == 1)

        try FileManager.default.removeItem(at: managed)
        await Self.expectStoreError({
            _ = try await recovered.resolve([reference])
        }) {
            if case .tamperedAsset(let id) = $0 { return id == asset.id }
            return false
        }
    }

    @Test func duplicateLegacyStackIsRejectedWithoutDecodeTrap() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeAdapter(name: "legacy", value: 1)
        let store = try LoRAStore(root: fixture.library)
        _ = try await store.importAdapter(from: source)
        let catalogURL = fixture.library.appendingPathComponent("catalog.json")
        let data = try Data(contentsOf: catalogURL)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["rememberedScales"] = nil
        var active = try #require(object["active"] as? [[String: Any]])
        active.append(try #require(active.first))
        object["active"] = active
        try JSONSerialization.data(withJSONObject: object).write(to: catalogURL)

        do {
            _ = try LoRAStore(root: fixture.library)
            Issue.record("Expected duplicate active stack rejection")
        } catch let error as LoRAStoreError {
            if case .corruptCatalog = error {} else {
                Issue.record("Unexpected catalog error: \(error)")
            }
        }
    }

    @Test @MainActor
    func viewModelRecipesWeightsAndCoordinatorShareOneOrderedStack() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeAdapter(name: "style", value: 1)
        let coordinator = InferenceCoordinator()
        let store = try LoRAStore(root: fixture.library)
        let lora = LoRAViewModel(store: store, coordinator: coordinator)
        await lora.importFiles([source])
        let reference = try #require(lora.activeReferences.first)
        await lora.updateTriggers(reference.managedID, text: "style token, wet glass")

        let modelRoot = fixture.root.appendingPathComponent("Models", isDirectory: true)
        let catalog = ModelCatalog(root: modelRoot)
        let generate = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: fixture.root.appendingPathComponent("Images", isDirectory: true))),
            coordinator: coordinator,
            memoryGovernor: MemoryGovernor(snapshot: .init(swapUsedBytes: 0, pressure: .normal)),
            loraLibrary: lora,
            weightsRootProvider: { modelRoot })
        generate.prompt = "test"
        let triggerGroup = try #require(generate.activeLoRATriggerGroups.first)
        #expect(triggerGroup.triggers == ["style token", "wet glass"])
        #expect(generate.prompt == "test") // Default-off metadata never mutates the prompt.
        #expect(generate.insertLoRATrigger(
            assetID: reference.managedID,
            trigger: "style token"))
        #expect(generate.prompt == "test, style token")
        #expect(!generate.insertLoRATrigger(
            assetID: reference.managedID,
            trigger: "STYLE TOKEN"))

        lora.configureTriggerInsertionHandler { assetID, triggers in
            for trigger in triggers {
                _ = generate.insertLoRATrigger(assetID: assetID, trigger: trigger)
            }
        }
        #expect(await lora.setAutomaticallyInsertTriggers(reference.managedID, enabled: true))
        await lora.setActive(reference.managedID, enabled: false)
        generate.prompt = "automatic"
        await lora.setActive(reference.managedID, enabled: true)
        #expect(generate.prompt == "automatic, style token, wet glass")
        let recipe = generate.currentRecipe(seed: .fixed(7), catalog: catalog)
        #expect(recipe.loras == [reference])

        let resolved = try await lora.resolve(recipe.loras)
        let weights = GenerateViewModel.makeWeights(catalog: catalog, resolvedLoRAs: resolved)
        #expect(weights.loraAdapters.count == 1)
        #expect(weights.loraAdapters[0].path == resolved[0].url)
        #expect(weights.loraAdapters[0].scale == 1)
        #expect(weights.orderedLoRAIdentity?.contains(reference.sha256) == true)

        var replay = recipe
        replay.loras[0].scale = 0.55
        try generate.applyRecipe(replay)
        #expect(lora.activeReferences.first?.scale == 0.55)
        replay.loras[0].scale = 0.75
        try generate.applyRecipe(replay)
        await lora.waitForPendingStackPersistenceForTesting()
        #expect(await store.snapshot().active.first?.scale == 0.75)

        let lease = try #require(coordinator.begin(.generate))
        let pendingRemoval = Task { await lora.remove(reference.managedID) }
        await Task.yield()
        #expect(lora.assets.count == 1)
        #expect(lora.isRemovalPending(reference.managedID))
        #expect(lora.operationMessage?.contains("will be removed automatically") == true)
        #expect(coordinator.isActive(lease))

        coordinator.finish(lease)
        await pendingRemoval.value
        #expect(lora.assets.isEmpty)
        #expect(lora.active.isEmpty)
        #expect(!lora.isRemovalPending(reference.managedID))
        #expect(lora.operationMessage?.contains("Removed") == true)
        #expect(lora.errorMessage == nil)
    }

    @Test @MainActor
    func importIsRejectedDuringInferenceButCatalogSaveAndPostRunImportRemainSafe() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstSource = try fixture.makeAdapter(name: "first", value: 1)
        let secondSource = try fixture.makeAdapter(name: "second", value: 2)
        let coordinator = InferenceCoordinator()
        let store = try LoRAStore(root: fixture.library)
        let lora = LoRAViewModel(store: store, coordinator: coordinator)

        await lora.importFiles([firstSource])
        let first = try #require(lora.activeReferences.first)
        let inference = try #require(coordinator.begin(.generate))

        lora.setScaleLocally(first.managedID, scale: 0.65)
        await lora.persistScale(first.managedID)
        #expect(await store.snapshot().active.first?.scale == 0.65)
        #expect(coordinator.isActive(inference))

        await lora.importFiles([secondSource])
        #expect(lora.assets.count == 1)
        #expect(lora.errorMessage?.contains("Wait for") == true)

        coordinator.finish(inference)
        await lora.importFiles([secondSource])
        #expect(lora.assets.count == 2)
        #expect(lora.errorMessage == nil)
    }

    private static func expectStoreError(
        _ body: () async throws -> Void,
        matches: (LoRAStoreError) -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            try await body()
            Issue.record("Expected LoRAStoreError", sourceLocation: sourceLocation)
        } catch let error as LoRAStoreError {
            #expect(matches(error), "Unexpected error: \(error)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error type: \(error)", sourceLocation: sourceLocation)
        }
    }

    private static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func managedSafeTensorFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "safetensors" }
    }
}

private struct Fixture {
    let root: URL
    let library: URL
    let sources: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Twisterminigen-LoRAStore-\(UUID().uuidString)", isDirectory: true)
        library = root.appendingPathComponent("Library", isDirectory: true)
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    func makeAdapter(name: String, value: Float) throws -> URL {
        let url = sources.appendingPathComponent("\(name).safetensors")
        try MLXRuntimeSafety.withExclusiveCPUOperation {
            let down = MLXArray.ones([2, 64]) * value
            let up = MLXArray.ones([6_144, 2]) * value
            try MLX.save(arrays: [
                "first.lora_A.weight": down,
                "first.lora_B.weight": up,
                "first.alpha": MLXArray(Float(2)),
            ], url: url)
        }
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
