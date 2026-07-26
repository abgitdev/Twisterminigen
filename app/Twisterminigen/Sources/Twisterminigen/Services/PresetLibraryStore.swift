import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PresetCoverLimits: Sendable, Equatable {
    static let standard = PresetCoverLimits()

    let maximumSourceBytes: Int64
    let maximumPixelCount: Int64
    let maximumDimension: Int
    let jpegQuality: Double

    init(
        maximumSourceBytes: Int64 = 64 * 1_024 * 1_024,
        maximumPixelCount: Int64 = 40_000_000,
        maximumDimension: Int = 640,
        jpegQuality: Double = 0.84
    ) {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumPixelCount = maximumPixelCount
        self.maximumDimension = maximumDimension
        self.jpegQuality = jpegQuality
    }
}

enum PresetLibraryStoreError: Error, Equatable, Sendable {
    case unsafeRoot(URL)
    case unsafeSource(URL)
    case sourceTooLarge(Int64)
    case unsupportedCoverFormat
    case coverDecodeFailed
    case coverEncodeFailed
    case coverRequired
    case invalidTitle
    case invalidSummary
    case missingCategory(String)
    case categoryIsBuiltIn(String)
    case cardIsBuiltIn(String)
    case cardNotFound(String)
    case categoryNotFound(String)
    case unsupportedSchema(Int)
    case corruptIndex(String)
    case invalidRecipe(String)
}

extension PresetLibraryStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsafeRoot(let url): return "The preset library folder is unsafe: \(url.path)"
        case .unsafeSource(let url): return "The selected cover is not a readable regular file: \(url.lastPathComponent)"
        case .sourceTooLarge(let max): return "The cover exceeds the \(ByteCountFormatter.string(fromByteCount: max, countStyle: .file)) safety limit."
        case .unsupportedCoverFormat: return "Preset covers must be PNG, JPEG, or HEIC images."
        case .coverDecodeFailed: return "The cover image could not be decoded safely."
        case .coverEncodeFailed: return "The cover image could not be stored as a managed thumbnail."
        case .coverRequired: return "Choose a PNG, JPEG, HEIC, or Gallery image for this preset."
        case .invalidTitle: return "Preset titles need between 2 and 80 characters."
        case .invalidSummary: return "The short description must be 220 characters or fewer."
        case .missingCategory(let id): return "The selected preset category no longer exists (\(id))."
        case .categoryIsBuiltIn: return "Built-in categories cannot be removed."
        case .cardIsBuiltIn: return "Built-in presets are read-only."
        case .cardNotFound: return "That personal preset no longer exists."
        case .categoryNotFound: return "That personal category no longer exists."
        case .unsupportedSchema(let version): return "This preset library was created by a newer app version (schema \(version))."
        case .corruptIndex(let message): return "The preset library index is invalid: \(message)"
        case .invalidRecipe(let message): return "This preset recipe is invalid: \(message)"
        }
    }
}

/// Versioned, local-first storage for the user's cards and categories.
///
/// Covers are canonical JPEG thumbnails written below `PresetCovers/`. Card records only keep
/// a managed filename, never an external URL. The actor serializes all mutations so index and
/// cover cleanup remain coherent across relaunches.
actor PresetLibraryStore {
    static let schemaVersion = 1
    static let maximumCards = 512
    static let maximumCategories = 128

    private struct Document: Codable, Sendable {
        var schemaVersion: Int
        var categories: [PresetCategory]
        var cards: [PresetCard]
        /// Optional keeps existing schema-1 documents source-compatible. A missing key means the
        /// preference predates favorites and therefore starts empty.
        var favoritePresetIDs: Set<String>?
        /// Legacy schema-1 key retained for byte-compatible decoding. The current UI treats these
        /// identifiers as permanent local deletion tombstones and exposes no restore action.
        var hiddenBuiltinPresetIDs: Set<String>?
        /// A persisted local tombstone for a built-in section. Optional keeps every existing
        /// schema-1 document readable without a migration rewrite.
        var removedBuiltinCategoryIDs: Set<String>? = nil
    }

    private struct Header: Decodable {
        var schemaVersion: Int
    }

    private let root: URL
    private let covers: URL
    private let indexURL: URL
    private let limits: PresetCoverLimits
    private var document: Document
    private var startupWarningValue: String?

    init(
        root: URL = AppPaths.presets,
        limits: PresetCoverLimits = .standard
    ) throws {
        let root = root.standardizedFileURL
        let covers = root.appendingPathComponent("PresetCovers", isDirectory: true)
        let indexURL = root.appendingPathComponent("presets.json", isDirectory: false)
        try Self.validate(limits: limits)
        try Self.ensureDirectory(root)
        try Self.ensureDirectory(covers)

        let opened = try Self.openDocument(at: indexURL)
        try Self.validate(document: opened.document)
        self.root = root
        self.covers = covers
        self.indexURL = indexURL
        self.limits = limits
        self.document = opened.document
        self.startupWarningValue = opened.warning
        try Self.removeOrphanedCovers(in: covers, cards: opened.document.cards)
    }

    func snapshot() -> PresetLibrarySnapshot {
        let knownIDs = BuiltinPresetCatalog.stableIDs.union(document.cards.map(\.id))
        let startupWarning = startupWarningValue
        startupWarningValue = nil
        return PresetLibrarySnapshot(
            categories: document.categories.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
            cards: document.cards.sorted(by: Self.cardSort),
            favoritePresetIDs: (document.favoritePresetIDs ?? []).intersection(knownIDs),
            removedBuiltinPresetIDs: (document.hiddenBuiltinPresetIDs ?? [])
                .intersection(BuiltinPresetCatalog.stableIDs),
            removedBuiltinCategoryIDs: (document.removedBuiltinCategoryIDs ?? [])
                .intersection(BuiltinPresetCatalog.categories.map(\.id)),
            startupWarning: startupWarning)
    }

    func setFavorite(id: String, isFavorite: Bool) throws {
        guard knownPresetIDs.contains(id) else { throw PresetLibraryStoreError.cardNotFound(id) }
        var next = document
        var ids = next.favoritePresetIDs ?? []
        if isFavorite { ids.insert(id) } else { ids.remove(id) }
        next.favoritePresetIDs = ids
        try persist(next)
        document = next
    }

    @discardableResult
    func toggleFavorite(id: String) throws -> Bool {
        guard knownPresetIDs.contains(id) else { throw PresetLibraryStoreError.cardNotFound(id) }
        var next = document
        var ids = next.favoritePresetIDs ?? []
        let isFavorite: Bool
        if ids.remove(id) != nil {
            isFavorite = false
        } else {
            ids.insert(id)
            isFavorite = true
        }
        next.favoritePresetIDs = ids
        try persist(next)
        document = next
        return isFavorite
    }

    func removeBuiltinCard(id: String) throws {
        guard BuiltinPresetCatalog.stableIDs.contains(id) else {
            throw PresetLibraryStoreError.cardNotFound(id)
        }
        var next = document
        var ids = next.hiddenBuiltinPresetIDs ?? []
        ids.insert(id)
        next.hiddenBuiltinPresetIDs = ids
        next.favoritePresetIDs?.remove(id)
        try persist(next)
        document = next
    }

    func coverURL(for card: PresetCard) -> URL? {
        guard card.origin == .personal, let name = card.coverFilename,
              Self.isManagedCoverFilename(name)
        else { return nil }
        let url = covers.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    @discardableResult
    func createCategory(title: String) throws -> PresetCategory {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...48).contains(normalized.count) else { throw PresetLibraryStoreError.invalidTitle }
        guard document.categories.count < Self.maximumCategories else {
            throw PresetLibraryStoreError.corruptIndex("the category limit is \(Self.maximumCategories)")
        }
        let removedBuiltinCategoryIDs = document.removedBuiltinCategoryIDs ?? []
        guard !BuiltinPresetCatalog.categories.contains(where: {
            !removedBuiltinCategoryIDs.contains($0.id)
                && $0.title.caseInsensitiveCompare(normalized) == .orderedSame
        }),
              !document.categories.contains(where: { $0.title.caseInsensitiveCompare(normalized) == .orderedSame })
        else { throw PresetLibraryStoreError.corruptIndex("a category named \(normalized) already exists") }

        let category = PresetCategory(
            id: "personal.category.\(UUID().uuidString.lowercased())",
            title: normalized,
            systemImage: "square.grid.2x2",
            isPersonal: true)
        var next = document
        next.categories.append(category)
        try persist(next)
        document = next
        return category
    }

    @discardableResult
    func save(draft: PresetCardDraft, coverData: Data?) throws -> PresetCard {
        let normalized = try Self.validate(draft: draft, categories: allCategories)
        if let id = normalized.id {
            return try update(id: id, draft: normalized, coverData: coverData)
        }
        guard document.cards.count < Self.maximumCards else {
            throw PresetLibraryStoreError.corruptIndex("the card limit is \(Self.maximumCards)")
        }
        guard let coverData else { throw PresetLibraryStoreError.coverRequired }
        let cover = try writeCover(coverData)
        let now = Date()
        let card = PresetCard(
            id: "personal.preset.\(UUID().uuidString.lowercased())",
            origin: .personal,
            categoryID: normalized.categoryID,
            title: normalized.title,
            summary: normalized.summary,
            recipe: normalized.recipe,
            coverFilename: cover.filename,
            createdAt: now,
            updatedAt: now)
        var next = document
        next.cards.append(card)
        do {
            try persist(next)
            document = next
            return card
        } catch {
            try? FileManager.default.removeItem(at: cover.url)
            throw error
        }
    }

    @discardableResult
    func removeCard(id: String) throws -> PresetCard {
        guard let index = document.cards.firstIndex(where: { $0.id == id }) else {
            throw PresetLibraryStoreError.cardNotFound(id)
        }
        let card = document.cards[index]
        guard card.origin == .personal else { throw PresetLibraryStoreError.cardIsBuiltIn(id) }
        var next = document
        next.cards.remove(at: index)
        next.favoritePresetIDs?.remove(id)
        try persist(next)
        document = next
        try? removeCover(named: card.coverFilename)
        return card
    }

    @discardableResult
    func removeCategory(id: String) throws -> [PresetCard] {
        if BuiltinPresetCatalog.categories.contains(where: { $0.id == id }) {
            let cards = document.cards.filter { $0.categoryID == id }
            let builtInCardIDs = BuiltinPresetCatalog.stableIDs(in: id)
            var next = document
            var removedCategoryIDs = next.removedBuiltinCategoryIDs ?? []
            removedCategoryIDs.insert(id)
            next.removedBuiltinCategoryIDs = removedCategoryIDs
            var removedCardIDs = next.hiddenBuiltinPresetIDs ?? []
            removedCardIDs.formUnion(builtInCardIDs)
            next.hiddenBuiltinPresetIDs = removedCardIDs
            next.categories.removeAll { $0.id == id }
            next.cards.removeAll { $0.categoryID == id }
            next.favoritePresetIDs?.subtract(cards.map(\.id))
            next.favoritePresetIDs?.subtract(builtInCardIDs)
            try persist(next)
            document = next
            for card in cards { try? removeCover(named: card.coverFilename) }
            return cards
        }

        guard let category = document.categories.first(where: { $0.id == id }) else {
            throw PresetLibraryStoreError.categoryNotFound(id)
        }
        guard category.isPersonal else { throw PresetLibraryStoreError.categoryIsBuiltIn(id) }
        let cards = document.cards.filter { $0.categoryID == id }
        var next = document
        next.categories.removeAll { $0.id == id }
        next.cards.removeAll { $0.categoryID == id }
        next.favoritePresetIDs?.subtract(cards.map(\.id))
        try persist(next)
        document = next
        for card in cards { try? removeCover(named: card.coverFilename) }
        return cards
    }

    /// Permanently empties the local Presets library in one atomic index update. Bundled assets
    /// remain code-signed resources, so built-ins are removed through persisted tombstones while
    /// every personal record and managed cover is physically deleted.
    func removeEverything() throws {
        let personalCards = document.cards
        var next = document
        next.categories = []
        next.cards = []
        next.favoritePresetIDs = []
        next.hiddenBuiltinPresetIDs = BuiltinPresetCatalog.stableIDs
        next.removedBuiltinCategoryIDs = Set(BuiltinPresetCatalog.categories.map(\.id))
        try persist(next)
        document = next
        for card in personalCards { try? removeCover(named: card.coverFilename) }
    }

    private var allCategories: [PresetCategory] {
        let removed = document.removedBuiltinCategoryIDs ?? []
        return BuiltinPresetCatalog.categories.filter { !removed.contains($0.id) } + document.categories
    }

    private var knownPresetIDs: Set<String> {
        BuiltinPresetCatalog.stableIDs.union(document.cards.map(\.id))
    }

    private func update(
        id: String,
        draft: PresetCardDraft,
        coverData: Data?
    ) throws -> PresetCard {
        guard let existingIndex = document.cards.firstIndex(where: { $0.id == id }) else {
            throw PresetLibraryStoreError.cardNotFound(id)
        }
        let existing = document.cards[existingIndex]
        guard existing.origin == .personal else { throw PresetLibraryStoreError.cardIsBuiltIn(id) }

        let imported = try coverData.map(writeCover)
        var updated = existing
        updated.categoryID = draft.categoryID
        updated.title = draft.title
        updated.summary = draft.summary
        updated.recipe = draft.recipe
        updated.updatedAt = Date()
        if let imported { updated.coverFilename = imported.filename }
        var next = document
        next.cards[existingIndex] = updated
        do {
            try persist(next)
            document = next
            if let imported, imported.filename != existing.coverFilename {
                try? removeCover(named: existing.coverFilename)
            }
            return updated
        } catch {
            if let imported { try? FileManager.default.removeItem(at: imported.url) }
            throw error
        }
    }

    private func writeCover(_ sourceData: Data) throws -> (filename: String, url: URL) {
        let jpeg = try PresetCoverCodec.canonicalJPEG(sourceData, limits: limits)
        let filename = "\(UUID().uuidString.lowercased()).jpg"
        let destination = covers.appendingPathComponent(filename, isDirectory: false)
        try jpeg.write(to: destination, options: [.atomic])
        return (filename, destination)
    }

    private func removeCover(named filename: String?) throws {
        guard let filename, Self.isManagedCoverFilename(filename) else { return }
        let url = covers.appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func persist(_ document: Document) throws {
        try Self.validate(document: document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: indexURL, options: [.atomic])
    }

    private static func openDocument(at url: URL) throws -> (document: Document, warning: String?) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return (Document(
                schemaVersion: schemaVersion,
                categories: [],
                cards: [],
                favoritePresetIDs: nil,
                hiddenBuiltinPresetIDs: nil), nil)
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.schemaVersion <= schemaVersion else {
                throw PresetLibraryStoreError.unsupportedSchema(header.schemaVersion)
            }
            guard header.schemaVersion == schemaVersion else {
                throw PresetLibraryStoreError.corruptIndex("unsupported schema \(header.schemaVersion)")
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            return (document, nil)
        } catch let error as PresetLibraryStoreError {
            throw error
        } catch {
            let quarantine = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(UUID().uuidString.lowercased()).json")
            try? fileManager.moveItem(at: url, to: quarantine)
            return (
                Document(
                    schemaVersion: schemaVersion,
                    categories: [],
                    cards: [],
                    favoritePresetIDs: nil,
                    hiddenBuiltinPresetIDs: nil),
                "Invalid preset data was isolated and the personal library restarted empty. \(error.localizedDescription)")
        }
    }

    private static func validate(document: Document) throws {
        guard document.schemaVersion == schemaVersion else {
            throw PresetLibraryStoreError.unsupportedSchema(document.schemaVersion)
        }
        guard document.categories.count <= maximumCategories, document.cards.count <= maximumCards else {
            throw PresetLibraryStoreError.corruptIndex("library limits exceeded")
        }
        let favorites = document.favoritePresetIDs ?? []
        let hiddenBuiltins = document.hiddenBuiltinPresetIDs ?? []
        let removedBuiltinCategories = document.removedBuiltinCategoryIDs ?? []
        guard favorites.count <= maximumCards + BuiltinPresetCatalog.stableIDs.count,
              hiddenBuiltins.count <= BuiltinPresetCatalog.stableIDs.count,
              removedBuiltinCategories.count <= BuiltinPresetCatalog.categories.count
        else { throw PresetLibraryStoreError.corruptIndex("invalid preset preferences") }
        let validBuiltinCategoryIDs = Set(BuiltinPresetCatalog.categories.map(\.id))
        guard removedBuiltinCategories.isSubset(of: validBuiltinCategoryIDs) else {
            throw PresetLibraryStoreError.corruptIndex("invalid removed built-in categories")
        }
        var categoryIDs = Set<String>()
        for category in document.categories {
            guard category.isPersonal,
                  category.id.hasPrefix("personal.category."),
                  !category.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PresetLibraryStoreError.corruptIndex("invalid personal category") }
            guard categoryIDs.insert(category.id).inserted else {
                throw PresetLibraryStoreError.corruptIndex("duplicate category ID")
            }
        }
        let categoryIDsWithBuiltins = categoryIDs.union(
            validBuiltinCategoryIDs.subtracting(removedBuiltinCategories))
        var cardIDs = Set<String>()
        for card in document.cards {
            guard card.origin == .personal, card.id.hasPrefix("personal.preset.") else {
                throw PresetLibraryStoreError.corruptIndex("built-in cards must not be persisted")
            }
            guard cardIDs.insert(card.id).inserted else {
                throw PresetLibraryStoreError.corruptIndex("duplicate preset ID")
            }
            guard categoryIDsWithBuiltins.contains(card.categoryID) else {
                throw PresetLibraryStoreError.missingCategory(card.categoryID)
            }
            guard let filename = card.coverFilename, isManagedCoverFilename(filename) else {
                throw PresetLibraryStoreError.corruptIndex("invalid cover filename")
            }
            do {
                try card.recipe.validate(for: .request)
            } catch {
                throw PresetLibraryStoreError.invalidRecipe(error.localizedDescription)
            }
        }
        // Unknown but well-formed IDs are tolerated and ignored by `snapshot()`. This makes
        // preferences forward-compatible when a built-in card is retired or renamed.
        guard favorites.allSatisfy({
            $0.hasPrefix("builtin.") || $0.hasPrefix("personal.preset.")
        }), hiddenBuiltins.allSatisfy({ $0.hasPrefix("builtin.") }) else {
            throw PresetLibraryStoreError.corruptIndex("invalid preset preference identifiers")
        }
    }

    private static func validate(draft: PresetCardDraft, categories: [PresetCategory]) throws -> PresetCardDraft {
        var result = draft
        result.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...80).contains(result.title.count) else { throw PresetLibraryStoreError.invalidTitle }
        guard result.summary.count <= 220 else { throw PresetLibraryStoreError.invalidSummary }
        guard categories.contains(where: { $0.id == result.categoryID }) else {
            throw PresetLibraryStoreError.missingCategory(result.categoryID)
        }
        do {
            try result.recipe.validate(for: .request)
        } catch {
            throw PresetLibraryStoreError.invalidRecipe(error.localizedDescription)
        }
        return result
    }

    private static func validate(limits: PresetCoverLimits) throws {
        guard limits.maximumSourceBytes > 0,
              limits.maximumPixelCount > 0,
              limits.maximumDimension > 0,
              (0...1).contains(limits.jpegQuality)
        else { throw PresetLibraryStoreError.coverEncodeFailed }
    }

    private static func ensureDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw PresetLibraryStoreError.unsafeRoot(url)
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw PresetLibraryStoreError.unsafeRoot(url) }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func removeOrphanedCovers(in directory: URL, cards: [PresetCard]) throws {
        let live = Set(cards.compactMap(\.coverFilename))
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        for file in files {
            guard Self.isManagedCoverFilename(file.lastPathComponent) else { continue }
            if !live.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func isManagedCoverFilename(_ filename: String) -> Bool {
        filename.range(of: "^[0-9a-fA-F-]{36}\\.jpg$", options: .regularExpression) != nil
    }

    private static func cardSort(_ lhs: PresetCard, _ rhs: PresetCard) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }
}

enum PresetCoverCodec {
    static func data(from sourceURL: URL, limits: PresetCoverLimits = .standard) throws -> Data {
        let url = sourceURL.standardizedFileURL
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw PresetLibraryStoreError.unsafeSource(url) }
        guard Int64(values?.fileSize ?? 0) <= limits.maximumSourceBytes else {
            throw PresetLibraryStoreError.sourceTooLarge(limits.maximumSourceBytes)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard Int64(data.count) <= limits.maximumSourceBytes else {
            throw PresetLibraryStoreError.sourceTooLarge(limits.maximumSourceBytes)
        }
        return data
    }

    static func canonicalJPEG(_ data: Data, limits: PresetCoverLimits) throws -> Data {
        guard !data.isEmpty, Int64(data.count) <= limits.maximumSourceBytes else {
            throw PresetLibraryStoreError.sourceTooLarge(limits.maximumSourceBytes)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let typeIdentifier = UTType(type as String),
              typeIdentifier.conforms(to: .image),
              typeIdentifier.conforms(to: .png) || typeIdentifier.conforms(to: .jpeg) || typeIdentifier.conforms(to: .heic)
        else { throw PresetLibraryStoreError.unsupportedCoverFormat }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw PresetLibraryStoreError.coverDecodeFailed }
        let pixels = Int64(width) * Int64(height)
        guard pixels > 0, pixels <= limits.maximumPixelCount else {
            throw PresetLibraryStoreError.coverDecodeFailed
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.maximumDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PresetLibraryStoreError.coverDecodeFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil)
        else { throw PresetLibraryStoreError.coverEncodeFailed }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: limits.jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PresetLibraryStoreError.coverEncodeFailed
        }
        return output as Data
    }
}
