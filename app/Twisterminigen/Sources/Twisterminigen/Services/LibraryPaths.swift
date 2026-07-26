import Foundation

enum LibraryPathError: Error, Equatable, LocalizedError {
    case invalidManagedFileName(String)
    case pathIsNotDirectChild(URL, directory: URL)
    case unsafePath(URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidManagedFileName(let name):
            return "Invalid managed generation file name: \(name)"
        case .pathIsNotDirectChild(let url, let directory):
            return "\(url.path) is not a direct child of \(directory.path)."
        case .unsafePath(let url, let reason):
            return "Unsafe library path \(url.path): \(reason)"
        }
    }
}

/// The only file-name shape the library owns. UUID hex is case-insensitive so files produced by
/// the existing uppercase writer and compatible lowercase writers are both accepted.
struct ManagedGenerationFileName: Hashable, Sendable {
    let rawValue: String
    let identifier: UUID
    let seed: UInt64

    init(identifier: UUID, seed: UInt64) {
        self.rawValue = "twist_\(identifier.uuidString)_\(seed).png"
        self.identifier = identifier
        self.seed = seed
    }

    init(validating rawValue: String) throws {
        let prefix = "twist_"
        let suffix = ".png"
        guard rawValue.hasPrefix(prefix), rawValue.hasSuffix(suffix),
              !rawValue.contains("/"), !rawValue.contains("\\") else {
            throw LibraryPathError.invalidManagedFileName(rawValue)
        }

        let payload = rawValue.dropFirst(prefix.count).dropLast(suffix.count)
        guard let separator = payload.lastIndex(of: "_") else {
            throw LibraryPathError.invalidManagedFileName(rawValue)
        }
        let uuidText = String(payload[..<separator])
        let seedText = String(payload[payload.index(after: separator)...])
        guard Self.isCanonicalUUID(uuidText), let identifier = UUID(uuidString: uuidText),
              let seed = UInt64(seedText), seedText == String(seed) else {
            throw LibraryPathError.invalidManagedFileName(rawValue)
        }

        self.rawValue = rawValue
        self.identifier = identifier
        self.seed = seed
    }

    var normalizedKey: String { rawValue.lowercased() }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 36 else { return false }
        let hyphens = Set([8, 13, 18, 23])
        for (index, scalar) in scalars.enumerated() {
            if hyphens.contains(index) {
                guard scalar.value == 45 else { return false }
            } else {
                let value = scalar.value
                let isDigit = (48...57).contains(value)
                let isUpperHex = (65...70).contains(value)
                let isLowerHex = (97...102).contains(value)
                guard isDigit || isUpperHex || isLowerHex else { return false }
            }
        }
        return true
    }
}

/// A recipe sidecar must use the exact stem and case of its managed PNG sibling.
struct ManagedGenerationRecipeFileName: Hashable, Sendable {
    static let suffix = ".recipe.json"

    let rawValue: String
    let imageFileName: ManagedGenerationFileName

    init(imageFileName: ManagedGenerationFileName) {
        self.imageFileName = imageFileName
        self.rawValue = String(imageFileName.rawValue.dropLast(".png".count)) + Self.suffix
    }

    init(validating rawValue: String) throws {
        guard rawValue.hasSuffix(Self.suffix),
              !rawValue.contains("/"), !rawValue.contains("\\") else {
            throw LibraryPathError.invalidManagedFileName(rawValue)
        }
        let stem = rawValue.dropLast(Self.suffix.count)
        let imageFileName = try ManagedGenerationFileName(validating: "\(stem).png")
        let expected = Self(imageFileName: imageFileName)
        guard expected.rawValue == rawValue else {
            throw LibraryPathError.invalidManagedFileName(rawValue)
        }
        self = expected
    }

    var normalizedKey: String { rawValue.lowercased() }
}

/// Every path used by the gallery library. Tests can inject a self-contained root; production uses
/// the existing AppPaths locations, including the thumbnail cache outside Application Support.
struct LibraryPaths: Equatable, Sendable {
    let root: URL
    let images: URL
    let recipes: URL
    let generationsIndex: URL
    let journal: URL
    let quarantine: URL
    let thumbnails: URL

    init(root: URL, thumbnails: URL? = nil) {
        let standardizedRoot = root.standardizedFileURL
        self.root = standardizedRoot
        self.images = standardizedRoot.appendingPathComponent("Images", isDirectory: true)
        self.recipes = standardizedRoot.appendingPathComponent("Recipes", isDirectory: true)
        self.generationsIndex = standardizedRoot.appendingPathComponent("generations.json")
        self.journal = standardizedRoot.appendingPathComponent("generations.transaction.json")
        self.quarantine = standardizedRoot.appendingPathComponent("Quarantine", isDirectory: true)
        self.thumbnails = (thumbnails
            ?? standardizedRoot.appendingPathComponent("thumbnails", isDirectory: true))
            .standardizedFileURL
    }

    init(
        root: URL,
        images: URL,
        recipes: URL,
        generationsIndex: URL,
        journal: URL,
        quarantine: URL,
        thumbnails: URL
    ) {
        self.root = root.standardizedFileURL
        self.images = images.standardizedFileURL
        self.recipes = recipes.standardizedFileURL
        self.generationsIndex = generationsIndex.standardizedFileURL
        self.journal = journal.standardizedFileURL
        self.quarantine = quarantine.standardizedFileURL
        self.thumbnails = thumbnails.standardizedFileURL
    }

    static var application: LibraryPaths {
        LibraryPaths(
            root: AppPaths.appSupport,
            images: AppPaths.images,
            recipes: AppPaths.appSupport.appendingPathComponent("Recipes", isDirectory: true),
            generationsIndex: AppPaths.generationsIndex,
            journal: AppPaths.appSupport.appendingPathComponent("generations.transaction.json"),
            quarantine: AppPaths.appSupport.appendingPathComponent("Quarantine", isDirectory: true),
            thumbnails: AppPaths.thumbnails)
    }

    /// User-owned gallery annotations are intentionally separate from the deterministic
    /// generation index and recipe sidecars.
    var galleryAnnotations: URL {
        root.appendingPathComponent("gallery-annotations.json", isDirectory: false)
    }

    /// External publishers reject both the injected Gallery root and the independently located
    /// thumbnail cache. Production AppPaths are added again by the publisher as defense in depth.
    var protectedExportRoots: [URL] { [root, thumbnails] }

    func imageURL(for fileName: String) throws -> URL {
        let name = try ManagedGenerationFileName(validating: fileName)
        return try directChild(named: name.rawValue, of: images)
    }

    func thumbnailURL(for fileName: String) throws -> URL {
        let name = try ManagedGenerationFileName(validating: fileName)
        return try directChild(named: name.rawValue, of: thumbnails)
    }

    func recipeURL(for imageFileName: String) throws -> URL {
        let imageName = try ManagedGenerationFileName(validating: imageFileName)
        let recipeName = ManagedGenerationRecipeFileName(imageFileName: imageName)
        return try directChild(named: recipeName.rawValue, of: recipes)
    }

    func recipeURL(forRecipeFileName fileName: String) throws -> URL {
        let name = try ManagedGenerationRecipeFileName(validating: fileName)
        return try directChild(named: name.rawValue, of: recipes)
    }

    private func directChild(named fileName: String, of directory: URL) throws -> URL {
        let candidate = directory.appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        guard candidate.lastPathComponent == fileName,
              candidate.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw LibraryPathError.pathIsNotDirectChild(candidate, directory: directory)
        }
        return candidate
    }
}
