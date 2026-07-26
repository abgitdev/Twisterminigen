import Foundation

/// Describes whether every recipe field was captured by the caller or inferred while preserving
/// an older scalar gallery record.
enum GenerationRecipeCapture: String, Codable, Sendable, Hashable {
    case exact
    case legacy

    // Compatibility spellings keep call sites expressive without multiplying persisted values.
    static let complete: Self = .exact
    static let compatibility: Self = .legacy
}

/// Describes how a generated result relates to the other results around it. This is result
/// provenance, not an input to diffusion, so it deliberately lives beside `Generation` instead
/// of inside the deterministic `GenerationRecipe`.
struct GenerationProvenance: Codable, Sendable, Hashable {
    static let maximumGroupCount = 64
    static let maximumBatchCount = 8

    enum Kind: String, Codable, Sendable, Hashable {
        case batch
        case queueLab
    }

    struct QueueLabGrid: Codable, Sendable, Hashable {
        let seedIndex: Int
        let seedCount: Int
        let xIndex: Int
        let xCount: Int
        let xLabel: String?
        let yIndex: Int
        let yCount: Int
        let yLabel: String?
    }

    let kind: Kind
    let groupID: UUID
    let itemIndex: Int
    let itemCount: Int
    let queueLabGrid: QueueLabGrid?
    /// Present for Queue Lab 2.0 groups. Optional keeps every pre-2.0 queue/gallery document
    /// decodable and distinguishes a genuinely replayable table from legacy coordinate-only data.
    let experimentContext: ExperimentContext?

    static func batch(groupID: UUID, itemIndex: Int, itemCount: Int) -> Self {
        Self(
            kind: .batch,
            groupID: groupID,
            itemIndex: itemIndex,
            itemCount: itemCount,
            queueLabGrid: nil,
            experimentContext: nil)
    }

    static func queueLab(
        groupID: UUID,
        itemIndex: Int,
        itemCount: Int,
        grid: QueueLabGrid,
        experimentContext: ExperimentContext? = nil
    ) -> Self {
        Self(
            kind: .queueLab,
            groupID: groupID,
            itemIndex: itemIndex,
            itemCount: itemCount,
            queueLabGrid: grid,
            experimentContext: experimentContext)
    }

    func validate(recipe: GenerationRecipe? = nil) throws {
        guard (1 ... Self.maximumGroupCount).contains(itemCount) else {
            throw ValidationError.invalidItemCount(itemCount)
        }
        guard (0 ..< itemCount).contains(itemIndex) else {
            throw ValidationError.invalidItemIndex(itemIndex, count: itemCount)
        }

        switch kind {
        case .batch:
            guard itemCount <= Self.maximumBatchCount else {
                throw ValidationError.invalidItemCount(itemCount)
            }
            guard queueLabGrid == nil else {
                throw ValidationError.unexpectedGrid
            }
            guard experimentContext == nil else {
                throw ValidationError.unexpectedExperimentContext
            }
        case .queueLab:
            guard let grid = queueLabGrid else {
                throw ValidationError.missingGrid
            }
            let counts = [grid.seedCount, grid.xCount, grid.yCount]
            guard counts.allSatisfy({ (1 ... Self.maximumGroupCount).contains($0) }),
                  (0 ..< grid.seedCount).contains(grid.seedIndex),
                  (0 ..< grid.xCount).contains(grid.xIndex),
                  (0 ..< grid.yCount).contains(grid.yIndex) else {
                throw ValidationError.invalidGrid
            }
            let (sweepCount, sweepOverflow) = grid.xCount.multipliedReportingOverflow(
                by: grid.yCount)
            let (expectedCount, countOverflow) = grid.seedCount.multipliedReportingOverflow(
                by: sweepCount)
            let expectedIndex = (grid.seedIndex * grid.yCount + grid.yIndex) * grid.xCount
                + grid.xIndex
            guard !sweepOverflow, !countOverflow,
                  expectedCount == itemCount, expectedIndex == itemIndex else {
                throw ValidationError.invalidGrid
            }
            for label in [grid.xLabel, grid.yLabel].compactMap({ $0 }) {
                guard !label.isEmpty, label.utf8.count <= 128,
                      label.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw ValidationError.invalidGridLabel
                }
            }
            if let experimentContext {
                let preview: QueueLab.Preview
                do {
                    preview = try experimentContext.preview()
                } catch {
                    throw ValidationError.invalidExperimentContext(error.localizedDescription)
                }
                let expectedXLabel = QueueLab.axisLabel(
                    experimentContext.configuration.xAxis,
                    in: experimentContext.sourceRecipe)
                let expectedYLabel = QueueLab.axisLabel(
                    experimentContext.configuration.yAxis,
                    in: experimentContext.sourceRecipe)
                guard preview.jobCount == itemCount,
                      preview.seeds.count == grid.seedCount,
                      max(1, preview.xValues.count) == grid.xCount,
                      max(1, preview.yValues.count) == grid.yCount,
                      expectedXLabel == grid.xLabel,
                      expectedYLabel == grid.yLabel else {
                    throw ValidationError.inconsistentExperimentContext
                }
                if let recipe,
                   preview.entries[itemIndex].recipe != recipe {
                    throw ValidationError.inconsistentExperimentRecipe
                }
            }
        }
    }

    enum ValidationError: Error, Equatable, LocalizedError {
        case invalidItemCount(Int)
        case invalidItemIndex(Int, count: Int)
        case unexpectedGrid
        case unexpectedExperimentContext
        case missingGrid
        case invalidGrid
        case invalidGridLabel
        case invalidExperimentContext(String)
        case inconsistentExperimentContext
        case inconsistentExperimentRecipe

        var errorDescription: String? {
            switch self {
            case .invalidItemCount(let count):
                return "Gallery group count \(count) is outside the supported range."
            case .invalidItemIndex(let index, let count):
                return "Gallery group index \(index) is invalid for \(count) items."
            case .unexpectedGrid:
                return "A direct batch cannot contain Queue Lab coordinates."
            case .unexpectedExperimentContext:
                return "A direct batch cannot contain a Queue Lab experiment context."
            case .missingGrid:
                return "Queue Lab provenance is missing its grid coordinates."
            case .invalidGrid:
                return "Queue Lab provenance contains inconsistent grid coordinates."
            case .invalidGridLabel:
                return "Queue Lab provenance contains an invalid axis label."
            case .invalidExperimentContext(let reason):
                return "Queue Lab experiment context is invalid: \(reason)"
            case .inconsistentExperimentContext:
                return "Queue Lab experiment context does not match its grid coordinates."
            case .inconsistentExperimentRecipe:
                return "Queue Lab experiment context does not reproduce this cell’s recipe."
            }
        }
    }
}

enum GenerationProvenanceCoding {
    private struct KindProbe: Decodable {
        let kind: String
    }

    /// Unknown retired grouping kinds are discarded for compatibility. Metadata for every current
    /// kind still decodes strictly so corruption cannot bypass validation.
    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> GenerationProvenance? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else {
            return nil
        }
        let probe = try container.decode(KindProbe.self, forKey: key)
        guard GenerationProvenance.Kind(rawValue: probe.kind) != nil else {
            return nil
        }
        return try container.decode(GenerationProvenance.self, forKey: key)
    }
}

/// A persisted record of one generated image. Pure app/Foundation types keep gallery persistence
/// decoupled from engine request types.
struct Generation: Codable, Identifiable, Sendable, Hashable {
    typealias RecipeCapture = GenerationRecipeCapture
    static let maximumDurationSeconds = 365.0 * 24 * 60 * 60

    let id: UUID
    let recipe: GenerationRecipe
    let recipeCapture: GenerationRecipeCapture
    let createdAt: Date
    let durationSeconds: Double
    let imageFileName: String    // relative to LibraryPaths.images
    let provenance: GenerationProvenance?
    let completionID: UUID?
    /// Producer identity is captured when the image is created, not when it is later exported.
    /// Optional keeps pre-release Gallery records decodable and makes their provenance explicit
    /// as unknown instead of falsely attributing them to the current app build.
    let producerAppVersion: String?
    let producerAppBuild: String?
    /// Optional so every pre-P3 gallery/index/sidecar remains decodable without migration.
    let performance: GenerationPerformanceMetrics?
    /// Optional so pre-Stage-5 gallery records remain decodable without a migration pass.
    let typographyQA: TypographyQAResult?

    init(
        id: UUID = UUID(),
        recipe: GenerationRecipe,
        recipeCapture: GenerationRecipeCapture = .exact,
        createdAt: Date = Date(),
        durationSeconds: Double,
        imageFileName: String,
        provenance: GenerationProvenance? = nil,
        completionID: UUID? = nil,
        producerAppVersion: String? = AppVersion.current,
        producerAppBuild: String? = AppVersion.build,
        performance: GenerationPerformanceMetrics? = nil,
        typographyQA: TypographyQAResult? = nil
    ) {
        self.id = id
        self.recipe = recipe
        self.recipeCapture = recipeCapture
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.imageFileName = imageFileName
        self.provenance = provenance
        self.completionID = completionID
        self.producerAppVersion = producerAppVersion
        self.producerAppBuild = producerAppBuild
        self.performance = performance
        self.typographyQA = typographyQA
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case recipe
        case recipeCapture
        case createdAt
        case durationSeconds
        case imageFileName
        case provenance
        case completionID
        case producerAppVersion
        case producerAppBuild
        case performance
        case typographyQA
    }

    /// Unsupported historical grouping metadata is intentionally discarded while the generation
    /// record and its managed image remain available as an ordinary Gallery result.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        recipe = try container.decode(GenerationRecipe.self, forKey: .recipe)
        recipeCapture = try container.decode(GenerationRecipeCapture.self, forKey: .recipeCapture)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        imageFileName = try container.decode(String.self, forKey: .imageFileName)
        provenance = try GenerationProvenanceCoding.decode(
            from: container,
            forKey: .provenance)
        completionID = try container.decodeIfPresent(UUID.self, forKey: .completionID)
        producerAppVersion = try container.decodeIfPresent(
            String.self,
            forKey: .producerAppVersion)
        producerAppBuild = try container.decodeIfPresent(
            String.self,
            forKey: .producerAppBuild)
        performance = try container.decodeIfPresent(
            GenerationPerformanceMetrics.self,
            forKey: .performance)
        typographyQA = try container.decodeIfPresent(
            TypographyQAResult.self,
            forKey: .typographyQA)
    }

    /// Source compatibility for the gallery UI and tests that still provide scalar settings.
    init(
        id: UUID = UUID(),
        prompt: String,
        width: Int,
        height: Int,
        steps: Int,
        seed: UInt64,
        createdAt: Date = Date(),
        durationSeconds: Double,
        imageFileName: String,
        provenance: GenerationProvenance? = nil,
        completionID: UUID? = nil,
        producerAppVersion: String? = AppVersion.current,
        producerAppBuild: String? = AppVersion.build,
        performance: GenerationPerformanceMetrics? = nil,
        typographyQA: TypographyQAResult? = nil
    ) {
        self.init(
            id: id,
            recipe: Self.compatibilityRecipe(
                prompt: prompt,
                width: width,
                height: height,
                steps: steps,
                seed: seed),
            recipeCapture: .legacy,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            imageFileName: imageFileName,
            provenance: provenance,
            completionID: completionID,
            producerAppVersion: producerAppVersion,
            producerAppBuild: producerAppBuild,
            performance: performance,
            typographyQA: typographyQA)
    }

    // Legacy gallery/UI accessors. The canonical values live in `recipe`.
    var prompt: String { recipe.prompts.positive }
    var width: Int { recipe.canvas.width }
    var height: Int { recipe.canvas.height }
    var steps: Int { recipe.sampler.steps }
    var seed: UInt64 { recipe.sampler.seed.fixedValue ?? 0 }
    var parentGenerationID: UUID? { recipe.parentGenerationID }
    var isRemix: Bool { recipe.inputImage != nil }

    /// Absolute URL of the image in the production library.
    var imageURL: URL { AppPaths.images.appendingPathComponent(imageFileName) }

    /// "1m 32s" / "47s".
    var durationText: String {
        guard durationSeconds.isFinite, durationSeconds >= 0 else { return "Unknown" }
        let bounded = min(durationSeconds, Self.maximumDurationSeconds)
        let seconds = Int(bounded.rounded(.towardZero))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    static func compatibilityRecipe(
        prompt: String,
        width: Int,
        height: Int,
        steps: Int,
        seed: UInt64
    ) -> GenerationRecipe {
        var recipe = GenerationRecipe.turbo(
            prompt: prompt,
            model: compatibilityModel,
            seed: .fixed(seed))
        recipe.canvas = .init(width: width, height: height)
        recipe.sampler.steps = steps
        return recipe
    }

    private static let compatibilityModel = GenerationRecipe.ModelReference(
        modelID: "krea-2-turbo",
        variantID: "alis-mixed-4-8",
        // This is the immutable identity of the app's pinned catalog, not a local-file probe.
        manifestHash: ModelCatalog(root: URL(fileURLWithPath: "/", isDirectory: true)).pinnedIdentity)
}

/// The exact pre-recipe JSON shape. Keeping this separate from `Generation` prevents permissive
/// fallback decoding from silently accepting malformed current records.
struct LegacyGenerationRecord: Codable, Sendable, Hashable {
    let id: UUID
    let prompt: String
    let width: Int
    let height: Int
    let steps: Int
    let seed: UInt64
    let createdAt: Date
    let durationSeconds: Double
    let imageFileName: String
    let completionID: UUID?

    init(
        id: UUID,
        prompt: String,
        width: Int,
        height: Int,
        steps: Int,
        seed: UInt64,
        createdAt: Date,
        durationSeconds: Double,
        imageFileName: String,
        completionID: UUID? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.imageFileName = imageFileName
        self.completionID = completionID
    }

    init(_ generation: Generation) {
        self.init(
            id: generation.id,
            prompt: generation.prompt,
            width: generation.width,
            height: generation.height,
            steps: generation.steps,
            seed: generation.seed,
            createdAt: generation.createdAt,
            durationSeconds: generation.durationSeconds,
            imageFileName: generation.imageFileName,
            completionID: generation.completionID)
    }

    var migrated: Generation {
        Generation(
            id: id,
            prompt: prompt,
            width: width,
            height: height,
            steps: steps,
            seed: seed,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            imageFileName: imageFileName,
            completionID: completionID)
    }
}

struct GenerationIndexEnvelope: Codable, Sendable, Hashable {
    static let supportedSchema = "twisterminigen.generation-index"
    static let currentVersion = 1

    let schema: String
    let version: Int
    let generations: [Generation]

    init(
        schema: String = Self.supportedSchema,
        version: Int = Self.currentVersion,
        generations: [Generation]
    ) {
        self.schema = schema
        self.version = version
        self.generations = generations
    }
}

struct GenerationSidecarEnvelope: Codable, Sendable, Hashable {
    static let supportedSchema = "twisterminigen.generation-sidecar"
    static let currentVersion = 1

    let schema: String
    let version: Int
    let generation: Generation
    let pngByteCount: Int64
    let pngSHA256: String

    init(
        schema: String = Self.supportedSchema,
        version: Int = Self.currentVersion,
        generation: Generation,
        pngByteCount: Int64,
        pngSHA256: String
    ) {
        self.schema = schema
        self.version = version
        self.generation = generation
        self.pngByteCount = pngByteCount
        self.pngSHA256 = pngSHA256
    }
}
