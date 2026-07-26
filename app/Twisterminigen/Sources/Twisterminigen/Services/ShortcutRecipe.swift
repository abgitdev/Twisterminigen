import Foundation

/// Deliberately narrow public input for macOS Shortcuts: one local text-to-image render only.
/// It exposes no URL, file path, model download, LoRA, Remix source, region, batch or queue field.
struct ShortcutRecipe: Codable, Equatable, Sendable {
    static let maximumJSONBytes = 128 * 1_024
    static let minimumSteps = 4
    static let maximumSteps = 12

    var prompt: String
    var width: Int
    var height: Int
    var steps: Int
    var seed: UInt64?

    init(
        prompt: String,
        width: Int = 1_024,
        height: Int = 1_024,
        steps: Int = 8,
        seed: UInt64? = nil
    ) {
        self.prompt = prompt
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case prompt, width, height, steps, seed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(String.self, forKey: .prompt)
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 1_024
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 1_024
        steps = try container.decodeIfPresent(Int.self, forKey: .steps) ?? 8
        seed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
    }

    static func decode(json: String) throws -> Self {
        guard let data = json.data(using: .utf8),
              !data.isEmpty,
              data.count <= maximumJSONBytes else {
            throw ShortcutRecipeError.invalidJSON
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ShortcutRecipeError.invalidJSON }
            let allowed = Set(CodingKeys.allCases.map(\.rawValue))
            let unknown = Set(object.keys).subtracting(allowed).sorted()
            guard unknown.isEmpty else { throw ShortcutRecipeError.unknownFields(unknown) }
            let recipe = try JSONDecoder().decode(Self.self, from: data)
            try recipe.validate()
            return recipe
        } catch let error as ShortcutRecipeError {
            throw error
        } catch {
            throw ShortcutRecipeError.invalidJSON
        }
    }

    func validate() throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShortcutRecipeError.emptyPrompt }
        guard trimmed.utf8.count <= GenerationRecipe.maximumPromptUTF8Bytes else {
            throw ShortcutRecipeError.promptTooLong
        }
        let allowedControls = CharacterSet(charactersIn: "\n\t\r")
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar) || allowedControls.contains(scalar)
        }) else {
            throw ShortcutRecipeError.invalidPrompt
        }
        guard (GenerationRecipe.minimumDimension ... GenerationRecipe.maximumDimension).contains(width),
              (GenerationRecipe.minimumDimension ... GenerationRecipe.maximumDimension).contains(height),
              width.isMultiple(of: GenerationRecipe.dimensionMultiple),
              height.isMultiple(of: GenerationRecipe.dimensionMultiple) else {
            throw ShortcutRecipeError.invalidSize(width: width, height: height)
        }
        guard (Self.minimumSteps ... Self.maximumSteps).contains(steps) else {
            throw ShortcutRecipeError.invalidSteps(steps)
        }
    }

    func generationRecipe(catalog: ModelCatalog) throws -> GenerationRecipe {
        try validate()
        var recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            width: width,
            height: height,
            steps: steps,
            seed: seed.map(GenerationRecipe.Seed.fixed) ?? .random,
            catalog: catalog)
        recipe = recipe.resolvingRandomSeed()
        try GenerationRecipeRuntime.validateConfiguration(for: recipe, catalog: catalog)
        return recipe
    }

    static let exampleJSON =
        #"{"prompt":"a small letterpress poster reading HELLO, cobalt ink on warm paper","width":1024,"height":1024,"steps":8,"seed":202}"#
}

enum ShortcutRecipeError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSON
    case unknownFields([String])
    case emptyPrompt
    case promptTooLong
    case invalidPrompt
    case invalidSize(width: Int, height: Int)
    case invalidSteps(Int)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Recipe JSON must contain prompt and optional width, height, steps and seed fields."
        case .unknownFields(let fields):
            return "Unsupported Shortcut fields: \(fields.joined(separator: ", "))."
        case .emptyPrompt:
            return "The Shortcut prompt cannot be empty."
        case .promptTooLong:
            return "The Shortcut prompt exceeds the recipe size limit."
        case .invalidPrompt:
            return "The Shortcut prompt contains unsupported control characters."
        case let .invalidSize(width, height):
            return "Shortcut size \(width)×\(height) is unsupported. Use 256…2048 and multiples of 16."
        case .invalidSteps(let steps):
            return "Shortcut steps \(steps) are unsupported. Use \(ShortcutRecipe.minimumSteps)…\(ShortcutRecipe.maximumSteps)."
        }
    }
}

/// The main app installs one renderer backed by its shared coordinator and stores. Keeping the
/// registry MainActor-isolated prevents an App Intent from constructing competing MLX ownership.
@MainActor
enum ShortcutRenderRuntime {
    typealias RenderAction = @MainActor @Sendable (ShortcutRecipe) async throws -> Generation
    private static var renderAction: RenderAction?

    static func configure(generate: GenerateViewModel) {
        renderAction = { [weak generate] recipe in
            guard let generate else { throw ShortcutRenderError.runtimeUnavailable }
            return try await generate.renderShortcutRecipe(recipe)
        }
    }

    /// Injection seam for contract tests and future non-UI clients. Production installs the
    /// GenerateViewModel overload above; tests can prove intent routing without touching MLX.
    static func configure(render: @escaping RenderAction) {
        renderAction = render
    }

    static func reset() {
        renderAction = nil
    }

    static func render(_ recipe: ShortcutRecipe) async throws -> Generation {
        guard let renderAction else { throw ShortcutRenderError.runtimeUnavailable }
        return try await renderAction(recipe)
    }
}

enum ShortcutRenderError: Error, Equatable, LocalizedError, Sendable {
    case runtimeUnavailable
    case licenseRequired
    case modelWeightsMissing
    case busy(String)
    case unsafeMemory
    case lostLease
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "Twisterminigen's local render service is not available. Open the app once and try again."
        case .licenseRequired:
            return "Review and accept the Krea 2 Community License in Twisterminigen Models first."
        case .modelWeightsMissing:
            return "The verified Krea 2 weights are missing. Open Twisterminigen Models first."
        case .busy(let reason):
            return reason
        case .unsafeMemory:
            return "Memory pressure is too high to start this Shortcut safely."
        case .lostLease:
            return "The local render reservation ended before work could start."
        case .missingOutput:
            return "The local renderer returned no image."
        }
    }
}
