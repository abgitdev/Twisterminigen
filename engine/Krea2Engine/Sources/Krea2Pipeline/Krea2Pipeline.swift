// Krea2Pipeline.swift
//





import Foundation
import Krea2Core
import Krea2DiT
import Krea2Sampler
import Krea2TextEncoder
import Krea2VAE
import MLX

public enum Krea2Pipeline {
    /// Keeps reusable Metal buffers bounded on memory-constrained unified-memory Macs. Model
    /// weights remain active; this only limits MLX's pool of already-freed intermediate buffers.
    public static let defaultCacheLimitBytes = 256 * 1_024 * 1_024
    /// Passed deterministic-random and real Krea latent parity gates against FP32 at 512px.
    public static let productionVAEComputeDType: DType = .bfloat16
    /// Encoder-only BF16 keeps Remix below the full-VAE memory footprint. A real-weight parity
    /// gate is run independently from decoder parity before release builds are promoted.
    public static let productionVAEEncoderComputeDType: DType = .bfloat16

    /// Coarse pipeline stages used by app-level coordination and honest progress UI.
    public enum Phase: Sendable {
        case encodingPrompt
        case encodingImage
        case loadingTransformer
        case denoising
        case decoding
    }

    public enum ConditioningCacheEvent: Sendable, Equatable {
        case disabled
        case miss
        case hit
    }

    public enum PerformanceStage: String, Sendable {
        case conditioningCacheLookup
        case conditioningCacheRestore
        case conditioningCacheStore
        case textEncoderLoad
        case textEncoderPositiveForward
        case textEncoderNegativeForward
        case conditioningMaterialization
        case conditioningHostCopy
        case vaeEncoderConstruct
        case vaeEncoderWeightLoad
        case vaeEncode
        case transformerConstruct
        case transformerQuantization
        case transformerWeightLoad
        case loraApply
        case denoising
        case vaeConstruct
        case vaeWeightLoad
        case vaeDecode
        case imageMaterialization
    }

    /// Exact resident model about to be opened by an MLX loader. The app uses this hook to create
    /// a verified, app-owned snapshot at the true load boundary (after the preceding stage), rather
    /// than handing a mutable catalog path to MLX.
    public enum ModelLoadComponent: String, Sendable, Equatable {
        case textEncoder
        case vaeEncoder
        case transformer
        case loraAdapters
        case vaeDecoder
    }

    /// A load lease maps every original URL for one resident stage to an app-owned verified
    /// snapshot. The engine retains the lease until the stage body has materialized its output and
    /// the resident model is released, because MLX safetensor arrays may retain lazy mappings even
    /// after `loadArrays` returns.
    public final class ModelLoadLease: @unchecked Sendable {
        private let fileReplacements: [String: URL]
        private let directoryReplacements: [String: URL]
        private let releaseHandler: @Sendable () -> Void

        public init(
            fileReplacements: [URL: URL],
            directoryReplacements: [URL: URL] = [:],
            onRelease: @escaping @Sendable () -> Void = {}
        ) {
            self.fileReplacements = Dictionary(uniqueKeysWithValues: fileReplacements.map {
                (Self.key($0.key), $0.value.standardizedFileURL)
            })
            self.directoryReplacements = Dictionary(
                uniqueKeysWithValues: directoryReplacements.map {
                    (Self.key($0.key), $0.value.standardizedFileURL)
                })
            self.releaseHandler = onRelease
        }

        deinit { releaseHandler() }

        public func replacementFile(for original: URL) throws -> URL {
            guard let replacement = fileReplacements[Self.key(original)] else {
                throw ModelLoadLeaseError.missingFileReplacement(original.path)
            }
            return replacement
        }

        public func replacementDirectory(for original: URL) throws -> URL {
            guard let replacement = directoryReplacements[Self.key(original)] else {
                throw ModelLoadLeaseError.missingDirectoryReplacement(original.path)
            }
            return replacement
        }

        private static func key(_ url: URL) -> String {
            url.standardizedFileURL.path
        }
    }

    public enum ModelLoadLeaseError: Error, LocalizedError, Sendable, Equatable {
        case missingFileReplacement(String)
        case missingDirectoryReplacement(String)

        public var errorDescription: String? {
            switch self {
            case .missingFileReplacement(let path):
                "The verified model snapshot does not contain the required file: \(path)"
            case .missingDirectoryReplacement(let path):
                "The verified model snapshot does not contain the required directory: \(path)"
            }
        }
    }

    public typealias ModelLoadVerification = @Sendable (ModelLoadComponent) throws -> ModelLoadLease

    public enum ImageInputError: Error, Equatable, Sendable {
        case invalidDimensions(width: Int, height: Int)
        case invalidPixelCount(expected: Int, actual: Int)
        case nonFinitePixel(Int)
        case pixelOutOfRange(Int)
    }

    /// Materialized host image passed across the app/engine boundary without retaining AppKit or
    /// MLX objects. Pixels are planar RGB in `[-1, 1]`, matching `Krea2VAEEncoderModel.encode`.
    public struct ImageInput: Sendable {
        public static let maximumDimension = 4_096

        public let width: Int
        public let height: Int
        public let planarRGB: [Float]

        public init(width: Int, height: Int, planarRGB: [Float]) throws {
            guard width > 0,
                  height > 0,
                  width <= Self.maximumDimension,
                  height <= Self.maximumDimension,
                  width.isMultiple(of: 8),
                  height.isMultiple(of: 8)
            else {
                throw ImageInputError.invalidDimensions(width: width, height: height)
            }
            let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            let (expected, channelOverflow) = pixels.multipliedReportingOverflow(by: 3)
            guard !pixelOverflow, !channelOverflow, planarRGB.count == expected else {
                throw ImageInputError.invalidPixelCount(
                    expected: pixelOverflow || channelOverflow ? 0 : expected,
                    actual: planarRGB.count)
            }
            for (index, value) in planarRGB.enumerated() {
                guard value.isFinite else { throw ImageInputError.nonFinitePixel(index) }
                guard (-1 ... 1).contains(value) else {
                    throw ImageInputError.pixelOutOfRange(index)
                }
            }
            self.width = width
            self.height = height
            self.planarRGB = planarRGB
        }
    }

    public struct Weights: Sendable {

        public var officialDir: URL

        public var ditQuantFile: URL
        /// Exact quantization recipe matching `ditQuantFile`.
        public var ditQuantization: Krea2DiTQuantization

        public var vaeFile: URL

        public var loraAdapters: [Krea2DiTLoRAConfig]
        /// Identity of the verified, pinned model manifest. A cache is disabled when this is nil.
        public var verifiedModelIdentity: String?
        /// Ordered verified adapter identity. Required only when `loraAdapters` is non-empty.
        public var orderedLoRAIdentity: String?
        /// Optional app-owned verifier invoked immediately before each resident model load.
        public var loadVerification: ModelLoadVerification?
        public init(
            officialDir: URL, ditQuantFile: URL, vaeFile: URL,
            ditQuantization: Krea2DiTQuantization = .mixed4And8,
            loraAdapters: [Krea2DiTLoRAConfig] = [],
            verifiedModelIdentity: String? = nil,
            orderedLoRAIdentity: String? = nil,
            loadVerification: ModelLoadVerification? = nil
        ) {
            self.officialDir = officialDir
            self.ditQuantFile = ditQuantFile
            self.ditQuantization = ditQuantization
            self.vaeFile = vaeFile
            self.loraAdapters = loraAdapters
            self.verifiedModelIdentity = verifiedModelIdentity
            self.orderedLoRAIdentity = orderedLoRAIdentity
            self.loadVerification = loadVerification
        }
    }




    public static func generate(
        prompt: String,
        weights: Weights,
        params: Krea2Sampler.Params = Krea2Sampler.Params(),
        negativePrompt: String = "",
        conditioningCache: Krea2ConditioningCache? = nil,
        cacheEventCallback: ((ConditioningCacheEvent) -> Void)? = nil,
        performanceStageCallback: ((PerformanceStage) -> Void)? = nil,
        phaseCallback: ((Phase) -> Void)? = nil,
        stepCallback: ((Int, Int) -> Void)? = nil
    ) async throws -> MLXArray {
        prepareMemoryForRun()
        defer { MLX.Memory.clearCache() }
        try Task.checkCancellation()

        phaseCallback?(.encodingPrompt)
        var condEmbeddings: MLXArray = MLXArray.zeros([1])
        var condMask: MLXArray = MLXArray.zeros([1])
        var negEmbeddings: MLXArray?
        var negMask: MLXArray?
        let cacheKey = conditioningCacheKey(
            prompt: prompt,
            negativePrompt: negativePrompt,
            weights: weights,
            params: params)
        performanceStageCallback?(.conditioningCacheLookup)
        if let cacheKey,
           let conditioningCache,
           let cached = await conditioningCache.value(for: cacheKey)
        {
            performanceStageCallback?(.conditioningCacheRestore)
            let restored = try Krea2ConditioningHostTransfer.restoreForInferenceTask(cached)
            condEmbeddings = restored.positive.embeddings
            condMask = restored.positive.mask
            negEmbeddings = restored.negative?.embeddings
            negMask = restored.negative?.mask
            eval(condEmbeddings, condMask)
            if let negEmbeddings, let negMask { eval(negEmbeddings, negMask) }
            try Task.checkCancellation()
            cacheEventCallback?(.hit)
        } else {
            cacheEventCallback?(cacheKey == nil || conditioningCache == nil ? .disabled : .miss)
            var pendingCacheValue: Krea2HostConditioning?
            do {
                var loadLease: ModelLoadLease?
                defer {
                    MLX.Memory.clearCache()
                    withExtendedLifetime(loadLease) {}
                }
                performanceStageCallback?(.textEncoderLoad)
                let loadDirectory: URL
                if let loadVerification = weights.loadVerification {
                    let lease = try loadVerification(.textEncoder)
                    loadDirectory = try lease.replacementDirectory(for: weights.officialDir)
                    loadLease = lease
                } else {
                    loadDirectory = weights.officialDir
                }
                let encoder = try await Krea2TextEncoder.load(
                    textEncoderDirectory: loadDirectory.appendingPathComponent("text_encoder"),
                    tokenizerDirectory: loadDirectory.appendingPathComponent("tokenizer"))
                try Task.checkCancellation()
                performanceStageCallback?(.textEncoderPositiveForward)
                let cond = encoder.encode(prompt: prompt)
                condEmbeddings = cond.embeddings
                condMask = cond.mask
                var negativeConditioning: Krea2TextConditioning?
                if params.guidance != 0 {

                    performanceStageCallback?(.textEncoderNegativeForward)
                    let neg = encoder.encode(prompt: negativePrompt)
                    negativeConditioning = neg
                    negEmbeddings = neg.embeddings
                    negMask = neg.mask
                    eval(neg.embeddings, neg.mask)
                }
                performanceStageCallback?(.conditioningMaterialization)
                eval(condEmbeddings, condMask)
                try Task.checkCancellation()
                if cacheKey != nil, conditioningCache != nil {
                    performanceStageCallback?(.conditioningHostCopy)
                    pendingCacheValue = try Krea2ConditioningHostTransfer.copyFromInferenceTask(
                        positive: cond,
                        negative: negativeConditioning)
                }
            }
            if let cacheKey, let conditioningCache, let pendingCacheValue {
                try Task.checkCancellation()
                performanceStageCallback?(.conditioningCacheStore)
                _ = try await conditioningCache.insert(pendingCacheValue, for: cacheKey)
            }
        }



        try Task.checkCancellation()
        phaseCallback?(.loadingTransformer)
        var latent: MLXArray = MLXArray.zeros([1])
        do {
            var transformerLease: ModelLoadLease?
            var adapterLease: ModelLoadLease?
            defer {
                MLX.Memory.clearCache()
                withExtendedLifetime(transformerLease) {}
                withExtendedLifetime(adapterLease) {}
            }
            performanceStageCallback?(.transformerConstruct)
            let dit = Krea2SingleStreamDiT()
            performanceStageCallback?(.transformerQuantization)
            weights.ditQuantization.quantize(dit)
            performanceStageCallback?(.transformerWeightLoad)
            let loadWeights: URL
            if let loadVerification = weights.loadVerification {
                let lease = try loadVerification(.transformer)
                loadWeights = try lease.replacementFile(for: weights.ditQuantFile)
                transformerLease = lease
            } else {
                loadWeights = weights.ditQuantFile
            }
            try Krea2DiTWeightLoader.loadQuantized(into: dit, file: loadWeights)
            try Task.checkCancellation()
            if !weights.loraAdapters.isEmpty {
                performanceStageCallback?(.loraApply)
                let loadAdapters: [Krea2DiTLoRAConfig]
                if let loadVerification = weights.loadVerification {
                    let lease = try loadVerification(.loraAdapters)
                    loadAdapters = try weights.loraAdapters.map { adapter in
                        Krea2DiTLoRAConfig(
                            path: try lease.replacementFile(for: adapter.path),
                            scale: adapter.scale)
                    }
                    adapterLease = lease
                } else {
                    loadAdapters = weights.loraAdapters
                }
                try Krea2DiTLoRALoader.apply(to: dit, adapters: loadAdapters)
                try Task.checkCancellation()
            }
            let sampler = Krea2Sampler(dit: dit)
            phaseCallback?(.denoising)
            performanceStageCallback?(.denoising)
            latent = try sampler.sample(
                context: condEmbeddings, mask: condMask,
                negativeContext: negEmbeddings, negativeMask: negMask,
                params: params, stepCallback: stepCallback)
            eval(latent)
            try Task.checkCancellation()
        }


        try Task.checkCancellation()
        phaseCallback?(.decoding)
        let image: MLXArray
        do {
            var loadLease: ModelLoadLease?
            defer {
                MLX.Memory.clearCache()
                withExtendedLifetime(loadLease) {}
            }
            performanceStageCallback?(.vaeConstruct)
            let vae = Krea2VAEDecoderModel()
            performanceStageCallback?(.vaeWeightLoad)
            let loadWeights: URL
            if let loadVerification = weights.loadVerification {
                let lease = try loadVerification(.vaeDecoder)
                loadWeights = try lease.replacementFile(for: weights.vaeFile)
                loadLease = lease
            } else {
                loadWeights = weights.vaeFile
            }
            try Krea2VAEWeightLoader.load(
                into: vae,
                file: loadWeights,
                computeDType: productionVAEComputeDType)
            try Task.checkCancellation()
            performanceStageCallback?(.vaeDecode)
            let pixels = try vae.decode(latent.asType(productionVAEComputeDType)) // (1,3,H,W)
            performanceStageCallback?(.imageMaterialization)
            image = clip(pixels, min: -1, max: 1) * 0.5 + 0.5
            eval(image)
            try Task.checkCancellation()
        }
        return image
    }



    public static func generateRegional(
        globalPrompt: String,
        regions: [Krea2Region],
        weights: Weights,
        params: Krea2Sampler.Params = Krea2Sampler.Params(),
        phaseCallback: ((Phase) -> Void)? = nil,
        stepCallback: ((Int, Int) -> Void)? = nil
    ) async throws -> MLXArray {
        prepareMemoryForRun()
        defer { MLX.Memory.clearCache() }
        try Task.checkCancellation()
        phaseCallback?(.encodingPrompt)
        var condEmbeddings: MLXArray = MLXArray.zeros([1])
        var txtLabels: MLXArray = MLXArray.zeros([1])
        do {
            var loadLease: ModelLoadLease?
            defer {
                MLX.Memory.clearCache()
                withExtendedLifetime(loadLease) {}
            }
            let loadDirectory: URL
            if let loadVerification = weights.loadVerification {
                let lease = try loadVerification(.textEncoder)
                loadDirectory = try lease.replacementDirectory(for: weights.officialDir)
                loadLease = lease
            } else {
                loadDirectory = weights.officialDir
            }
            let encoder = try await Krea2TextEncoder.load(
                textEncoderDirectory: loadDirectory.appendingPathComponent("text_encoder"),
                tokenizerDirectory: loadDirectory.appendingPathComponent("tokenizer"))
            try Task.checkCancellation()
            let cond = encoder.encodeRegional(globalPrompt: globalPrompt, regions: regions)
            condEmbeddings = cond.embeddings
            txtLabels = cond.txtLabels
            eval(condEmbeddings, txtLabels)
            try Task.checkCancellation()
        }

        try Task.checkCancellation()
        phaseCallback?(.loadingTransformer)
        var latent: MLXArray = MLXArray.zeros([1])
        do {
            var transformerLease: ModelLoadLease?
            var adapterLease: ModelLoadLease?
            defer {
                MLX.Memory.clearCache()
                withExtendedLifetime(transformerLease) {}
                withExtendedLifetime(adapterLease) {}
            }
            let dit = Krea2SingleStreamDiT()
            weights.ditQuantization.quantize(dit)
            let loadWeights: URL
            if let loadVerification = weights.loadVerification {
                let lease = try loadVerification(.transformer)
                loadWeights = try lease.replacementFile(for: weights.ditQuantFile)
                transformerLease = lease
            } else {
                loadWeights = weights.ditQuantFile
            }
            try Krea2DiTWeightLoader.loadQuantized(into: dit, file: loadWeights)
            try Task.checkCancellation()
            if !weights.loraAdapters.isEmpty {
                let loadAdapters: [Krea2DiTLoRAConfig]
                if let loadVerification = weights.loadVerification {
                    let lease = try loadVerification(.loraAdapters)
                    loadAdapters = try weights.loraAdapters.map { adapter in
                        Krea2DiTLoRAConfig(
                            path: try lease.replacementFile(for: adapter.path),
                            scale: adapter.scale)
                    }
                    adapterLease = lease
                } else {
                    loadAdapters = weights.loraAdapters
                }
                try Krea2DiTLoRALoader.apply(to: dit, adapters: loadAdapters)
                try Task.checkCancellation()
            }
            let sampler = Krea2Sampler(dit: dit)
            phaseCallback?(.denoising)
            latent = try sampler.sampleRegional(
                context: condEmbeddings, txtLabels: txtLabels, regions: regions.map(\.bbox),
                params: params, stepCallback: stepCallback)
            eval(latent)
            try Task.checkCancellation()
        }

        try Task.checkCancellation()
        phaseCallback?(.decoding)
        let image: MLXArray
        do {
            var loadLease: ModelLoadLease?
            defer {
                MLX.Memory.clearCache()
                withExtendedLifetime(loadLease) {}
            }
            let vae = Krea2VAEDecoderModel()
            let loadWeights: URL
            if let loadVerification = weights.loadVerification {
                let lease = try loadVerification(.vaeDecoder)
                loadWeights = try lease.replacementFile(for: weights.vaeFile)
                loadLease = lease
            } else {
                loadWeights = weights.vaeFile
            }
            try Krea2VAEWeightLoader.load(
                into: vae,
                file: loadWeights,
                computeDType: productionVAEComputeDType)
            try Task.checkCancellation()
            let pixels = try vae.decode(latent.asType(productionVAEComputeDType))
            image = clip(pixels, min: -1, max: 1) * 0.5 + 0.5
            eval(image)
            try Task.checkCancellation()
        }
        return image
    }

    private static func prepareMemoryForRun() {
        MLX.Memory.cacheLimit = defaultCacheLimitBytes
        MLX.Memory.peakMemory = 0
    }

    static func conditioningCacheKey(
        prompt: String,
        negativePrompt: String,
        weights: Weights,
        params: Krea2Sampler.Params
    ) -> Krea2ConditioningCacheKey? {
        guard let modelIdentity = weights.verifiedModelIdentity,
              !modelIdentity.isEmpty
        else { return nil }

        let loraIdentity: String
        if weights.loraAdapters.isEmpty {
            loraIdentity = "none"
        } else if let verified = weights.orderedLoRAIdentity, !verified.isEmpty {
            loraIdentity = verified
        } else {
            return nil
        }

        let usesCFG = params.guidance != 0
        return Krea2ConditioningCacheKey(
            verifiedModelIdentity: modelIdentity,
            canonicalModelRoot: Krea2ConditioningCacheKey.canonicalModelRoot(
                for: weights.officialDir.deletingLastPathComponent()),
            positivePrompt: prompt,
            negativePrompt: usesCFG ? negativePrompt : nil,
            cfgBranch: usesCFG ? .positiveAndNegative : .positive,
            guidanceMode: usesCFG ? .classifierFree : .disabled,
            templateIdentity: "qwen-image-v1-prefix34-suffix5-pad151643",
            maxLength: Krea2PromptTemplate.maxConditioningTokens,
            selectLayers: Krea2PromptTemplate.selectLayers,
            dtypeIdentity: .bfloat16,
            orderedLoRAIdentity: loraIdentity,
            regionalPromptBBoxIdentity: [])
    }
}
