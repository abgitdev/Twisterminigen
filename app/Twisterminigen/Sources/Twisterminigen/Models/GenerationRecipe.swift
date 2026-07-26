import CryptoKit
import Foundation

/// A portable, deterministic description of one generation request.
///
/// Managed assets are identified by UUID and content hash. File-system locations and security
/// scoped bookmarks deliberately do not belong in the recipe format.
struct GenerationRecipe: Codable, Hashable, Sendable {
    static let supportedSchema = "twisterminigen.generation-recipe"
    static let currentVersion = 1

    static let minimumDimension = 256
    static let maximumDimension = 2_048
    static let dimensionMultiple = 16
    static let minimumSteps = 1
    static let maximumSteps = 100
    static let maximumLoRACount = 8
    /// Keep the editor useful for multi-subject composition while bounding conditioning size and
    /// the ordered overlap surface. The engine supports N regions; eight is the reviewed UI cap.
    static let maximumRegionCount = 8
    static let maximumLoRAScale = 2.0
    static let maximumGuidance = 20.0
    static let maximumPromptUTF8Bytes = 65_536
    static let maximumExactTextUTF8Bytes = 4_096

    var schema: String
    var version: Int
    var prompts: Prompts
    var canvas: Canvas
    var sampler: FlowEulerSampler
    var model: ModelReference
    /// Ordered active adapters. Disabled adapters are omitted instead of carrying an `enabled` flag.
    var loras: [LoRAReference]
    /// Ordered regions; ordering is significant when rectangles overlap.
    var regions: [BBoxRegion]
    var inputImage: InputImageReference?

    init(
        schema: String = Self.supportedSchema,
        version: Int = Self.currentVersion,
        prompts: Prompts,
        canvas: Canvas,
        sampler: FlowEulerSampler,
        model: ModelReference,
        loras: [LoRAReference] = [],
        regions: [BBoxRegion] = [],
        inputImage: InputImageReference? = nil
    ) {
        self.schema = schema
        self.version = version
        self.prompts = prompts
        self.canvas = canvas
        self.sampler = sampler
        self.model = model
        self.loras = loras
        self.regions = regions
        self.inputImage = inputImage
    }

    struct Prompts: Codable, Hashable, Sendable {
        var positive: String
        var negative: String
        var exactText: String?

        init(positive: String, negative: String = "", exactText: String? = nil) {
            self.positive = positive
            self.negative = negative
            self.exactText = exactText
        }
    }

    struct Canvas: Codable, Hashable, Sendable {
        var width: Int
        var height: Int

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    struct FlowEulerSampler: Codable, Hashable, Sendable {
        var steps: Int
        var seed: Seed
        var guidance: Double
        var schedule: Schedule
        var precision: Precision

        init(
            steps: Int,
            seed: Seed,
            guidance: Double,
            schedule: Schedule,
            precision: Precision
        ) {
            self.steps = steps
            self.seed = seed
            self.guidance = guidance
            self.schedule = schedule
            self.precision = precision
        }
    }

    struct Schedule: Codable, Hashable, Sendable {
        var mu: Double
        var minres: Int
        var maxres: Int
        var y1: Double
        var y2: Double

        init(mu: Double, minres: Int, maxres: Int, y1: Double, y2: Double) {
            self.mu = mu
            self.minres = minres
            self.maxres = maxres
            self.y1 = y1
            self.y2 = y2
        }
    }

    enum Seed: Codable, Hashable, Sendable {
        case random
        case fixed(UInt64)

        private enum CodingKeys: String, CodingKey {
            case kind
            case value
        }

        private enum Kind: String, Codable {
            case random
            case fixed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .random:
                self = .random
            case .fixed:
                self = .fixed(try container.decode(UInt64.self, forKey: .value))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .random:
                try container.encode(Kind.random, forKey: .kind)
            case .fixed(let value):
                try container.encode(Kind.fixed, forKey: .kind)
                try container.encode(value, forKey: .value)
            }
        }

        var fixedValue: UInt64? {
            guard case .fixed(let value) = self else { return nil }
            return value
        }
    }

    enum Precision: String, Codable, Hashable, Sendable {
        case bfloat16
        case float16
        case float32
    }

    /// The source checkpoint and its sampler behavior, independent of weight quantization.
    enum CheckpointFamily: String, Codable, CaseIterable, Hashable, Sendable {
        case turbo
        case raw

        var displayName: String {
            switch self {
            case .turbo: "Turbo"
            case .raw: "Raw"
            }
        }
    }

    /// The DiT weight representation, independent of the source checkpoint family.
    enum QuantizationTier: String, Codable, CaseIterable, Hashable, Sendable {
        case mixed4And8 = "mixed-4-8"
        case q8

        var displayName: String {
            switch self {
            case .mixed4And8: "mixed-4/8"
            case .q8: "q8"
            }
        }

        var qualityName: String {
            switch self {
            case .mixed4And8: "Default"
            case .q8: "Best Fidelity"
            }
        }
    }

    struct ModelReference: Codable, Hashable, Sendable {
        var modelID: String
        var variantID: String
        var manifestHash: String
        var checkpointFamily: CheckpointFamily
        var quantizationTier: QuantizationTier

        init(
            modelID: String,
            variantID: String,
            manifestHash: String,
            checkpointFamily: CheckpointFamily = .turbo,
            quantizationTier: QuantizationTier = .mixed4And8
        ) {
            self.modelID = modelID
            self.variantID = variantID
            self.manifestHash = manifestHash
            self.checkpointFamily = checkpointFamily
            self.quantizationTier = quantizationTier
        }

        private enum CodingKeys: String, CodingKey {
            case modelID
            case variantID
            case manifestHash
            case checkpointFamily
            case quantizationTier
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            modelID = try container.decode(String.self, forKey: .modelID)
            variantID = try container.decode(String.self, forKey: .variantID)
            manifestHash = try container.decode(String.self, forKey: .manifestHash)
            checkpointFamily = try container.decodeIfPresent(
                CheckpointFamily.self,
                forKey: .checkpointFamily) ?? .turbo
            quantizationTier = try container.decodeIfPresent(
                QuantizationTier.self,
                forKey: .quantizationTier) ?? .mixed4And8
        }
    }

    struct LoRAReference: Codable, Hashable, Sendable {
        var managedID: UUID
        var sha256: String
        var scale: Double

        init(managedID: UUID, sha256: String, scale: Double) {
            self.managedID = managedID
            self.sha256 = sha256
            self.scale = scale
        }
    }

    struct NormalizedRect: Codable, Hashable, Sendable {
        var x0: Double
        var y0: Double
        var x1: Double
        var y1: Double

        init(x0: Double, y0: Double, x1: Double, y1: Double) {
            self.x0 = x0
            self.y0 = y0
            self.x1 = x1
            self.y1 = y1
        }

        init(x: Double, y: Double, width: Double, height: Double) {
            self.init(x0: x, y0: y, x1: x + width, y1: y + height)
        }

        var x: Double { x0 }
        var y: Double { y0 }
        var width: Double { x1 - x0 }
        var height: Double { y1 - y0 }
    }

    struct BBoxRegion: Codable, Hashable, Sendable, Identifiable {
        var id: UUID
        var prompt: String
        var rect: NormalizedRect

        init(id: UUID, prompt: String, rect: NormalizedRect) {
            self.id = id
            self.prompt = prompt
            self.rect = rect
        }
    }

    enum ResizeMode: String, Codable, Hashable, Sendable {
        case fit
        case fill
        case stretch
    }

    struct InputImageReference: Codable, Hashable, Sendable {
        var managedID: UUID
        var sha256: String
        var strength: Double
        var resize: ResizeMode
        var crop: NormalizedRect?
        var sourceGenerationID: UUID?

        init(
            managedID: UUID,
            sha256: String,
            strength: Double,
            resize: ResizeMode,
            crop: NormalizedRect? = nil,
            sourceGenerationID: UUID? = nil
        ) {
            self.managedID = managedID
            self.sha256 = sha256
            self.strength = strength
            self.resize = resize
            self.crop = crop
            self.sourceGenerationID = sourceGenerationID
        }
    }

    enum Kind: String, Codable, Hashable, Sendable {
        case textToImage = "text-to-image"
        case imageToImage = "image-to-image"
    }

    enum ValidationPurpose: Hashable, Sendable {
        case request
        case persistedResult
    }

    enum ValidationError: Error, Equatable, Sendable {
        case incompatibleSchema(String)
        case incompatibleVersion(Int)
        case emptyValue(String)
        case invalidDimension(field: String, value: Int)
        case invalidStepCount(Int)
        case randomSeedForPersistedResult
        case nonFinite(String)
        case outOfBounds(String)
        case invalidSchedule(String)
        case invalidHash(String)
        case tooManyLoRAs(actual: Int, maximum: Int)
        case tooManyRegions(actual: Int, maximum: Int)
        case duplicateLoRAID(UUID)
        case duplicateRegionID(UUID)
        case invalidNormalizedRect(String)
        case invalidText(String)
        case valueTooLong(field: String, maximumUTF8Bytes: Int)
    }

    var kind: Kind {
        inputImage == nil ? .textToImage : .imageToImage
    }

    /// Gallery lineage for a Remix prepared from a managed generation. Kept on the input-image
    /// reference so imported files remain ordinary Remix sources with no invented parent.
    var parentGenerationID: UUID? {
        inputImage?.sourceGenerationID
    }

    /// Stable identity for resources that must be resident together in one engine session.
    /// Prompt, canvas, schedule, seed, and per-request image data intentionally do not split a session.
    var sessionKey: String {
        var fields = SessionKeyFields()
        fields.append(schema)
        fields.append(version)
        fields.append(kind.rawValue)
        fields.append(!regions.isEmpty)
        fields.append(model.modelID)
        fields.append(model.variantID)
        fields.append(model.manifestHash)
        fields.append(model.checkpointFamily.rawValue)
        fields.append(model.quantizationTier.rawValue)
        fields.append(sampler.precision.rawValue)
        fields.append(loras.count)
        for lora in loras {
            fields.append(lora.managedID.uuidString.lowercased())
            fields.append(lora.sha256)
            fields.append(lora.scale)
        }
        let digest = SHA256.hash(data: fields.data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Constructs the current Krea 2 Turbo request without relying on mutable engine defaults.
    static func turbo(
        prompt: String,
        negativePrompt: String = "",
        model: ModelReference,
        seed: Seed = .random
    ) -> Self {
        turbo(
            prompts: Prompts(positive: prompt, negative: negativePrompt),
            model: model,
            seed: seed)
    }

    /// Constructs the current Krea 2 Turbo request without relying on mutable engine defaults.
    static func turbo(
        prompts: Prompts,
        model: ModelReference,
        seed: Seed = .random
    ) -> Self {
        Self(
            schema: supportedSchema,
            version: currentVersion,
            prompts: prompts,
            canvas: Canvas(width: 1_024, height: 1_024),
            sampler: FlowEulerSampler(
                steps: 8,
                seed: seed,
                guidance: 0,
                schedule: Schedule(
                    mu: 1.15,
                    minres: 256,
                    maxres: 1_280,
                    y1: 0.5,
                    y2: 1.15),
                precision: .bfloat16),
            model: model,
            loras: [],
            regions: [],
            inputImage: nil)
    }

    /// Returns a copy whose random seed has been resolved exactly once. Fixed seeds are preserved.
    func resolvingRandomSeed(
        using generator: () -> UInt64 = { UInt64.random(in: UInt64.min ... UInt64.max) }
    ) -> Self {
        guard case .random = sampler.seed else { return self }
        var resolved = self
        resolved.sampler.seed = .fixed(generator())
        return resolved
    }

    /// Deterministic injection point for callers that already selected the random seed.
    func resolvingRandomSeed(to seed: UInt64) -> Self {
        resolvingRandomSeed { seed }
    }

    func validate(for purpose: ValidationPurpose = .request) throws {
        guard schema == Self.supportedSchema else {
            throw ValidationError.incompatibleSchema(schema)
        }
        guard version == Self.currentVersion else {
            throw ValidationError.incompatibleVersion(version)
        }

        try Self.requireNonempty(prompts.positive, field: "prompts.positive")
        try Self.requireBoundedText(prompts.positive, field: "prompts.positive")
        try Self.requireBoundedText(prompts.negative, field: "prompts.negative")
        if let exactText = prompts.exactText {
            try Self.requireNonempty(exactText, field: "prompts.exactText")
            guard exactText.utf8.count <= Self.maximumExactTextUTF8Bytes else {
                throw ValidationError.valueTooLong(
                    field: "prompts.exactText",
                    maximumUTF8Bytes: Self.maximumExactTextUTF8Bytes)
            }
            let allowedControls = CharacterSet(charactersIn: "\n\t\r")
            guard exactText.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    || allowedControls.contains(scalar)
            }) else {
                throw ValidationError.invalidText("prompts.exactText")
            }
        }
        try Self.validateDimension(canvas.width, field: "canvas.width")
        try Self.validateDimension(canvas.height, field: "canvas.height")

        guard (Self.minimumSteps ... Self.maximumSteps).contains(sampler.steps) else {
            throw ValidationError.invalidStepCount(sampler.steps)
        }
        if purpose == .persistedResult, case .random = sampler.seed {
            throw ValidationError.randomSeedForPersistedResult
        }

        try Self.requireFinite(sampler.guidance, field: "sampler.guidance")
        guard (0 ... Self.maximumGuidance).contains(sampler.guidance) else {
            throw ValidationError.outOfBounds("sampler.guidance")
        }
        try Self.validateSchedule(sampler.schedule)

        try Self.requireNonempty(model.modelID, field: "model.modelID")
        try Self.requireNonempty(model.variantID, field: "model.variantID")
        try Self.requireHash(model.manifestHash, field: "model.manifestHash")

        guard loras.count <= Self.maximumLoRACount else {
            throw ValidationError.tooManyLoRAs(
                actual: loras.count,
                maximum: Self.maximumLoRACount)
        }
        var loraIDs = Set<UUID>()
        for (index, lora) in loras.enumerated() {
            guard loraIDs.insert(lora.managedID).inserted else {
                throw ValidationError.duplicateLoRAID(lora.managedID)
            }
            try Self.requireHash(lora.sha256, field: "loras[\(index)].sha256")
            try Self.requireFinite(lora.scale, field: "loras[\(index)].scale")
            guard lora.scale > 0, lora.scale <= Self.maximumLoRAScale else {
                throw ValidationError.outOfBounds("loras[\(index)].scale")
            }
        }

        guard regions.count <= Self.maximumRegionCount else {
            throw ValidationError.tooManyRegions(
                actual: regions.count,
                maximum: Self.maximumRegionCount)
        }
        var regionIDs = Set<UUID>()
        for (index, region) in regions.enumerated() {
            guard regionIDs.insert(region.id).inserted else {
                throw ValidationError.duplicateRegionID(region.id)
            }
            try Self.requireNonempty(region.prompt, field: "regions[\(index)].prompt")
            try Self.requireBoundedText(region.prompt, field: "regions[\(index)].prompt")
            try Self.validateNormalizedRect(region.rect, field: "regions[\(index)].rect")
        }

        if let inputImage {
            try Self.requireHash(inputImage.sha256, field: "inputImage.sha256")
            try Self.requireFinite(inputImage.strength, field: "inputImage.strength")
            guard inputImage.strength > 0, inputImage.strength <= 1 else {
                throw ValidationError.outOfBounds("inputImage.strength")
            }
            if let crop = inputImage.crop {
                try Self.validateNormalizedRect(crop, field: "inputImage.crop")
            }
        }
    }

    func validate(requiringFixedSeed: Bool) throws {
        try validate(for: requiringFixedSeed ? .persistedResult : .request)
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case version
        case prompts
        case canvas
        case sampler
        case model
        case loras
        case regions
        case inputImage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        version = try container.decode(Int.self, forKey: .version)
        prompts = try container.decode(Prompts.self, forKey: .prompts)
        canvas = try container.decode(Canvas.self, forKey: .canvas)
        sampler = try container.decode(FlowEulerSampler.self, forKey: .sampler)
        model = try container.decode(ModelReference.self, forKey: .model)
        loras = try container.decodeIfPresent([LoRAReference].self, forKey: .loras) ?? []
        regions = try container.decodeIfPresent([BBoxRegion].self, forKey: .regions) ?? []
        inputImage = try container.decodeIfPresent(InputImageReference.self, forKey: .inputImage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(version, forKey: .version)
        try container.encode(prompts, forKey: .prompts)
        try container.encode(canvas, forKey: .canvas)
        try container.encode(sampler, forKey: .sampler)
        try container.encode(model, forKey: .model)
        try container.encode(loras, forKey: .loras)
        try container.encode(regions, forKey: .regions)
        try container.encodeIfPresent(inputImage, forKey: .inputImage)
    }

    private static func requireNonempty(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyValue(field)
        }
    }

    private static func requireBoundedText(_ value: String, field: String) throws {
        guard value.utf8.count <= maximumPromptUTF8Bytes else {
            throw ValidationError.valueTooLong(
                field: field,
                maximumUTF8Bytes: maximumPromptUTF8Bytes)
        }
    }

    private static func validateDimension(_ value: Int, field: String) throws {
        guard (minimumDimension ... maximumDimension).contains(value),
              value.isMultiple(of: dimensionMultiple)
        else {
            throw ValidationError.invalidDimension(field: field, value: value)
        }
    }

    private static func validateSchedule(_ schedule: Schedule) throws {
        try requireFinite(schedule.mu, field: "sampler.schedule.mu")
        try requireFinite(schedule.y1, field: "sampler.schedule.y1")
        try requireFinite(schedule.y2, field: "sampler.schedule.y2")
        try validateDimension(schedule.minres, field: "sampler.schedule.minres")
        try validateDimension(schedule.maxres, field: "sampler.schedule.maxres")
        guard schedule.minres <= schedule.maxres else {
            throw ValidationError.invalidSchedule("sampler.schedule.resolutionRange")
        }
        guard schedule.mu > 0 else {
            throw ValidationError.outOfBounds("sampler.schedule.mu")
        }
        guard schedule.y1 > 0, schedule.y2 > 0, schedule.y1 <= schedule.y2 else {
            throw ValidationError.invalidSchedule("sampler.schedule.yRange")
        }
    }

    private static func requireFinite(_ value: Double, field: String) throws {
        guard value.isFinite else { throw ValidationError.nonFinite(field) }
    }

    private static func requireHash(_ value: String, field: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy(Self.isHexDigit) else {
            throw ValidationError.invalidHash(field)
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
    }

    private static func validateNormalizedRect(_ rect: NormalizedRect, field: String) throws {
        let values = [rect.x0, rect.y0, rect.x1, rect.y1]
        guard values.allSatisfy(\.isFinite) else {
            throw ValidationError.nonFinite(field)
        }
        guard rect.x0 >= 0,
              rect.y0 >= 0,
              rect.x1 <= 1,
              rect.y1 <= 1,
              rect.x0 < rect.x1,
              rect.y0 < rect.y1
        else {
            throw ValidationError.invalidNormalizedRect(field)
        }
    }
}

extension GenerationRecipe.ValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .incompatibleSchema(let actual):
            return "Unsupported generation recipe schema: \(actual)."
        case .incompatibleVersion(let actual):
            return "Unsupported generation recipe version: \(actual)."
        case .emptyValue(let field):
            return "\(field) must not be empty."
        case .invalidDimension(let field, let value):
            return "\(field) has invalid dimension \(value)."
        case .invalidStepCount(let value):
            return "The sampler step count \(value) is outside the supported range."
        case .randomSeedForPersistedResult:
            return "A persisted result recipe must contain a fixed seed."
        case .nonFinite(let field):
            return "\(field) must be finite."
        case .outOfBounds(let field):
            return "\(field) is outside the supported bounds."
        case .invalidSchedule(let field):
            return "\(field) does not describe a valid flow schedule."
        case .invalidHash(let field):
            return "\(field) must be a 64-character SHA-256 hash."
        case .tooManyLoRAs(let actual, let maximum):
            return "The recipe contains \(actual) LoRAs; the maximum is \(maximum)."
        case .tooManyRegions(let actual, let maximum):
            return "The recipe contains \(actual) regions; the maximum is \(maximum)."
        case .duplicateLoRAID(let id):
            return "The LoRA ID \(id) occurs more than once."
        case .duplicateRegionID(let id):
            return "The region ID \(id) occurs more than once."
        case .invalidNormalizedRect(let field):
            return "\(field) must be a nonempty rectangle within normalized image bounds."
        case .invalidText(let field):
            return "\(field) contains an unsupported control character."
        case .valueTooLong(let field, let maximumUTF8Bytes):
            return "\(field) exceeds the \(maximumUTF8Bytes)-byte UTF-8 limit."
        }
    }
}

private struct SessionKeyFields {
    private(set) var data = Data()

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func append(_ value: Int) {
        var encoded = Int64(value).bigEndian
        Swift.withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt64) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Double) {
        append(value.bitPattern)
    }

    mutating func append(_ value: Bool) {
        data.append(value ? 1 : 0)
    }
}
