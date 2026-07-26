import Foundation

enum QueueJobEditDraftError: Error, Equatable, LocalizedError {
    case invalidSeed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSeed(let value):
            return "Seed “\(value)” is invalid. Enter a non-negative whole number or leave it empty for random."
        }
    }
}

/// Editable Queue fields. Applying a draft changes only the controls shown in the inline editor;
/// model, LoRA, Remix, Regions, schedule, precision, and guidance stay byte-for-byte unchanged.
struct QueueJobEditDraft: Equatable {
    var prompt: String
    var negativePrompt: String
    var exactText: String
    var width: Int
    var height: Int
    var steps: Int
    var seedText: String

    init(job: QueueJob) {
        prompt = job.recipe.prompts.positive
        negativePrompt = job.recipe.prompts.negative
        exactText = job.recipe.prompts.exactText ?? ""
        width = job.recipe.canvas.width
        height = job.recipe.canvas.height
        steps = job.recipe.sampler.steps
        seedText = job.seedText
    }

    var seedIsValid: Bool {
        let trimmed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || UInt64(trimmed) != nil
    }

    func applying(to job: QueueJob) throws -> GenerationRecipe {
        var edited = job.recipe
        edited.prompts.positive = prompt
        edited.prompts.negative = negativePrompt
        edited.prompts.exactText = exactText.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty ? nil : exactText
        edited.canvas = .init(width: width, height: height)
        edited.sampler.steps = steps

        let trimmedSeed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSeed.isEmpty {
            edited.sampler.seed = .random
        } else if let seed = UInt64(trimmedSeed) {
            edited.sampler.seed = .fixed(seed)
        } else {
            throw QueueJobEditDraftError.invalidSeed(seedText)
        }

        try edited.validate(for: .request)
        return edited
    }
}
