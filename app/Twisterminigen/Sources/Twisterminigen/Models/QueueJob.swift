import Foundation

enum QueueDuplicateSeedMode: String, CaseIterable, Sendable, Equatable, Identifiable {
    case same
    case random
    case sequential

    var id: String { rawValue }

    var title: String {
        switch self {
        case .same: return "Same seed"
        case .random: return "Random seed"
        case .sequential: return "Sequential seeds"
        }
    }

    var help: String {
        switch self {
        case .same: return "Reuse the source job's fixed seed for every copy."
        case .random: return "Resolve an independent random seed when each copy begins."
        case .sequential: return "Advance the source fixed seed by one for each copy."
        }
    }
}

enum QueueJobDuplicationError: Error, Equatable, LocalizedError, Sendable {
    case sequentialSeedRequiresFixedSeed
    case sequentialSeedOverflow(base: UInt64, offset: Int)
    case invalidCopyCount(Int)

    var errorDescription: String? {
        switch self {
        case .sequentialSeedRequiresFixedSeed:
            return "Sequential duplication needs a fixed source seed. Choose Same or Random for this job."
        case let .sequentialSeedOverflow(base, offset):
            return "Seed \(base) cannot be advanced by \(offset) without overflowing UInt64."
        case let .invalidCopyCount(count):
            return "Generate Again needs 1...\(QueueLab.maximumJobCount) copies; received \(count)."
        }
    }
}

/// One durable generation request waiting for queue execution.
struct QueueJob: Codable, Identifiable, Sendable, Equatable {
    static let legacyModelReference = ModelCatalog(
        root: URL(fileURLWithPath: "/", isDirectory: true)
    ).generationReference

    let id: UUID
    let recipe: GenerationRecipe
    let provenance: GenerationProvenance?

    init(
        id: UUID = UUID(),
        recipe: GenerationRecipe,
        provenance: GenerationProvenance? = nil
    ) {
        self.id = id
        self.recipe = recipe
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case recipe
        case provenance
    }

    /// A queued recipe remains usable when its historical grouping metadata is no longer
    /// supported. The recipe is decoded as an independent pending job.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        recipe = try container.decode(GenerationRecipe.self, forKey: .recipe)
        provenance = try GenerationProvenanceCoding.decode(
            from: container,
            forKey: .provenance)
    }

    /// Compatibility initializer for callers that still expose the original Turbo controls.
    init(
        id: UUID = UUID(),
        prompt: String,
        width: Int = 1_024,
        height: Int = 1_024,
        steps: Int = 8,
        seedText: String = ""
    ) {
        self.init(
            id: id,
            recipe: Self.legacyTurboRecipe(
                prompt: prompt,
                width: width,
                height: height,
                steps: steps,
                seed: Self.seed(from: seedText)))
    }

    var prompt: String {
        recipe.prompts.positive
    }

    var width: Int {
        recipe.canvas.width
    }

    var height: Int {
        recipe.canvas.height
    }

    var steps: Int {
        recipe.sampler.steps
    }

    /// The intended Gallery parent survives queue persistence, duplication, and crash recovery
    /// because it is part of the exact recipe rather than transient Generate UI state.
    var parentGenerationID: UUID? { recipe.parentGenerationID }

    /// Empty means random, matching the original Generate form convention.
    var seedText: String {
        switch recipe.sampler.seed {
        case .random: ""
        case .fixed(let seed): String(seed)
        }
    }

    static func legacyTurboRecipe(
        prompt: String,
        width: Int,
        height: Int,
        steps: Int,
        seed: GenerationRecipe.Seed
    ) -> GenerationRecipe {
        var recipe = GenerationRecipe.turbo(
            prompt: prompt,
            model: legacyModelReference,
            seed: seed)
        recipe.canvas = .init(width: width, height: height)
        recipe.sampler.steps = steps
        return recipe
    }

    private static func seed(from seedText: String) -> GenerationRecipe.Seed {
        let value = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let seed = UInt64(value) else { return .random }
        return .fixed(seed)
    }

    /// Replaces one pending recipe without moving it or changing its durable queue identity.
    /// Manual edits deliberately clear experiment provenance: after a user changes a Queue Lab or
    /// Batch coordinate it is an independent request, not the original point.
    func replacingRecipe(_ recipe: GenerationRecipe) -> QueueJob {
        QueueJob(id: id, recipe: recipe, provenance: nil)
    }

    /// Creates an independent queue request. Experiment provenance is deliberately cleared:
    /// another execution is not the original Batch/Queue Lab coordinate.
    func duplicate(
        id newID: UUID = UUID(),
        seedMode: QueueDuplicateSeedMode,
        sequenceOffset: Int = 1
    ) throws -> QueueJob {
        var copy = recipe
        switch seedMode {
        case .same:
            break
        case .random:
            copy.sampler.seed = .random
        case .sequential:
            guard case let .fixed(base) = copy.sampler.seed else {
                throw QueueJobDuplicationError.sequentialSeedRequiresFixedSeed
            }
            guard sequenceOffset > 0 else {
                throw QueueJobDuplicationError.invalidCopyCount(sequenceOffset)
            }
            guard let offset = UInt64(exactly: sequenceOffset) else {
                throw QueueJobDuplicationError.sequentialSeedOverflow(
                    base: base,
                    offset: sequenceOffset)
            }
            let (next, additionOverflow) = base.addingReportingOverflow(offset)
            guard !additionOverflow else {
                throw QueueJobDuplicationError.sequentialSeedOverflow(
                    base: base,
                    offset: sequenceOffset)
            }
            copy.sampler.seed = .fixed(next)
        }
        return QueueJob(id: newID, recipe: copy, provenance: nil)
    }
}
