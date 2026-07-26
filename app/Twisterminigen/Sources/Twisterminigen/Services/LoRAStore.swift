import CryptoKit
import Darwin
import Foundation
import Krea2DiT
import MLX

enum LoRAStoreError: Error, Equatable, Sendable {
    case unavailable(String)
    case unsafeRoot(URL)
    case unsafeSource(URL)
    case payloadTooLarge(URL, maximumBytes: Int64)
    case unsupportedCatalogVersion(Int)
    case corruptCatalog(String)
    case duplicateContent(UUID)
    case assetNotFound(UUID)
    case assetMismatch(UUID)
    case tamperedAsset(UUID)
    case tooManyActive(Int)
    case invalidScale(Double)
    case invalidMetadata(String)
    case posixFailure(operation: String, code: Int32)
}

extension LoRAStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .unsafeRoot(let url): return "The LoRA library folder is unsafe: \(url.path)"
        case .unsafeSource(let url): return "The selected LoRA is not a readable regular .safetensors file: \(url.lastPathComponent)"
        case .payloadTooLarge(let url, let maximum):
            return "\(url.lastPathComponent) exceeds the \(ByteCountFormatter.string(fromByteCount: maximum, countStyle: .file)) safety limit."
        case .unsupportedCatalogVersion(let version):
            return "This LoRA catalog was written by a newer app version (schema \(version))."
        case .corruptCatalog(let reason): return "The LoRA catalog is invalid: \(reason)"
        case .duplicateContent: return "That exact LoRA is already in the library."
        case .assetNotFound: return "A referenced LoRA is no longer in the library."
        case .assetMismatch: return "A referenced LoRA no longer matches its saved recipe."
        case .tamperedAsset: return "A managed LoRA file changed after import. Remove it and import the original again."
        case .tooManyActive(let maximum): return "At most \(maximum) LoRA adapters can be active at once."
        case .invalidScale: return "LoRA scale must be between 0.01 and 2.00."
        case .invalidMetadata(let reason): return "LoRA metadata is invalid: \(reason)"
        case let .posixFailure(operation, code):
            return "LoRA storage failed during \(operation) (POSIX \(code))."
        }
    }
}

actor LoRAStore {
    static let schemaVersion = 1
    static let maximumCatalogBytes = 2 * 1_024 * 1_024
    static let maximumAssets = 128
    static let maximumActive = GenerationRecipe.maximumLoRACount
    static let maximumNameBytes = 256
    static let maximumTriggerCount = 8
    static let maximumTriggerBytes = 128

    struct ResolvedAdapter: Sendable, Equatable {
        let reference: GenerationRecipe.LoRAReference
        let asset: LoRAAsset
        let url: URL

        var engineConfig: Krea2DiTLoRAConfig {
            .init(path: url, scale: Float(reference.scale))
        }
    }

    private struct Catalog: Codable, Sendable, Equatable {
        var schemaVersion: Int
        var assets: [LoRAAsset]
        var active: [LoRASelection]
        var rememberedScales: [String: Double]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case assets
            case active
            case rememberedScales
        }

        init(
            schemaVersion: Int,
            assets: [LoRAAsset],
            active: [LoRASelection],
            rememberedScales: [String: Double] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.assets = assets
            self.active = active
            self.rememberedScales = rememberedScales
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            assets = try container.decode([LoRAAsset].self, forKey: .assets)
            active = try container.decode([LoRASelection].self, forKey: .active)
            if let decoded = try container.decodeIfPresent(
                [String: Double].self,
                forKey: .rememberedScales) {
                rememberedScales = decoded
            } else {
                rememberedScales = [:]
                for selection in active {
                    rememberedScales[selection.assetID.uuidString.lowercased()] = selection.scale
                }
            }
        }
    }

    private struct CatalogHeader: Decodable {
        let schemaVersion: Int
    }

    private let root: URL
    private let catalogURL: URL
    private var catalog: Catalog

    init(root: URL = AppPaths.loras) throws {
        let root = root.standardizedFileURL
        self.root = root
        self.catalogURL = root.appendingPathComponent("catalog.json")
        self.catalog = try Self.loadCatalogIfPresent(
            from: root.appendingPathComponent("catalog.json"))
        try Self.ensureManagedDirectory(root)
        try Self.validate(catalog: catalog)
        try Self.recoverInterruptedRemovals(in: root, catalog: catalog)
        try Self.quarantineAbandonedManagedFiles(
            in: root,
            keeping: Set(catalog.assets.map(\.managedFilename)))
    }

    func snapshot() -> LoRALibrarySnapshot {
        LoRALibrarySnapshot(assets: catalog.assets, active: catalog.active)
    }

    /// Reloads the catalog after a confirmed Storage Manager operation. Recreating the private
    /// directory keeps the still-running process usable while an absent catalog means an empty
    /// library.
    func reloadAfterExternalStorageChange() throws -> LoRALibrarySnapshot {
        try Self.ensureManagedDirectory(root)
        let reloaded = try Self.loadCatalogIfPresent(from: catalogURL)
        try Self.validate(catalog: reloaded)
        catalog = reloaded
        return snapshot()
    }

    @discardableResult
    func importAdapter(
        from source: URL,
        displayName: String? = nil,
        triggers: [String] = [],
        origin: LoRAOrigin = .localImport,
        expectedSHA256: String? = nil
    ) throws -> LoRALibrarySnapshot {
        guard catalog.assets.count < Self.maximumAssets else {
            throw LoRAStoreError.invalidMetadata("the library limit is \(Self.maximumAssets) adapters")
        }
        let source = source.standardizedFileURL
        let accessedSecurityScope = source.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope { source.stopAccessingSecurityScopedResource() }
        }
        let sourceValues = try source.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard source.pathExtension.lowercased() == "safetensors",
              sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              FileManager.default.isReadableFile(atPath: source.path),
              let sourceBytes = sourceValues.fileSize,
              sourceBytes > 0 else {
            throw LoRAStoreError.unsafeSource(source)
        }
        guard Int64(sourceBytes) <= Krea2DiTLoRALoader.maximumFileBytes else {
            throw LoRAStoreError.payloadTooLarge(
                source, maximumBytes: Krea2DiTLoRALoader.maximumFileBytes)
        }
        let name = try Self.validatedName(
            displayName ?? source.deletingPathExtension().lastPathComponent)

        let id = UUID()
        let staging = root.appendingPathComponent(".import-\(id.uuidString.lowercased()).safetensors")
        let filename = "\(id.uuidString.lowercased()).safetensors"
        let destination = root.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: staging) }

        try FileManager.default.copyItem(at: source, to: staging)
        try Self.setPermissions(0o600, on: staging)
        let stagingValues = try staging.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard stagingValues.isRegularFile == true,
              stagingValues.isSymbolicLink != true,
              let copiedBytes = stagingValues.fileSize,
              copiedBytes > 0 else {
            throw LoRAStoreError.unsafeSource(source)
        }
        guard Int64(copiedBytes) <= Krea2DiTLoRALoader.maximumFileBytes else {
            throw LoRAStoreError.payloadTooLarge(
                source, maximumBytes: Krea2DiTLoRALoader.maximumFileBytes)
        }
        let digest = try Self.sha256(at: staging)
        if let expectedSHA256,
           digest.caseInsensitiveCompare(expectedSHA256) != .orderedSame {
            throw LoRAStoreError.invalidMetadata(
                "the downloaded adapter does not match its pinned SHA-256")
        }
        if let existing = catalog.assets.first(where: { $0.sha256 == digest }) {
            throw LoRAStoreError.duplicateContent(existing.id)
        }

        // Import validation never needs Metal. Keeping this one-time finite/shape scan on the CPU
        // avoids scheduling GPU completion handlers beside a render and gives the process-wide
        // inference/model-mutation lease a fully host-side save boundary.
        let stats = try MLXRuntimeSafety.withExclusiveCPUOperation {
            try Krea2DiTLoRALoader.inspect(adapters: [.init(path: staging)])
        }
        guard let stats = stats.first else {
            throw LoRAStoreError.invalidMetadata("adapter inspection returned no result")
        }
        let asset = LoRAAsset(
            id: id,
            name: name,
            managedFilename: filename,
            sha256: digest,
            byteCount: Int64(copiedBytes),
            matchedTargets: stats.matchedTargets,
            totalTargets: stats.totalTargets,
            matchedKeys: stats.matchedKeys,
            totalKeys: stats.totalKeys,
            tensorBytes: stats.tensorBytes,
            triggers: try Self.validatedTriggers(triggers),
            origin: origin,
            importedAt: Self.nowToMilliseconds())

        try Self.rename(staging, to: destination)
        var next = catalog
        next.assets.append(asset)
        next.assets.sort { lhs, rhs in
            if lhs.importedAt == rhs.importedAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.importedAt < rhs.importedAt
        }
        if next.active.count < Self.maximumActive {
            next.active.append(.init(assetID: id, scale: 1))
        }
        next.rememberedScales[id.uuidString.lowercased()] = 1
        do {
            try persist(next)
            catalog = next
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return snapshot()
    }

    @discardableResult
    func remove(id: UUID) throws -> LoRALibrarySnapshot {
        guard let asset = catalog.assets.first(where: { $0.id == id }) else {
            throw LoRAStoreError.assetNotFound(id)
        }
        let file = root.appendingPathComponent(asset.managedFilename)
        let trash = root.appendingPathComponent(
            ".trash-\(id.uuidString.lowercased()).safetensors")
        var moved = false
        if FileManager.default.fileExists(atPath: file.path) {
            try Self.rename(file, to: trash)
            moved = true
        }

        var next = catalog
        next.assets.removeAll { $0.id == id }
        next.active.removeAll { $0.assetID == id }
        next.rememberedScales[id.uuidString.lowercased()] = nil
        do {
            try persist(next)
            catalog = next
        } catch {
            if moved { try? Self.rename(trash, to: file) }
            throw error
        }
        if moved { try? FileManager.default.removeItem(at: trash) }
        return snapshot()
    }

    @discardableResult
    func setActive(id: UUID, enabled: Bool) throws -> LoRALibrarySnapshot {
        guard catalog.assets.contains(where: { $0.id == id }) else {
            throw LoRAStoreError.assetNotFound(id)
        }
        var next = catalog
        let alreadyActive = next.active.contains { $0.assetID == id }
        if enabled, !alreadyActive {
            guard next.active.count < Self.maximumActive else {
                throw LoRAStoreError.tooManyActive(Self.maximumActive)
            }
            let remembered = next.rememberedScales[id.uuidString.lowercased()] ?? 1
            next.active.append(.init(assetID: id, scale: remembered))
        } else if !enabled {
            if let selection = next.active.first(where: { $0.assetID == id }) {
                next.rememberedScales[id.uuidString.lowercased()] = selection.scale
            }
            next.active.removeAll { $0.assetID == id }
        }
        try persist(next)
        catalog = next
        return snapshot()
    }

    @discardableResult
    func setScale(id: UUID, scale: Double) throws -> LoRALibrarySnapshot {
        try Self.validate(scale: scale)
        guard let index = catalog.active.firstIndex(where: { $0.assetID == id }) else {
            throw LoRAStoreError.assetNotFound(id)
        }
        var next = catalog
        next.active[index].scale = scale
        next.rememberedScales[id.uuidString.lowercased()] = scale
        try persist(next)
        catalog = next
        return snapshot()
    }

    @discardableResult
    func moveActive(id: UUID, offset: Int) throws -> LoRALibrarySnapshot {
        guard let source = catalog.active.firstIndex(where: { $0.assetID == id }) else {
            throw LoRAStoreError.assetNotFound(id)
        }
        let destination = min(max(0, source + offset), catalog.active.count - 1)
        guard source != destination else { return snapshot() }
        var next = catalog
        let selection = next.active.remove(at: source)
        next.active.insert(selection, at: destination)
        try persist(next)
        catalog = next
        return snapshot()
    }

    @discardableResult
    func updateTriggers(id: UUID, triggers: [String]) throws -> LoRALibrarySnapshot {
        guard let index = catalog.assets.firstIndex(where: { $0.id == id }) else {
            throw LoRAStoreError.assetNotFound(id)
        }
        let validated = try Self.validatedTriggers(triggers)
        var next = catalog
        next.assets[index].triggers = validated
        try persist(next)
        catalog = next
        return snapshot()
    }

    /// Persists the explicit trigger-insertion preference independently from the active stack.
    /// Changing this flag never mutates a prompt; it is consulted only on a future disabled→enabled
    /// adapter transition.
    @discardableResult
    func setAutomaticallyInsertTriggers(
        id: UUID,
        enabled: Bool
    ) throws -> LoRALibrarySnapshot {
        guard let index = catalog.assets.firstIndex(where: { $0.id == id }) else {
            throw LoRAStoreError.assetNotFound(id)
        }
        guard catalog.assets[index].automaticallyInsertTriggers != enabled else {
            return snapshot()
        }
        var next = catalog
        next.assets[index].automaticallyInsertTriggers = enabled
        try persist(next)
        catalog = next
        return snapshot()
    }

    @discardableResult
    func replaceActive(with references: [GenerationRecipe.LoRAReference]) throws -> LoRALibrarySnapshot {
        let selections = try selections(for: references)
        var next = catalog
        next.active = selections
        for selection in selections {
            next.rememberedScales[selection.assetID.uuidString.lowercased()] = selection.scale
        }
        try persist(next)
        catalog = next
        return snapshot()
    }

    func resolve(
        _ references: [GenerationRecipe.LoRAReference]
    ) throws -> [ResolvedAdapter] {
        let selections = try selections(for: references)
        return try zip(references, selections).map { reference, selection in
            guard let asset = catalog.assets.first(where: { $0.id == selection.assetID }) else {
                throw LoRAStoreError.assetNotFound(selection.assetID)
            }
            let url = root.appendingPathComponent(asset.managedFilename)
            try Self.verify(asset: asset, at: url)
            return ResolvedAdapter(reference: reference, asset: asset, url: url)
        }
    }

    private func selections(
        for references: [GenerationRecipe.LoRAReference]
    ) throws -> [LoRASelection] {
        guard references.count <= Self.maximumActive else {
            throw LoRAStoreError.tooManyActive(Self.maximumActive)
        }
        var seen = Set<UUID>()
        return try references.map { reference in
            try Self.validate(scale: reference.scale)
            guard seen.insert(reference.managedID).inserted else {
                throw LoRAStoreError.invalidMetadata("duplicate adapter \(reference.managedID)")
            }
            guard let asset = catalog.assets.first(where: { $0.id == reference.managedID }) else {
                throw LoRAStoreError.assetNotFound(reference.managedID)
            }
            guard asset.sha256.caseInsensitiveCompare(reference.sha256) == .orderedSame else {
                throw LoRAStoreError.assetMismatch(reference.managedID)
            }
            return LoRASelection(assetID: reference.managedID, scale: reference.scale)
        }
    }

    private func persist(_ next: Catalog) throws {
        try Self.validate(catalog: next)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        guard !data.isEmpty, data.count <= Self.maximumCatalogBytes else {
            throw LoRAStoreError.corruptCatalog("encoded catalog exceeds the safety limit")
        }
        let temporary = root.appendingPathComponent(".catalog-\(UUID().uuidString.lowercased()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        try Self.setPermissions(0o600, on: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        try Self.rename(temporary, to: catalogURL)
    }

    private static func loadCatalogIfPresent(from url: URL) throws -> Catalog {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Catalog(
                schemaVersion: schemaVersion,
                assets: [],
                active: [],
                rememberedScales: [:])
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumCatalogBytes else {
            throw LoRAStoreError.corruptCatalog("catalog file type or size is unsafe")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let header: CatalogHeader
        do {
            header = try decoder.decode(CatalogHeader.self, from: data)
        } catch {
            throw LoRAStoreError.corruptCatalog("missing schema version")
        }
        guard header.schemaVersion == schemaVersion else {
            throw LoRAStoreError.unsupportedCatalogVersion(header.schemaVersion)
        }
        do {
            return try decoder.decode(Catalog.self, from: data)
        } catch {
            throw LoRAStoreError.corruptCatalog(error.localizedDescription)
        }
    }

    private static func validate(catalog: Catalog) throws {
        guard catalog.schemaVersion == schemaVersion else {
            throw LoRAStoreError.unsupportedCatalogVersion(catalog.schemaVersion)
        }
        guard catalog.assets.count <= maximumAssets else {
            throw LoRAStoreError.corruptCatalog("too many assets")
        }
        guard catalog.active.count <= maximumActive else {
            throw LoRAStoreError.corruptCatalog("too many active adapters")
        }
        var ids = Set<UUID>()
        var hashes = Set<String>()
        for asset in catalog.assets {
            guard ids.insert(asset.id).inserted,
                  hashes.insert(asset.sha256.lowercased()).inserted else {
                throw LoRAStoreError.corruptCatalog("duplicate ID or SHA-256")
            }
            guard asset.managedFilename == "\(asset.id.uuidString.lowercased()).safetensors",
                  isSHA256(asset.sha256),
                  asset.byteCount > 0,
                  asset.byteCount <= Krea2DiTLoRALoader.maximumFileBytes,
                  asset.tensorBytes > 0,
                  asset.matchedTargets > 0,
                  asset.totalTargets >= asset.matchedTargets,
                  asset.matchedKeys > 0,
                  asset.totalKeys >= asset.matchedKeys else {
                throw LoRAStoreError.corruptCatalog("invalid asset record")
            }
            _ = try validatedName(asset.name)
            _ = try validatedTriggers(asset.triggers)
            switch asset.origin.kind {
            case .localImport:
                guard asset.origin == .localImport else {
                    throw LoRAStoreError.corruptCatalog("invalid local adapter origin")
                }
            case .officialKreaStyle:
                guard let style = OfficialKreaStyleLoRACatalog.style(
                    matchingSHA256: asset.sha256),
                      asset.origin == style.origin,
                      asset.byteCount == style.byteCount else {
                    throw LoRAStoreError.corruptCatalog("unrecognized official Krea adapter origin")
                }
            }
        }
        var activeIDs = Set<UUID>()
        for selection in catalog.active {
            guard ids.contains(selection.assetID), activeIDs.insert(selection.assetID).inserted else {
                throw LoRAStoreError.corruptCatalog("invalid active stack")
            }
            try validate(scale: selection.scale)
        }
        for (key, scale) in catalog.rememberedScales {
            guard let id = UUID(uuidString: key),
                  key == id.uuidString.lowercased(),
                  ids.contains(id) else {
                throw LoRAStoreError.corruptCatalog("invalid remembered scale key")
            }
            try validate(scale: scale)
        }
    }

    private static func validatedName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumNameBytes,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw LoRAStoreError.invalidMetadata("name is empty, too long, or contains control characters")
        }
        return value
    }

    private static func validatedTriggers(_ triggers: [String]) throws -> [String] {
        guard triggers.count <= maximumTriggerCount else {
            throw LoRAStoreError.invalidMetadata("at most \(maximumTriggerCount) trigger phrases are allowed")
        }
        let equivalence: String.CompareOptions = [
            .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
        ]
        var seen: [String] = []
        return try triggers.map { trigger in
            let value = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= maximumTriggerBytes,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !seen.contains(where: {
                      $0.compare(value, options: equivalence) == .orderedSame
                  }) else {
                throw LoRAStoreError.invalidMetadata("trigger phrases must be short, unique, and printable")
            }
            seen.append(value)
            return value
        }
    }

    private static func validate(scale: Double) throws {
        guard scale.isFinite, scale >= 0.01,
              scale <= GenerationRecipe.maximumLoRAScale else {
            throw LoRAStoreError.invalidScale(scale)
        }
    }

    private static func verify(asset: LoRAAsset, at url: URL) throws {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize.map(Int64.init) == asset.byteCount,
                  FileManager.default.isReadableFile(atPath: url.path),
                  try sha256(at: url).caseInsensitiveCompare(asset.sha256) == .orderedSame else {
                throw LoRAStoreError.tamperedAsset(asset.id)
            }
        } catch is LoRAStoreError {
            throw LoRAStoreError.tamperedAsset(asset.id)
        } catch {
            throw LoRAStoreError.tamperedAsset(asset.id)
        }
    }

    private static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func nowToMilliseconds() -> Date {
        let milliseconds = floor(Date().timeIntervalSince1970 * 1_000)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ("0" ... "9").contains(Character(String($0)))
                || ("a" ... "f").contains(Character(String($0)))
        }
    }

    private static func ensureManagedDirectory(_ root: URL) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LoRAStoreError.unsafeRoot(root)
            }
        } else {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        }
        try setPermissions(0o700, on: root)
    }

    private static func recoverInterruptedRemovals(in root: URL, catalog: Catalog) throws {
        let assetsByID = Dictionary(uniqueKeysWithValues: catalog.assets.map { ($0.id, $0) })
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [])
        for trash in files where trash.lastPathComponent.hasPrefix(".trash-")
            && trash.pathExtension.lowercased() == "safetensors" {
            let stem = trash.deletingPathExtension().lastPathComponent
            let idText = String(stem.dropFirst(".trash-".count))
            guard let id = UUID(uuidString: idText), let asset = assetsByID[id] else {
                try? FileManager.default.removeItem(at: trash)
                continue
            }
            let destination = root.appendingPathComponent(asset.managedFilename)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: trash)
            } else {
                try verify(asset: asset, at: trash)
                try rename(trash, to: destination)
            }
        }
    }

    private static func quarantineAbandonedManagedFiles(
        in root: URL,
        keeping: Set<String>
    ) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        let abandoned = files.filter { file in
            guard file.pathExtension.lowercased() == "safetensors" else { return false }
            let stem = file.deletingPathExtension().lastPathComponent
            return UUID(uuidString: stem) != nil && !keeping.contains(file.lastPathComponent)
        }
        if !abandoned.isEmpty {
            let quarantine = root.appendingPathComponent("Orphans", isDirectory: true)
            if FileManager.default.fileExists(atPath: quarantine.path) {
                let values = try quarantine.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw LoRAStoreError.unsafeRoot(quarantine)
                }
            } else {
                try FileManager.default.createDirectory(
                    at: quarantine,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            }
            try setPermissions(0o700, on: quarantine)
            for file in abandoned {
                var destination = quarantine.appendingPathComponent(file.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    destination = quarantine.appendingPathComponent(
                        "\(file.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.lowercased()).safetensors")
                }
                try rename(file, to: destination)
            }
        }
        let hidden = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [])
        for file in hidden where file.lastPathComponent.hasPrefix(".import-")
            || file.lastPathComponent.hasPrefix(".trash-")
            || file.lastPathComponent.hasPrefix(".catalog-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func setPermissions(_ mode: mode_t, on url: URL) throws {
        let result = url.path.withCString { Darwin.chmod($0, mode) }
        guard result == 0 else {
            throw LoRAStoreError.posixFailure(operation: "chmod", code: errno)
        }
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw LoRAStoreError.posixFailure(operation: "rename", code: errno)
        }
    }
}
