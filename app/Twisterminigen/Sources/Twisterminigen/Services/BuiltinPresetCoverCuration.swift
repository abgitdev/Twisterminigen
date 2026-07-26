import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The checked-in, privacy-safe contract for built-in preset artwork. A manifest is deliberately
/// produced only after every cover has been curated from exact, integrity-checked Gallery
/// generations. Gallery identifiers, filenames, and source-image hashes are used only during that
/// local curation operation and are never serialized into the public manifest.
struct BuiltinPresetCoverManifest: Codable, Equatable, Sendable {
    static let supportedSchema = "twisterminigen.builtin-preset-covers"
    static let currentVersion = 2

    struct Entry: Codable, Equatable, Sendable {
        let presetID: String
        let assetFilename: String
        let recipeSHA256: String
        let fixedSeed: UInt64
        let jpegSHA256: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int
        let crop: String
    }

    let schema: String
    let version: Int
    let covers: [Entry]

    init(
        schema: String = Self.supportedSchema,
        version: Int = Self.currentVersion,
        covers: [Entry]
    ) {
        self.schema = schema
        self.version = version
        self.covers = covers
    }
}

enum BuiltinPresetCoverCurationError: Error, LocalizedError {
    case unsafeDirectory(URL)
    case destinationExists(URL)
    case incompleteSelection(expected: Set<String>, actual: Set<String>)
    case duplicateGeneration(UUID)
    case generationNotFound(UUID)
    case inexactGalleryRecord(UUID)
    case recipeMismatch(presetID: String, generationID: UUID)
    case sourceIdentityMismatch(UUID)
    case sourceDimensionsMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case invalidSourcePNG(String)
    case manifestMissing(URL)
    case invalidManifest(String)
    case invalidAsset(String)
    case coverTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory(let url):
            return "Preset cover output is not a safe local directory: \(url.path)"
        case .destinationExists(let url):
            return "Preset cover output already exists and will not be replaced: \(url.path)"
        case .incompleteSelection(let expected, let actual):
            let missing = expected.subtracting(actual).sorted().joined(separator: ", ")
            let unexpected = actual.subtracting(expected).sorted().joined(separator: ", ")
            return "A sealed cover set requires every built-in preset. Missing: [\(missing)]. Unexpected: [\(unexpected)]."
        case .duplicateGeneration(let id):
            return "Gallery generation \(id.uuidString) was assigned to more than one preset."
        case .generationNotFound(let id):
            return "Gallery generation \(id.uuidString) no longer exists."
        case .inexactGalleryRecord(let id):
            return "Gallery generation \(id.uuidString) is a legacy record and does not contain an exact recipe."
        case .recipeMismatch(let presetID, let generationID):
            return "Gallery generation \(generationID.uuidString) does not exactly reproduce \(presetID)."
        case .sourceIdentityMismatch(let id):
            return "Gallery generation \(id.uuidString) has an image filename that does not match its UUID and fixed seed."
        case .sourceDimensionsMismatch(let expectedWidth, let expectedHeight, let actualWidth, let actualHeight):
            return "Gallery PNG is \(actualWidth) x \(actualHeight), but its exact recipe requires \(expectedWidth) x \(expectedHeight)."
        case .invalidSourcePNG(let reason):
            return "The verified Gallery source is not a supported single-frame PNG: \(reason)"
        case .manifestMissing(let url):
            return "The built-in cover manifest is missing at \(url.path)."
        case .invalidManifest(let reason):
            return "The built-in cover manifest is invalid: \(reason)"
        case .invalidAsset(let reason):
            return "A built-in cover asset is invalid: \(reason)"
        case .coverTooLarge(let count):
            return "The canonical cover is \(count) bytes; the maximum is \(BuiltinPresetCatalog.maximumCoverBytes)."
        }
    }
}

/// Runtime verification and developer-facing validation for the sealed resource directory.
enum BuiltinPresetCoverContract {
    static let manifestFilename = "builtin-preset-covers.json"
    static let cropPolicy = "center-square"
    static let fullFrameLetterboxPolicy = "full-frame-letterbox"
    private static let manifestKeys: Set<String> = ["schema", "version", "covers"]
    private static let entryKeys: Set<String> = [
        "presetID",
        "assetFilename",
        "recipeSHA256",
        "fixedSeed",
        "jpegSHA256",
        "pixelWidth",
        "pixelHeight",
        "byteCount",
        "crop",
    ]

    static func cropPolicy(for card: PresetCard) -> String {
        card.categoryID == BuiltinPresetCatalog.characterSheetCategoryID
            ? fullFrameLetterboxPolicy
            : cropPolicy
    }

    static func recipeSHA256(_ recipe: GenerationRecipe) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(recipe))
    }

    /// Validates the complete manifest and every JPEG against the current built-in recipes.
    @discardableResult
    static func validate(
        directory: URL,
        expectedCards: [PresetCard]
    ) throws -> BuiltinPresetCoverManifest {
        let manifest = try loadManifest(from: directory)
        try validateShape(manifest)

        let expected = Dictionary(uniqueKeysWithValues: expectedCards.map { ($0.id, $0) })
        guard Set(expected.keys) == BuiltinPresetCatalog.stableIDs else {
            throw BuiltinPresetCoverCurationError.invalidManifest(
                "the caller did not provide the complete built-in catalog")
        }
        for entry in manifest.covers {
            guard let card = expected[entry.presetID] else {
                throw BuiltinPresetCoverCurationError.invalidManifest(
                    "unknown preset ID \(entry.presetID)")
            }
            try validate(entry: entry, for: card, directory: directory)
        }

        let jpegNames = try regularJPEGNames(in: directory)
        guard jpegNames == BuiltinPresetCatalog.expectedCoverFilenames else {
            throw BuiltinPresetCoverCurationError.invalidManifest(
                "the JPEG files do not exactly match the manifest assets")
        }
        return manifest
    }

    /// Resolves one bundled cover only when the complete manifest shape, exact recipe digest,
    /// fixed seed, byte count, dimensions, and asset checksum all agree. Any failure falls back to
    /// the honest UI placeholder instead of displaying unverified artwork.
    static func url(for card: PresetCard, bundle: Bundle) -> URL? {
        guard card.origin == .builtIn,
              let manifestURL = bundle.url(
                forResource: "builtin-preset-covers",
                withExtension: "json",
                subdirectory: "PresetCovers")
                ?? bundle.url(forResource: "builtin-preset-covers", withExtension: "json")
        else { return nil }
        return url(for: card, directory: manifestURL.deletingLastPathComponent())
    }

    static func url(for card: PresetCard, directory: URL) -> URL? {
        do {
            let manifest = try loadManifest(from: directory)
            try validateShape(manifest)
            guard let entry = manifest.covers.first(where: { $0.presetID == card.id }) else {
                return nil
            }
            try validate(entry: entry, for: card, directory: directory)
            return directory.appendingPathComponent(entry.assetFilename, isDirectory: false)
        } catch {
            return nil
        }
    }

    private static func loadManifest(from directory: URL) throws -> BuiltinPresetCoverManifest {
        try requireSafeDirectory(directory)
        let url = directory.appendingPathComponent(manifestFilename, isDirectory: false)
        guard isRegularFile(url),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw BuiltinPresetCoverCurationError.manifestMissing(url)
        }
        guard data.count <= 1_024 * 1_024 else {
            throw BuiltinPresetCoverCurationError.invalidManifest("manifest exceeds 1 MiB")
        }
        try requireExactPublicKeyShape(data)
        do {
            return try JSONDecoder().decode(BuiltinPresetCoverManifest.self, from: data)
        } catch {
            throw BuiltinPresetCoverCurationError.invalidManifest(error.localizedDescription)
        }
    }

    private static func validateShape(_ manifest: BuiltinPresetCoverManifest) throws {
        guard manifest.schema == BuiltinPresetCoverManifest.supportedSchema,
              manifest.version == BuiltinPresetCoverManifest.currentVersion else {
            throw BuiltinPresetCoverCurationError.invalidManifest(
                "unsupported schema or version")
        }
        guard manifest.covers.count == BuiltinPresetCatalog.stableIDs.count else {
            throw BuiltinPresetCoverCurationError.invalidManifest(
                "expected \(BuiltinPresetCatalog.stableIDs.count) covers, found \(manifest.covers.count)")
        }

        let ids = manifest.covers.map(\.presetID)
        let filenames = manifest.covers.map(\.assetFilename)
        let jpegHashes = manifest.covers.map(\.jpegSHA256)
        guard Set(ids).count == ids.count,
              Set(ids) == BuiltinPresetCatalog.stableIDs,
              Set(filenames).count == filenames.count,
              Set(filenames) == BuiltinPresetCatalog.expectedCoverFilenames,
              Set(jpegHashes).count == jpegHashes.count else {
            throw BuiltinPresetCoverCurationError.invalidManifest(
                "preset IDs or sealed assets are incomplete or duplicated")
        }

        for entry in manifest.covers {
            let expectedFilename = String(entry.presetID.dropFirst("builtin.".count)) + ".jpg"
            guard entry.presetID.hasPrefix("builtin."),
                  entry.assetFilename == expectedFilename,
                  isSHA256(entry.recipeSHA256),
                  isSHA256(entry.jpegSHA256),
                  entry.pixelWidth == BuiltinPresetCatalog.coverPixelSize,
                  entry.pixelHeight == BuiltinPresetCatalog.coverPixelSize,
                  (1 ... BuiltinPresetCatalog.maximumCoverBytes).contains(entry.byteCount),
                  entry.crop == cropPolicy || entry.crop == fullFrameLetterboxPolicy else {
                throw BuiltinPresetCoverCurationError.invalidManifest(
                    "invalid recipe or asset metadata for \(entry.presetID)")
            }
        }
    }

    /// `Codable` ignores unknown JSON keys by default. The public resource contract must instead
    /// fail closed so a stale curation manifest cannot silently retain private Gallery fields.
    private static func requireExactPublicKeyShape(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == manifestKeys,
              let covers = root["covers"] as? [[String: Any]],
              covers.allSatisfy({ Set($0.keys) == entryKeys })
        else {
            throw BuiltinPresetCoverCurationError.invalidManifest(
                "the public manifest contains missing or unexpected fields")
        }
    }

    private static func validate(
        entry: BuiltinPresetCoverManifest.Entry,
        for card: PresetCard,
        directory: URL
    ) throws {
        guard card.origin == .builtIn,
              card.coverFilename == entry.assetFilename,
              card.recipe.sampler.seed.fixedValue == entry.fixedSeed,
              entry.crop == cropPolicy(for: card),
              try recipeSHA256(card.recipe) == entry.recipeSHA256 else {
            throw BuiltinPresetCoverCurationError.invalidManifest(
                "recipe or seed mismatch for \(entry.presetID)")
        }

        let url = directory.appendingPathComponent(entry.assetFilename, isDirectory: false)
            .standardizedFileURL
        guard url.deletingLastPathComponent() == directory.standardizedFileURL,
              isRegularFile(url) else {
            throw BuiltinPresetCoverCurationError.invalidAsset(
                "\(entry.assetFilename) is missing or unsafe")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == entry.byteCount,
              data.count <= BuiltinPresetCatalog.maximumCoverBytes,
              sha256(data) == entry.jpegSHA256 else {
            throw BuiltinPresetCoverCurationError.invalidAsset(
                "checksum or byte count mismatch for \(entry.assetFilename)")
        }
        let dimensions = try BuiltinPresetCoverCodec.jpegDimensions(data)
        guard dimensions.width == BuiltinPresetCatalog.coverPixelSize,
              dimensions.height == BuiltinPresetCatalog.coverPixelSize else {
            throw BuiltinPresetCoverCurationError.invalidAsset(
                "\(entry.assetFilename) is not a 256 x 256 JPEG")
        }
    }

    fileprivate static func requireSafeDirectory(_ directory: URL) throws {
        let url = directory.standardizedFileURL
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw BuiltinPresetCoverCurationError.unsafeDirectory(url)
        }
    }

    fileprivate static func isRegularFile(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func regularJPEGNames(in directory: URL) throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        return Set(files.compactMap { url in
            guard url.pathExtension.lowercased() == "jpg", isRegularFile(url) else { return nil }
            return url.lastPathComponent
        })
    }
}

/// A developer curation service. It never renders, never modifies Gallery files, never accepts a
/// partial set, and never replaces an existing output. All files are built in a sibling staging
/// directory and moved into place only after the complete checksum contract validates.
enum BuiltinPresetCoverCurator {
    struct Selection: Hashable, Sendable {
        let presetID: String
        let generationID: UUID

        init(presetID: String, generationID: UUID) {
            self.presetID = presetID
            self.generationID = generationID
        }
    }

    @discardableResult
    static func publish(
        selections: [Selection],
        gallery: GenerationStore,
        catalog: ModelCatalog,
        destinationDirectory: URL
    ) async throws -> BuiltinPresetCoverManifest {
        let expectedCards = BuiltinPresetCatalog.cards(catalog: catalog)
        let expectedByID = Dictionary(uniqueKeysWithValues: expectedCards.map { ($0.id, $0) })
        let selectedIDs = selections.map(\.presetID)
        guard Set(selectedIDs).count == selections.count,
              Set(selectedIDs) == BuiltinPresetCatalog.stableIDs else {
            throw BuiltinPresetCoverCurationError.incompleteSelection(
                expected: BuiltinPresetCatalog.stableIDs,
                actual: Set(selectedIDs))
        }
        var seenGenerationIDs = Set<UUID>()
        for selection in selections where !seenGenerationIDs.insert(selection.generationID).inserted {
            throw BuiltinPresetCoverCurationError.duplicateGeneration(selection.generationID)
        }

        let destination = destinationDirectory.standardizedFileURL
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        try BuiltinPresetCoverContract.requireSafeDirectory(parent)
        guard !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw BuiltinPresetCoverCurationError.destinationExists(destination)
        }

        let galleryRecords = await gallery.all()
        let recordsByID = Dictionary(uniqueKeysWithValues: galleryRecords.map { ($0.id, $0) })
        let selectionByID = Dictionary(uniqueKeysWithValues: selections.map { ($0.presetID, $0) })
        let staging = parent.appendingPathComponent(
            ".preset-covers-staging-\(UUID().uuidString.lowercased())",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        var installed = false
        defer {
            if !installed { try? FileManager.default.removeItem(at: staging) }
        }

        var entries: [BuiltinPresetCoverManifest.Entry] = []
        for presetID in BuiltinPresetCatalog.stableIDs.sorted() {
            guard let selection = selectionByID[presetID],
                  let card = expectedByID[presetID] else {
                throw BuiltinPresetCoverCurationError.invalidManifest(
                    "built-in catalog changed during curation")
            }
            guard let generation = recordsByID[selection.generationID] else {
                throw BuiltinPresetCoverCurationError.generationNotFound(selection.generationID)
            }
            guard generation.recipeCapture == .exact else {
                throw BuiltinPresetCoverCurationError.inexactGalleryRecord(generation.id)
            }
            guard generation.recipe == card.recipe else {
                throw BuiltinPresetCoverCurationError.recipeMismatch(
                    presetID: presetID,
                    generationID: generation.id)
            }
            guard let sourceName = try? ManagedGenerationFileName(
                    validating: generation.imageFileName),
                  sourceName.identifier == generation.id,
                  sourceName.seed == card.recipe.sampler.seed.fixedValue else {
                throw BuiltinPresetCoverCurationError.sourceIdentityMismatch(generation.id)
            }

            // This API rechecks the source PNG against its private Gallery sidecar checksum.
            let pngData = try await gallery.pngDataForExport(for: generation)
            let cropPolicy = BuiltinPresetCoverContract.cropPolicy(for: card)
            let jpeg = try BuiltinPresetCoverCodec.canonicalJPEG(
                fromVerifiedGalleryPNG: pngData,
                expectedWidth: card.recipe.canvas.width,
                expectedHeight: card.recipe.canvas.height,
                cropPolicy: cropPolicy)
            guard let filename = card.coverFilename else {
                throw BuiltinPresetCoverCurationError.invalidManifest(
                    "\(presetID) has no stable cover filename")
            }
            let output = staging.appendingPathComponent(filename, isDirectory: false)
            try jpeg.write(to: output, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: output.path)

            entries.append(.init(
                presetID: presetID,
                assetFilename: filename,
                recipeSHA256: try BuiltinPresetCoverContract.recipeSHA256(card.recipe),
                fixedSeed: sourceName.seed,
                jpegSHA256: BuiltinPresetCoverContract.sha256(jpeg),
                pixelWidth: BuiltinPresetCatalog.coverPixelSize,
                pixelHeight: BuiltinPresetCatalog.coverPixelSize,
                byteCount: jpeg.count,
                crop: cropPolicy))
        }

        let manifest = BuiltinPresetCoverManifest(covers: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestURL = staging.appendingPathComponent(
            BuiltinPresetCoverContract.manifestFilename,
            isDirectory: false)
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: manifestURL.path)

        _ = try BuiltinPresetCoverContract.validate(
            directory: staging,
            expectedCards: expectedCards)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: destination)
        installed = true
        return manifest
    }
}

private enum BuiltinPresetCoverCodec {
    static func canonicalJPEG(
        fromVerifiedGalleryPNG data: Data,
        expectedWidth: Int,
        expectedHeight: Int,
        cropPolicy: String = BuiltinPresetCoverContract.cropPolicy
    ) throws -> Data {
        guard !data.isEmpty,
              data.count <= 256 * 1_024 * 1_024,
              data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .png) == true else {
            throw BuiltinPresetCoverCurationError.invalidSourcePNG("format or size")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width == expectedWidth, height == expectedHeight else {
            throw BuiltinPresetCoverCurationError.sourceDimensionsMismatch(
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: width,
                actualHeight: height)
        }
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        guard orientation == 1,
              width >= BuiltinPresetCatalog.coverPixelSize,
              height >= BuiltinPresetCatalog.coverPixelSize,
              Int64(width) * Int64(height) <= 40_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw BuiltinPresetCoverCurationError.invalidSourcePNG(
                "orientation, dimensions, or decode")
        }

        let outputSide = CGFloat(BuiltinPresetCatalog.coverPixelSize)
        let outputRect = CGRect(x: 0, y: 0, width: outputSide, height: outputSide)
        let sourceImage: CGImage
        let drawRect: CGRect
        switch cropPolicy {
        case BuiltinPresetCoverContract.cropPolicy:
            let side = min(image.width, image.height)
            let cropRect = CGRect(
                x: (image.width - side) / 2,
                y: (image.height - side) / 2,
                width: side,
                height: side)
            guard let cropped = image.cropping(to: cropRect) else {
                throw BuiltinPresetCoverCurationError.invalidSourcePNG("center crop")
            }
            sourceImage = cropped
            drawRect = outputRect
        case BuiltinPresetCoverContract.fullFrameLetterboxPolicy:
            sourceImage = image
            let scale = min(
                outputSide / CGFloat(image.width),
                outputSide / CGFloat(image.height))
            let fittedWidth = CGFloat(image.width) * scale
            let fittedHeight = CGFloat(image.height) * scale
            drawRect = CGRect(
                x: (outputSide - fittedWidth) / 2,
                y: (outputSide - fittedHeight) / 2,
                width: fittedWidth,
                height: fittedHeight)
        default:
            throw BuiltinPresetCoverCurationError.invalidSourcePNG(
                "unsupported crop policy")
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: BuiltinPresetCatalog.coverPixelSize,
                height: BuiltinPresetCatalog.coverPixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BuiltinPresetCoverCurationError.invalidSourcePNG("cover context")
        }
        context.setFillColor(
            cropPolicy == BuiltinPresetCoverContract.fullFrameLetterboxPolicy
                ? CGColor(gray: 0.035, alpha: 1)
                : CGColor(gray: 1, alpha: 1))
        context.fill(outputRect)
        context.interpolationQuality = .high
        context.draw(sourceImage, in: drawRect)
        guard let outputImage = context.makeImage() else {
            throw BuiltinPresetCoverCurationError.invalidSourcePNG("resize")
        }

        var smallestEncodedSize = Int.max
        for quality in [0.90, 0.82, 0.72, 0.62, 0.50, 0.40, 0.30] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil) else { continue }
            CGImageDestinationAddImage(destination, outputImage, [
                kCGImageDestinationLossyCompressionQuality: quality,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            let jpeg = output as Data
            smallestEncodedSize = min(smallestEncodedSize, jpeg.count)
            if jpeg.count <= BuiltinPresetCatalog.maximumCoverBytes { return jpeg }
        }
        throw BuiltinPresetCoverCurationError.coverTooLarge(
            smallestEncodedSize == .max ? 0 : smallestEncodedSize)
    }

    static func jpegDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .jpeg) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw BuiltinPresetCoverCurationError.invalidAsset("JPEG decode failed")
        }
        return (width, height)
    }
}
