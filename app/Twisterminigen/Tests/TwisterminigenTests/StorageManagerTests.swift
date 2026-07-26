import Foundation
import Testing
@testable import Twisterminigen

@Suite("Storage Manager")
struct StorageManagerTests {
    @Test("Inventory covers every requested macOS location and storage category")
    func inventoryCoversExpectedLocations() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }

        try fixture.write("model", to: fixture.layout.defaultWeightsRoot
            .appendingPathComponent("unrecognized-model.bin"))
        try fixture.write("lora", to: fixture.layout.loraRoot
            .appendingPathComponent("adapter.safetensors"))
        try fixture.write("gallery", to: fixture.layout.galleryRoots[0]
            .appendingPathComponent("result.png"))
        try fixture.write("thumb", to: fixture.layout.thumbnailRoot
            .appendingPathComponent("result.png"))
        try fixture.write("quarantine", to: fixture.layout.quarantineRoots[0]
            .appendingPathComponent("isolated.bin"))
        try fixture.write("log", to: fixture.layout.appSupport
            .appendingPathComponent("system-log.json"))
        try fixture.write("preference", to: fixture.layout.preferenceFiles[0])
        try fixture.write("http", to: fixture.layout.httpStorageRoots[0]
            .appendingPathComponent("cache.db"))
        try fixture.write("shortcut", to: fixture.layout.appShortcutsMetadataRoots[0]
            .appendingPathComponent("metadata.data"))
        try fixture.write(
            "diagnostic",
            to: fixture.layout.diagnosticDirectory
                .appendingPathComponent("Twisterminigen_2026-07-24.crash"))

        let snapshot = await fixture.manager.scan()
        let kinds = Set(snapshot.expectedLocations.map(\.kind))

        #expect(kinds == Set(StorageLocationKind.allCasesForTesting))
        #expect(snapshot.categories.first { $0.category == .lora }?.fileCount == 1)
        #expect(snapshot.categories.first { $0.category == .gallery }?.fileCount == 1)
        #expect(snapshot.categories.first { $0.category == .cache }?.fileCount == 2)
        #expect(snapshot.categories.first { $0.category == .quarantine }?.fileCount == 1)
        #expect(snapshot.categories.first { $0.category == .logs }?.fileCount == 2)
        #expect(snapshot.categories.first { $0.category == .applicationData }?.fileCount == 2)
    }

    @Test("Two matching 18 GB model copies are protected until explicitly confirmed")
    func largeDuplicateModelsRequireConfirmation() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let imported = fixture.layout.importedModelsRoot
            .appendingPathComponent("copy", isDirectory: true)
        let logicalBytes: Int64 = 18 * 1_073_741_824
        try fixture.createSparseKnownModel(at: fixture.layout.defaultWeightsRoot, bytes: logicalBytes)
        try fixture.createSparseKnownModel(at: imported, bytes: logicalBytes)

        let snapshot = await fixture.manager.scan()
        #expect(snapshot.possibleModelDuplicates.count == 1)
        #expect(snapshot.possibleModelDuplicates[0].installations.count == 2)
        #expect(snapshot.possibleModelDuplicates[0].bytesPerCopy == logicalBytes)
        #expect(snapshot.unusedModels.isEmpty)

        let protected = await fixture.manager.dryRun(
            StorageDeletionRequest(option: .deleteUnusedModels))
        #expect(protected.fileCount == 0)
        #expect(protected.protectedDuplicateRoots.contains(imported.standardizedFileURL))

        let confirmed = await fixture.manager.dryRun(StorageDeletionRequest(
            option: .deleteUnusedModels,
            confirmedDuplicateRoots: [imported.standardizedFileURL]))
        #expect(confirmed.fileCount == 1)
        #expect(confirmed.bytes == logicalBytes)
    }

    @Test("Dry-run is exact and full reset can preserve user Gallery results")
    func dryRunAndPreserveGallery() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let gallery = fixture.layout.galleryRoots[0].appendingPathComponent("keep.png")
        let appData = fixture.layout.appSupport.appendingPathComponent("queue.json")
        let thumbnail = fixture.layout.thumbnailRoot.appendingPathComponent("keep.png")
        try fixture.write(Data(repeating: 1, count: 11), to: gallery)
        try fixture.write(Data(repeating: 2, count: 17), to: appData)
        try fixture.write(Data(repeating: 3, count: 23), to: thumbnail)

        let plan = await fixture.manager.dryRun(StorageDeletionRequest(
            option: .fullReset,
            preserveUserResults: true))

        #expect(plan.fileCount == 2)
        #expect(plan.bytes == 40)
        #expect(!plan.files.contains { $0.url == gallery.standardizedFileURL })
        #expect(plan.files.contains { $0.url == appData.standardizedFileURL })
        #expect(plan.files.contains { $0.url == thumbnail.standardizedFileURL })

        let result = await fixture.manager.execute(plan: plan)
        #expect(result.deletedFiles == 2)
        #expect(result.deletedBytes == 40)
        #expect(FileManager.default.fileExists(atPath: gallery.path))
    }

    @Test("Preserved custom Gallery remains reachable after reset and bootstrap")
    func preservedCustomGalleryRebootstraps() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let container = fixture.root.appendingPathComponent("External", isDirectory: true)
        let support = container.appendingPathComponent(AppPaths.appName, isDirectory: true)
        let identifier = UUID().uuidString
        let marker = support.appendingPathComponent(AppPaths.storageOwnershipMarkerName)
        let gallery = support.appendingPathComponent("Images/keep.png")
        let appData = support.appendingPathComponent("queue.json")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try fixture.write(
            """
            {"identifier":"\(identifier)","schema":"twisterminigen.storage-owner","version":1}
            """,
            to: marker)
        try fixture.write("keep", to: gallery)
        try fixture.write("delete", to: appData)
        fixture.defaults.set(container.path, forKey: AppPaths.storageContainerDefaultsKey)
        fixture.defaults.set(
            identifier,
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey)
        fixture.defaults.set("reset me", forKey: "unrelatedPreference")
        let layout = StorageManagerLayout(
            library: fixture.layout.library,
            appSupport: support,
            caches: support.appendingPathComponent("Caches", isDirectory: true),
            weightsRoot: support.appendingPathComponent("Models", isDirectory: true),
            weightsSource: .managed,
            home: fixture.layout.home,
            bundleIdentifier: fixture.layout.bundleIdentifier,
            appName: fixture.layout.appName,
            appSupportOwnershipIdentifier: identifier)
        let manager = StorageManager(
            layout: layout,
            defaults: StorageDefaultsStore(fixture.defaults))

        let plan = await manager.dryRun(StorageDeletionRequest(
            option: .fullReset,
            preserveUserResults: true))
        #expect(!plan.files.contains { $0.url == marker.standardizedFileURL })
        let result = await manager.execute(plan: plan)

        #expect(result.failedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: gallery.path))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(fixture.defaults.object(forKey: "unrelatedPreference") == nil)
        #expect(
            fixture.defaults.string(forKey: AppPaths.storageContainerDefaultsKey)
                == container.path)
        #expect(
            fixture.defaults.string(forKey: AppPaths.storageOwnershipIdentifierDefaultsKey)
                == identifier)

        let modelRoot = try AppPaths.bootstrap(
            defaults: fixture.defaults,
            libraryDirectory: fixture.layout.library,
            capacityProvider: { _ in AppPaths.minimumBootstrapCapacity })
        #expect(modelRoot == support.appendingPathComponent("Models", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: gallery.path))
    }

    @Test("A nested file added after dry-run invalidates the whole deletion plan")
    func lateNestedFileInvalidatesPlan() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let original = fixture.layout.appSupport.appendingPathComponent("queue.json")
        let images = fixture.layout.appSupport.appendingPathComponent("Images", isDirectory: true)
        try fixture.write("original", to: original)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let plan = await fixture.manager.dryRun(
            StorageDeletionRequest(option: .fullReset))

        let late = images.appendingPathComponent("nested/late.png")
        try fixture.write("late", to: late)
        let result = await fixture.manager.execute(plan: plan)

        #expect(result.deletedFiles == 0)
        #expect(!result.failedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: late.path))
    }

    @Test("A failed custom-root deletion never removes the ownership marker")
    func partialFailurePreservesOwnershipMarker() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let container = fixture.root.appendingPathComponent("External", isDirectory: true)
        let support = container.appendingPathComponent(AppPaths.appName, isDirectory: true)
        let identifier = UUID().uuidString
        let marker = support.appendingPathComponent(AppPaths.storageOwnershipMarkerName)
        let locked = support.appendingPathComponent("Locked", isDirectory: true)
        let undeletable = locked.appendingPathComponent("queue.json")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try fixture.write(
            """
            {"identifier":"\(identifier)","schema":"twisterminigen.storage-owner","version":1}
            """,
            to: marker)
        try fixture.write("keep until writable", to: undeletable)
        fixture.defaults.set(container.path, forKey: AppPaths.storageContainerDefaultsKey)
        fixture.defaults.set(
            identifier,
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey)
        let layout = StorageManagerLayout(
            library: fixture.layout.library,
            appSupport: support,
            caches: support.appendingPathComponent("Caches", isDirectory: true),
            weightsRoot: support.appendingPathComponent("Models", isDirectory: true),
            weightsSource: .managed,
            home: fixture.layout.home,
            bundleIdentifier: fixture.layout.bundleIdentifier,
            appName: fixture.layout.appName,
            appSupportOwnershipIdentifier: identifier)
        let manager = StorageManager(
            layout: layout,
            defaults: StorageDefaultsStore(fixture.defaults))
        let plan = await manager.dryRun(
            StorageDeletionRequest(option: .fullReset))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: locked.path)
        }

        let result = await manager.execute(plan: plan)

        #expect(!result.failedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(
            fixture.defaults.string(forKey: AppPaths.storageContainerDefaultsKey)
                == container.path)
    }

    @Test("Export writes a recovery manifest before the planned files are deleted")
    func exportThenDelete() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let cache = fixture.layout.thumbnailRoot.appendingPathComponent("thumb.png")
        try fixture.write(Data(repeating: 4, count: 31), to: cache)
        let plan = await fixture.manager.dryRun(
            StorageDeletionRequest(option: .clearCache))

        let exports = fixture.root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let exported = try await fixture.manager.export(
            plan: plan,
            to: exports,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(exported.fileCount == 1)
        #expect(exported.bytes == 31)
        let manifestURL = exported.root.appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        let manifestData = try Data(contentsOf: manifestURL)
        let manifestText = try #require(String(data: manifestData, encoding: .utf8))
        #expect(!manifestText.contains(fixture.root.path))
        #expect(!manifestText.contains("file://"))
        let manifest = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        #expect(manifest["version"] as? Int == 2)
        let files = try #require(manifest["files"] as? [[String: Any]])
        let record = try #require(files.first)
        #expect(Set(record.keys) == ["bytes", "category", "relativePath"])
        #expect(record["relativePath"] as? String == "cache/000000/thumb.png")
        #expect(FileManager.default.fileExists(atPath: cache.path))

        let result = await fixture.manager.execute(plan: plan)
        #expect(result.deletedFiles == 1)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("Quarantine retention removes expired files then enforces the byte limit oldest first")
    func quarantineRetention() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let root = fixture.layout.quarantineRoots[0]
        let expired = root.appendingPathComponent("expired.bin")
        let older = root.appendingPathComponent("older.bin")
        let newer = root.appendingPathComponent("newer.bin")
        try fixture.write(Data(repeating: 1, count: 20), to: expired)
        try fixture.write(Data(repeating: 2, count: 20), to: older)
        try fixture.write(Data(repeating: 3, count: 20), to: newer)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-40 * 86_400)],
            ofItemAtPath: expired.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 86_400)],
            ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-86_400)],
            ofItemAtPath: newer.path)

        let result = await fixture.manager.enforceQuarantineRetention(
            QuarantineRetentionPolicy(maximumBytes: 20, maximumAgeDays: 30),
            now: now)

        #expect(result.deletedFiles == 2)
        #expect(result.deletedBytes == 40)
        #expect(result.remainingBytes == 20)
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(!FileManager.default.fileExists(atPath: older.path))
        #expect(FileManager.default.fileExists(atPath: newer.path))
    }

    @Test("Full reset never treats a shared custom folder as application support")
    func sharedFolderUnrelatedFileSurvivesReset() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let shared = fixture.root.appendingPathComponent("Shared", isDirectory: true)
        let unrelated = shared.appendingPathComponent("unrelated.txt")
        try fixture.write("must survive", to: unrelated)
        let unsafeLayout = StorageManagerLayout(
            library: fixture.layout.library,
            appSupport: shared,
            caches: fixture.layout.caches,
            weightsRoot: shared.appendingPathComponent("Models", isDirectory: true),
            weightsSource: .managed,
            home: fixture.layout.home,
            bundleIdentifier: fixture.layout.bundleIdentifier,
            appName: fixture.layout.appName)
        let manager = StorageManager(
            layout: unsafeLayout,
            defaults: StorageDefaultsStore(fixture.defaults))

        let plan = await manager.dryRun(
            StorageDeletionRequest(option: .fullReset))
        let result = await manager.execute(plan: plan)

        #expect(plan.refusedRoots.contains(shared.standardizedFileURL))
        #expect(!plan.files.contains { $0.url == unrelated.standardizedFileURL })
        #expect(!plan.canExecute)
        #expect(result.deletedFiles == 0)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("Custom app-owned subdirectory reset cannot cross into its shared container")
    func ownedSubdirectoryContainsReset() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let shared = fixture.root.appendingPathComponent("Shared", isDirectory: true)
        let support = shared.appendingPathComponent(AppPaths.appName, isDirectory: true)
        let identifier = UUID().uuidString
        let marker = support.appendingPathComponent(AppPaths.storageOwnershipMarkerName)
        let unrelated = shared.appendingPathComponent("unrelated.txt")
        let owned = support.appendingPathComponent("queue.json")
        try fixture.write("must survive", to: unrelated)
        try fixture.write("delete", to: owned)
        try fixture.write(
            """
            {"identifier":"\(identifier)","schema":"twisterminigen.storage-owner","version":1}
            """,
            to: marker)
        fixture.defaults.set(
            shared.path,
            forKey: AppPaths.storageContainerDefaultsKey)
        fixture.defaults.set(
            identifier,
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey)
        let layout = StorageManagerLayout(
            library: fixture.layout.library,
            appSupport: support,
            caches: support.appendingPathComponent("Caches", isDirectory: true),
            weightsRoot: support.appendingPathComponent("Models", isDirectory: true),
            weightsSource: .managed,
            home: fixture.layout.home,
            bundleIdentifier: fixture.layout.bundleIdentifier,
            appName: fixture.layout.appName,
            appSupportOwnershipIdentifier: identifier)
        let manager = StorageManager(
            layout: layout,
            defaults: StorageDefaultsStore(fixture.defaults))

        let plan = await manager.dryRun(
            StorageDeletionRequest(option: .fullReset))
        let result = await manager.execute(plan: plan)

        #expect(plan.refusedRoots.isEmpty)
        #expect(plan.files.contains { $0.url == owned.standardizedFileURL })
        #expect(!plan.files.contains { $0.url == unrelated.standardizedFileURL })
        #expect(result.failedPaths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("Replacing a planned file with same-size content invalidates the whole plan")
    func fileIdentityPreventsSameSizeReplacement() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let file = fixture.layout.appSupport.appendingPathComponent("queue.json")
        try fixture.write("first", to: file)
        let plan = await fixture.manager.dryRun(
            StorageDeletionRequest(option: .fullReset))
        let originalDate = try file.resourceValues(
            forKeys: [.contentModificationDateKey]).contentModificationDate

        try FileManager.default.removeItem(at: file)
        try fixture.write("other", to: file)
        if let originalDate {
            try FileManager.default.setAttributes(
                [.modificationDate: originalDate],
                ofItemAtPath: file.path)
        }

        let result = await fixture.manager.execute(plan: plan)

        #expect(result.deletedFiles == 0)
        #expect(result.failedPaths.contains(file.standardizedFileURL))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Home, Documents, Desktop, and filesystem root are never reset roots")
    func broadRootsAreRefused() async throws {
        let fixture = try StorageManagerFixture()
        defer { fixture.remove() }
        let broadRoots = [
            fixture.layout.home,
            fixture.layout.home.appendingPathComponent("Documents", isDirectory: true),
            fixture.layout.home.appendingPathComponent("Desktop", isDirectory: true),
            URL(fileURLWithPath: "/", isDirectory: true),
        ]

        for root in broadRoots {
            let layout = StorageManagerLayout(
                library: fixture.layout.library,
                appSupport: root,
                caches: fixture.layout.caches,
                weightsRoot: root.appendingPathComponent("Models", isDirectory: true),
                weightsSource: .managed,
                home: fixture.layout.home,
                bundleIdentifier: fixture.layout.bundleIdentifier,
                appName: fixture.layout.appName)
            let plan = await StorageManager(
                layout: layout,
                defaults: StorageDefaultsStore(fixture.defaults)).dryRun(
                StorageDeletionRequest(option: .fullReset))
            #expect(plan.refusedRoots.contains(root.standardizedFileURL))
            #expect(!plan.canExecute)
        }
    }
}

private extension StorageLocationKind {
    static let allCasesForTesting: [StorageLocationKind] = [
        .applicationSupport, .caches, .preferences, .httpStorages,
        .diagnostics, .appShortcutsMetadata,
    ]
}

private struct StorageManagerFixture {
    let root: URL
    let layout: StorageManagerLayout
    let manager: StorageManager
    let defaults: VolatileUserDefaults

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Twisterminigen-StorageManager-\(UUID().uuidString)",
                isDirectory: true)
            .resolvingSymlinksInPath()
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent(
            "Application Support/Twisterminigen",
            isDirectory: true)
        let caches = library.appendingPathComponent(
            "Caches/Twisterminigen",
            isDirectory: true)
        let defaults = VolatileUserDefaults()
        let layout = StorageManagerLayout(
            library: library,
            appSupport: support,
            caches: caches,
            weightsRoot: support.appendingPathComponent("Models", isDirectory: true),
            weightsSource: .managed,
            home: root.appendingPathComponent("home", isDirectory: true),
            bundleIdentifier: "com.personal.twisterminigen",
            appName: "Twisterminigen")
        self.root = root
        self.layout = layout
        self.defaults = defaults
        self.manager = StorageManager(
            layout: layout,
            defaults: StorageDefaultsStore(defaults))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func createSparseKnownModel(at root: URL, bytes: Int64) throws {
        guard let knownFile = ModelCatalog(root: root).allFiles.first else {
            Issue.record("The production model catalog has no files")
            return
        }
        try FileManager.default.createDirectory(
            at: knownFile.localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(
            atPath: knownFile.localURL.path,
            contents: nil))
        let handle = try FileHandle(forWritingTo: knownFile.localURL)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
