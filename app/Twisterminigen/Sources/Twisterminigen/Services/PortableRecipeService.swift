import Darwin
import CryptoKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Public, JSON-backed document type used by Finder, open panels and Shortcuts.
    static let twisterRecipe = UTType(
        exportedAs: "com.twisterminigen.recipe",
        conformingTo: .json)
}

/// A portable recipe intentionally carries references, not arbitrary paths or opaque file payloads.
/// Missing private assets are reported during import instead of being silently removed.
struct PortableRecipeDocument: Codable, Equatable, Sendable {
    static let supportedSchema = "twisterminigen.portable-recipe"
    static let currentVersion = 1

    struct Dependencies: Codable, Equatable, Sendable {
        struct Model: Codable, Equatable, Sendable {
            var reference: GenerationRecipe.ModelReference
        }

        struct LoRA: Codable, Equatable, Sendable {
            var managedID: UUID
            var sha256: String
            var displayName: String?
        }

        struct Remix: Codable, Equatable, Sendable {
            var managedID: UUID
            var sha256: String
            var sourceGenerationID: UUID?
            var pixelWidth: Int?
            var pixelHeight: Int?
        }

        var model: Model
        var loras: [LoRA]
        var remix: Remix?
    }

    /// Explicit disclosure for an exported result. Recipe-only documents intentionally leave this
    /// nil; Gallery's "Export with recipe" path supplies it from the immutable Generation record.
    struct OutputProvenance: Codable, Equatable, Sendable {
        static let supportedSchema = "twisterminigen.ai-output-provenance"
        static let currentVersion = 1

        var schema: String
        var version: Int
        var aiGenerated: Bool
        var disclosure: String
        var generator: String
        var generatorVersion: String
        var generatorBuild: String
        var model: GenerationRecipe.ModelReference
        var generationID: UUID
        var generatedAt: Date
        var pngSHA256: String
        var pngByteCount: Int64

        init(generation: Generation, exportedPNGData: Data) {
            schema = Self.supportedSchema
            version = Self.currentVersion
            aiGenerated = true
            disclosure = "AI-generated locally with Krea 2; review the output before distribution."
            generator = "Twisterminigen"
            generatorVersion = generation.producerAppVersion ?? "unknown"
            generatorBuild = generation.producerAppBuild ?? "unknown"
            model = generation.recipe.model
            generationID = generation.id
            generatedAt = generation.createdAt
            pngSHA256 = SHA256.hash(data: exportedPNGData)
                .map { String(format: "%02x", $0) }
                .joined()
            pngByteCount = Int64(exportedPNGData.count)
        }

        func validate(recipe: GenerationRecipe) throws {
            guard schema == Self.supportedSchema,
                  version == Self.currentVersion,
                  aiGenerated,
                  disclosure == "AI-generated locally with Krea 2; review the output before distribution.",
                  generator == "Twisterminigen",
                  !generatorVersion.isEmpty,
                  !generatorBuild.isEmpty,
                  pngSHA256.count == 64,
                  pngSHA256.utf8.allSatisfy({
                      (48 ... 57).contains($0) || (97 ... 102).contains($0)
                  }),
                  pngByteCount > 0,
                  model == recipe.model else {
                throw PortableRecipeError.inconsistentDependencies("AI output provenance")
            }
        }
    }

    var schema: String
    var version: Int
    var recipe: GenerationRecipe
    var dependencies: Dependencies
    var outputProvenance: OutputProvenance?

    init(
        recipe: GenerationRecipe,
        loraSnapshot: LoRALibrarySnapshot = .empty,
        inputImageSnapshot: InputImageLibrarySnapshot = .empty
    ) {
        let loras = recipe.loras.map { reference in
            Dependencies.LoRA(
                managedID: reference.managedID,
                sha256: reference.sha256.lowercased(),
                displayName: loraSnapshot.assets.first(where: {
                    $0.id == reference.managedID
                        && $0.sha256.caseInsensitiveCompare(reference.sha256) == .orderedSame
                })?.name)
        }
        let remix = recipe.inputImage.map { reference in
            let asset = inputImageSnapshot.assets.first(where: {
                $0.id == reference.managedID
                    && $0.sha256.caseInsensitiveCompare(reference.sha256) == .orderedSame
            })
            return Dependencies.Remix(
                managedID: reference.managedID,
                sha256: reference.sha256.lowercased(),
                sourceGenerationID: reference.sourceGenerationID,
                pixelWidth: asset?.width,
                pixelHeight: asset?.height)
        }
        self.schema = Self.supportedSchema
        self.version = Self.currentVersion
        self.recipe = recipe
        self.dependencies = Dependencies(
            model: .init(reference: recipe.model),
            loras: loras,
            remix: remix)
        self.outputProvenance = nil
    }

    init(generation: Generation, exportedPNGData: Data) {
        self.init(recipe: generation.recipe)
        outputProvenance = OutputProvenance(
            generation: generation,
            exportedPNGData: exportedPNGData)
    }

    func validate() throws {
        guard schema == Self.supportedSchema else {
            throw PortableRecipeError.incompatibleSchema(schema)
        }
        guard version == Self.currentVersion else {
            throw PortableRecipeError.incompatibleVersion(version)
        }
        do {
            try recipe.validate(for: .request)
        } catch {
            throw PortableRecipeError.invalidRecipe(error.localizedDescription)
        }
        guard dependencies.model.reference == recipe.model else {
            throw PortableRecipeError.inconsistentDependencies("model reference")
        }
        guard dependencies.loras.count == recipe.loras.count else {
            throw PortableRecipeError.inconsistentDependencies("LoRA count")
        }
        for (dependency, reference) in zip(dependencies.loras, recipe.loras) {
            guard dependency.managedID == reference.managedID,
                  dependency.sha256.caseInsensitiveCompare(reference.sha256) == .orderedSame else {
                throw PortableRecipeError.inconsistentDependencies("ordered LoRA references")
            }
            if let name = dependency.displayName {
                try Self.validateHint(name, field: "LoRA display name", maximumBytes: 256)
            }
        }
        switch (dependencies.remix, recipe.inputImage) {
        case (nil, nil): break
        case let (.some(dependency), .some(reference)):
            guard dependency.managedID == reference.managedID,
                  dependency.sha256.caseInsensitiveCompare(reference.sha256) == .orderedSame,
                  dependency.sourceGenerationID == reference.sourceGenerationID else {
                throw PortableRecipeError.inconsistentDependencies("Remix reference")
            }
            for dimension in [dependency.pixelWidth, dependency.pixelHeight].compactMap({ $0 }) {
                guard (1 ... InputImageStoreLimits.standard.maximumDimension).contains(dimension) else {
                    throw PortableRecipeError.inconsistentDependencies("Remix dimensions")
                }
            }
        default:
            throw PortableRecipeError.inconsistentDependencies("Remix presence")
        }
        try outputProvenance?.validate(recipe: recipe)
    }

    private static func validateHint(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PortableRecipeError.invalidHint(field)
        }
    }
}

struct PortableRecipeImportReport: Equatable, Sendable {
    enum Issue: Equatable, Sendable {
        case modelBuildMissing(modelID: String, variantID: String)
        case modelWeightsMissing
        case loraMissing(id: UUID, name: String?)
        case loraHashMismatch(id: UUID, name: String?)
        case remixMissing(id: UUID)
        case remixHashMismatch(id: UUID)

        var description: String {
            switch self {
            case let .modelBuildMissing(modelID, variantID):
                return "Model build missing: \(modelID) / \(variantID)."
            case .modelWeightsMissing:
                return "The exact model build is selected, but one or more verified weight files are missing."
            case let .loraMissing(id, name):
                return "LoRA missing: \(name ?? id.uuidString)."
            case let .loraHashMismatch(id, name):
                return "LoRA content mismatch: \(name ?? id.uuidString)."
            case let .remixMissing(id):
                return "Remix source missing: \(id.uuidString)."
            case let .remixHashMismatch(id):
                return "Remix source content mismatch: \(id.uuidString)."
            }
        }
    }

    let document: PortableRecipeDocument
    let issues: [Issue]
    let importedLegacyRecipe: Bool

    var canApply: Bool { issues.isEmpty }
    var summary: String {
        if issues.isEmpty {
            return importedLegacyRecipe
                ? "Legacy recipe validated. All dependencies are available."
                : "Recipe validated. All dependencies are available."
        }
        return issues.map(\.description).joined(separator: "\n")
    }
}

enum PortableRecipeError: Error, Equatable, LocalizedError, Sendable {
    case unsafeSource(URL)
    case wrongExtension(URL)
    case fileTooLarge(maximumBytes: Int)
    case invalidJSON
    case unknownTopLevelFields([String])
    case incompatibleSchema(String)
    case incompatibleVersion(Int)
    case invalidRecipe(String)
    case inconsistentDependencies(String)
    case invalidHint(String)
    case invalidDestination(URL)
    case managedDestination(URL)
    case destinationExists(URL)
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeSource(let url):
            return "The selected recipe is not a readable regular file: \(url.lastPathComponent)."
        case .wrongExtension:
            return "Choose a .twisterrecipe document."
        case .fileTooLarge(let maximumBytes):
            return "The recipe exceeds the \(maximumBytes)-byte safety limit."
        case .invalidJSON:
            return "The recipe document is not valid JSON."
        case .unknownTopLevelFields(let fields):
            return "The recipe contains unsupported fields: \(fields.joined(separator: ", "))."
        case .incompatibleSchema(let schema):
            return "Unsupported recipe schema: \(schema)."
        case .incompatibleVersion(let version):
            return "This recipe requires a newer format version (\(version))."
        case .invalidRecipe(let reason):
            return "The embedded generation recipe is invalid: \(reason)"
        case .inconsistentDependencies(let field):
            return "The dependency manifest does not match the recipe (\(field))."
        case .invalidHint(let field):
            return "The portable dependency hint is invalid (\(field))."
        case .invalidDestination(let url):
            return "The recipe cannot be written to \(url.path)."
        case .managedDestination:
            return "Choose a destination outside Twisterminigen's managed storage."
        case .destinationExists:
            return "A file already exists at that destination; choose another name."
        case .writeFailed(let code):
            return "The recipe could not be written safely (POSIX \(code))."
        }
    }
}

enum PortableRecipeService {
    static let maximumDocumentBytes = 2 * 1_024 * 1_024

    static func encode(_ document: PortableRecipeDocument) throws -> Data {
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard !data.isEmpty, data.count <= maximumDocumentBytes else {
            throw PortableRecipeError.fileTooLarge(maximumBytes: maximumDocumentBytes)
        }
        return data
    }

    /// Supports the current envelope and the pre-envelope raw GenerationRecipe JSON shape.
    static func decode(_ data: Data) throws -> (document: PortableRecipeDocument, legacy: Bool) {
        guard !data.isEmpty, data.count <= maximumDocumentBytes else {
            throw PortableRecipeError.fileTooLarge(maximumBytes: maximumDocumentBytes)
        }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]) as? [String: Any] else {
                throw PortableRecipeError.invalidJSON
            }
            object = decoded
        } catch let error as PortableRecipeError {
            throw error
        } catch {
            throw PortableRecipeError.invalidJSON
        }

        let schema = object["schema"] as? String
        let decoder = JSONDecoder()
        do {
            if schema == PortableRecipeDocument.supportedSchema {
                let allowed = Set([
                    "schema", "version", "recipe", "dependencies", "outputProvenance",
                ])
                let unknown = Set(object.keys).subtracting(allowed).sorted()
                guard unknown.isEmpty else {
                    throw PortableRecipeError.unknownTopLevelFields(unknown)
                }
                let document = try decoder.decode(PortableRecipeDocument.self, from: data)
                try document.validate()
                return (document, false)
            }

            if schema == GenerationRecipe.supportedSchema {
                let recipe = try decoder.decode(GenerationRecipe.self, from: data)
                let document = PortableRecipeDocument(recipe: recipe)
                try document.validate()
                return (document, true)
            }
            throw PortableRecipeError.incompatibleSchema(schema ?? "missing")
        } catch let error as PortableRecipeError {
            throw error
        } catch {
            throw PortableRecipeError.invalidJSON
        }
    }

    static func inspect(
        _ document: PortableRecipeDocument,
        catalog: ModelCatalog,
        loraSnapshot: LoRALibrarySnapshot,
        inputImageSnapshot: InputImageLibrarySnapshot,
        modelWeightsReady: Bool,
        importedLegacyRecipe: Bool = false
    ) throws -> PortableRecipeImportReport {
        try document.validate()
        var issues: [PortableRecipeImportReport.Issue] = []

        if document.recipe.model != catalog.generationReference(
            for: document.recipe.model.quantizationTier) {
            issues.append(.modelBuildMissing(
                modelID: document.recipe.model.modelID,
                variantID: document.recipe.model.variantID))
        } else if !modelWeightsReady {
            issues.append(.modelWeightsMissing)
        }

        for dependency in document.dependencies.loras {
            guard let asset = loraSnapshot.assets.first(where: {
                $0.id == dependency.managedID
            }) else {
                issues.append(.loraMissing(
                    id: dependency.managedID,
                    name: dependency.displayName))
                continue
            }
            if asset.sha256.caseInsensitiveCompare(dependency.sha256) != .orderedSame {
                issues.append(.loraHashMismatch(
                    id: dependency.managedID,
                    name: dependency.displayName ?? asset.name))
            }
        }

        if let dependency = document.dependencies.remix {
            if let asset = inputImageSnapshot.assets.first(where: {
                $0.id == dependency.managedID
            }) {
                if asset.sha256.caseInsensitiveCompare(dependency.sha256) != .orderedSame {
                    issues.append(.remixHashMismatch(id: dependency.managedID))
                }
            } else {
                issues.append(.remixMissing(id: dependency.managedID))
            }
        }
        return PortableRecipeImportReport(
            document: document,
            issues: issues,
            importedLegacyRecipe: importedLegacyRecipe)
    }

    static func read(from source: URL) throws -> (PortableRecipeDocument, Bool) {
        let source = source.standardizedFileURL
        guard source.pathExtension.lowercased() == "twisterrecipe" else {
            throw PortableRecipeError.wrongExtension(source)
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        // Validate and consume the same descriptor. A path-level resourceValues/Data(contentsOf:)
        // pair would leave a replacement window between the check and the read.
        let descriptor = source.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw PortableRecipeError.unsafeSource(source)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw PortableRecipeError.unsafeSource(source)
        }
        guard status.st_size <= off_t(maximumDocumentBytes) else {
            throw PortableRecipeError.fileTooLarge(maximumBytes: maximumDocumentBytes)
        }

        let expectedSize = Int(status.st_size)
        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumDocumentBytes))
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                while true {
                    let result = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else { throw PortableRecipeError.unsafeSource(source) }
            guard count > 0 else { break }
            guard data.count <= maximumDocumentBytes - count else {
                throw PortableRecipeError.fileTooLarge(maximumBytes: maximumDocumentBytes)
            }
            buffer.withUnsafeBytes { bytes in
                data.append(bytes.bindMemory(to: UInt8.self).baseAddress!, count: count)
            }
        }
        guard data.count == expectedSize else { throw PortableRecipeError.unsafeSource(source) }
        let decoded = try decode(data)
        return (decoded.document, decoded.legacy)
    }

    /// Secure no-overwrite writer. Save panels can ask before replacement, but the service still
    /// refuses races and symlink destinations instead of trusting UI state.
    static func write(
        _ document: PortableRecipeDocument,
        to destination: URL,
        protectedRoots: [URL] = []
    ) throws -> ExternalPublicationOutcome {
        let destination = destination.standardizedFileURL
        guard destination.pathExtension.lowercased() == "twisterrecipe" else {
            throw PortableRecipeError.wrongExtension(destination)
        }
        let data = try encode(document)
        let outcome = ValidatedExternalPublisher.publishDocument(
            data,
            to: destination,
            kind: .portableRecipe,
            protectedRoots: protectedRoots)
        if case .failedBeforeVisibility(_, let error) = outcome {
            switch error {
            case .wrongExtension:
                throw PortableRecipeError.wrongExtension(destination)
            case .invalidDestination, .duplicateDestination:
                throw PortableRecipeError.invalidDestination(destination)
            case .managedDestination:
                throw PortableRecipeError.managedDestination(destination)
            case .destinationExists:
                throw PortableRecipeError.destinationExists(destination)
            case .writeFailed(let code):
                throw PortableRecipeError.writeFailed(code)
            }
        }
        return outcome
    }
}
