import Foundation

enum GalleryAnnotationStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsafeFile(URL)
    case fileTooLarge(URL)
    case corruptFile(URL, reason: String)
    case incompatibleSchema(expected: String, found: String)
    case incompatibleVersion(expected: Int, found: Int)
    case tooManyFavorites(Int)
    case revisionOverflow

    var errorDescription: String? {
        switch self {
        case .unsafeFile(let url):
            return "Gallery annotations refused an unsafe file at \(url.path)."
        case .fileTooLarge(let url):
            return "Gallery annotations exceed the safety limit at \(url.path)."
        case .corruptFile(_, let reason):
            return "Gallery annotations are invalid and were left untouched: \(reason)"
        case .incompatibleSchema(let expected, let found):
            return "Gallery annotations use schema \(found); this app supports \(expected)."
        case .incompatibleVersion(let expected, let found):
            return "Gallery annotations are version \(found); this app supports version \(expected)."
        case .tooManyFavorites(let count):
            return "Gallery annotations contain too many favorites (\(count))."
        case .revisionOverflow:
            return "Gallery annotation revision cannot be advanced."
        }
    }
}

/// Persists mutable, user-authored Gallery state without changing a generation's recipe or its
/// verified PNG/sidecar identity. A malformed file is preserved and blocks mutation so favorites
/// are never silently reset.
actor GalleryAnnotationStore {
    static let schema = "twisterminigen.gallery-annotations"
    static let currentVersion = 1
    static let maximumFavoriteCount = 100_000

    private static let maximumFileBytes = 2 * 1_024 * 1_024
    private static let privateFilePermissions = 0o600
    private static let privateDirectoryPermissions = 0o700

    private struct Envelope: Codable, Equatable, Sendable {
        let schema: String
        let version: Int
        var revision: UInt64
        var favoriteIDs: [UUID]
    }

    private let fileURL: URL
    private var revision: UInt64
    private var favoriteIDsValue: Set<UUID>
    private let startupFailure: GalleryAnnotationStoreError?

    init(fileURL: URL = LibraryPaths.application.galleryAnnotations) {
        self.fileURL = fileURL.standardizedFileURL
        do {
            let envelope = try Self.load(from: self.fileURL)
            self.revision = envelope?.revision ?? 0
            self.favoriteIDsValue = Set(envelope?.favoriteIDs ?? [])
            self.startupFailure = nil
        } catch let error as GalleryAnnotationStoreError {
            self.revision = 0
            self.favoriteIDsValue = []
            self.startupFailure = error
        } catch {
            self.revision = 0
            self.favoriteIDsValue = []
            self.startupFailure = .corruptFile(
                self.fileURL,
                reason: error.localizedDescription)
        }
    }

    func favorites() throws -> Set<UUID> {
        try requireAvailable()
        return favoriteIDsValue
    }

    @discardableResult
    func setFavorite(_ isFavorite: Bool, for generationID: UUID) throws -> Bool {
        try requireAvailable()
        var candidate = favoriteIDsValue
        if isFavorite {
            candidate.insert(generationID)
        } else {
            candidate.remove(generationID)
        }
        try commit(candidate)
        return candidate.contains(generationID)
    }

    @discardableResult
    func toggleFavorite(for generationID: UUID) throws -> Bool {
        try setFavorite(!favoriteIDsValue.contains(generationID), for: generationID)
    }

    func removeAnnotations(for generationIDs: Set<UUID>) throws {
        try requireAvailable()
        try commit(favoriteIDsValue.subtracting(generationIDs))
    }

    func reconcile(validGenerationIDs: Set<UUID>) throws -> Set<UUID> {
        try requireAvailable()
        let candidate = favoriteIDsValue.intersection(validGenerationIDs)
        try commit(candidate)
        return candidate
    }

    /// Storage Manager may remove the annotation envelope as part of Gallery deletion or reset.
    /// Clear the actor cache without recreating the deleted file.
    func resetAfterExternalStorageChange() {
        revision = 0
        favoriteIDsValue = []
    }

    private func commit(_ candidate: Set<UUID>) throws {
        guard candidate != favoriteIDsValue else { return }
        guard candidate.count <= Self.maximumFavoriteCount else {
            throw GalleryAnnotationStoreError.tooManyFavorites(candidate.count)
        }
        let (nextRevision, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else { throw GalleryAnnotationStoreError.revisionOverflow }
        let envelope = Envelope(
            schema: Self.schema,
            version: Self.currentVersion,
            revision: nextRevision,
            favoriteIDs: candidate.sorted { $0.uuidString < $1.uuidString })
        try Self.persist(envelope, to: fileURL)
        revision = nextRevision
        favoriteIDsValue = candidate
    }

    private func requireAvailable() throws {
        if let startupFailure { throw startupFailure }
    }

    private static func load(from fileURL: URL) throws -> Envelope? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw GalleryAnnotationStoreError.unsafeFile(fileURL)
        }
        guard let fileSize = values.fileSize,
              fileSize >= 0, fileSize <= maximumFileBytes else {
            throw GalleryAnnotationStoreError.fileTooLarge(fileURL)
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count == fileSize else {
            throw GalleryAnnotationStoreError.corruptFile(
                fileURL,
                reason: "the file changed while it was being read")
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw GalleryAnnotationStoreError.corruptFile(
                fileURL,
                reason: error.localizedDescription)
        }
        guard envelope.schema == schema else {
            throw GalleryAnnotationStoreError.incompatibleSchema(
                expected: schema,
                found: envelope.schema)
        }
        guard envelope.version == currentVersion else {
            throw GalleryAnnotationStoreError.incompatibleVersion(
                expected: currentVersion,
                found: envelope.version)
        }
        guard envelope.favoriteIDs.count <= maximumFavoriteCount else {
            throw GalleryAnnotationStoreError.tooManyFavorites(envelope.favoriteIDs.count)
        }
        guard Set(envelope.favoriteIDs).count == envelope.favoriteIDs.count else {
            throw GalleryAnnotationStoreError.corruptFile(
                fileURL,
                reason: "favorite identifiers are duplicated")
        }
        return envelope
    }

    private static func persist(_ envelope: Envelope, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw GalleryAnnotationStoreError.unsafeFile(directory)
        }
        if fileManager.fileExists(atPath: fileURL.path) {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw GalleryAnnotationStoreError.unsafeFile(fileURL)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= maximumFileBytes else {
            throw GalleryAnnotationStoreError.fileTooLarge(fileURL)
        }
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: privateDirectoryPermissions],
            ofItemAtPath: directory.path)
        try fileManager.setAttributes(
            [.posixPermissions: privateFilePermissions],
            ofItemAtPath: fileURL.path)
    }
}
