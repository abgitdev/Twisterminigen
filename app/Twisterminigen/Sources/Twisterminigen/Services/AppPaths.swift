import Foundation

struct ModelDirectoryResolution: Sendable, Equatable {
    let root: URL
    let shouldPersist: Bool
}

enum ModelWeightsSource: String, Sendable, Equatable {
    case managed
    case linked

    var isReadOnly: Bool { self == .linked }
}

/// Pure policy for selecting the model directory. Filesystem probing is supplied by the caller.
enum ModelDirectoryResolver {
    static func resolve(
        storedPath: String?,
        legacyRoot: URL,
        fallbackRoot: URL,
        legacyContainsCurrentWeights: Bool
    ) -> ModelDirectoryResolution {
        if let storedPath, !storedPath.isEmpty {
            return ModelDirectoryResolution(
                root: URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL,
                shouldPersist: false)
        }

        let root = legacyContainsCurrentWeights ? legacyRoot : fallbackRoot
        return ModelDirectoryResolution(root: root.standardizedFileURL, shouldPersist: true)
    }
}

/// Single source of truth for every on-disk location the app uses.
///
/// Storage layout:
/// ```
/// ~/Library/Application Support/Twisterminigen/
///   ├─ Images/           ← generated PNGs
///   ├─ InputImages/      ← canonical managed input PNGs + private catalog
///   ├─ LoRAs/            ← managed, verified adapter files + private catalog
///   ├─ Presets/          ← personal preset index + canonical cover thumbnails
///   ├─ OptionalModels/    ← separately installed Describe / AI-upscale weights
///   ├─ generations.json  ← deterministic gallery index
///   └─ gallery-annotations.json ← mutable user favorites, separate from recipes
/// ~/Library/Caches/Twisterminigen/
///   └─ thumbnails/       ← gallery thumbnails (safe to clear)
/// ```
enum AppPaths {
    static let appName = "Twisterminigen"
    /// Legacy builds stored the app-support directory itself under this key. Such a path cannot
    /// be proven app-owned, so bootstrap refuses it until the user explicitly chooses a container
    /// again. Never silently adopt or delete a legacy root.
    static let storageRootDefaultsKey = "applicationStorageRootPathV1"
    static let storageContainerDefaultsKey = "applicationStorageContainerPathV2"
    static let storageOwnershipIdentifierDefaultsKey = "applicationStorageOwnershipIDV1"
    static let storageOwnershipMarkerName = ".twisterminigen-storage-owner.json"
    static let weightsRootDefaultsKey = "modelWeightsRootPath"
    static let weightsSourceDefaultsKey = "modelWeightsSourceV1"
    static let minimumBootstrapCapacity: Int64 = 64 * 1024

    private static var library: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    // MARK: Application Support

    static var appSupport: URL {
        applicationSupportDirectory(defaults: .standard, libraryDirectory: library)
    }

    static var images: URL { appSupport.appendingPathComponent("Images", isDirectory: true) }
    static var inputImages: URL {
        appSupport.appendingPathComponent("InputImages", isDirectory: true)
    }
    static var loras: URL { appSupport.appendingPathComponent("LoRAs", isDirectory: true) }
    static var presets: URL { appSupport.appendingPathComponent("Presets", isDirectory: true) }
    static var presetCovers: URL {
        presets.appendingPathComponent("PresetCovers", isDirectory: true)
    }
    static var optionalModels: URL {
        appSupport.appendingPathComponent("OptionalModels", isDirectory: true)
    }
    static var importedModels: URL {
        appSupport.appendingPathComponent("ImportedModels", isDirectory: true)
    }
    static var linkedModelVerification: URL {
        appSupport.appendingPathComponent("LinkedModelVerification", isDirectory: true)
    }
    static var presetsIndex: URL { presets.appendingPathComponent("presets.json") }
    static var generationsIndex: URL { appSupport.appendingPathComponent("generations.json") }
    static var systemLog: URL { appSupport.appendingPathComponent("system-log.json") }

    // MARK: Caches

    static var caches: URL {
        cacheDirectory(defaults: .standard, libraryDirectory: library)
    }
    static var thumbnails: URL { caches.appendingPathComponent("thumbnails", isDirectory: true) }

    // MARK: Model weights

    static var defaultWeightsRoot: URL {
        appSupport.appendingPathComponent("Models", isDirectory: true)
    }

    static var weightsRoot: URL {
        resolveWeightsRoot(
            defaults: .standard,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            applicationSupportDirectory: appSupport,
            legacyContainsCurrentWeights: { containsCurrentWeights(at: $0) })
    }

    static var weightsSource: ModelWeightsSource {
        weightsSource(defaults: .standard)
    }

    static func weightsSource(defaults: UserDefaults) -> ModelWeightsSource {
        guard let raw = defaults.string(forKey: weightsSourceDefaultsKey),
              let source = ModelWeightsSource(rawValue: raw) else { return .managed }
        return source
    }

    static func applicationSupportDirectory(
        defaults: UserDefaults,
        libraryDirectory: URL
    ) -> URL {
        if let storedContainer = defaults.string(forKey: storageContainerDefaultsKey),
           !storedContainer.isEmpty {
            return URL(fileURLWithPath: storedContainer, isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent(appName, isDirectory: true)
        }
        // Preserve the legacy value only so startup can report a recoverable, fail-closed error.
        // bootstrap() rejects this configuration before touching the filesystem.
        if let storedPath = defaults.string(forKey: storageRootDefaultsKey),
           !storedPath.isEmpty {
            return URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL
        }
        return libraryDirectory
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    static func cacheDirectory(
        defaults: UserDefaults,
        libraryDirectory: URL
    ) -> URL {
        if defaults.string(forKey: storageContainerDefaultsKey)?.isEmpty == false {
            return applicationSupportDirectory(
                defaults: defaults,
                libraryDirectory: libraryDirectory)
                .appendingPathComponent("Caches", isDirectory: true)
        }
        return libraryDirectory
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    /// Switches all app-owned data to a user-selected folder without moving or deleting the old
    /// location. An app-owned model selection follows the new root; explicitly linked weights do
    /// not.
    static func setStorageRoot(
        _ root: URL,
        defaults: UserDefaults = .standard,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let libraryDirectory = libraryDirectory ?? library
        let container = root.standardizedFileURL
        _ = try validateExistingContainer(container, fileManager: fileManager)
        let currentContainer = defaults.string(forKey: storageContainerDefaultsKey).map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        let currentIdentifier = normalizedOwnershipIdentifier(defaults.string(
            forKey: storageOwnershipIdentifierDefaultsKey))
        let newSupport = container.appendingPathComponent(appName, isDirectory: true)
        let targetState = try validateSelectionTarget(
            newSupport,
            selectedContainer: container,
            currentContainer: currentContainer,
            currentIdentifier: currentIdentifier,
            fileManager: fileManager)

        // Do not mutate any preference until both the container and target app directory have
        // passed every fail-closed check.
        let oldSupport = applicationSupportDirectory(
            defaults: defaults,
            libraryDirectory: libraryDirectory)
        let oldModels = oldSupport.appendingPathComponent("Models", isDirectory: true)
        let oldImports = oldSupport.appendingPathComponent("ImportedModels", isDirectory: true)
        let storedWeights = defaults.string(forKey: weightsRootDefaultsKey).map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        let followsAppStorage = weightsSource(defaults: defaults) == .managed
            && storedWeights.map {
                $0 == oldModels.standardizedFileURL || isWithin($0, parent: oldImports)
            } ?? true

        let ownershipIdentifier: String
        switch targetState {
        case .newOrEmpty:
            ownershipIdentifier = UUID().uuidString
        case .currentOwned(let identifier):
            ownershipIdentifier = identifier
        }
        defaults.set(container.path, forKey: storageContainerDefaultsKey)
        defaults.set(
            ownershipIdentifier,
            forKey: storageOwnershipIdentifierDefaultsKey)
        defaults.removeObject(forKey: storageRootDefaultsKey)
        if followsAppStorage {
            defaults.set(
                newSupport
                    .appendingPathComponent("Models", isDirectory: true)
                    .standardizedFileURL.path,
                forKey: weightsRootDefaultsKey)
            defaults.set(ModelWeightsSource.managed.rawValue, forKey: weightsSourceDefaultsKey)
        }
    }

    /// Resolves and persists the initial selection without creating or copying model files.
    static func resolveWeightsRoot(
        defaults: UserDefaults,
        homeDirectory: URL,
        applicationSupportDirectory: URL,
        legacyContainsCurrentWeights: (URL) -> Bool
    ) -> URL {
        let legacyRoot = homeDirectory
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("krea2-weights", isDirectory: true)
        let fallbackRoot = applicationSupportDirectory
            .appendingPathComponent("Models", isDirectory: true)
        let storedPath = defaults.string(forKey: weightsRootDefaultsKey)
        let hasStoredSelection = storedPath.map { !$0.isEmpty } ?? false
        let resolution = ModelDirectoryResolver.resolve(
            storedPath: storedPath,
            legacyRoot: legacyRoot,
            fallbackRoot: fallbackRoot,
            legacyContainsCurrentWeights: hasStoredSelection
                ? false
                : legacyContainsCurrentWeights(legacyRoot))

        if resolution.shouldPersist {
            defaults.set(resolution.root.path, forKey: weightsRootDefaultsKey)
        }
        if defaults.string(forKey: weightsSourceDefaultsKey) == nil {
            let models = fallbackRoot.standardizedFileURL
            let imported = applicationSupportDirectory
                .appendingPathComponent("ImportedModels", isDirectory: true)
                .standardizedFileURL
            let root = resolution.root.standardizedFileURL
            let appOwned = root == models || isWithin(root, parent: imported)
            defaults.set(
                (appOwned ? ModelWeightsSource.managed : .linked).rawValue,
                forKey: weightsSourceDefaultsKey)
        }
        return resolution.root
    }

    static func setWeightsRoot(
        _ root: URL,
        source: ModelWeightsSource = .managed,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(root.standardizedFileURL.path, forKey: weightsRootDefaultsKey)
        defaults.set(source.rawValue, forKey: weightsSourceDefaultsKey)
    }

    private static func containsCurrentWeights(at root: URL) -> Bool {
        ModelCatalog(root: root).defaultFiles.allSatisfy {
            FileProbe.size($0.localURL) == $0.expectedBytes
        }
    }

    private static func isWithin(_ child: URL, parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    // MARK: Bootstrap

    /// Creates and verifies all directories. Call once at launch before any storage use.
    ///
    /// A small write/remove probe catches existing read-only trees that `createDirectory` alone
    /// would accept. `capacityProvider` is injectable so an out-of-space path can be tested
    /// deterministically without filling a real volume.
    @discardableResult
    static func bootstrap(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        libraryDirectory: URL? = nil,
        capacityProvider: ((URL) throws -> Int64?)? = nil
    ) throws -> URL {
        let libraryDirectory = libraryDirectory ?? library
        let storedContainer = defaults.string(forKey: storageContainerDefaultsKey)
        if storedContainer?.isEmpty != false,
           let legacyRoot = defaults.string(forKey: storageRootDefaultsKey),
           !legacyRoot.isEmpty {
            throw AppStorageBootstrapError(
                kind: .invalidLocation,
                operation: "legacy-storage-root",
                location: URL(fileURLWithPath: legacyRoot, isDirectory: true),
                underlyingDescription:
                    "This folder was selected by a legacy build and has no verifiable "
                    + "app-owned boundary. Choose a storage container again; existing files "
                    + "will remain untouched.")
        }
        let customContext = try customStorageContext(
            storedContainer: storedContainer,
            defaults: defaults,
            fileManager: fileManager)
        let support = applicationSupportDirectory(
            defaults: defaults,
            libraryDirectory: libraryDirectory)
        let cacheRoot = cacheDirectory(
            defaults: defaults,
            libraryDirectory: libraryDirectory)
        let modelRoot = resolveWeightsRoot(
            defaults: defaults,
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            applicationSupportDirectory: support,
            legacyContainsCurrentWeights: { containsCurrentWeights(at: $0) })
        try verifyCustomContainer(customContext, fileManager: fileManager)
        try AppStorageBootstrapper.prepareDirectory(
            support,
            fileManager: fileManager,
            withIntermediateDirectories: customContext == nil)
        try verifyCustomContainer(customContext, fileManager: fileManager)
        try establishOwnership(
            of: support,
            defaults: defaults,
            fileManager: fileManager,
            isCustomStorage: customContext != nil)
        try verifyCustomContainer(customContext, fileManager: fileManager)

        var directories = [
            support.appendingPathComponent("Images", isDirectory: true),
            support.appendingPathComponent("InputImages", isDirectory: true),
            support.appendingPathComponent("LoRAs", isDirectory: true),
            support.appendingPathComponent("Presets", isDirectory: true),
            support
                .appendingPathComponent("Presets", isDirectory: true)
                .appendingPathComponent("PresetCovers", isDirectory: true),
            support.appendingPathComponent("OptionalModels", isDirectory: true),
            support.appendingPathComponent("ImportedModels", isDirectory: true),
            support.appendingPathComponent("LinkedModelVerification", isDirectory: true),
            cacheRoot,
            cacheRoot.appendingPathComponent("thumbnails", isDirectory: true),
        ]
        // A linked root is external and strictly read-only. Even directory creation belongs only
        // to managed storage; a missing linked folder must surface as unavailable, not be recreated.
        if !weightsSource(defaults: defaults).isReadOnly { directories.append(modelRoot) }

        for dir in directories {
            try verifyCustomContainer(customContext, fileManager: fileManager)
            try AppStorageBootstrapper.prepareDirectory(
                dir,
                fileManager: fileManager,
                withIntermediateDirectories: customContext == nil)
            try verifyCustomContainer(customContext, fileManager: fileManager)
        }
        let availableCapacity: Int64?
        do {
            if let capacityProvider {
                availableCapacity = try capacityProvider(support)
            } else {
                availableCapacity = try support.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
            }
        } catch {
            throw AppStorageBootstrapError.wrap(
                error,
                operation: "check-capacity",
                location: support)
        }
        if let availableCapacity, availableCapacity < minimumBootstrapCapacity {
            throw AppStorageBootstrapError(
                kind: .noSpace,
                operation: "check-capacity",
                location: support,
                underlyingDescription:
                    "Only \(availableCapacity) bytes are available; "
                    + "\(minimumBootstrapCapacity) bytes are required for startup.")
        }
        for dir in directories {
            try verifyCustomContainer(customContext, fileManager: fileManager)
            try AppStorageBootstrapper.verifyWritable(dir, fileManager: fileManager)
            try verifyCustomContainer(customContext, fileManager: fileManager)
        }
        try verifyCustomContainer(customContext, fileManager: fileManager)
        return modelRoot
    }

    static func isCanonicalApplicationSupportDirectory(
        _ root: URL,
        libraryDirectory: URL
    ) -> Bool {
        sameResolvedPath(
            root,
            libraryDirectory
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(appName, isDirectory: true))
    }

    static func hasValidOwnershipMarker(
        at root: URL,
        identifier: String?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let identifier, !identifier.isEmpty,
              let record = readOwnershipRecord(at: root, fileManager: fileManager),
              record.identifier == identifier else { return false }
        return record.schema == AppStorageOwnershipRecord.expectedSchema
            && record.version == 1
    }

    private static func customStorageContext(
        storedContainer: String?,
        defaults: UserDefaults,
        fileManager: FileManager
    ) throws -> AppCustomStorageContext? {
        guard let storedContainer, !storedContainer.isEmpty else { return nil }
        let container = URL(
            fileURLWithPath: storedContainer,
            isDirectory: true).standardizedFileURL
        let identity = try validateExistingContainer(container, fileManager: fileManager)
        guard let identifier = normalizedOwnershipIdentifier(defaults.string(
            forKey: storageOwnershipIdentifierDefaultsKey)) else {
            throw AppStorageBootstrapError(
                kind: .invalidLocation,
                operation: "validate-ownership-identifier",
                location: container,
                underlyingDescription:
                    "Custom storage requires a nonempty UUID ownership identifier.")
        }
        let support = container.appendingPathComponent(appName, isDirectory: true)
        _ = try validateSelectionTarget(
            support,
            selectedContainer: container,
            currentContainer: container,
            currentIdentifier: identifier,
            fileManager: fileManager)
        return AppCustomStorageContext(
            container: container,
            identity: identity)
    }

    private static func validateExistingContainer(
        _ container: URL,
        fileManager: FileManager
    ) throws -> AppStorageDirectoryIdentity {
        let container = container.standardizedFileURL
        guard container.resolvingSymlinksInPath().standardizedFileURL.path
                == container.path else {
            throw AppStorageBootstrapError(
                kind: .invalidLocation,
                operation: "validate-storage-container",
                location: container,
                underlyingDescription:
                    "The selected container or one of its ancestors is a symbolic link.")
        }
        let values: URLResourceValues
        do {
            values = try container.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey,
            ])
        } catch {
            throw AppStorageBootstrapError(
                kind: .unavailable,
                operation: "validate-storage-container",
                location: container,
                underlyingDescription:
                    "The selected container does not exist or its volume is not mounted: "
                    + (error as NSError).localizedDescription)
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AppStorageBootstrapError(
                kind: .invalidLocation,
                operation: "validate-storage-container",
                location: container,
                underlyingDescription:
                    "The selected container must be a real, non-symbolic-link directory.")
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: container.path)
        } catch {
            throw AppStorageBootstrapError.wrap(
                error,
                operation: "identify-storage-container",
                location: container)
        }
        let identity = AppStorageDirectoryIdentity(
            volume: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            file: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) })
        guard identity.file != nil || identity.resourceIdentifier != nil else {
            throw AppStorageBootstrapError(
                kind: .unavailable,
                operation: "identify-storage-container",
                location: container,
                underlyingDescription:
                    "The filesystem did not provide a stable directory identity.")
        }
        return identity
    }

    private static func validateSelectionTarget(
        _ support: URL,
        selectedContainer: URL,
        currentContainer: URL?,
        currentIdentifier: String?,
        fileManager: FileManager
    ) throws -> AppStorageSelectionTarget {
        let support = support.standardizedFileURL
        if let values = try? support.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ]) {
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  support.resolvingSymlinksInPath().standardizedFileURL.path
                    == support.path else {
                throw AppStorageBootstrapError(
                    kind: .invalidLocation,
                    operation: "validate-storage-target",
                    location: support,
                    underlyingDescription:
                        "The target app directory is not a real non-symbolic-link directory.")
            }
        } else if !fileManager.fileExists(atPath: support.path) {
            return .newOrEmpty
        } else {
            throw AppStorageBootstrapError(
                kind: .unavailable,
                operation: "validate-storage-target",
                location: support,
                underlyingDescription:
                    "The target app directory could not be inspected.")
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: support,
                includingPropertiesForKeys: nil)
        } catch {
            throw AppStorageBootstrapError.wrap(
                error,
                operation: "inspect-storage-target",
                location: support)
        }
        guard !entries.isEmpty else { return .newOrEmpty }
        guard let currentContainer,
              sameExactPath(selectedContainer, currentContainer),
              let currentIdentifier,
              hasValidOwnershipMarker(
                at: support,
                identifier: currentIdentifier,
                fileManager: fileManager) else {
            throw AppStorageBootstrapError(
                kind: .invalidLocation,
                operation: "claim-storage-target",
                location: support,
                underlyingDescription:
                    "The target Twisterminigen directory is nonempty and is not the currently "
                    + "verified app-owned storage. It was left untouched.")
        }
        return .currentOwned(currentIdentifier)
    }

    private static func verifyCustomContainer(
        _ context: AppCustomStorageContext?,
        fileManager: FileManager
    ) throws {
        guard let context else { return }
        let current = try validateExistingContainer(
            context.container,
            fileManager: fileManager)
        guard current == context.identity else {
            throw AppStorageBootstrapError(
                kind: .unavailable,
                operation: "verify-storage-container-identity",
                location: context.container,
                underlyingDescription:
                    "The custom storage container changed while it was being prepared.")
        }
    }

    private static func establishOwnership(
        of support: URL,
        defaults: UserDefaults,
        fileManager: FileManager,
        isCustomStorage: Bool
    ) throws {
        let marker = support.appendingPathComponent(storageOwnershipMarkerName)
        let storedIdentifier = normalizedOwnershipIdentifier(defaults.string(
            forKey: storageOwnershipIdentifierDefaultsKey))
        if let record = readOwnershipRecord(at: support, fileManager: fileManager) {
            guard record.schema == AppStorageOwnershipRecord.expectedSchema,
                  record.version == 1,
                  storedIdentifier == record.identifier
                    || (!isCustomStorage && storedIdentifier == nil) else {
                throw AppStorageBootstrapError(
                    kind: .invalidLocation,
                    operation: "validate-ownership-marker",
                    location: marker,
                    underlyingDescription:
                        "The storage ownership marker does not match this installation.")
            }
            try applyPrivatePermissions(
                to: support,
                marker: marker,
                fileManager: fileManager)
            if !isCustomStorage && storedIdentifier == nil {
                defaults.set(
                    record.identifier,
                    forKey: storageOwnershipIdentifierDefaultsKey)
            }
            return
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: support,
                includingPropertiesForKeys: nil)
        } catch {
            throw AppStorageBootstrapError.wrap(
                error,
                operation: "inspect-storage-root",
                location: support)
        }
        guard entries.isEmpty || !isCustomStorage else {
            throw AppStorageBootstrapError(
                kind: .invalidLocation,
                operation: "claim-storage-root",
                location: support,
                underlyingDescription:
                    "The app-owned subdirectory already contains data but has no valid "
                    + "ownership marker. It was left untouched.")
        }

        guard !isCustomStorage || storedIdentifier != nil else {
            throw AppStorageBootstrapError(
                kind: .invalidLocation,
                operation: "validate-ownership-identifier",
                location: support,
                underlyingDescription:
                    "Custom storage requires an exact nonempty UUID ownership identifier.")
        }
        let identifier = storedIdentifier ?? UUID().uuidString
        let record = AppStorageOwnershipRecord(
            schema: AppStorageOwnershipRecord.expectedSchema,
            version: 1,
            identifier: identifier)
        do {
            // Close the parent directory before the marker is materialized so there is no window
            // where a newly written identifier inherits a permissive default directory mode.
            try enforcePrivatePermissions(
                0o700,
                at: support,
                fileManager: fileManager)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: marker, options: .withoutOverwriting)
            try enforcePrivatePermissions(
                0o600,
                at: marker,
                fileManager: fileManager)
            defaults.set(
                identifier,
                forKey: storageOwnershipIdentifierDefaultsKey)
        } catch {
            throw AppStorageBootstrapError.wrap(
                error,
                operation: "write-ownership-marker",
                location: marker)
        }
    }

    private static func readOwnershipRecord(
        at root: URL,
        fileManager: FileManager = .default
    ) -> AppStorageOwnershipRecord? {
        let marker = root.appendingPathComponent(storageOwnershipMarkerName)
        guard let values = try? marker.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let fileSize = values.fileSize,
        fileSize > 0,
        fileSize <= AppStorageOwnershipRecord.maximumEncodedBytes,
        let handle = try? FileHandle(forReadingFrom: marker) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(
            upToCount: AppStorageOwnershipRecord.maximumEncodedBytes + 1),
        data.count <= AppStorageOwnershipRecord.maximumEncodedBytes,
        let record = try? JSONDecoder().decode(AppStorageOwnershipRecord.self, from: data),
        record.schema == AppStorageOwnershipRecord.expectedSchema,
        record.version == 1,
        normalizedOwnershipIdentifier(record.identifier) == record.identifier else { return nil }
        return record
    }

    private static func applyPrivatePermissions(
        to support: URL,
        marker: URL,
        fileManager: FileManager
    ) throws {
        try enforcePrivatePermissions(
            0o700,
            at: support,
            fileManager: fileManager)
        try enforcePrivatePermissions(
            0o600,
            at: marker,
            fileManager: fileManager)
    }

    private static func enforcePrivatePermissions(
        _ expected: Int,
        at url: URL,
        fileManager: FileManager
    ) throws {
        let volume: URLResourceValues
        do {
            volume = try url.resourceValues(forKeys: [.volumeSupportsExtendedSecurityKey])
        } catch {
            throw AppStorageBootstrapError.wrap(
                error,
                operation: "inspect-permission-capability",
                location: url)
        }
        // FAT-like filesystems do not implement POSIX security bits. Their limitation is explicit;
        // the ownership marker remains authoritative and no unverifiable chmod claim is made.
        if volume.volumeSupportsExtendedSecurity == false { return }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: expected)],
                ofItemAtPath: url.path)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let actual = attributes[.posixPermissions] as? NSNumber,
                  actual.intValue & 0o777 == expected else {
                throw AppStorageBootstrapError(
                    kind: .permissions,
                    operation: "verify-private-permissions",
                    location: url,
                    underlyingDescription:
                        "The filesystem did not retain the required private permission bits.")
            }
        } catch {
            if let failure = error as? AppStorageBootstrapError { throw failure }
            throw AppStorageBootstrapError(
                kind: .permissions,
                operation: "set-private-permissions",
                location: url,
                underlyingDescription: (error as NSError).localizedDescription)
        }
    }

    private static func normalizedOwnershipIdentifier(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= AppStorageOwnershipRecord.maximumIdentifierBytes,
              UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private static func sameExactPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private static func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private struct AppStorageDirectoryIdentity: Equatable {
    let volume: UInt64?
    let file: UInt64?
    let resourceIdentifier: String?
}

private struct AppCustomStorageContext {
    let container: URL
    let identity: AppStorageDirectoryIdentity
}

private enum AppStorageSelectionTarget {
    case newOrEmpty
    case currentOwned(String)
}

private struct AppStorageOwnershipRecord: Codable {
    static let expectedSchema = "twisterminigen.storage-owner"
    static let maximumEncodedBytes = 4_096
    static let maximumIdentifierBytes = 64

    let schema: String
    let version: Int
    let identifier: String
}

enum AppStorageFailureKind: String, Sendable, Equatable {
    case permissions
    case noSpace
    case invalidLocation
    case unavailable
}

struct AppStorageBootstrapError: LocalizedError, Sendable, Equatable {
    let kind: AppStorageFailureKind
    let operation: String
    let location: URL
    let underlyingDescription: String

    var errorDescription: String? {
        switch kind {
        case .permissions:
            "Twisterminigen cannot write to its storage folder."
        case .noSpace:
            "The storage volume does not have enough free space."
        case .invalidLocation:
            "The selected storage location is not a safe writable folder."
        case .unavailable:
            "Twisterminigen storage is unavailable."
        }
    }

    var recoverySuggestion: String? {
        switch kind {
        case .permissions:
            "Restore read and write access, choose another folder, then retry."
        case .noSpace:
            "Free disk space or choose a folder on another volume, then retry."
        case .invalidLocation:
            "Choose a normal local folder that is not a file or symbolic link."
        case .unavailable:
            "Check that the volume is mounted and writable, or choose another folder."
        }
    }

    var diagnosticMessage: String {
        "kind=\(kind.rawValue); operation=\(operation); path=\(location.path); "
            + "cause=\(underlyingDescription)"
    }

    static func wrap(
        _ error: Error,
        operation: String,
        location: URL
    ) -> AppStorageBootstrapError {
        if let failure = error as? AppStorageBootstrapError { return failure }
        return AppStorageBootstrapError(
            kind: classify(error),
            operation: operation,
            location: location,
            underlyingDescription: (error as NSError).localizedDescription)
    }

    private static func classify(_ error: Error) -> AppStorageFailureKind {
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.domain == NSPOSIXErrorDomain {
                switch candidate.code {
                case Int(POSIXErrorCode.ENOSPC.rawValue): return .noSpace
                case Int(POSIXErrorCode.EACCES.rawValue),
                     Int(POSIXErrorCode.EPERM.rawValue),
                     Int(POSIXErrorCode.EROFS.rawValue):
                    return .permissions
                default: break
                }
            }
            if candidate.domain == NSCocoaErrorDomain {
                switch candidate.code {
                case CocoaError.Code.fileWriteOutOfSpace.rawValue:
                    return .noSpace
                case CocoaError.Code.fileWriteNoPermission.rawValue,
                     CocoaError.Code.fileWriteVolumeReadOnly.rawValue:
                    return .permissions
                default: break
                }
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .unavailable
    }
}

private enum AppStorageBootstrapper {
    static func prepareDirectory(
        _ directory: URL,
        fileManager: FileManager,
        withIntermediateDirectories: Bool
    ) throws {
        do {
            if fileManager.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw AppStorageBootstrapError(
                        kind: .invalidLocation,
                        operation: "validate-directory",
                        location: directory,
                        underlyingDescription:
                            "The path already exists but is not a non-symbolic-link directory.")
                }
            } else {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: withIntermediateDirectories)
            }

            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AppStorageBootstrapError(
                    kind: .invalidLocation,
                    operation: "validate-directory",
                    location: directory,
                    underlyingDescription:
                        "The prepared path is not a non-symbolic-link directory.")
            }

            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            if let permissions, permissions.intValue & 0o222 == 0 {
                throw AppStorageBootstrapError(
                    kind: .permissions,
                    operation: "validate-permissions",
                    location: directory,
                    underlyingDescription: "The directory has no writable permission bits.")
            }
        } catch {
            throw AppStorageBootstrapError.wrap(
                error,
                operation: "create-directory",
                location: directory)
        }
    }

    static func verifyWritable(_ directory: URL, fileManager: FileManager) throws {
        let probe = directory.appendingPathComponent(
            ".twisterminigen-write-probe-\(UUID().uuidString)",
            isDirectory: false)
        do {
            try Data(repeating: 0xA5, count: 4_096)
                .write(to: probe, options: .withoutOverwriting)
            try fileManager.removeItem(at: probe)
        } catch {
            try? fileManager.removeItem(at: probe)
            throw AppStorageBootstrapError.wrap(
                error,
                operation: "write-probe",
                location: directory)
        }
    }
}
