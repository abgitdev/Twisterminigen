import Foundation

/// A presentation-neutral, exhaustive comparison of two persisted recipes. Values use exact
/// round-trippable scalar strings so a difference is never hidden by display rounding.
struct GalleryRecipeComparison: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let label: String
        let left: String
        let right: String

        var id: String { label }
        var isDifferent: Bool { left != right }
    }

    let rows: [Row]

    init(left: GenerationRecipe, right: GenerationRecipe) {
        rows = [
            Row(label: "Recipe schema", left: left.schema, right: right.schema),
            Row(label: "Recipe version", left: String(left.version), right: String(right.version)),
            Row(label: "Positive prompt", left: left.prompts.positive, right: right.prompts.positive),
            Row(label: "Negative prompt", left: Self.visible(left.prompts.negative), right: Self.visible(right.prompts.negative)),
            Row(label: "Visible text", left: Self.visible(left.prompts.exactText), right: Self.visible(right.prompts.exactText)),
            Row(label: "Model", left: left.model.modelID, right: right.model.modelID),
            Row(label: "Variant", left: left.model.variantID, right: right.model.variantID),
            Row(label: "Checkpoint", left: left.model.checkpointFamily.rawValue, right: right.model.checkpointFamily.rawValue),
            Row(label: "Quantization", left: left.model.quantizationTier.rawValue, right: right.model.quantizationTier.rawValue),
            Row(label: "Manifest", left: left.model.manifestHash, right: right.model.manifestHash),
            Row(label: "Canvas", left: Self.canvas(left.canvas), right: Self.canvas(right.canvas)),
            Row(label: "Steps", left: String(left.sampler.steps), right: String(right.sampler.steps)),
            Row(label: "Seed", left: Self.seed(left.sampler.seed), right: Self.seed(right.sampler.seed)),
            Row(label: "Guidance", left: Self.scalar(left.sampler.guidance), right: Self.scalar(right.sampler.guidance)),
            Row(label: "Precision", left: left.sampler.precision.rawValue, right: right.sampler.precision.rawValue),
            Row(label: "Schedule", left: Self.schedule(left.sampler.schedule), right: Self.schedule(right.sampler.schedule)),
            Row(label: "LoRAs", left: Self.loras(left.loras), right: Self.loras(right.loras)),
            Row(label: "Regions", left: Self.regions(left.regions), right: Self.regions(right.regions)),
            Row(label: "Input image", left: Self.inputImage(left.inputImage), right: Self.inputImage(right.inputImage)),
        ]
    }

    var differenceCount: Int { rows.lazy.filter { $0.isDifferent }.count }

    private static func visible(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    private static func canvas(_ value: GenerationRecipe.Canvas) -> String {
        "\(value.width) × \(value.height)"
    }

    private static func seed(_ value: GenerationRecipe.Seed) -> String {
        switch value {
        case .random: return "Random"
        case .fixed(let seed): return String(seed)
        }
    }

    private static func scalar(_ value: Double) -> String {
        String(value)
    }

    private static func schedule(_ value: GenerationRecipe.Schedule) -> String {
        "mu \(scalar(value.mu)); min \(value.minres); max \(value.maxres); y1 \(scalar(value.y1)); y2 \(scalar(value.y2))"
    }

    private static func loras(_ values: [GenerationRecipe.LoRAReference]) -> String {
        guard !values.isEmpty else { return "—" }
        return values.enumerated().map { index, value in
            "\(index + 1). \(value.managedID.uuidString.lowercased()) · scale \(scalar(value.scale)) · \(value.sha256.lowercased())"
        }.joined(separator: "\n")
    }

    private static func regions(_ values: [GenerationRecipe.BBoxRegion]) -> String {
        guard !values.isEmpty else { return "—" }
        return values.enumerated().map { index, value in
            "\(index + 1). \(value.id.uuidString.lowercased()) · \(value.prompt) · \(rect(value.rect))"
        }.joined(separator: "\n")
    }

    private static func inputImage(_ value: GenerationRecipe.InputImageReference?) -> String {
        guard let value else { return "—" }
        let source = value.sourceGenerationID?.uuidString.lowercased() ?? "external"
        let crop = value.crop.map(rect) ?? "full"
        return "\(value.managedID.uuidString.lowercased()) · source \(source) · strength \(scalar(value.strength)) · \(value.resize.rawValue) · crop \(crop) · \(value.sha256.lowercased())"
    }

    private static func rect(_ value: GenerationRecipe.NormalizedRect) -> String {
        "[\(scalar(value.x0)), \(scalar(value.y0)), \(scalar(value.x1)), \(scalar(value.y1))]"
    }
}
