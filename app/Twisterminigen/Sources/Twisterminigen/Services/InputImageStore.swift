import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct InputImageStoreLimits: Sendable, Equatable {
    static let standard = InputImageStoreLimits()

    let maximumSourceBytes: Int64
    let maximumManagedPNGBytes: Int64
    let maximumPixelCount: Int64
    let maximumDimension: Int

    init(
        maximumSourceBytes: Int64 = 64 * 1_024 * 1_024,
        maximumManagedPNGBytes: Int64 = 192 * 1_024 * 1_024,
        maximumPixelCount: Int64 = 40_000_000,
        maximumDimension: Int = 16_384
    ) {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumManagedPNGBytes = maximumManagedPNGBytes
        self.maximumPixelCount = maximumPixelCount
        self.maximumDimension = maximumDimension
    }
}

enum InputImageStoreError: Error, Equatable, Sendable {
    case unavailable(String)
    case unsafeRoot(URL)
    case unsafeSource(URL)
    case payloadTooLarge(maximumBytes: Int64)
    case imageTooLarge(width: Int, height: Int, maximumPixels: Int64)
    case unsupportedFormat
    case decodeFailed
    case encodeFailed
    case unsupportedCatalogVersion(Int)
    case corruptCatalog(String)
    case duplicateContent(UUID)
    case assetNotFound(UUID)
    case assetMismatch(UUID)
    case tamperedAsset(UUID)
    case invalidTargetSize(width: Int, height: Int)
    case invalidCrop
    case posixFailure(operation: String, code: Int32)
}

extension InputImageStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .unsafeRoot(let url):
            return "The input image library folder is unsafe: \(url.path)"
        case .unsafeSource(let url):
            return "The selected input image is not a readable regular file: \(url.lastPathComponent)"
        case .payloadTooLarge(let maximumBytes):
            return "The input image exceeds the \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)) safety limit."
        case .imageTooLarge(let width, let height, let maximumPixels):
            return "The \(width)x\(height) input image exceeds the \(maximumPixels)-pixel safety limit."
        case .unsupportedFormat:
            return "Only PNG, JPEG, and HEIC input images are supported."
        case .decodeFailed: return "The input image could not be decoded safely."
        case .encodeFailed: return "The managed PNG could not be encoded."
        case .unsupportedCatalogVersion(let version):
            return "This input image catalog was written by a newer app version (schema \(version))."
        case .corruptCatalog(let reason):
            return "The input image catalog is invalid: \(reason)"
        case .duplicateContent:
            return "That exact input image is already in the library."
        case .assetNotFound:
            return "A referenced input image is no longer in the library."
        case .assetMismatch:
            return "A referenced input image no longer matches its saved recipe."
        case .tamperedAsset:
            return "A managed input image changed after import. Remove it and import the original again."
        case .invalidTargetSize(let width, let height):
            return "The input image target size \(width)x\(height) is invalid."
        case .invalidCrop:
            return "The input image crop must be a nonempty normalized rectangle."
        case let .posixFailure(operation, code):
            return "Input image storage failed during \(operation) (POSIX \(code))."
        }
    }
}

actor InputImageStore {
    static let schemaVersion = 1
    static let maximumCatalogBytes = 2 * 1_024 * 1_024
    static let maximumAssets = 512

    struct ResolvedImage: Sendable, Equatable {
        let reference: GenerationRecipe.InputImageReference
        let asset: InputImageAsset
        let url: URL
    }

    private struct Catalog: Codable, Sendable, Equatable {
        var schemaVersion: Int
        var assets: [InputImageAsset]
    }

    private struct CatalogHeader: Decodable {
        let schemaVersion: Int
    }

    private let root: URL
    private let catalogURL: URL
    private let limits: InputImageStoreLimits
    private var catalog: Catalog

    init(
        root: URL = AppPaths.inputImages,
        limits: InputImageStoreLimits = .standard
    ) throws {
        let root = root.standardizedFileURL
        try Self.validate(limits: limits)
        try Self.validateManagedDirectoryIfPresent(root)
        let catalogURL = root.appendingPathComponent("catalog.json")
        let catalog = try Self.loadCatalogIfPresent(from: catalogURL)
        try Self.validate(catalog: catalog, limits: limits)

        self.root = root
        self.catalogURL = catalogURL
        self.limits = limits
        self.catalog = catalog

        try Self.ensureManagedDirectory(root)
        try Self.enforcePermissions(for: catalog, root: root, catalogURL: catalogURL)
        try Self.recoverInterruptedRemovals(in: root, catalog: catalog)
        try Self.quarantineAbandonedManagedFiles(
            in: root,
            keeping: Set(catalog.assets.map(\.managedFilename)))
    }

    func snapshot() -> InputImageLibrarySnapshot {
        InputImageLibrarySnapshot(assets: catalog.assets)
    }

    @discardableResult
    func `import`(sourceURL: URL) throws -> InputImageAsset {
        guard catalog.assets.count < Self.maximumAssets else {
            throw InputImageStoreError.corruptCatalog(
                "the library limit is \(Self.maximumAssets) images")
        }
        let sourceURL = sourceURL.standardizedFileURL
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let data: Data
        do {
            data = try Self.readBoundedRegularFile(
                at: sourceURL,
                maximumBytes: limits.maximumSourceBytes)
        } catch BoundedFileReadError.tooLarge {
            throw InputImageStoreError.payloadTooLarge(
                maximumBytes: limits.maximumSourceBytes)
        } catch {
            throw InputImageStoreError.unsafeSource(sourceURL)
        }
        let canonical = try InputImageCodec.canonicalize(
            data,
            allowedFormats: .supported,
            limits: limits)
        return try store(canonical)
    }

    @discardableResult
    func importPNGData(_ data: Data) throws -> InputImageAsset {
        guard catalog.assets.count < Self.maximumAssets else {
            throw InputImageStoreError.corruptCatalog(
                "the library limit is \(Self.maximumAssets) images")
        }
        guard !data.isEmpty else { throw InputImageStoreError.decodeFailed }
        guard Int64(data.count) <= limits.maximumSourceBytes else {
            throw InputImageStoreError.payloadTooLarge(
                maximumBytes: limits.maximumSourceBytes)
        }
        let canonical = try InputImageCodec.canonicalize(
            data,
            allowedFormats: .pngOnly,
            limits: limits)
        return try store(canonical)
    }

    func resolve(
        _ reference: GenerationRecipe.InputImageReference
    ) throws -> ResolvedImage {
        guard let asset = catalog.assets.first(where: { $0.id == reference.managedID }) else {
            throw InputImageStoreError.assetNotFound(reference.managedID)
        }
        guard asset.sha256.caseInsensitiveCompare(reference.sha256) == .orderedSame else {
            throw InputImageStoreError.assetMismatch(reference.managedID)
        }
        let url = root.appendingPathComponent(asset.managedFilename)
        try Self.verify(asset: asset, at: url)
        return ResolvedImage(reference: reference, asset: asset, url: url)
    }

    func managedPNGData(
        _ reference: GenerationRecipe.InputImageReference
    ) throws -> Data {
        let resolved = try resolve(reference)
        let data = try Self.readBoundedRegularFile(
            at: resolved.url,
            maximumBytes: limits.maximumManagedPNGBytes)
        guard Int64(data.count) == resolved.asset.byteCount,
              Self.sha256(data) == resolved.asset.sha256 else {
            throw InputImageStoreError.tamperedAsset(resolved.asset.id)
        }
        return data
    }

    /// Returns an ephemeral, upright PNG for AppKit previews without changing the verified
    /// schema-v1 managed asset. Schema v1 historically stores the canonical raster vertically
    /// inverted; inference preprocessing compensates for that layout separately and must continue
    /// to consume `managedPNGData(_:)` unchanged.
    func managedPreviewPNGData(
        _ reference: GenerationRecipe.InputImageReference
    ) throws -> Data {
        let data = try managedPNGData(reference)
        return try InputImageCodec.uprightPreviewPNGForSchemaV1(
            data,
            limits: limits)
    }

    func prepare(
        _ reference: GenerationRecipe.InputImageReference,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> InputImagePlanarRGB {
        let data = try managedPNGData(reference)
        return try InputImagePreprocessor.preprocess(
            pngData: data,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            resizeMode: reference.resize,
            crop: reference.crop)
    }

    @discardableResult
    func remove(id: UUID) throws -> InputImageLibrarySnapshot {
        guard let asset = catalog.assets.first(where: { $0.id == id }) else {
            throw InputImageStoreError.assetNotFound(id)
        }
        let file = root.appendingPathComponent(asset.managedFilename)
        let trash = root.appendingPathComponent(
            ".trash-\(id.uuidString.lowercased()).png")
        var moved = false
        if try Self.pathStatus(at: file) != nil {
            guard try Self.pathStatus(at: trash) == nil else {
                throw InputImageStoreError.unavailable(
                    "An unfinished removal already exists for this input image.")
            }
            try Self.rename(file, to: trash)
            try Self.synchronizeDirectory(root)
            moved = true
        }

        var next = catalog
        next.assets.removeAll { $0.id == id }
        do {
            try persist(next)
            catalog = next
        } catch {
            if moved, (try? Self.pathStatus(at: file)) == nil {
                try? Self.rename(trash, to: file)
                try? Self.synchronizeDirectory(root)
            }
            throw error
        }
        if moved {
            try? FileManager.default.removeItem(at: trash)
            try? Self.synchronizeDirectory(root)
        }
        return snapshot()
    }

    private func store(_ canonical: InputImageCodec.CanonicalImage) throws -> InputImageAsset {
        let digest = Self.sha256(canonical.pngData)
        if let existing = catalog.assets.first(where: { $0.sha256 == digest }) {
            throw InputImageStoreError.duplicateContent(existing.id)
        }

        let id = UUID()
        let idText = id.uuidString.lowercased()
        let filename = "\(idText).png"
        let staging = root.appendingPathComponent(".import-\(idText).png")
        let destination = root.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: staging) }

        try Self.writeExclusive(canonical.pngData, to: staging)
        guard try Self.pathStatus(at: destination) == nil else {
            throw InputImageStoreError.unavailable(
                "A managed input image UUID collision occurred.")
        }
        try Self.rename(staging, to: destination)
        try Self.synchronizeDirectory(root)

        let asset = InputImageAsset(
            id: id,
            managedFilename: filename,
            sha256: digest,
            byteCount: Int64(canonical.pngData.count),
            width: canonical.width,
            height: canonical.height,
            importedAt: Self.nowToMilliseconds())
        var next = catalog
        next.assets.append(asset)
        next.assets.sort { lhs, rhs in
            if lhs.importedAt == rhs.importedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.importedAt < rhs.importedAt
        }
        do {
            try persist(next)
            catalog = next
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try? Self.synchronizeDirectory(root)
            throw error
        }
        return asset
    }

    private func persist(_ next: Catalog) throws {
        try Self.validate(catalog: next, limits: limits)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        guard !data.isEmpty, data.count <= Self.maximumCatalogBytes else {
            throw InputImageStoreError.corruptCatalog(
                "encoded catalog exceeds the safety limit")
        }
        let temporary = root.appendingPathComponent(
            ".catalog-\(UUID().uuidString.lowercased()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.writeExclusive(data, to: temporary)
        try Self.rename(temporary, to: catalogURL)
        try Self.synchronizeDirectory(root)
    }

    private static func validate(limits: InputImageStoreLimits) throws {
        guard limits.maximumSourceBytes > 0,
              limits.maximumManagedPNGBytes > 0,
              limits.maximumPixelCount > 0,
              limits.maximumDimension > 0 else {
            throw InputImageStoreError.unavailable("Input image safety limits are invalid.")
        }
    }

    private static func loadCatalogIfPresent(from url: URL) throws -> Catalog {
        guard let status = try pathStatus(at: url) else {
            return Catalog(schemaVersion: schemaVersion, assets: [])
        }
        guard isRegularFile(status), !isSymbolicLink(status),
              status.st_size > 0,
              status.st_size <= off_t(maximumCatalogBytes) else {
            throw InputImageStoreError.corruptCatalog(
                "catalog file type or size is unsafe")
        }
        let data: Data
        do {
            data = try readBoundedRegularFile(
                at: url,
                maximumBytes: Int64(maximumCatalogBytes))
        } catch {
            throw InputImageStoreError.corruptCatalog(
                "catalog file could not be read safely")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let header: CatalogHeader
        do {
            header = try decoder.decode(CatalogHeader.self, from: data)
        } catch {
            throw InputImageStoreError.corruptCatalog("missing schema version")
        }
        guard header.schemaVersion == schemaVersion else {
            throw InputImageStoreError.unsupportedCatalogVersion(header.schemaVersion)
        }
        do {
            return try decoder.decode(Catalog.self, from: data)
        } catch {
            throw InputImageStoreError.corruptCatalog(error.localizedDescription)
        }
    }

    private static func validate(
        catalog: Catalog,
        limits: InputImageStoreLimits
    ) throws {
        guard catalog.schemaVersion == schemaVersion else {
            throw InputImageStoreError.unsupportedCatalogVersion(catalog.schemaVersion)
        }
        guard catalog.assets.count <= maximumAssets else {
            throw InputImageStoreError.corruptCatalog("too many assets")
        }
        var ids = Set<UUID>()
        var hashes = Set<String>()
        for asset in catalog.assets {
            guard ids.insert(asset.id).inserted,
                  hashes.insert(asset.sha256).inserted else {
                throw InputImageStoreError.corruptCatalog("duplicate ID or SHA-256")
            }
            guard asset.managedFilename == "\(asset.id.uuidString.lowercased()).png",
                  isSHA256(asset.sha256),
                  asset.byteCount > 0,
                  asset.byteCount <= limits.maximumManagedPNGBytes,
                  dimensionsAreSafe(
                    width: asset.width,
                    height: asset.height,
                    limits: limits),
                  asset.importedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw InputImageStoreError.corruptCatalog("invalid asset record")
            }
        }
    }

    private static func validateManagedDirectoryIfPresent(_ root: URL) throws {
        guard let status = try pathStatus(at: root) else { return }
        guard isDirectory(status), !isSymbolicLink(status) else {
            throw InputImageStoreError.unsafeRoot(root)
        }
    }

    private static func ensureManagedDirectory(_ root: URL) throws {
        if try pathStatus(at: root) == nil {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        }
        try validateManagedDirectoryIfPresent(root)
        try setPermissions(0o700, on: root)
    }

    private static func enforcePermissions(
        for catalog: Catalog,
        root: URL,
        catalogURL: URL
    ) throws {
        if let status = try pathStatus(at: catalogURL),
           isRegularFile(status), !isSymbolicLink(status) {
            try setPermissions(0o600, on: catalogURL)
        }
        for asset in catalog.assets {
            let url = root.appendingPathComponent(asset.managedFilename)
            if let status = try pathStatus(at: url),
               isRegularFile(status), !isSymbolicLink(status) {
                try setPermissions(0o600, on: url)
            }
        }
    }

    private static func recoverInterruptedRemovals(
        in root: URL,
        catalog: Catalog
    ) throws {
        let assetsByID = Dictionary(uniqueKeysWithValues: catalog.assets.map { ($0.id, $0) })
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [])
        for trash in files where trash.lastPathComponent.hasPrefix(".trash-")
            && trash.pathExtension.lowercased() == "png" {
            let stem = trash.deletingPathExtension().lastPathComponent
            let idText = String(stem.dropFirst(".trash-".count))
            guard let id = UUID(uuidString: idText), let asset = assetsByID[id],
                  let status = try pathStatus(at: trash),
                  isRegularFile(status), !isSymbolicLink(status) else {
                continue
            }
            let destination = root.appendingPathComponent(asset.managedFilename)
            guard try pathStatus(at: destination) == nil else { continue }
            do {
                try verify(asset: asset, at: trash)
                try rename(trash, to: destination)
                try setPermissions(0o600, on: destination)
                try synchronizeDirectory(root)
            } catch InputImageStoreError.tamperedAsset {
                continue
            }
        }
    }

    private static func quarantineAbandonedManagedFiles(
        in root: URL,
        keeping: Set<String>
    ) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [])
        let abandoned = files.filter { file in
            let name = file.lastPathComponent
            if name.hasPrefix(".import-") && file.pathExtension.lowercased() == "png" {
                return true
            }
            if name.hasPrefix(".trash-") && file.pathExtension.lowercased() == "png" {
                return true
            }
            if name.hasPrefix(".catalog-") && file.pathExtension.lowercased() == "tmp" {
                return true
            }
            guard file.pathExtension.lowercased() == "png",
                  UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else {
                return false
            }
            return !keeping.contains(name)
        }
        guard !abandoned.isEmpty else { return }

        let quarantine = root.appendingPathComponent("Orphans", isDirectory: true)
        try ensurePrivateDirectory(quarantine)
        for file in abandoned {
            guard let status = try pathStatus(at: file) else { continue }
            var destination = quarantine.appendingPathComponent(file.lastPathComponent)
            if try pathStatus(at: destination) != nil {
                let extensionName = file.pathExtension
                let stem = file.deletingPathExtension().lastPathComponent
                destination = quarantine.appendingPathComponent(
                    "\(stem)-\(UUID().uuidString.lowercased()).\(extensionName)")
            }
            try rename(file, to: destination)
            if !isSymbolicLink(status) {
                try setPermissions(isDirectory(status) ? 0o700 : 0o600, on: destination)
            }
        }
        try synchronizeDirectory(quarantine)
        try synchronizeDirectory(root)
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        if let status = try pathStatus(at: url) {
            guard isDirectory(status), !isSymbolicLink(status) else {
                throw InputImageStoreError.unsafeRoot(url)
            }
        } else {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        }
        try setPermissions(0o700, on: url)
    }

    private static func verify(asset: InputImageAsset, at url: URL) throws {
        do {
            guard let status = try pathStatus(at: url),
                  isRegularFile(status), !isSymbolicLink(status),
                  Int64(status.st_size) == asset.byteCount,
                  try sha256(at: url, expectedBytes: asset.byteCount) == asset.sha256 else {
                throw InputImageStoreError.tamperedAsset(asset.id)
            }
        } catch {
            throw InputImageStoreError.tamperedAsset(asset.id)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(at url: URL, expectedBytes: Int64) throws -> String {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw InputImageStoreError.posixFailure(operation: "open", code: errno)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              isRegularFile(status),
              Int64(status.st_size) == expectedBytes else {
            throw InputImageStoreError.posixFailure(operation: "fstat", code: errno)
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw InputImageStoreError.posixFailure(operation: "read", code: errno)
            }
            if count == 0 { break }
            total += Int64(count)
            guard total <= expectedBytes else {
                throw InputImageStoreError.unavailable("Managed input image size changed while reading.")
            }
            buffer.withUnsafeBytes { bytes in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: bytes.baseAddress,
                    count: count))
            }
        }
        guard total == expectedBytes else {
            throw InputImageStoreError.unavailable("Managed input image size changed while reading.")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readBoundedRegularFile(
        at url: URL,
        maximumBytes: Int64
    ) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw BoundedFileReadError.unsafe }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              isRegularFile(status),
              !isSymbolicLink(status),
              status.st_size > 0 else {
            throw BoundedFileReadError.unsafe
        }
        guard Int64(status.st_size) <= maximumBytes else {
            throw BoundedFileReadError.tooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw BoundedFileReadError.unsafe }
            if count == 0 { break }
            guard Int64(data.count) <= maximumBytes - Int64(count) else {
                throw BoundedFileReadError.tooLarge
            }
            buffer.withUnsafeBytes { bytes in
                data.append(bytes.bindMemory(to: UInt8.self).baseAddress!, count: count)
            }
        }
        guard !data.isEmpty else { throw BoundedFileReadError.unsafe }
        return data
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw InputImageStoreError.posixFailure(operation: "open", code: errno)
        }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove { try? FileManager.default.removeItem(at: url) }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw InputImageStoreError.posixFailure(operation: "write", code: errno)
                }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw InputImageStoreError.posixFailure(operation: "fsync", code: errno)
        }
        shouldRemove = false
    }

    private static func pathStatus(at url: URL) throws -> stat? {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result == 0 { return status }
        if errno == ENOENT { return nil }
        throw InputImageStoreError.posixFailure(operation: "lstat", code: errno)
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
    }

    private static func isDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
    }

    private static func isSymbolicLink(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFLNK
    }

    private static func setPermissions(_ mode: mode_t, on url: URL) throws {
        let result = url.path.withCString { Darwin.chmod($0, mode) }
        guard result == 0 else {
            throw InputImageStoreError.posixFailure(operation: "chmod", code: errno)
        }
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw InputImageStoreError.posixFailure(operation: "rename", code: errno)
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw InputImageStoreError.posixFailure(operation: "open directory", code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 || errno == EINVAL else {
            throw InputImageStoreError.posixFailure(operation: "fsync directory", code: errno)
        }
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

    fileprivate static func dimensionsAreSafe(
        width: Int,
        height: Int,
        limits: InputImageStoreLimits
    ) -> Bool {
        guard width > 0, height > 0,
              width <= limits.maximumDimension,
              height <= limits.maximumDimension else { return false }
        return Int64(width) <= limits.maximumPixelCount / Int64(height)
    }
}

enum InputImagePreprocessor {
    /// Pure host preprocessing. `pngData` is decoded without file-system access.
    static func preprocess(
        pngData: Data,
        targetWidth: Int,
        targetHeight: Int,
        resizeMode: GenerationRecipe.ResizeMode,
        crop: GenerationRecipe.NormalizedRect? = nil
    ) throws -> InputImagePlanarRGB {
        let limits = InputImageStoreLimits.standard
        guard InputImageStore.dimensionsAreSafe(
            width: targetWidth,
            height: targetHeight,
            limits: limits) else {
            throw InputImageStoreError.invalidTargetSize(
                width: targetWidth,
                height: targetHeight)
        }
        let raster = try InputImageCodec.decodePNG(pngData, limits: limits)
        let base = try samplingRect(for: crop, width: raster.width, height: raster.height)
        let destination: DestinationRect
        let source: SamplingRect

        switch resizeMode {
        case .stretch:
            source = base
            destination = DestinationRect(
                x: 0, y: 0, width: targetWidth, height: targetHeight)
        case .fit:
            let widthLimited = Int64(targetWidth) * Int64(base.height)
                <= Int64(targetHeight) * Int64(base.width)
            let contentWidth: Int
            let contentHeight: Int
            if widthLimited {
                contentWidth = targetWidth
                contentHeight = max(
                    1,
                    roundedDivision(
                        Int64(base.height) * Int64(targetWidth),
                        by: Int64(base.width)))
            } else {
                contentHeight = targetHeight
                contentWidth = max(
                    1,
                    roundedDivision(
                        Int64(base.width) * Int64(targetHeight),
                        by: Int64(base.height)))
            }
            source = base
            destination = DestinationRect(
                x: (targetWidth - contentWidth) / 2,
                y: (targetHeight - contentHeight) / 2,
                width: contentWidth,
                height: contentHeight)
        case .fill:
            let sourceAspect = base.width / base.height
            let targetAspect = Double(targetWidth) / Double(targetHeight)
            if sourceAspect > targetAspect {
                let width = base.height * targetAspect
                source = SamplingRect(
                    x: base.x + (base.width - width) / 2,
                    y: base.y,
                    width: width,
                    height: base.height,
                    clampX0: base.clampX0,
                    clampY0: base.clampY0,
                    clampX1: base.clampX1,
                    clampY1: base.clampY1)
            } else {
                let height = base.width / targetAspect
                source = SamplingRect(
                    x: base.x,
                    y: base.y + (base.height - height) / 2,
                    width: base.width,
                    height: height,
                    clampX0: base.clampX0,
                    clampY0: base.clampY0,
                    clampX1: base.clampX1,
                    clampY1: base.clampY1)
            }
            destination = DestinationRect(
                x: 0, y: 0, width: targetWidth, height: targetHeight)
        }

        let planeSize = targetWidth * targetHeight
        var values = [Float](repeating: 0, count: planeSize * 3)
        for destinationY in 0 ..< destination.height {
            let sourceY = source.y
                + (Double(destinationY) + 0.5) * source.height / Double(destination.height)
                - 0.5
            for destinationX in 0 ..< destination.width {
                let sourceX = source.x
                    + (Double(destinationX) + 0.5) * source.width / Double(destination.width)
                    - 0.5
                let rgb = raster.sample(
                    x: min(max(sourceX, source.clampX0), source.clampX1),
                    y: min(max(sourceY, source.clampY0), source.clampY1))
                let outputIndex = (destination.y + destinationY) * targetWidth
                    + destination.x + destinationX
                values[outputIndex] = rgb.0 / 127.5 - 1
                values[planeSize + outputIndex] = rgb.1 / 127.5 - 1
                values[planeSize * 2 + outputIndex] = rgb.2 / 127.5 - 1
            }
        }
        return InputImagePlanarRGB(
            width: targetWidth,
            height: targetHeight,
            values: values)
    }

    private static func samplingRect(
        for crop: GenerationRecipe.NormalizedRect?,
        width: Int,
        height: Int
    ) throws -> SamplingRect {
        guard let crop else {
            return SamplingRect(
                x: 0,
                y: 0,
                width: Double(width),
                height: Double(height),
                clampX0: 0,
                clampY0: 0,
                clampX1: Double(width - 1),
                clampY1: Double(height - 1))
        }
        let values = [crop.x0, crop.y0, crop.x1, crop.y1]
        guard values.allSatisfy(\.isFinite),
              crop.x0 >= 0, crop.y0 >= 0,
              crop.x1 <= 1, crop.y1 <= 1,
              crop.x0 < crop.x1, crop.y0 < crop.y1 else {
            throw InputImageStoreError.invalidCrop
        }
        let left = min(width - 1, max(0, Int(floor(crop.x0 * Double(width)))))
        let top = min(height - 1, max(0, Int(floor(crop.y0 * Double(height)))))
        let right = min(width, max(left + 1, Int(ceil(crop.x1 * Double(width)))))
        let bottom = min(height, max(top + 1, Int(ceil(crop.y1 * Double(height)))))
        return SamplingRect(
            x: Double(left),
            y: Double(top),
            width: Double(right - left),
            height: Double(bottom - top),
            clampX0: Double(left),
            clampY0: Double(top),
            clampX1: Double(right - 1),
            clampY1: Double(bottom - 1))
    }

    private static func roundedDivision(_ numerator: Int64, by denominator: Int64) -> Int {
        Int((numerator + denominator / 2) / denominator)
    }

    private struct SamplingRect {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let clampX0: Double
        let clampY0: Double
        let clampX1: Double
        let clampY1: Double
    }

    private struct DestinationRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
}

private enum BoundedFileReadError: Error {
    case unsafe
    case tooLarge
}

private enum InputImageCodec {
    enum AllowedFormats {
        case supported
        case pngOnly
    }

    struct CanonicalImage {
        let pngData: Data
        let width: Int
        let height: Int
    }

    struct Raster {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        func sample(x: Double, y: Double) -> (Float, Float, Float) {
            let x0 = Int(floor(x))
            let y0 = Int(floor(y))
            let x1 = min(width - 1, x0 + 1)
            let y1 = min(height - 1, y0 + 1)
            let fx = Float(x - Double(x0))
            let fy = Float(y - Double(y0))
            let topLeft = (y0 * width + x0) * 4
            let topRight = (y0 * width + x1) * 4
            let bottomLeft = (y1 * width + x0) * 4
            let bottomRight = (y1 * width + x1) * 4

            func channel(_ offset: Int) -> Float {
                let top = Float(rgba[topLeft + offset]) * (1 - fx)
                    + Float(rgba[topRight + offset]) * fx
                let bottom = Float(rgba[bottomLeft + offset]) * (1 - fx)
                    + Float(rgba[bottomRight + offset]) * fx
                return top * (1 - fy) + bottom * fy
            }
            return (channel(0), channel(1), channel(2))
        }
    }

    static func canonicalize(
        _ data: Data,
        allowedFormats: AllowedFormats,
        limits: InputImageStoreLimits
    ) throws -> CanonicalImage {
        guard !data.isEmpty else { throw InputImageStoreError.decodeFailed }
        guard Int64(data.count) <= limits.maximumSourceBytes else {
            throw InputImageStoreError.payloadTooLarge(
                maximumBytes: limits.maximumSourceBytes)
        }
        let image = try decodedImage(
            data,
            allowedFormats: allowedFormats,
            maximumBytes: limits.maximumSourceBytes,
            limits: limits)
        let canonical = try opaqueSRGBImage(from: image)
        let pngData = try encodePNG(
            canonical,
            maximumBytes: limits.maximumManagedPNGBytes)
        return CanonicalImage(
            pngData: pngData,
            width: canonical.width,
            height: canonical.height)
    }

    /// Schema-v1 managed PNGs already contain the canonical raster produced by
    /// `opaqueSRGBImage(from:)`, whose historical coordinate transform inverted the visible
    /// vertical orientation. Reapplying that transform only to an in-memory preview restores the
    /// source orientation while preserving managed bytes, catalog hashes, and inference behavior.
    static func uprightPreviewPNGForSchemaV1(
        _ data: Data,
        limits: InputImageStoreLimits
    ) throws -> Data {
        guard !data.isEmpty else { throw InputImageStoreError.decodeFailed }
        guard Int64(data.count) <= limits.maximumManagedPNGBytes else {
            throw InputImageStoreError.payloadTooLarge(
                maximumBytes: limits.maximumManagedPNGBytes)
        }
        let image = try decodedImage(
            data,
            allowedFormats: .pngOnly,
            maximumBytes: limits.maximumManagedPNGBytes,
            limits: limits)
        let upright = try opaqueSRGBImage(from: image)
        return try encodePNG(
            upright,
            maximumBytes: limits.maximumManagedPNGBytes)
    }

    private static func encodePNG(
        _ image: CGImage,
        maximumBytes: Int64
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil) else {
            throw InputImageStoreError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw InputImageStoreError.encodeFailed
        }
        let pngData = output as Data
        guard !pngData.isEmpty,
              Int64(pngData.count) <= maximumBytes else {
            throw InputImageStoreError.payloadTooLarge(
                maximumBytes: maximumBytes)
        }
        return pngData
    }

    static func decodePNG(
        _ data: Data,
        limits: InputImageStoreLimits
    ) throws -> Raster {
        guard !data.isEmpty else { throw InputImageStoreError.decodeFailed }
        guard Int64(data.count) <= limits.maximumManagedPNGBytes else {
            throw InputImageStoreError.payloadTooLarge(
                maximumBytes: limits.maximumManagedPNGBytes)
        }
        let image = try decodedImage(
            data,
            allowedFormats: .pngOnly,
            maximumBytes: limits.maximumManagedPNGBytes,
            limits: limits)
        return try topDownRGBA(from: image)
    }

    private static func decodedImage(
        _ data: Data,
        allowedFormats: AllowedFormats,
        maximumBytes: Int64,
        limits: InputImageStoreLimits
    ) throws -> CGImage {
        guard Int64(data.count) <= maximumBytes else {
            throw InputImageStoreError.payloadTooLarge(maximumBytes: maximumBytes)
        }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            let identifier = CGImageSourceGetType(source) as String?,
            let type = UTType(identifier) else {
            throw InputImageStoreError.decodeFailed
        }
        let isPNG = type.conforms(to: .png)
        let isJPEG = type.conforms(to: .jpeg)
        let isHEIC = type.conforms(to: .heic)
        switch allowedFormats {
        case .supported:
            guard isPNG || isJPEG || isHEIC else {
                throw InputImageStoreError.unsupportedFormat
            }
        case .pngOnly:
            guard isPNG else { throw InputImageStoreError.unsupportedFormat }
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            sourceOptions as CFDictionary) as NSDictionary?,
            let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw InputImageStoreError.decodeFailed
        }
        let rawWidth = widthNumber.intValue
        let rawHeight = heightNumber.intValue
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1 ... 8).contains(orientation) else {
            throw InputImageStoreError.decodeFailed
        }
        let swapsDimensions = (5 ... 8).contains(orientation)
        let width = swapsDimensions ? rawHeight : rawWidth
        let height = swapsDimensions ? rawWidth : rawHeight
        guard InputImageStore.dimensionsAreSafe(
            width: width,
            height: height,
            limits: limits) else {
            throw InputImageStoreError.imageTooLarge(
                width: width,
                height: height,
                maximumPixels: limits.maximumPixelCount)
        }

        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(rawWidth, rawHeight),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            decodeOptions as CFDictionary),
            image.width == width,
            image.height == height else {
            throw InputImageStoreError.decodeFailed
        }
        return image
    }

    private static func opaqueSRGBImage(from image: CGImage) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InputImageStoreError.decodeFailed
        }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setBlendMode(.normal)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let canonical = context.makeImage() else {
            throw InputImageStoreError.decodeFailed
        }
        return canonical
    }

    private static func topDownRGBA(from image: CGImage) throws -> Raster {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InputImageStoreError.decodeFailed
        }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { throw InputImageStoreError.decodeFailed }
        let count = image.width * image.height * 4
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return Raster(
            width: image.width,
            height: image.height,
            rgba: Array(UnsafeBufferPointer(start: bytes, count: count)))
    }
}
