import CryptoKit
import Darwin
import Foundation

struct QueueRecipeMetadataDocument: Codable, Equatable, Sendable {
    static let supportedSchema = "twisterminigen.queue-recipe-metadata"
    static let currentVersion = 1

    let schema: String
    let version: Int
    let exportedAt: Date
    let queueJobID: UUID
    let recipeSHA256: String
    let recipe: GenerationRecipe
    let dependencies: PortableRecipeDocument.Dependencies
    let provenance: GenerationProvenance?

    init(job: QueueJob, exportedAt: Date = Date()) throws {
        let portable = PortableRecipeDocument(recipe: job.recipe)
        try portable.validate()
        schema = Self.supportedSchema
        version = Self.currentVersion
        self.exportedAt = exportedAt
        queueJobID = job.id
        recipeSHA256 = try QueueRecipeMetadataService.recipeSHA256(job.recipe)
        recipe = job.recipe
        dependencies = portable.dependencies
        provenance = job.provenance
    }

    func validate() throws {
        guard schema == Self.supportedSchema, version == Self.currentVersion else {
            throw QueueRecipeMetadataError.invalidDocument
        }
        try recipe.validate(for: .request)
        try provenance?.validate(recipe: recipe)
        let portable = PortableRecipeDocument(recipe: recipe)
        guard dependencies.model.reference == portable.dependencies.model.reference,
              dependencies.loras.map(\.managedID) == portable.dependencies.loras.map(\.managedID),
              dependencies.loras.map(\.sha256) == portable.dependencies.loras.map(\.sha256),
              dependencies.remix?.managedID == portable.dependencies.remix?.managedID,
              dependencies.remix?.sha256 == portable.dependencies.remix?.sha256,
              recipeSHA256 == (try QueueRecipeMetadataService.recipeSHA256(recipe)) else {
            throw QueueRecipeMetadataError.invalidDocument
        }
    }
}

enum QueueRecipeMetadataError: Error, Equatable, LocalizedError, Sendable {
    case wrongExtension
    case destinationExists(URL)
    case invalidDestination(URL)
    case managedDestination(URL)
    case invalidDocument
    case writeFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .wrongExtension: return "Choose a .json destination for queue metadata."
        case .destinationExists(let url): return "\(url.lastPathComponent) already exists."
        case .invalidDestination(let url): return "Queue metadata cannot be written to \(url.path)."
        case .managedDestination:
            return "Choose a queue metadata destination outside Twisterminigen's managed storage."
        case .invalidDocument: return "The queue recipe metadata is internally inconsistent."
        case .writeFailure(let code): return "Queue metadata export failed (POSIX \(code))."
        }
    }
}

enum QueueRecipeMetadataService {
    static func recipeSHA256(_ recipe: GenerationRecipe) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(recipe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encoded(_ document: QueueRecipeMetadataDocument) throws -> Data {
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    static func write(
        _ document: QueueRecipeMetadataDocument,
        to destination: URL,
        protectedRoots: [URL] = []
    ) throws -> ExternalPublicationOutcome {
        let destination = destination.standardizedFileURL
        guard destination.pathExtension.lowercased() == "json" else {
            throw QueueRecipeMetadataError.wrongExtension
        }
        let data = try encoded(document)
        let outcome = ValidatedExternalPublisher.publishDocument(
            data,
            to: destination,
            kind: .queueRecipeMetadata,
            protectedRoots: protectedRoots)
        if case .failedBeforeVisibility(_, let error) = outcome {
            switch error {
            case .wrongExtension:
                throw QueueRecipeMetadataError.wrongExtension
            case .invalidDestination, .duplicateDestination:
                throw QueueRecipeMetadataError.invalidDestination(destination)
            case .managedDestination:
                throw QueueRecipeMetadataError.managedDestination(destination)
            case .destinationExists:
                throw QueueRecipeMetadataError.destinationExists(destination)
            case .writeFailed(let code):
                throw QueueRecipeMetadataError.writeFailure(code)
            }
        }
        return outcome
    }
}
