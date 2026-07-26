import Foundation
import Krea2Core
import Krea2DiT
import Krea2Sampler
import Krea2TextEncoder
import Krea2VAE
import MLX

/// The single resident model owned by a staged inference session.
///
/// A resident stage is exposed only inside a synchronous scoped closure. The scope is closed and
/// its model reference is released before the next model can start loading.
public enum Krea2PipelineSessionStage: String, CaseIterable, Equatable, Sendable {
    case idle
    case loadingTextEncoder
    case textEncoderResident
    case loadingEncoder
    case encoderResident
    case loadingTransformer
    case transformerResident
    case loadingDecoder
    case decoderResident
}

public enum Krea2PipelineSessionError: Error, Equatable, Sendable, CustomStringConvertible {
    case stageConflict(
        active: Krea2PipelineSessionStage,
        requested: Krea2PipelineSessionStage
    )
    case stageClosed(Krea2PipelineSessionStage)
    case operationAlreadyInProgress(Krea2PipelineSessionStage)
    case invalidTensorShape(tensor: String, expected: String, actual: [Int])
    case invalidValidTokenCount(actual: Int, maximum: Int)
    case incompatibleConditioningBranches(positive: [Int], negative: [Int])
    case negativeConditioningRequired
    case regionalConditioningCount(expected: Int, actual: Int)
    case invalidRegionalLabel(Int32)
    case regionPromptHasNoTokens(Int)
    case invalidRegionBBox(Int)

    public var description: String {
        switch self {
        case .stageConflict(let active, let requested):
            return "cannot enter \(requested.rawValue) while \(active.rawValue) is active"
        case .stageClosed(let stage):
            return "the scoped \(stage.rawValue) stage is already closed"
        case .operationAlreadyInProgress(let stage):
            return "another operation is already running in \(stage.rawValue)"
        case .invalidTensorShape(let tensor, let expected, let actual):
            return "invalid \(tensor) shape \(actual); expected \(expected)"
        case .invalidValidTokenCount(let actual, let maximum):
            return "invalid validTokenCount \(actual); expected 0...\(maximum)"
        case .incompatibleConditioningBranches(let positive, let negative):
            return "positive and negative conditioning shapes differ: \(positive) vs \(negative)"
        case .negativeConditioningRequired:
            return "classifier-free guidance requires materialized negative conditioning"
        case .regionalConditioningCount(let expected, let actual):
            return "regional conditioning contains \(actual) regions; expected \(expected)"
        case .invalidRegionalLabel(let label):
            return "regional conditioning contains invalid text label \(label)"
        case .regionPromptHasNoTokens(let index):
            return "region \(index + 1) has no tokens after prompt truncation"
        case .invalidRegionBBox(let index):
            return "region \(index + 1) has an invalid normalized bounding box"
        }
    }
}

/// Text conditioning whose lazy MLX graph has been evaluated while the text encoder was resident.
///
/// This type intentionally has no `Sendable` conformance: its values contain live `MLXArray`s and
/// must remain inside the serialized inference task.
public struct Krea2MaterializedConditioning {
    public let positive: Krea2InferenceTextConditioning
    public let negative: Krea2InferenceTextConditioning?

    public init(
        materializing positive: Krea2InferenceTextConditioning,
        negative: Krea2InferenceTextConditioning? = nil
    ) throws {
        try Krea2PipelineTensorContract.validateConditioning(
            embeddings: positive.embeddings.shape,
            mask: positive.mask.shape,
            validTokenCount: positive.validTokenCount,
            branch: "positive"
        )
        if let negative {
            try Krea2PipelineTensorContract.validateConditioning(
                embeddings: negative.embeddings.shape,
                mask: negative.mask.shape,
                validTokenCount: negative.validTokenCount,
                branch: "negative"
            )
            try Krea2PipelineTensorContract.validateMatchingConditioning(
                positive: positive.embeddings.shape,
                negative: negative.embeddings.shape
            )
        }

        try Task.checkCancellation()
        eval(positive.embeddings, positive.mask)
        if let negative {
            eval(negative.embeddings, negative.mask)
        }
        try Task.checkCancellation()

        self.positive = positive
        self.negative = negative
    }

    public init(materializing conditioning: Krea2InferenceConditioning) throws {
        try self.init(
            materializing: conditioning.positive,
            negative: conditioning.negative
        )
    }

    public init(
        materializing positive: Krea2TextConditioning,
        negative: Krea2TextConditioning? = nil
    ) throws {
        let inferencePositive = Krea2InferenceTextConditioning(
            embeddings: positive.embeddings,
            mask: positive.mask,
            validTokenCount: positive.validTokenCount
        )
        let inferenceNegative = negative.map {
            Krea2InferenceTextConditioning(
                embeddings: $0.embeddings,
                mask: $0.mask,
                validTokenCount: $0.validTokenCount
            )
        }
        try self.init(materializing: inferencePositive, negative: inferenceNegative)
    }
}

/// Regional conditioning evaluated while the text encoder is resident. Region ordering is part
/// of the tensor contract because the same order assigns image-patch labels in the sampler.
public struct Krea2MaterializedRegionalConditioning {
    public let embeddings: MLXArray
    public let txtLabels: MLXArray
    public let regions: [Krea2RegionBBox]

    public init(
        materializing conditioning: Krea2RegionalConditioning,
        regions: [Krea2RegionBBox]
    ) throws {
        guard conditioning.regionCount == regions.count else {
            throw Krea2PipelineSessionError.regionalConditioningCount(
                expected: regions.count,
                actual: conditioning.regionCount)
        }
        for (index, region) in regions.enumerated() {
            let values = [region.x0, region.y0, region.x1, region.y1]
            guard values.allSatisfy(\.isFinite),
                  region.x0 >= 0, region.y0 >= 0,
                  region.x1 <= 1, region.y1 <= 1,
                  region.x0 < region.x1, region.y0 < region.y1 else {
                throw Krea2PipelineSessionError.invalidRegionBBox(index)
            }
        }
        let shape = conditioning.embeddings.shape
        guard shape.count == 4, shape[0] == 1, shape.dropFirst().allSatisfy({ $0 > 0 }) else {
            throw Krea2PipelineSessionError.invalidTensorShape(
                tensor: "regional embeddings",
                expected: Krea2PipelineTensorContract.conditioningShapeDescription,
                actual: shape)
        }
        let labelShape = conditioning.txtLabels.shape
        guard labelShape == [shape[1]] || labelShape == [1, shape[1]] else {
            throw Krea2PipelineSessionError.invalidTensorShape(
                tensor: "regional text labels",
                expected: "rank-1 [tokens] or rank-2 [1, tokens]",
                actual: labelShape)
        }
        try Task.checkCancellation()
        eval(conditioning.embeddings, conditioning.txtLabels)
        try Task.checkCancellation()
        let labels = conditioning.txtLabels.asArray(Int32.self)
        let maximumLabel = Int32(regions.count)
        if let invalid = labels.first(where: { $0 < -1 || $0 > maximumLabel }) {
            throw Krea2PipelineSessionError.invalidRegionalLabel(invalid)
        }
        for index in regions.indices where !labels.contains(Int32(index + 1)) {
            throw Krea2PipelineSessionError.regionPromptHasNoTokens(index)
        }
        self.embeddings = conditioning.embeddings
        self.txtLabels = conditioning.txtLabels
        self.regions = regions
    }
}

/// A single, fully evaluated latent. The leading model axis is required to be exactly one; jobs
/// are sampled sequentially and are never combined into a true batch by this API.
///
/// This type intentionally has no `Sendable` conformance because it owns an `MLXArray`.
public struct Krea2MaterializedLatent {
    public let array: MLXArray

    public init(materializing array: MLXArray) throws {
        try Krea2PipelineTensorContract.validateLatent(array.shape)
        try Task.checkCancellation()
        eval(array)
        try Task.checkCancellation()
        self.array = array
    }
}

/// Reusable staged inference API for a bounded group of jobs.
///
/// The stage closures are synchronous by design. They permit repeated sequential operations while
/// one model is resident, but cannot suspend while retaining TE, DiT, or VAE. The coordinator is
/// deliberately not `Sendable`; create and use it in one serialized inference task.
public final class Krea2PipelineSession {
    public typealias PerformanceStageCallback = (Krea2Pipeline.PerformanceStage) -> Void

    public var stage: Krea2PipelineSessionStage { state.stage }
    public let cacheLimitBytes: Int

    private var state = Krea2PipelineSessionStateMachine()
    private let performanceStageCallback: PerformanceStageCallback?
    private let loadVerification: Krea2Pipeline.ModelLoadVerification?

    public init(
        cacheLimitBytes: Int = Krea2Pipeline.defaultCacheLimitBytes,
        performanceStageCallback: PerformanceStageCallback? = nil,
        loadVerification: Krea2Pipeline.ModelLoadVerification? = nil
    ) {
        self.cacheLimitBytes = max(0, cacheLimitBytes)
        self.performanceStageCallback = performanceStageCallback
        self.loadVerification = loadVerification
    }

    /// Loads one text encoder and permits any number of sequential prompt encodes in `body`.
    /// Every returned conditioning is evaluated before this method releases the encoder.
    public func withTextEncoder<Result>(
        officialDirectory: URL,
        _ body: (TextEncoderStage) throws -> Result
    ) async throws -> Result {
        try state.beginLoading(.textEncoder)
        prepareMemory()

        var encoder: Krea2TextEncoder?
        var loadLease: Krea2Pipeline.ModelLoadLease?
        do {
            try Task.checkCancellation()
            performanceStageCallback?(.textEncoderLoad)
            let loadDirectory: URL
            if let loadVerification {
                let lease = try loadVerification(.textEncoder)
                loadDirectory = try lease.replacementDirectory(for: officialDirectory)
                loadLease = lease
            } else {
                loadDirectory = officialDirectory
            }
            encoder = try await Krea2TextEncoder.load(
                textEncoderDirectory: loadDirectory.appendingPathComponent("text_encoder"),
                tokenizerDirectory: loadDirectory.appendingPathComponent("tokenizer")
            )
            try Task.checkCancellation()
            try state.markResident(.textEncoder)
        } catch {
            encoder = nil
            state.reset()
            MLX.Memory.clearCache()
            withExtendedLifetime(loadLease) {}
            throw error
        }

        let scopedStage = TextEncoderStage(
            encoder: encoder!,
            performanceStageCallback: performanceStageCallback
        )
        encoder = nil
        defer {
            scopedStage.invalidate()
            state.reset()
            MLX.Memory.clearCache()
            withExtendedLifetime(loadLease) {}
        }
        return try body(scopedStage)
    }

    /// Loads and quantizes one DiT, applies the ordered LoRA list once, then permits repeated
    /// sequential `sample` calls in `body`.
    public func withTransformer<Result>(
        quantizedWeights: URL,
        quantization: Krea2DiTQuantization = .mixed4And8,
        loraAdapters: [Krea2DiTLoRAConfig] = [],
        _ body: (TransformerStage) throws -> Result
    ) throws -> Result {
        try state.beginLoading(.transformer)
        prepareMemory()

        var dit: Krea2SingleStreamDiT?
        var transformerLease: Krea2Pipeline.ModelLoadLease?
        var adapterLease: Krea2Pipeline.ModelLoadLease?
        do {
            try Task.checkCancellation()
            performanceStageCallback?(.transformerConstruct)
            dit = Krea2SingleStreamDiT()
            performanceStageCallback?(.transformerQuantization)
            quantization.quantize(dit!)
            try Task.checkCancellation()
            performanceStageCallback?(.transformerWeightLoad)
            let loadWeights: URL
            if let loadVerification {
                let lease = try loadVerification(.transformer)
                loadWeights = try lease.replacementFile(for: quantizedWeights)
                transformerLease = lease
            } else {
                loadWeights = quantizedWeights
            }
            try Krea2DiTWeightLoader.loadQuantized(into: dit!, file: loadWeights)
            try Task.checkCancellation()
            if !loraAdapters.isEmpty {
                performanceStageCallback?(.loraApply)
                let loadAdapters: [Krea2DiTLoRAConfig]
                if let loadVerification {
                    let lease = try loadVerification(.loraAdapters)
                    loadAdapters = try loraAdapters.map { adapter in
                        Krea2DiTLoRAConfig(
                            path: try lease.replacementFile(for: adapter.path),
                            scale: adapter.scale)
                    }
                    adapterLease = lease
                } else {
                    loadAdapters = loraAdapters
                }
                try Krea2DiTLoRALoader.apply(to: dit!, adapters: loadAdapters)
                try Task.checkCancellation()
            }
            try state.markResident(.transformer)
        } catch {
            dit = nil
            state.reset()
            MLX.Memory.clearCache()
            withExtendedLifetime(transformerLease) {}
            withExtendedLifetime(adapterLease) {}
            throw error
        }

        let scopedStage = TransformerStage(
            sampler: Krea2Sampler(dit: dit!),
            performanceStageCallback: performanceStageCallback
        )
        dit = nil
        defer {
            scopedStage.invalidate()
            state.reset()
            MLX.Memory.clearCache()
            withExtendedLifetime(transformerLease) {}
            withExtendedLifetime(adapterLease) {}
        }
        return try body(scopedStage)
    }

    /// Loads only the VAE encoder roots, materializes each source latent, and releases the model
    /// before the transformer is constructed.
    public func withEncoder<Result>(
        weights: URL,
        computeDType: DType = Krea2Pipeline.productionVAEEncoderComputeDType,
        _ body: (EncoderStage) throws -> Result
    ) throws -> Result {
        try state.beginLoading(.encoder)
        prepareMemory()

        var encoder: Krea2VAEEncoderModel?
        var loadLease: Krea2Pipeline.ModelLoadLease?
        do {
            try Task.checkCancellation()
            performanceStageCallback?(.vaeEncoderConstruct)
            encoder = Krea2VAEEncoderModel()
            performanceStageCallback?(.vaeEncoderWeightLoad)
            let loadWeights: URL
            if let loadVerification {
                let lease = try loadVerification(.vaeEncoder)
                loadWeights = try lease.replacementFile(for: weights)
                loadLease = lease
            } else {
                loadWeights = weights
            }
            try Krea2VAEWeightLoader.load(
                into: encoder!,
                file: loadWeights,
                computeDType: computeDType)
            try Task.checkCancellation()
            try state.markResident(.encoder)
        } catch {
            encoder = nil
            state.reset()
            MLX.Memory.clearCache()
            withExtendedLifetime(loadLease) {}
            throw error
        }

        let scopedStage = EncoderStage(
            encoder: encoder!,
            computeDType: computeDType,
            performanceStageCallback: performanceStageCallback)
        encoder = nil
        defer {
            scopedStage.invalidate()
            state.reset()
            MLX.Memory.clearCache()
            withExtendedLifetime(loadLease) {}
        }
        return try body(scopedStage)
    }

    /// Loads one decoder-only VAE and permits repeated sequential `decode` calls in `body`.
    /// Encoder and quant-conv weights never become resident in this stage.
    public func withDecoder<Result>(
        weights: URL,
        computeDType: DType = Krea2Pipeline.productionVAEComputeDType,
        _ body: (DecoderStage) throws -> Result
    ) throws -> Result {
        try state.beginLoading(.decoder)
        prepareMemory()

        var decoder: Krea2VAEDecoderModel?
        var loadLease: Krea2Pipeline.ModelLoadLease?
        do {
            try Task.checkCancellation()
            performanceStageCallback?(.vaeConstruct)
            decoder = Krea2VAEDecoderModel()
            performanceStageCallback?(.vaeWeightLoad)
            let loadWeights: URL
            if let loadVerification {
                let lease = try loadVerification(.vaeDecoder)
                loadWeights = try lease.replacementFile(for: weights)
                loadLease = lease
            } else {
                loadWeights = weights
            }
            try Krea2VAEWeightLoader.load(
                into: decoder!,
                file: loadWeights,
                computeDType: computeDType
            )
            try Task.checkCancellation()
            try state.markResident(.decoder)
        } catch {
            decoder = nil
            state.reset()
            MLX.Memory.clearCache()
            withExtendedLifetime(loadLease) {}
            throw error
        }

        let scopedStage = DecoderStage(
            decoder: decoder!,
            computeDType: computeDType,
            performanceStageCallback: performanceStageCallback
        )
        decoder = nil
        defer {
            scopedStage.invalidate()
            state.reset()
            MLX.Memory.clearCache()
            withExtendedLifetime(loadLease) {}
        }
        return try body(scopedStage)
    }

    private func prepareMemory() {
        MLX.Memory.cacheLimit = cacheLimitBytes
    }

    public final class TextEncoderStage {
        private var encoder: Krea2TextEncoder?
        private var operationInProgress = false
        private let performanceStageCallback: PerformanceStageCallback?

        fileprivate init(
            encoder: Krea2TextEncoder,
            performanceStageCallback: PerformanceStageCallback?
        ) {
            self.encoder = encoder
            self.performanceStageCallback = performanceStageCallback
        }

        /// `negativePrompt == nil` materializes only the positive branch. Pass `.some("")` for
        /// an empty CFG negative prompt.
        public func materialize(
            prompt: String,
            negativePrompt: String? = nil
        ) throws -> Krea2MaterializedConditioning {
            guard let encoder else {
                throw Krea2PipelineSessionError.stageClosed(.textEncoderResident)
            }
            guard !operationInProgress else {
                throw Krea2PipelineSessionError.operationAlreadyInProgress(.textEncoderResident)
            }
            operationInProgress = true
            defer { operationInProgress = false }

            try Task.checkCancellation()
            performanceStageCallback?(.textEncoderPositiveForward)
            let positive = encoder.encode(prompt: prompt)
            try Task.checkCancellation()

            let negative: Krea2TextConditioning?
            if let negativePrompt {
                performanceStageCallback?(.textEncoderNegativeForward)
                negative = encoder.encode(prompt: negativePrompt)
                try Task.checkCancellation()
            } else {
                negative = nil
            }

            performanceStageCallback?(.conditioningMaterialization)
            return try Krea2MaterializedConditioning(
                materializing: positive,
                negative: negative
            )
        }

        public func materializeRegional(
            globalPrompt: String,
            regions: [Krea2Region]
        ) throws -> Krea2MaterializedRegionalConditioning {
            guard let encoder else {
                throw Krea2PipelineSessionError.stageClosed(.textEncoderResident)
            }
            guard !operationInProgress else {
                throw Krea2PipelineSessionError.operationAlreadyInProgress(.textEncoderResident)
            }
            operationInProgress = true
            defer { operationInProgress = false }

            try Task.checkCancellation()
            performanceStageCallback?(.textEncoderPositiveForward)
            let conditioning = encoder.encodeRegional(
                globalPrompt: globalPrompt,
                regions: regions)
            try Task.checkCancellation()
            performanceStageCallback?(.conditioningMaterialization)
            return try Krea2MaterializedRegionalConditioning(
                materializing: conditioning,
                regions: regions.map(\.bbox))
        }

        fileprivate func invalidate() {
            encoder = nil
        }
    }

    public final class TransformerStage {
        private var sampler: Krea2Sampler?
        private var operationInProgress = false
        private let performanceStageCallback: PerformanceStageCallback?

        fileprivate init(
            sampler: Krea2Sampler,
            performanceStageCallback: PerformanceStageCallback?
        ) {
            self.sampler = sampler
            self.performanceStageCallback = performanceStageCallback
        }

        /// Samples exactly one job. Call repeatedly for resident-sequential generation; this API
        /// never combines jobs along the model's leading axis.
        public func sample(
            conditioning: Krea2MaterializedConditioning,
            params: Krea2Sampler.Params = Krea2Sampler.Params(),
            initLatent: Krea2MaterializedLatent? = nil,
            strength: Double = 1,
            previewEverySteps: Int = 0,
            previewCallback: ((Krea2LatentPreviewFrame) -> Void)? = nil,
            stepCallback: ((Int, Int) -> Void)? = nil
        ) throws -> Krea2MaterializedLatent {
            guard let sampler else {
                throw Krea2PipelineSessionError.stageClosed(.transformerResident)
            }
            guard !operationInProgress else {
                throw Krea2PipelineSessionError.operationAlreadyInProgress(.transformerResident)
            }
            guard params.guidance == 0 || conditioning.negative != nil else {
                throw Krea2PipelineSessionError.negativeConditioningRequired
            }
            operationInProgress = true
            defer { operationInProgress = false }

            try Task.checkCancellation()
            performanceStageCallback?(.denoising)
            let latent = try sampler.sample(
                context: conditioning.positive.embeddings,
                mask: conditioning.positive.mask,
                negativeContext: conditioning.negative?.embeddings,
                negativeMask: conditioning.negative?.mask,
                params: params,
                initLatent: initLatent?.array,
                strength: strength,
                previewEverySteps: previewEverySteps,
                previewCallback: previewCallback,
                stepCallback: stepCallback
            )
            try Task.checkCancellation()
            return try Krea2MaterializedLatent(materializing: latent)
        }

        public func sampleRegional(
            conditioning: Krea2MaterializedRegionalConditioning,
            params: Krea2Sampler.Params = Krea2Sampler.Params(),
            initLatent: Krea2MaterializedLatent? = nil,
            strength: Double = 1,
            previewEverySteps: Int = 0,
            previewCallback: ((Krea2LatentPreviewFrame) -> Void)? = nil,
            stepCallback: ((Int, Int) -> Void)? = nil
        ) throws -> Krea2MaterializedLatent {
            guard let sampler else {
                throw Krea2PipelineSessionError.stageClosed(.transformerResident)
            }
            guard !operationInProgress else {
                throw Krea2PipelineSessionError.operationAlreadyInProgress(.transformerResident)
            }
            guard params.guidance == 0 else {
                throw Krea2PipelineSessionError.negativeConditioningRequired
            }
            operationInProgress = true
            defer { operationInProgress = false }

            try Task.checkCancellation()
            performanceStageCallback?(.denoising)
            let latent = try sampler.sampleRegional(
                context: conditioning.embeddings,
                txtLabels: conditioning.txtLabels,
                regions: conditioning.regions,
                params: params,
                initLatent: initLatent?.array,
                strength: strength,
                previewEverySteps: previewEverySteps,
                previewCallback: previewCallback,
                stepCallback: stepCallback)
            try Task.checkCancellation()
            return try Krea2MaterializedLatent(materializing: latent)
        }

        fileprivate func invalidate() {
            sampler = nil
        }
    }

    public final class EncoderStage {
        private var encoder: Krea2VAEEncoderModel?
        private let computeDType: DType
        private var operationInProgress = false
        private let performanceStageCallback: PerformanceStageCallback?

        fileprivate init(
            encoder: Krea2VAEEncoderModel,
            computeDType: DType,
            performanceStageCallback: PerformanceStageCallback?
        ) {
            self.encoder = encoder
            self.computeDType = computeDType
            self.performanceStageCallback = performanceStageCallback
        }

        public func encode(_ image: Krea2Pipeline.ImageInput) throws -> Krea2MaterializedLatent {
            guard let encoder else {
                throw Krea2PipelineSessionError.stageClosed(.encoderResident)
            }
            guard !operationInProgress else {
                throw Krea2PipelineSessionError.operationAlreadyInProgress(.encoderResident)
            }
            operationInProgress = true
            defer { operationInProgress = false }

            try Task.checkCancellation()
            let pixels = MLXArray(image.planarRGB)
                .reshaped([1, 3, image.height, image.width])
                .asType(computeDType)
            performanceStageCallback?(.vaeEncode)
            let latent = encoder.encode(pixels)
            let expected = [
                1,
                Krea2VAEEncoderModel.latentChannels,
                image.height / Krea2VAEEncoderModel.spatialScale,
                image.width / Krea2VAEEncoderModel.spatialScale,
            ]
            guard latent.shape == expected else {
                throw Krea2PipelineSessionError.invalidTensorShape(
                    tensor: "encoded latent",
                    expected: "\(expected)",
                    actual: latent.shape)
            }
            try Task.checkCancellation()
            return try Krea2MaterializedLatent(materializing: latent)
        }

        fileprivate func invalidate() {
            encoder = nil
        }
    }

    public final class DecoderStage {
        private var decoder: Krea2VAEDecoderModel?
        private let computeDType: DType
        private var operationInProgress = false
        private let performanceStageCallback: PerformanceStageCallback?

        fileprivate init(
            decoder: Krea2VAEDecoderModel,
            computeDType: DType,
            performanceStageCallback: PerformanceStageCallback?
        ) {
            self.decoder = decoder
            self.computeDType = computeDType
            self.performanceStageCallback = performanceStageCallback
        }

        /// Decodes exactly one latent to a materialized `(1, 3, H, W)` image in `[0, 1]`.
        /// The returned `MLXArray` remains confined to the serialized inference task.
        public func decode(_ latent: Krea2MaterializedLatent) throws -> MLXArray {
            guard let decoder else {
                throw Krea2PipelineSessionError.stageClosed(.decoderResident)
            }
            guard !operationInProgress else {
                throw Krea2PipelineSessionError.operationAlreadyInProgress(.decoderResident)
            }
            operationInProgress = true
            defer { operationInProgress = false }

            try Task.checkCancellation()
            performanceStageCallback?(.vaeDecode)
            let decoded = try decoder.decode(latent.array.asType(computeDType))
            try Task.checkCancellation()
            let image = clip(decoded, min: -1, max: 1) * 0.5 + 0.5
            try Krea2PipelineTensorContract.validateImage(image.shape)
            performanceStageCallback?(.imageMaterialization)
            eval(image)
            try Task.checkCancellation()
            return image
        }

        fileprivate func invalidate() {
            decoder = nil
        }
    }
}

enum Krea2PipelineResidentModel: CaseIterable {
    case textEncoder
    case encoder
    case transformer
    case decoder

    var loadingStage: Krea2PipelineSessionStage {
        switch self {
        case .textEncoder: .loadingTextEncoder
        case .encoder: .loadingEncoder
        case .transformer: .loadingTransformer
        case .decoder: .loadingDecoder
        }
    }

    var residentStage: Krea2PipelineSessionStage {
        switch self {
        case .textEncoder: .textEncoderResident
        case .encoder: .encoderResident
        case .transformer: .transformerResident
        case .decoder: .decoderResident
        }
    }
}

struct Krea2PipelineSessionStateMachine {
    private(set) var stage: Krea2PipelineSessionStage = .idle

    mutating func beginLoading(_ model: Krea2PipelineResidentModel) throws {
        guard stage == .idle else {
            throw Krea2PipelineSessionError.stageConflict(
                active: stage,
                requested: model.loadingStage
            )
        }
        stage = model.loadingStage
    }

    mutating func markResident(_ model: Krea2PipelineResidentModel) throws {
        guard stage == model.loadingStage else {
            throw Krea2PipelineSessionError.stageConflict(
                active: stage,
                requested: model.residentStage
            )
        }
        stage = model.residentStage
    }

    mutating func release(_ model: Krea2PipelineResidentModel) throws {
        guard stage == model.residentStage else {
            throw Krea2PipelineSessionError.stageConflict(active: stage, requested: .idle)
        }
        stage = .idle
    }

    mutating func reset() {
        stage = .idle
    }
}

enum Krea2PipelineTensorContract {
    static let conditioningShapeDescription =
        "rank-4 [1, tokens, layers, width] with a singleton leading axis"
    static let maskShapeDescription =
        "rank-2 [1, tokens] with a singleton leading axis"
    static let latentShapeDescription =
        "rank-4 [1, 16, height, width] with a singleton leading axis"
    static let imageShapeDescription =
        "rank-4 [1, 3, height, width] with a singleton leading axis"

    static func validateConditioning(
        embeddings: [Int],
        mask: [Int],
        validTokenCount: Int,
        branch: String
    ) throws {
        guard embeddings.count == 4,
              embeddings[0] == 1,
              embeddings.dropFirst().allSatisfy({ $0 > 0 })
        else {
            throw Krea2PipelineSessionError.invalidTensorShape(
                tensor: "\(branch) embeddings",
                expected: conditioningShapeDescription,
                actual: embeddings
            )
        }
        guard mask.count == 2,
              mask[0] == 1,
              mask[1] == embeddings[1]
        else {
            throw Krea2PipelineSessionError.invalidTensorShape(
                tensor: "\(branch) mask",
                expected: maskShapeDescription,
                actual: mask
            )
        }
        guard validTokenCount >= 0, validTokenCount <= mask[1] else {
            throw Krea2PipelineSessionError.invalidValidTokenCount(
                actual: validTokenCount,
                maximum: mask[1]
            )
        }
    }

    static func validateMatchingConditioning(positive: [Int], negative: [Int]) throws {
        guard positive == negative else {
            throw Krea2PipelineSessionError.incompatibleConditioningBranches(
                positive: positive,
                negative: negative
            )
        }
    }

    static func validateLatent(_ shape: [Int]) throws {
        guard shape.count == 4,
              shape[0] == 1,
              shape[1] == Krea2VAEDecoderModel.latentChannels,
              shape[2] > 0,
              shape[3] > 0
        else {
            throw Krea2PipelineSessionError.invalidTensorShape(
                tensor: "latent",
                expected: latentShapeDescription,
                actual: shape
            )
        }
    }

    static func validateImage(_ shape: [Int]) throws {
        guard shape.count == 4,
              shape[0] == 1,
              shape[1] == 3,
              shape[2] > 0,
              shape[3] > 0
        else {
            throw Krea2PipelineSessionError.invalidTensorShape(
                tensor: "decoded image",
                expected: imageShapeDescription,
                actual: shape
            )
        }
    }
}
