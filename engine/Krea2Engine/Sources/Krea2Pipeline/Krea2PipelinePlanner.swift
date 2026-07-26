import Foundation
import Krea2Sampler
import Krea2TextEncoder
import MLX

private enum Krea2PlannedConditioning {
    case standard(Krea2MaterializedConditioning)
    case regional(Krea2MaterializedRegionalConditioning)
}

public extension Krea2Pipeline {
    static let maxPlannedRequests = 4

    struct PlannedRequest: Sendable {
        public let prompt: String
        public let negativePrompt: String
        public let params: Krea2Sampler.Params
        public let regions: [Krea2Region]
        public let inputImage: ImageInput?
        public let imageStrength: Float

        public init(
            prompt: String,
            negativePrompt: String = "",
            params: Krea2Sampler.Params,
            regions: [Krea2Region] = [],
            inputImage: ImageInput? = nil,
            imageStrength: Float = 1
        ) {
            self.prompt = prompt
            self.negativePrompt = negativePrompt
            self.params = params
            self.regions = regions
            self.inputImage = inputImage
            self.imageStrength = imageStrength
        }
    }

    struct PlannedOutput {
        public let requestIndex: Int
        public let pixels: MLXArray
    }

    enum PlannedGenerationError: Error, Equatable, Sendable {
        case invalidRequestCount(actual: Int, maximum: Int)
        case invalidPreviewInterval(Int)
        case invalidImageStrength(Int)
        case inputImageSizeMismatch(
            index: Int,
            expectedWidth: Int,
            expectedHeight: Int,
            actualWidth: Int,
            actualHeight: Int)
        case missingConditioning(Int)
        case missingLatent(Int)
        case missingImage(Int)
    }

    /// Runs one bounded group without a true batch dimension. Each heavyweight model is loaded
    /// once, used sequentially, and released before the next resident stage begins.
    static func generatePlanned(
        requests: [PlannedRequest],
        weights: Weights,
        conditioningCache: Krea2ConditioningCache? = nil,
        cacheEventCallback: ((Int, ConditioningCacheEvent) -> Void)? = nil,
        performanceStageCallback: ((PerformanceStage) -> Void)? = nil,
        previewEverySteps: Int = 0,
        phaseCallback: ((Phase) -> Void)? = nil,
        itemPhaseCallback: ((Int, Phase) -> Void)? = nil,
        itemPreviewCallback: ((Int, Krea2LatentPreviewFrame) -> Void)? = nil,
        itemStepCallback: ((Int, Int, Int) -> Void)? = nil
    ) async throws -> [PlannedOutput] {
        guard (1 ... maxPlannedRequests).contains(requests.count) else {
            throw PlannedGenerationError.invalidRequestCount(
                actual: requests.count,
                maximum: maxPlannedRequests)
        }
        guard previewEverySteps >= 0 else {
            throw PlannedGenerationError.invalidPreviewInterval(previewEverySteps)
        }

        MLX.Memory.cacheLimit = defaultCacheLimitBytes
        MLX.Memory.peakMemory = 0
        defer { MLX.Memory.clearCache() }
        try Task.checkCancellation()

        for index in requests.indices {
            let request = requests[index]
            guard request.imageStrength.isFinite,
                  request.imageStrength > 0,
                  request.imageStrength <= 1
            else {
                throw PlannedGenerationError.invalidImageStrength(index)
            }
            if let image = request.inputImage,
               (image.width != request.params.width || image.height != request.params.height)
            {
                throw PlannedGenerationError.inputImageSizeMismatch(
                    index: index,
                    expectedWidth: request.params.width,
                    expectedHeight: request.params.height,
                    actualWidth: image.width,
                    actualHeight: image.height)
            }
        }

        let session = Krea2PipelineSession(
            cacheLimitBytes: defaultCacheLimitBytes,
            performanceStageCallback: performanceStageCallback,
            loadVerification: weights.loadVerification)
        var conditionings = [Krea2PlannedConditioning?](
            repeating: nil,
            count: requests.count)
        var keys = [Krea2ConditioningCacheKey?](repeating: nil, count: requests.count)
        var representatives: [Int] = []
        var aliases: [Int: [Int]] = [:]
        var representativeForKey: [Krea2ConditioningCacheKey: Int] = [:]

        phaseCallback?(.encodingPrompt)
        for index in requests.indices {
            try Task.checkCancellation()
            let request = requests[index]
            if !request.regions.isEmpty {
                cacheEventCallback?(index, .disabled)
                representatives.append(index)
                continue
            }
            let key = conditioningCacheKey(
                prompt: request.prompt,
                negativePrompt: request.negativePrompt,
                weights: weights,
                params: request.params)
            keys[index] = key
            performanceStageCallback?(.conditioningCacheLookup)

            if let key,
               let conditioningCache,
               let cached = await conditioningCache.value(for: key)
            {
                performanceStageCallback?(.conditioningCacheRestore)
                let restored = try Krea2ConditioningHostTransfer.restoreForInferenceTask(cached)
                conditionings[index] = .standard(try Krea2MaterializedConditioning(
                    materializing: restored))
                cacheEventCallback?(index, .hit)
                continue
            }

            if let key, let representative = representativeForKey[key] {
                cacheEventCallback?(index, .hit)
                aliases[representative, default: []].append(index)
            } else {
                cacheEventCallback?(
                    index,
                    key == nil || conditioningCache == nil ? .disabled : .miss)
                representatives.append(index)
                if let key { representativeForKey[key] = index }
            }
        }

        var pendingCacheValues: [(Krea2ConditioningCacheKey, Krea2HostConditioning)] = []
        if !representatives.isEmpty {
            try await session.withTextEncoder(officialDirectory: weights.officialDir) { encoder in
                for representative in representatives {
                    try Task.checkCancellation()
                    let request = requests[representative]
                    if request.regions.isEmpty {
                        let materialized = try encoder.materialize(
                            prompt: request.prompt,
                            negativePrompt: request.params.guidance != 0
                                ? request.negativePrompt
                                : nil)
                        conditionings[representative] = .standard(materialized)
                        for alias in aliases[representative] ?? [] {
                            conditionings[alias] = .standard(materialized)
                        }

                        if let key = keys[representative], conditioningCache != nil {
                            performanceStageCallback?(.conditioningHostCopy)
                            let host = try Krea2ConditioningHostTransfer.copyFromInferenceTask(
                                positive: materialized.positive,
                                negative: materialized.negative)
                            pendingCacheValues.append((key, host))
                        }
                    } else {
                        let materialized = try encoder.materializeRegional(
                            globalPrompt: request.prompt,
                            regions: request.regions)
                        conditionings[representative] = .regional(materialized)
                    }
                }
            }
        }

        if let conditioningCache {
            for (key, value) in pendingCacheValues {
                try Task.checkCancellation()
                performanceStageCallback?(.conditioningCacheStore)
                _ = try await conditioningCache.insert(value, for: key)
            }
        }

        var initialLatents = [Krea2MaterializedLatent?](
            repeating: nil,
            count: requests.count)
        let imageRequestIndices = requests.indices.filter { index in
            requests[index].inputImage != nil && requests[index].imageStrength < 1
        }
        if !imageRequestIndices.isEmpty {
            phaseCallback?(.encodingImage)
            try session.withEncoder(
                weights: weights.vaeFile,
                computeDType: productionVAEEncoderComputeDType
            ) { encoder in
                for index in imageRequestIndices {
                    try Task.checkCancellation()
                    guard let image = requests[index].inputImage else { continue }
                    itemPhaseCallback?(index, .encodingImage)
                    initialLatents[index] = try encoder.encode(image)
                }
            }
        }

        phaseCallback?(.loadingTransformer)
        var latents = [Krea2MaterializedLatent?](repeating: nil, count: requests.count)
        try session.withTransformer(
            quantizedWeights: weights.ditQuantFile,
            quantization: weights.ditQuantization,
            loraAdapters: weights.loraAdapters
        ) { transformer in
            for index in requests.indices {
                try Task.checkCancellation()
                guard let conditioning = conditionings[index] else {
                    throw PlannedGenerationError.missingConditioning(index)
                }
                let previewCallback: ((Krea2LatentPreviewFrame) -> Void)?
                if let itemPreviewCallback {
                    previewCallback = { frame in
                        itemPreviewCallback(index, frame)
                    }
                } else {
                    previewCallback = nil
                }
                phaseCallback?(.denoising)
                itemPhaseCallback?(index, .denoising)
                switch conditioning {
                case .standard(let standard):
                    latents[index] = try transformer.sample(
                        conditioning: standard,
                        params: requests[index].params,
                        initLatent: initialLatents[index],
                        strength: Double(requests[index].imageStrength),
                        previewEverySteps: previewEverySteps,
                        previewCallback: previewCallback,
                        stepCallback: { step, total in
                            itemStepCallback?(index, step, total)
                        })
                case .regional(let regional):
                    latents[index] = try transformer.sampleRegional(
                        conditioning: regional,
                        params: requests[index].params,
                        initLatent: initialLatents[index],
                        strength: Double(requests[index].imageStrength),
                        previewEverySteps: previewEverySteps,
                        previewCallback: previewCallback,
                        stepCallback: { step, total in
                            itemStepCallback?(index, step, total)
                        })
                }
            }
        }
        conditionings = [Krea2PlannedConditioning?](
            repeating: nil,
            count: requests.count)
        initialLatents = [Krea2MaterializedLatent?](
            repeating: nil,
            count: requests.count)

        phaseCallback?(.decoding)
        var images = [MLXArray?](repeating: nil, count: requests.count)
        try session.withDecoder(
            weights: weights.vaeFile,
            computeDType: productionVAEComputeDType
        ) { decoder in
            for index in requests.indices {
                try Task.checkCancellation()
                guard let latent = latents[index] else {
                    throw PlannedGenerationError.missingLatent(index)
                }
                itemPhaseCallback?(index, .decoding)
                images[index] = try decoder.decode(latent)
            }
        }

        return try images.indices.map { index in
            guard let pixels = images[index] else {
                throw PlannedGenerationError.missingImage(index)
            }
            return PlannedOutput(requestIndex: index, pixels: pixels)
        }
    }
}
