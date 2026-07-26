import Foundation

enum StorageCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case models
    case lora
    case gallery
    case cache
    case quarantine
    case logs
    case applicationData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: "Models"
        case .lora: "LoRA"
        case .gallery: "Gallery"
        case .cache: "Cache"
        case .quarantine: "Quarantine"
        case .logs: "Logs & diagnostics"
        case .applicationData: "App data & metadata"
        }
    }
}

enum StorageLocationKind: String, Codable, Sendable {
    case applicationSupport
    case caches
    case preferences
    case httpStorages
    case diagnostics
    case appShortcutsMetadata

    var title: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .httpStorages: "HTTPStorages"
        case .diagnostics: "Diagnostics"
        case .appShortcutsMetadata: "App Shortcuts metadata"
        }
    }
}

struct StorageExpectedLocation: Identifiable, Equatable, Sendable {
    let kind: StorageLocationKind
    let url: URL
    let exists: Bool
    let fileCount: Int
    let bytes: Int64

    var id: String { "\(kind.rawValue):\(url.path)" }
}

struct StorageCategorySnapshot: Identifiable, Equatable, Sendable {
    let category: StorageCategory
    let fileCount: Int
    let bytes: Int64

    var id: StorageCategory { category }
}

struct StorageModelInstallation: Identifiable, Equatable, Sendable {
    let root: URL
    let isSelected: Bool
    let isManaged: Bool
    let fileCount: Int
    let bytes: Int64
    let signature: String

    var id: String { root.path }
}

struct StorageDuplicateGroup: Identifiable, Equatable, Sendable {
    let signature: String
    let installations: [StorageModelInstallation]

    var id: String { signature }
    var bytesPerCopy: Int64 { installations.first?.bytes ?? 0 }
}

struct StorageSnapshot: Equatable, Sendable {
    let categories: [StorageCategorySnapshot]
    let expectedLocations: [StorageExpectedLocation]
    let modelInstallations: [StorageModelInstallation]
    let possibleModelDuplicates: [StorageDuplicateGroup]
    let unusedModels: [StorageModelInstallation]
    let scannedAt: Date

    var totalFiles: Int { categories.reduce(0) { $0 + $1.fileCount } }
    var totalBytes: Int64 { categories.reduce(0) { $0 + $1.bytes } }
}

enum StorageDeletionOption: String, CaseIterable, Codable, Sendable, Identifiable {
    case clearCache
    case deleteGallery
    case deleteUnusedModels
    case deleteModelsAndLoRA
    case fullReset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clearCache: "Clear cache only"
        case .deleteGallery: "Delete Gallery"
        case .deleteUnusedModels: "Delete unused models"
        case .deleteModelsAndLoRA: "Delete models and LoRA"
        case .fullReset: "Full application reset"
        }
    }

    var detail: String {
        switch self {
        case .clearCache:
            "Removes thumbnails, the app cache, and HTTP cache."
        case .deleteGallery:
            "Removes generated images, private recipes, annotations, and thumbnails."
        case .deleteUnusedModels:
            "Removes app-managed model installations that are not selected."
        case .deleteModelsAndLoRA:
            "Removes every app-managed model and imported LoRA. Linked models stay untouched."
        case .fullReset:
            "Removes app-owned data, caches, preferences, diagnostics, and metadata."
        }
    }
}

struct StorageDeletionRequest: Equatable, Sendable {
    var option: StorageDeletionOption
    var preserveUserResults: Bool
    var confirmedDuplicateRoots: Set<URL>

    init(
        option: StorageDeletionOption,
        preserveUserResults: Bool = false,
        confirmedDuplicateRoots: Set<URL> = []
    ) {
        self.option = option
        self.preserveUserResults = preserveUserResults
        self.confirmedDuplicateRoots = confirmedDuplicateRoots
    }
}

struct StoragePlannedFile: Identifiable, Equatable, Sendable {
    let url: URL
    let category: StorageCategory
    let bytes: Int64
    let identity: StorageFileIdentity

    var id: String { url.path }
}

struct StorageFileIdentity: Equatable, Sendable {
    let volume: UInt64?
    let file: UInt64?
    let createdAt: Date?
    let modifiedAt: Date?
}

struct StoragePlannedRoot: Identifiable, Equatable, Sendable {
    let url: URL
    let identity: StorageFileIdentity?

    var id: String { url.path }
}

struct StorageDeletionPlan: Equatable, Sendable {
    let request: StorageDeletionRequest
    let files: [StoragePlannedFile]
    /// Complete regular-file inventory observed beneath every verified root at dry-run time,
    /// including deliberately preserved or duplicate-protected files. Execution compares this
    /// snapshot again so a late file cannot be silently omitted from the confirmed plan.
    let observedFiles: [StoragePlannedFile]
    let verifiedRoots: [StoragePlannedRoot]
    let refusedRoots: [URL]
    let protectedDuplicateRoots: [URL]
    let createdAt: Date

    var cleanupRoots: [URL] { verifiedRoots.map(\.url) }
    var canExecute: Bool { refusedRoots.isEmpty && !files.isEmpty }
    var fileCount: Int { files.count }
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var categoryCounts: [StorageCategorySnapshot] {
        StorageCategory.allCases.compactMap { category in
            let selected = files.filter { $0.category == category }
            guard !selected.isEmpty else { return nil }
            return StorageCategorySnapshot(
                category: category,
                fileCount: selected.count,
                bytes: selected.reduce(0) { $0 + $1.bytes })
        }
    }
}

struct StorageDeletionResult: Equatable, Sendable {
    let deletedFiles: Int
    let deletedBytes: Int64
    let failedPaths: [URL]
}

struct StorageExportResult: Equatable, Sendable {
    let root: URL
    let fileCount: Int
    let bytes: Int64
}

struct QuarantineRetentionPolicy: Codable, Equatable, Sendable {
    static let defaultMaximumBytes: Int64 = 2 * 1_073_741_824
    static let defaultMaximumAgeDays = 30

    var maximumBytes: Int64
    var maximumAgeDays: Int

    static let `default` = QuarantineRetentionPolicy(
        maximumBytes: defaultMaximumBytes,
        maximumAgeDays: defaultMaximumAgeDays)

    func normalized() -> QuarantineRetentionPolicy {
        QuarantineRetentionPolicy(
            maximumBytes: max(0, maximumBytes),
            maximumAgeDays: max(0, maximumAgeDays))
    }
}

struct QuarantineRetentionResult: Equatable, Sendable {
    let deletedFiles: Int
    let deletedBytes: Int64
    let remainingBytes: Int64
}

struct StorageManagerLayout: Equatable, Sendable {
    let library: URL
    let appSupport: URL
    let caches: URL
    let weightsRoot: URL
    let weightsSource: ModelWeightsSource
    let home: URL
    let bundleIdentifier: String
    let appName: String
    let appSupportOwnershipIdentifier: String?

    init(
        library: URL,
        appSupport: URL,
        caches: URL,
        weightsRoot: URL,
        weightsSource: ModelWeightsSource,
        home: URL,
        bundleIdentifier: String,
        appName: String,
        appSupportOwnershipIdentifier: String? = nil
    ) {
        self.library = library
        self.appSupport = appSupport
        self.caches = caches
        self.weightsRoot = weightsRoot
        self.weightsSource = weightsSource
        self.home = home
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appSupportOwnershipIdentifier = appSupportOwnershipIdentifier
    }

    static func application(
        bundleIdentifier: String = Bundle.main.bundleIdentifier
            ?? "com.personal.twisterminigen"
    ) -> StorageManagerLayout {
        let manager = FileManager.default
        let library = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return StorageManagerLayout(
            library: library,
            appSupport: AppPaths.appSupport,
            caches: AppPaths.caches,
            weightsRoot: AppPaths.weightsRoot,
            weightsSource: AppPaths.weightsSource,
            home: manager.homeDirectoryForCurrentUser,
            bundleIdentifier: bundleIdentifier,
            appName: AppPaths.appName,
            appSupportOwnershipIdentifier: UserDefaults.standard.string(
                forKey: AppPaths.storageOwnershipIdentifierDefaultsKey))
    }

    var defaultWeightsRoot: URL {
        appSupport.appendingPathComponent("Models", isDirectory: true)
    }

    var importedModelsRoot: URL {
        appSupport.appendingPathComponent("ImportedModels", isDirectory: true)
    }

    var optionalModelsRoot: URL {
        appSupport.appendingPathComponent("OptionalModels", isDirectory: true)
    }

    var loraRoot: URL {
        appSupport.appendingPathComponent("LoRAs", isDirectory: true)
    }

    var thumbnailRoot: URL {
        caches.appendingPathComponent("thumbnails", isDirectory: true)
    }

    var quarantineRoots: [URL] {
        [
            appSupport.appendingPathComponent("Quarantine", isDirectory: true),
            appSupport
                .appendingPathComponent("InputImages", isDirectory: true)
                .appendingPathComponent("Orphans", isDirectory: true),
        ]
    }

    var galleryRoots: [URL] {
        [
            appSupport.appendingPathComponent("Images", isDirectory: true),
            appSupport.appendingPathComponent("Recipes", isDirectory: true),
            appSupport.appendingPathComponent("generations.json"),
            appSupport.appendingPathComponent("generations.transaction.json"),
            appSupport.appendingPathComponent("gallery-annotations.json"),
        ]
    }

    var logRoots: [URL] {
        [appSupport.appendingPathComponent("system-log.json")] + diagnosticFiles
    }

    var preferenceFiles: [URL] {
        [
            library.appendingPathComponent(
                "Preferences/\(bundleIdentifier).plist",
                isDirectory: false),
            library.appendingPathComponent(
                "Preferences/\(appName).plist",
                isDirectory: false),
        ]
    }

    var httpStorageRoots: [URL] {
        [
            library.appendingPathComponent(
                "HTTPStorages/\(bundleIdentifier)",
                isDirectory: true),
            library.appendingPathComponent(
                "HTTPStorages/\(appName)",
                isDirectory: true),
        ]
    }

    var diagnosticDirectory: URL {
        library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
    }

    var diagnosticFiles: [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: diagnosticDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants])
        else { return [] }
        return urls.filter {
            let name = $0.lastPathComponent.lowercased()
            return name.hasPrefix(appName.lowercased() + "_")
                || name.hasPrefix(appName.lowercased() + "-")
                || name == appName.lowercased()
        }
    }

    var appShortcutsMetadataRoots: [URL] {
        [
            library.appendingPathComponent(
                "Application Support/com.apple.shortcuts/Actions/\(bundleIdentifier)",
                isDirectory: true),
            library.appendingPathComponent(
                "Application Support/com.apple.shortcuts/AppShortcuts/\(bundleIdentifier)",
                isDirectory: true),
            library.appendingPathComponent(
                "Application Support/com.apple.siri.shortcuts/metadata/\(bundleIdentifier)",
                isDirectory: true),
        ]
    }

    var secondaryCacheRoots: [URL] {
        [
            library.appendingPathComponent(
                "Caches/\(bundleIdentifier)",
                isDirectory: true),
        ]
    }

    var legacyWeightsRoot: URL {
        home.appendingPathComponent("Developer/krea2-weights", isDirectory: true)
    }
}

enum StorageManagerError: LocalizedError, Equatable {
    case unsafeRoot(URL)
    case exportInsideManagedStorage(URL)
    case exportDestinationExists(URL)
    case sourceChanged(URL)

    var errorDescription: String? {
        switch self {
        case .unsafeRoot(let url):
            "Storage Manager refused an unsafe root: \(url.path)"
        case .exportInsideManagedStorage(let url):
            "Choose an export folder outside app-managed storage: \(url.path)"
        case .exportDestinationExists(let url):
            "The export destination already exists: \(url.path)"
        case .sourceChanged(let url):
            "A planned file changed after the dry-run and was left untouched: \(url.path)"
        }
    }
}

/// Sendable ownership wrapper for the UserDefaults instance used by Storage Manager. Foundation
/// UserDefaults is internally synchronized; test doubles supplied here provide their own lock.
final class StorageDefaultsStore: @unchecked Sendable {
    static let standard = StorageDefaultsStore(.standard)

    private let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func replaceExplicitValues(with values: [String: String]) -> Bool {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        _ = defaults.synchronize()
        return values.allSatisfy { defaults.string(forKey: $0.key) == $0.value }
    }
}

actor StorageManager {
    private struct InventoryFile: Equatable, Sendable {
        let url: URL
        let bytes: Int64
        let modified: Date?
        let identity: StorageFileIdentity
    }

    private struct StorageRoutingSnapshot: Sendable {
        let containerPath: String?
        let ownershipIdentifier: String?
    }

    let layout: StorageManagerLayout
    private let fileManager: FileManager
    private let defaults: StorageDefaultsStore

    init(
        layout: StorageManagerLayout = .application(),
        fileManager: FileManager = .default,
        defaults: StorageDefaultsStore = .standard
    ) {
        self.layout = layout
        self.fileManager = fileManager
        self.defaults = defaults
    }

    func scan() -> StorageSnapshot {
        let expected = expectedLocations()
        let installations = modelInstallations()
        let duplicates = Dictionary(grouping: installations, by: \.signature)
            .values
            .filter { $0.count > 1 && !$0.first!.signature.isEmpty }
            .map {
                StorageDuplicateGroup(
                    signature: $0[0].signature,
                    installations: $0.sorted { $0.root.path < $1.root.path })
            }
            .sorted { $0.bytesPerCopy > $1.bytesPerCopy }
        let protectedRoots = Set(duplicates.flatMap(\.installations).map(\.root))
        let unused = installations.filter {
            $0.isManaged && !$0.isSelected && !protectedRoots.contains($0.root)
        }
        let files = allOwnedFiles()
        let grouped = Dictionary(grouping: files) { category(for: $0.url) }
        let categories = StorageCategory.allCases.map { category in
            let values = grouped[category] ?? []
            return StorageCategorySnapshot(
                category: category,
                fileCount: values.count,
                bytes: values.reduce(0) { $0 + $1.bytes })
        }
        return StorageSnapshot(
            categories: categories,
            expectedLocations: expected,
            modelInstallations: installations,
            possibleModelDuplicates: duplicates,
            unusedModels: unused,
            scannedAt: Date())
    }

    func dryRun(_ request: StorageDeletionRequest) -> StorageDeletionPlan {
        let snapshot = scan()
        let duplicateRoots = Set(
            snapshot.possibleModelDuplicates.flatMap(\.installations).map(\.root))
        var roots: [URL] = []
        var candidates: [InventoryFile] = []

        switch request.option {
        case .clearCache:
            roots = cacheRoots
        case .deleteGallery:
            roots = layout.galleryRoots + [layout.thumbnailRoot]
        case .deleteUnusedModels:
            roots = snapshot.modelInstallations
                .filter { $0.isManaged && !$0.isSelected }
                .map(\.root)
        case .deleteModelsAndLoRA:
            roots = managedModelRoots(from: snapshot) + [layout.loraRoot]
        case .fullReset:
            roots = fullResetRoots(from: snapshot)
        }

        let rootAssessment = assessDeletionRoots(uniqueRoots(roots))
        let observed = inventory(roots: rootAssessment.safe)
        candidates = observed
        if request.option == .fullReset, request.preserveUserResults {
            candidates.removeAll { file in
                layout.galleryRoots.contains { isWithin(file.url, root: $0) }
            }
        }
        if request.option == .fullReset {
            // This marker is the durable proof that a custom directory belongs to the app. It is
            // routing metadata, not resettable user state, and must survive partial or full resets.
            candidates.removeAll { samePath($0.url, ownershipMarkerURL) }
            // Never unlink a live preferences plist behind cfprefsd. Full reset clears explicit
            // values through the injected UserDefaults instance after filesystem deletion succeeds.
            candidates.removeAll { candidate in
                layout.preferenceFiles.contains { samePath(candidate.url, $0) }
            }
        }
        let protected = duplicateRoots.subtracting(request.confirmedDuplicateRoots)
        candidates.removeAll { file in
            protected.contains { isWithin(file.url, root: $0) }
        }
        candidates = unique(candidates)

        return StorageDeletionPlan(
            request: request,
            files: candidates.map {
                StoragePlannedFile(
                    url: $0.url,
                    category: category(for: $0.url),
                    bytes: $0.bytes,
                    identity: $0.identity)
            },
            observedFiles: plannedFiles(from: observed),
            verifiedRoots: rootAssessment.safe.map {
                StoragePlannedRoot(url: $0, identity: currentIdentity(of: $0))
            },
            refusedRoots: rootAssessment.refused,
            protectedDuplicateRoots: protected.sorted { $0.path < $1.path },
            createdAt: Date())
    }

    func export(
        plan: StorageDeletionPlan,
        to parent: URL,
        now: Date = Date()
    ) throws -> StorageExportResult {
        if let refused = plan.refusedRoots.first {
            throw StorageManagerError.unsafeRoot(refused)
        }
        guard validate(plan: plan) else {
            throw StorageManagerError.sourceChanged(
                plan.files.first?.url ?? plan.cleanupRoots.first ?? layout.appSupport)
        }
        let destinationParent = parent.standardizedFileURL
        guard !managedRoots.contains(where: {
            isWithin(destinationParent, root: $0) || isWithin($0, root: destinationParent)
        }) else {
            throw StorageManagerError.exportInsideManagedStorage(destinationParent)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = destinationParent.appendingPathComponent(
            "Twisterminigen-Storage-Export-\(formatter.string(from: now))",
            isDirectory: true)
        guard !fileManager.fileExists(atPath: root.path) else {
            throw StorageManagerError.exportDestinationExists(root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)

        var copied = 0
        var bytes: Int64 = 0
        var manifestFiles: [StorageExportManifestFile] = []
        do {
            for (index, item) in plan.files.enumerated() {
                guard matchesCurrentState(item) else {
                    throw StorageManagerError.sourceChanged(item.url)
                }
                let exportIndex = String(format: "%06d", index)
                let categoryRoot = root
                    .appendingPathComponent(item.category.rawValue, isDirectory: true)
                    .appendingPathComponent(exportIndex, isDirectory: true)
                try fileManager.createDirectory(
                    at: categoryRoot,
                    withIntermediateDirectories: true)
                let destination = categoryRoot.appendingPathComponent(item.url.lastPathComponent)
                try fileManager.copyItem(at: item.url, to: destination)
                copied += 1
                bytes += item.bytes
                manifestFiles.append(StorageExportManifestFile(
                    category: item.category,
                    bytes: item.bytes,
                    relativePath:
                        "\(item.category.rawValue)/\(exportIndex)/\(item.url.lastPathComponent)"))
            }
            let manifest = StorageExportManifest(
                schema: "twisterminigen.storage-export",
                version: 2,
                createdAt: now,
                option: plan.request.option,
                preserveUserResults: plan.request.preserveUserResults,
                files: manifestFiles)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(
                to: root.appendingPathComponent("manifest.json"),
                options: .atomic)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
        return StorageExportResult(root: root, fileCount: copied, bytes: bytes)
    }

    func execute(plan: StorageDeletionPlan) -> StorageDeletionResult {
        var deletedFiles = 0
        var deletedBytes: Int64 = 0
        var failures: [URL] = []
        let routingSnapshot = plan.request.option == .fullReset
            ? validatedStorageRoutingSnapshot()
            : nil

        guard plan.refusedRoots.isEmpty,
              plan.request.option != .fullReset || routingSnapshot != nil,
              validate(plan: plan) else {
            return StorageDeletionResult(
                deletedFiles: 0,
                deletedBytes: 0,
                failedPaths: plan.files.map(\.url))
        }

        for item in plan.files {
            guard pathHasNoSymlink(item.url),
                  matchesCurrentState(item) else {
                failures.append(item.url)
                continue
            }
            do {
                try fileManager.removeItem(at: item.url)
                deletedFiles += 1
                deletedBytes += item.bytes
            } catch {
                failures.append(item.url)
            }
        }
        let postDeleteInventoryMatches = inventoryMatchesExpectedRemainder(for: plan)
        if !postDeleteInventoryMatches {
            failures.append(contentsOf: unexpectedInventoryPaths(for: plan))
            if failures.isEmpty {
                failures.append(plan.cleanupRoots.first ?? layout.appSupport)
            }
        }
        removeEmptyDirectories(under: plan.cleanupRoots)
        if plan.request.option == .clearCache || plan.request.option == .fullReset {
            URLCache.shared.removeAllCachedResponses()
        }
        if plan.request.option == .fullReset && failures.isEmpty {
            if let routingSnapshot,
               !resetDefaultsPreservingStorageRouting(routingSnapshot) {
                failures.append(layout.appSupport)
            }
        }
        return StorageDeletionResult(
            deletedFiles: deletedFiles,
            deletedBytes: deletedBytes,
            failedPaths: failures)
    }

    func enforceQuarantineRetention(
        _ policy: QuarantineRetentionPolicy,
        now: Date = Date()
    ) -> QuarantineRetentionResult {
        let policy = policy.normalized()
        let safeRoots = assessDeletionRoots(layout.quarantineRoots).safe
        guard safeRoots.count == uniqueRoots(layout.quarantineRoots).count else {
            return QuarantineRetentionResult(
                deletedFiles: 0,
                deletedBytes: 0,
                remainingBytes: 0)
        }
        let files = inventory(roots: safeRoots)
            .sorted {
                ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast)
            }
        let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -policy.maximumAgeDays,
            to: now) ?? now
        var toDelete: [InventoryFile] = files.filter {
            ($0.modified ?? .distantPast) < cutoff
        }
        var selected = Set(toDelete.map(\.url))
        var remainingBytes = files
            .filter { !selected.contains($0.url) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        if remainingBytes > policy.maximumBytes {
            for file in files where !selected.contains(file.url) {
                toDelete.append(file)
                selected.insert(file.url)
                remainingBytes -= file.bytes
                if remainingBytes <= policy.maximumBytes { break }
            }
        }

        var deletedFiles = 0
        var deletedBytes: Int64 = 0
        var deletedURLs = Set<URL>()
        for file in toDelete {
            guard pathHasNoSymlink(file.url),
                  currentIdentity(of: file.url) == file.identity else { continue }
            if (try? fileManager.removeItem(at: file.url)) != nil {
                deletedFiles += 1
                deletedBytes += file.bytes
                deletedURLs.insert(file.url)
            }
        }
        removeEmptyDirectories(under: safeRoots)
        remainingBytes = files
            .filter { !deletedURLs.contains($0.url) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        return QuarantineRetentionResult(
            deletedFiles: deletedFiles,
            deletedBytes: deletedBytes,
            remainingBytes: max(0, remainingBytes))
    }

    private var cacheRoots: [URL] {
        [layout.caches] + layout.secondaryCacheRoots + layout.httpStorageRoots
    }

    private var managedRoots: [URL] {
        [
            layout.appSupport,
            layout.caches,
            layout.defaultWeightsRoot,
            layout.importedModelsRoot,
            layout.optionalModelsRoot,
        ] + layout.secondaryCacheRoots
            + layout.httpStorageRoots
            + layout.preferenceFiles
            + layout.appShortcutsMetadataRoots
    }

    private func assessDeletionRoots(_ roots: [URL]) -> (safe: [URL], refused: [URL]) {
        var safe: [URL] = []
        var refused: [URL] = []
        for root in roots {
            if isSafeDeletionRoot(root) {
                safe.append(root.standardizedFileURL)
            } else {
                refused.append(root.standardizedFileURL)
            }
        }
        return (
            safe.sorted { $0.path < $1.path },
            refused.sorted { $0.path < $1.path })
    }

    /// Destructive operations are allowlisted to paths whose ownership is independently
    /// established. A configured path or a `.managed` enum value is not ownership proof.
    private func isSafeDeletionRoot(_ root: URL) -> Bool {
        let root = root.standardizedFileURL
        guard !isBroadUserRoot(root), pathHasNoSymlink(root) else { return false }

        if isWithin(root, root: layout.appSupport) {
            return hasProvenAppSupportOwnership
        }

        let canonicalCache = layout.library
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent(layout.appName, isDirectory: true)
        if isWithin(root, root: layout.caches) {
            return samePath(layout.caches, canonicalCache)
                || (isWithin(layout.caches, root: layout.appSupport)
                    && hasProvenAppSupportOwnership)
        }
        if layout.secondaryCacheRoots.contains(where: { isWithin(root, root: $0) }) {
            return true
        }
        if layout.httpStorageRoots.contains(where: { isWithin(root, root: $0) }) {
            return true
        }
        if layout.appShortcutsMetadataRoots.contains(where: { isWithin(root, root: $0) }) {
            return true
        }
        if layout.preferenceFiles.contains(where: { samePath(root, $0) }) {
            return true
        }
        if isDiagnosticFile(root) {
            return true
        }
        return false
    }

    private var hasProvenAppSupportOwnership: Bool {
        guard !isBroadUserRoot(layout.appSupport),
              pathHasNoSymlink(layout.appSupport) else { return false }
        if AppPaths.isCanonicalApplicationSupportDirectory(
            layout.appSupport,
            libraryDirectory: layout.library) {
            return true
        }
        return AppPaths.hasValidOwnershipMarker(
            at: layout.appSupport,
            identifier: layout.appSupportOwnershipIdentifier,
            fileManager: fileManager)
    }

    private func isBroadUserRoot(_ root: URL) -> Bool {
        let unsafe = [
            URL(fileURLWithPath: "/", isDirectory: true),
            layout.home,
            layout.home.appendingPathComponent("Desktop", isDirectory: true),
            layout.home.appendingPathComponent("Documents", isDirectory: true),
            layout.library,
        ]
        return unsafe.contains { samePath(root, $0) }
    }

    private func isDiagnosticFile(_ url: URL) -> Bool {
        guard samePath(url.deletingLastPathComponent(), layout.diagnosticDirectory) else {
            return false
        }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix(layout.appName.lowercased() + "_")
            || name.hasPrefix(layout.appName.lowercased() + "-")
            || name == layout.appName.lowercased()
    }

    private func validate(plan: StorageDeletionPlan) -> Bool {
        guard plan.refusedRoots.isEmpty,
              !plan.verifiedRoots.isEmpty,
              plan.verifiedRoots.allSatisfy({
                  isSafeDeletionRoot($0.url)
                      && currentIdentity(of: $0.url) == $0.identity
              }),
              plannedFiles(from: inventory(roots: plan.cleanupRoots)) == plan.observedFiles
        else { return false }
        return plan.files.allSatisfy { item in
            plan.cleanupRoots.contains { isWithin(item.url, root: $0) }
                && pathHasNoSymlink(item.url)
                && matchesCurrentState(item)
        }
    }

    private var ownershipMarkerURL: URL {
        layout.appSupport.appendingPathComponent(AppPaths.storageOwnershipMarkerName)
            .standardizedFileURL
    }

    private func plannedFiles(from inventory: [InventoryFile]) -> [StoragePlannedFile] {
        inventory.map {
            StoragePlannedFile(
                url: $0.url,
                category: category(for: $0.url),
                bytes: $0.bytes,
                identity: $0.identity)
        }
    }

    private func expectedRemainder(for plan: StorageDeletionPlan) -> [StoragePlannedFile] {
        let deletedPaths = Set(plan.files.map { $0.url.standardizedFileURL.path })
        return plan.observedFiles.filter {
            !deletedPaths.contains($0.url.standardizedFileURL.path)
        }
    }

    private func inventoryMatchesExpectedRemainder(for plan: StorageDeletionPlan) -> Bool {
        plannedFiles(from: inventory(roots: plan.cleanupRoots)) == expectedRemainder(for: plan)
    }

    private func unexpectedInventoryPaths(for plan: StorageDeletionPlan) -> [URL] {
        let expected = Dictionary(
            uniqueKeysWithValues: expectedRemainder(for: plan).map {
                ($0.url.standardizedFileURL.path, $0)
            })
        let actualFiles = plannedFiles(from: inventory(roots: plan.cleanupRoots))
        let actual = Dictionary(uniqueKeysWithValues: actualFiles.map {
            ($0.url.standardizedFileURL.path, $0)
        })
        return Set(expected.keys).union(actual.keys)
            .filter { expected[$0] != actual[$0] }
            .sorted()
            .map { URL(fileURLWithPath: $0) }
    }

    /// A reset may clear application preferences, but it must never sever the independently
    /// verified route to a custom storage tree. The marker remains on disk and these minimal
    /// routing values are restored after every other explicit value is removed.
    private func validatedStorageRoutingSnapshot() -> StorageRoutingSnapshot? {
        let isCanonical = AppPaths.isCanonicalApplicationSupportDirectory(
            layout.appSupport,
            libraryDirectory: layout.library)

        if !isCanonical {
            guard let storedContainer = defaults.string(
                    forKey: AppPaths.storageContainerDefaultsKey),
                  !storedContainer.isEmpty,
                  let storedIdentifier = defaults.string(
                    forKey: AppPaths.storageOwnershipIdentifierDefaultsKey),
                  !storedIdentifier.isEmpty,
                  storedIdentifier == layout.appSupportOwnershipIdentifier
            else { return nil }
            let container = URL(
                fileURLWithPath: storedContainer,
                isDirectory: true).standardizedFileURL
            guard samePath(
                container.appendingPathComponent(layout.appName, isDirectory: true),
                layout.appSupport),
                AppPaths.hasValidOwnershipMarker(
                    at: layout.appSupport,
                    identifier: storedIdentifier,
                    fileManager: fileManager)
            else { return nil }
            return StorageRoutingSnapshot(
                containerPath: container.path,
                ownershipIdentifier: storedIdentifier)
        } else if let storedIdentifier = defaults.string(
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey),
            AppPaths.hasValidOwnershipMarker(
                at: layout.appSupport,
                identifier: storedIdentifier,
                fileManager: fileManager) {
            return StorageRoutingSnapshot(
                containerPath: nil,
                ownershipIdentifier: storedIdentifier)
        }
        return StorageRoutingSnapshot(containerPath: nil, ownershipIdentifier: nil)
    }

    private func resetDefaultsPreservingStorageRouting(
        _ routing: StorageRoutingSnapshot
    ) -> Bool {
        var values: [String: String] = [
            AppPaths.weightsRootDefaultsKey: layout.defaultWeightsRoot.path,
            AppPaths.weightsSourceDefaultsKey: ModelWeightsSource.managed.rawValue,
        ]
        if let containerPath = routing.containerPath {
            values[AppPaths.storageContainerDefaultsKey] = containerPath
        }
        if let ownershipIdentifier = routing.ownershipIdentifier {
            values[AppPaths.storageOwnershipIdentifierDefaultsKey] = ownershipIdentifier
        }
        return defaults.replaceExplicitValues(with: values)
    }

    private func expectedLocations() -> [StorageExpectedLocation] {
        let locations: [(StorageLocationKind, URL)] =
            [(.applicationSupport, layout.appSupport), (.caches, layout.caches)]
            + layout.preferenceFiles.map { (.preferences, $0) }
            + layout.httpStorageRoots.map { (.httpStorages, $0) }
            + [(.diagnostics, layout.diagnosticDirectory)]
            + layout.appShortcutsMetadataRoots.map { (.appShortcutsMetadata, $0) }
        return locations.map { kind, url in
            let files: [InventoryFile]
            if kind == .diagnostics {
                files = inventory(roots: layout.diagnosticFiles)
            } else if isSafeDeletionRoot(url) {
                files = inventory(roots: [url])
            } else {
                files = []
            }
            return StorageExpectedLocation(
                kind: kind,
                url: url,
                exists: fileManager.fileExists(atPath: url.path),
                fileCount: files.count,
                bytes: files.reduce(0) { $0 + $1.bytes })
        }
    }

    private func allOwnedFiles() -> [InventoryFile] {
        let roots = uniqueRoots(
            [layout.appSupport, layout.caches]
                + layout.secondaryCacheRoots
                + layout.httpStorageRoots
                + layout.preferenceFiles
                + layout.diagnosticFiles
                + layout.appShortcutsMetadataRoots
                + (layout.weightsSource.isReadOnly ? [] : [layout.weightsRoot]))
        return inventory(roots: roots.filter(isSafeDeletionRoot))
    }

    private func modelInstallations() -> [StorageModelInstallation] {
        var roots = [layout.weightsRoot, layout.defaultWeightsRoot, layout.legacyWeightsRoot]
        if let children = try? fileManager.contentsOfDirectory(
            at: layout.importedModelsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) {
            roots.append(contentsOf: children.filter { url in
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            })
        }
        return uniqueRoots(roots).compactMap { root in
            let catalog = ModelCatalog(root: root)
            let found = catalog.allFiles.compactMap { file -> (String, Int64)? in
                guard let bytes = currentSize(of: file.localURL) else { return nil }
                return (file.remotePath, bytes)
            }
            guard !found.isEmpty else { return nil }
            let signature = found
                .sorted { $0.0 < $1.0 }
                .map { "\($0.0):\($0.1)" }
                .joined(separator: "|")
            let isManaged = isManagedModelRoot(root)
            let files = isManaged ? inventory(roots: [root]) : []
            return StorageModelInstallation(
                root: root,
                isSelected: samePath(root, layout.weightsRoot),
                isManaged: isManaged,
                fileCount: isManaged ? files.count : found.count,
                bytes: isManaged
                    ? files.reduce(0) { $0 + $1.bytes }
                    : found.reduce(0) { $0 + $1.1 },
                signature: signature)
        }
    }

    private func managedModelRoots(from snapshot: StorageSnapshot) -> [URL] {
        var roots = [
            layout.defaultWeightsRoot,
            layout.importedModelsRoot,
            layout.optionalModelsRoot,
        ]
        if !layout.weightsSource.isReadOnly {
            roots.append(layout.weightsRoot)
        }
        roots.append(contentsOf: snapshot.modelInstallations.filter(\.isManaged).map(\.root))
        return uniqueRoots(roots)
    }

    private func fullResetRoots(from snapshot: StorageSnapshot) -> [URL] {
        uniqueRoots(
            [layout.appSupport, layout.caches]
                + layout.secondaryCacheRoots
                + layout.httpStorageRoots
                + layout.preferenceFiles
                + layout.diagnosticFiles
                + layout.appShortcutsMetadataRoots
                + managedModelRoots(from: snapshot))
    }

    private func isManagedModelRoot(_ root: URL) -> Bool {
        guard hasProvenAppSupportOwnership,
              isWithin(root, root: layout.appSupport) else { return false }
        if samePath(root, layout.defaultWeightsRoot) { return true }
        if isWithin(root, root: layout.importedModelsRoot) { return true }
        if isWithin(root, root: layout.optionalModelsRoot) { return true }
        return samePath(root, layout.weightsRoot) && !layout.weightsSource.isReadOnly
    }

    private func category(for url: URL) -> StorageCategory {
        if layout.quarantineRoots.contains(where: { isWithin(url, root: $0) }) {
            return .quarantine
        }
        if modelCategoryRoots.contains(where: { isWithin(url, root: $0) }) {
            return .models
        }
        if isWithin(url, root: layout.loraRoot) { return .lora }
        if layout.galleryRoots.contains(where: { isWithin(url, root: $0) }) {
            return .gallery
        }
        if cacheRoots.contains(where: { isWithin(url, root: $0) }) { return .cache }
        if layout.logRoots.contains(where: { isWithin(url, root: $0) }) { return .logs }
        return .applicationData
    }

    private var modelCategoryRoots: [URL] {
        [
            layout.defaultWeightsRoot,
            layout.importedModelsRoot,
            layout.optionalModelsRoot,
        ] + (layout.weightsSource.isReadOnly ? [] : [layout.weightsRoot])
    }

    private func inventory(roots: [URL]) -> [InventoryFile] {
        unique(roots.flatMap(inventory(root:)))
    }

    private func inventory(root: URL) -> [InventoryFile] {
        let root = root.standardizedFileURL
        guard let values = try? root.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey,
        ]) else { return [] }
        if values.isSymbolicLink == true { return [] }
        if values.isDirectory != true {
            guard values.isRegularFile == true, let bytes = values.fileSize else { return [] }
            guard let identity = currentIdentity(of: root) else { return [] }
            return [InventoryFile(
                url: root,
                bytes: Int64(bytes),
                modified: values.contentModificationDate,
                identity: identity)]
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey,
            ],
            options: [],
            errorHandler: { _, _ in true })
        else { return [] }
        var files: [InventoryFile] = []
        for case let url as URL in enumerator {
            guard let item = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey,
            ]) else { continue }
            if item.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard item.isRegularFile == true, let bytes = item.fileSize else { continue }
            let standardized = url.standardizedFileURL
            guard let identity = currentIdentity(of: standardized) else { continue }
            files.append(InventoryFile(
                url: standardized,
                bytes: Int64(bytes),
                modified: item.contentModificationDate,
                identity: identity))
        }
        return files
    }

    private func currentSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private func currentFileState(
        of url: URL
    ) -> (Int64, StorageFileIdentity)? {
        guard let bytes = currentSize(of: url),
              let identity = currentIdentity(of: url) else { return nil }
        return (bytes, identity)
    }

    private func matchesCurrentState(_ item: StoragePlannedFile) -> Bool {
        guard let state = currentFileState(of: item.url) else { return false }
        return state.0 == item.bytes && state.1 == item.identity
    }

    private func currentIdentity(of url: URL) -> StorageFileIdentity? {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .creationDateKey, .contentModificationDateKey,
        ]),
        values.isSymbolicLink != true,
        values.isDirectory == true || values.isRegularFile == true,
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        else { return nil }
        return StorageFileIdentity(
            volume: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            file: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            createdAt: values.creationDate,
            modifiedAt: values.contentModificationDate)
    }

    private func pathHasNoSymlink(_ url: URL) -> Bool {
        url.standardizedFileURL.path
            == url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func removeEmptyDirectories(under roots: [URL]) {
        for root in uniqueRoots(roots) {
            guard pathHasNoSymlink(root) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [])
            else { continue }
            var directories: [URL] = []
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])
                if values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                } else if values?.isDirectory == true {
                    directories.append(url)
                }
            }
            for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
                if pathHasNoSymlink(directory),
                   (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                    try? fileManager.removeItem(at: directory)
                }
            }
            if (try? fileManager.contentsOfDirectory(atPath: root.path).isEmpty) == true {
                try? fileManager.removeItem(at: root)
            }
        }
    }

    private func unique(_ files: [InventoryFile]) -> [InventoryFile] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
            .sorted { $0.url.path < $1.url.path }
    }

    private func uniqueRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        return roots.map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
            .filter { candidate in
                !roots.contains { other in
                    let other = other.standardizedFileURL
                    return other.path != candidate.path && isWithin(candidate, root: other)
                }
            }
            .sorted { $0.path < $1.path }
    }

    private func isWithin(_ url: URL, root: URL) -> Bool {
        let child = url.standardizedFileURL.path
        let parent = root.standardizedFileURL.path
        return child == parent || child.hasPrefix(parent + "/")
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}

private struct StorageExportManifest: Codable {
    let schema: String
    let version: Int
    let createdAt: Date
    let option: StorageDeletionOption
    let preserveUserResults: Bool
    let files: [StorageExportManifestFile]
}

private struct StorageExportManifestFile: Codable {
    let category: StorageCategory
    let bytes: Int64
    let relativePath: String
}
