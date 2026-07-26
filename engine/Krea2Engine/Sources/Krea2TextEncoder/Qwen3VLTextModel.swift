// Qwen3VLTextModel.swift
//


//



//







import Foundation
import MLX
import MLXNN

public enum Qwen3VLTextKVCachePhase: Sendable, Equatable {
    case empty
    case prefilled
    case decoding
}

public enum Qwen3VLTextKVCacheError: Error, CustomStringConvertible {
    case invalidLayerCount(Int)
    case invalidCapacity(Int)
    case invalidTokenCount(Int)
    case alreadyPrefilled
    case prefillRequired
    case decodeRequiresSingleToken(actual: Int)
    case capacityExceeded(current: Int, requested: Int, maximum: Int)
    case staleTransition
    case incompatibleCache
    case bfloat16Required
    case invalidInputShape(actual: [Int])
    case invalidLayerStorageCount(expected: Int, actual: Int)
    case invalidLayerStorageShape(layer: Int, expected: [Int], keys: [Int], values: [Int])
    case invalidLayerStorageDType(layer: Int)

    public var description: String {
        switch self {
        case .invalidLayerCount(let count):
            return "KV cache layer count must be positive, got \(count)"
        case .invalidCapacity(let capacity):
            return "KV cache capacity must be positive, got \(capacity)"
        case .invalidTokenCount(let count):
            return "KV cache token count must be positive, got \(count)"
        case .alreadyPrefilled:
            return "KV cache prefill may only run on an empty cache"
        case .prefillRequired:
            return "KV cache requires prefill before decode"
        case .decodeRequiresSingleToken(let actual):
            return "KV cache decode requires exactly one token, got \(actual)"
        case .capacityExceeded(let current, let requested, let maximum):
            return "KV cache capacity exceeded: current=\(current), requested=\(requested), maximum=\(maximum)"
        case .staleTransition:
            return "KV cache transition no longer matches its state"
        case .incompatibleCache:
            return "KV cache belongs to a different Qwen3-VL text model"
        case .bfloat16Required:
            return "KV cache inference requires BF16 compute"
        case .invalidInputShape(let actual):
            return "KV cache prefill expects input_ids shape (1, L), got \(actual)"
        case .invalidLayerStorageCount(let expected, let actual):
            return "KV cache expected \(expected) layer entries, got \(actual)"
        case .invalidLayerStorageShape(let layer, let expected, let keys, let values):
            return "KV cache layer \(layer) expected K/V shape \(expected), got keys=\(keys), values=\(values)"
        case .invalidLayerStorageDType(let layer):
            return "KV cache layer \(layer) is not BF16"
        }
    }
}

enum Qwen3VLKVCacheAttentionMask: Sendable, Equatable {
    case causal(shape: [Int])
    case none
}

enum Qwen3VLKVCacheDecodeMode: Sendable, Equatable {
    case parityPaddedQueries
    case fastSingleQuery
}

struct Qwen3VLKVCacheStep: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case prefill
        case decode
    }

    let kind: Kind
    let tokenCount: Int
    let positions: Range<Int>
    let keyLength: Int
    let decodeMode: Qwen3VLKVCacheDecodeMode?
    let dummyQueryCount: Int
    let attentionQueryLength: Int
    let attentionMask: Qwen3VLKVCacheAttentionMask

    func layerStorageShape(numKVHeads: Int, headDim: Int) -> [Int] {
        [1, numKVHeads, keyLength, headDim]
    }

    func attentionQueryShape(numHeads: Int, headDim: Int) -> [Int] {
        [1, numHeads, attentionQueryLength, headDim]
    }
}

/// Host-only state machine: it owns no MLX arrays and is safe to exercise without Metal.
struct Qwen3VLKVCacheState: Sendable, Equatable {
    let layerCount: Int
    let maxSequenceLength: Int
    private(set) var sequenceLength: Int
    private(set) var phase: Qwen3VLTextKVCachePhase

    init(layerCount: Int, maxSequenceLength: Int) throws {
        guard layerCount > 0 else {
            throw Qwen3VLTextKVCacheError.invalidLayerCount(layerCount)
        }
        guard maxSequenceLength > 0 else {
            throw Qwen3VLTextKVCacheError.invalidCapacity(maxSequenceLength)
        }
        self.layerCount = layerCount
        self.maxSequenceLength = maxSequenceLength
        self.sequenceLength = 0
        self.phase = .empty
    }

    func planPrefill(tokenCount: Int) throws -> Qwen3VLKVCacheStep {
        guard phase == .empty else {
            throw Qwen3VLTextKVCacheError.alreadyPrefilled
        }
        guard tokenCount > 0 else {
            throw Qwen3VLTextKVCacheError.invalidTokenCount(tokenCount)
        }
        try checkCapacity(for: tokenCount)
        return Qwen3VLKVCacheStep(
            kind: .prefill,
            tokenCount: tokenCount,
            positions: 0 ..< tokenCount,
            keyLength: tokenCount,
            decodeMode: nil,
            dummyQueryCount: 0,
            attentionQueryLength: tokenCount,
            attentionMask: .causal(shape: [1, 1, tokenCount, tokenCount])
        )
    }

    func planDecode(
        tokenCount: Int,
        mode: Qwen3VLKVCacheDecodeMode = .parityPaddedQueries
    ) throws -> Qwen3VLKVCacheStep {
        guard phase != .empty else {
            throw Qwen3VLTextKVCacheError.prefillRequired
        }
        guard tokenCount == 1 else {
            throw Qwen3VLTextKVCacheError.decodeRequiresSingleToken(actual: tokenCount)
        }
        try checkCapacity(for: tokenCount)
        let keyLength = sequenceLength + tokenCount
        let dummyQueryCount: Int
        let attentionMask: Qwen3VLKVCacheAttentionMask
        switch mode {
        case .parityPaddedQueries:
            dummyQueryCount = sequenceLength
            attentionMask = .causal(shape: [1, 1, keyLength, keyLength])
        case .fastSingleQuery:
            dummyQueryCount = 0
            attentionMask = .none
        }
        return Qwen3VLKVCacheStep(
            kind: .decode,
            tokenCount: tokenCount,
            positions: sequenceLength ..< keyLength,
            keyLength: keyLength,
            decodeMode: mode,
            dummyQueryCount: dummyQueryCount,
            attentionQueryLength: dummyQueryCount + tokenCount,
            attentionMask: attentionMask
        )
    }

    mutating func commit(_ step: Qwen3VLKVCacheStep) throws {
        let expected: Qwen3VLKVCacheStep
        switch step.kind {
        case .prefill:
            expected = try planPrefill(tokenCount: step.tokenCount)
        case .decode:
            guard let mode = step.decodeMode else {
                throw Qwen3VLTextKVCacheError.staleTransition
            }
            expected = try planDecode(tokenCount: step.tokenCount, mode: mode)
        }
        guard expected == step else {
            throw Qwen3VLTextKVCacheError.staleTransition
        }

        sequenceLength = step.keyLength
        phase = step.kind == .prefill ? .prefilled : .decoding
    }

    private func checkCapacity(for tokenCount: Int) throws {
        let (nextLength, overflow) = sequenceLength.addingReportingOverflow(tokenCount)
        guard !overflow, nextLength <= maxSequenceLength else {
            throw Qwen3VLTextKVCacheError.capacityExceeded(
                current: sequenceLength,
                requested: tokenCount,
                maximum: maxSequenceLength
            )
        }
    }
}

private struct Qwen3VLTextLayerKV {
    let keys: MLXArray
    let values: MLXArray
}

/// Per-invocation, per-layer autoregressive cache. The model stores no cache globally; callers
/// create one with `makeKVCache`, prefill it once, then decode one token at a time.
public final class Qwen3VLTextKVCache {
    public let maxSequenceLength: Int
    public var sequenceLength: Int { state.sequenceLength }
    public var phase: Qwen3VLTextKVCachePhase { state.phase }
    public var layerCount: Int { state.layerCount }

    fileprivate let owner: ObjectIdentifier
    fileprivate let numKVHeads: Int
    fileprivate let headDim: Int
    fileprivate var state: Qwen3VLKVCacheState
    fileprivate var storage: [Qwen3VLTextLayerKV] = []

    fileprivate init(
        owner: ObjectIdentifier,
        config: Krea2TextEncoderConfig,
        maxSequenceLength: Int
    ) throws {
        self.owner = owner
        self.numKVHeads = config.numKeyValueHeads
        self.headDim = config.headDim
        self.state = try Qwen3VLKVCacheState(
            layerCount: config.numHiddenLayers,
            maxSequenceLength: maxSequenceLength
        )
        self.maxSequenceLength = maxSequenceLength
    }

    fileprivate func planPrefill(tokenCount: Int) throws -> Qwen3VLKVCacheStep {
        try state.planPrefill(tokenCount: tokenCount)
    }

    fileprivate func planDecode(mode: Qwen3VLKVCacheDecodeMode) throws -> Qwen3VLKVCacheStep {
        guard storage.count == state.layerCount else {
            throw Qwen3VLTextKVCacheError.prefillRequired
        }
        return try state.planDecode(tokenCount: 1, mode: mode)
    }

    fileprivate func commit(_ step: Qwen3VLKVCacheStep, storage nextStorage: [Qwen3VLTextLayerKV]) throws {
        guard nextStorage.count == state.layerCount else {
            throw Qwen3VLTextKVCacheError.invalidLayerStorageCount(
                expected: state.layerCount,
                actual: nextStorage.count
            )
        }

        let expectedShape = step.layerStorageShape(numKVHeads: numKVHeads, headDim: headDim)
        for (index, layer) in nextStorage.enumerated() {
            guard layer.keys.shape == expectedShape, layer.values.shape == expectedShape else {
                throw Qwen3VLTextKVCacheError.invalidLayerStorageShape(
                    layer: index,
                    expected: expectedShape,
                    keys: layer.keys.shape,
                    values: layer.values.shape
                )
            }
            guard layer.keys.dtype == .bfloat16, layer.values.dtype == .bfloat16 else {
                throw Qwen3VLTextKVCacheError.invalidLayerStorageDType(layer: index)
            }
        }

        try state.commit(step)
        storage = nextStorage
    }
}

public final class Qwen3VLTextModel: Module {
    public let config: Krea2TextEncoderConfig

    @ModuleInfo public var embed_tokens: Embedding
    public var layers: [Qwen3VLTextDecoderLayer]
    public var norm: Qwen3RMSNorm

    public init(config: Krea2TextEncoderConfig) {
        self.config = config
        self._embed_tokens = ModuleInfo(wrappedValue: Embedding(
            embeddingCount: config.vocabSize,
            dimensions: config.hiddenSize
        ))
        self.layers = (0 ..< config.numHiddenLayers).map { _ in
            Qwen3VLTextDecoderLayer(config: config)
        }
        self.norm = Qwen3RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }


    /// - Parameters:
    ///   - inputIds: (B, L) int32




    public func hiddenStateTaps(
        inputIds: MLXArray,
        validMask: MLXArray,
        taps: [Int],
        computeDType: DType = .bfloat16
    ) -> [MLXArray] {
        precondition(!taps.isEmpty, "Tap list must not be empty")
        let maxTap = taps.max()!
        precondition(maxTap <= config.numHiddenLayers, "Tap \(maxTap) exceeds layer count \(config.numHiddenLayers)")

        var h = embed_tokens(inputIds).asType(computeDType)
        let positionIds = Qwen3RoPE.cumulativePositionIds(validMask: validMask)
        let (cos, sin) = Qwen3RoPE.tables(
            positionIds: positionIds,
            headDim: config.headDim,
            theta: config.ropeTheta
        )
        let mask = Self.additiveCausalPaddingMask(validMask: validMask, dtype: computeDType)
        eval(h, mask)

        let tapSet = Set(taps)
        var collected: [Int: MLXArray] = [:]
        if tapSet.contains(0) {
            collected[0] = h
        }


        let layersToRun = min(maxTap, config.numHiddenLayers)
        for i in 0 ..< layersToRun {
            h = layers[i](h, cos: cos, sin: sin, mask: mask)
            let hfIndex = i + 1
            if tapSet.contains(hfIndex) {
                eval(h)
                collected[hfIndex] = h
            }
        }


        if tapSet.contains(config.numHiddenLayers), maxTap == config.numHiddenLayers {
            let normalized = norm(h)
            eval(normalized)
            collected[config.numHiddenLayers] = normalized
        }

        return taps.map { collected[$0]! }
    }









    public func nextTokenLogits(inputIds: MLXArray, computeDType: DType = .bfloat16) -> MLXArray {
        let b = inputIds.dim(0), l = inputIds.dim(1)
        var h = embed_tokens(inputIds).asType(computeDType)
        let (cos, sin) = Qwen3RoPE.tables(length: l, headDim: config.headDim, theta: config.ropeTheta)
        let validMask = MLXArray.ones([b, l])
        let mask = Self.additiveCausalPaddingMask(validMask: validMask, dtype: computeDType)
        for layer in layers {
            h = layer(h, cos: cos, sin: sin, mask: mask)
        }
        let normalized = norm(h)
        let lastHidden = normalized[0..., l - 1, 0...]
        return embed_tokens.asLinear(lastHidden)             // (B, vocab)
    }

    /// Creates an empty bounded cache tied to this model instance. The cache stores BF16 K/V
    /// tensors only after prefill and never outlives the caller unless explicitly retained.
    public func makeKVCache(maxSequenceLength: Int) throws -> Qwen3VLTextKVCache {
        try Qwen3VLTextKVCache(
            owner: ObjectIdentifier(self),
            config: config,
            maxSequenceLength: maxSequenceLength
        )
    }

    /// Causal full-prompt prefill. This may be called exactly once on an empty cache.
    /// - Returns: (1, vocab) logits for the token immediately after the prompt.
    public func prefillNextTokenLogits(
        inputIds: MLXArray,
        cache: Qwen3VLTextKVCache,
        computeDType: DType = .bfloat16
    ) throws -> MLXArray {
        try validate(cache: cache, computeDType: computeDType)
        guard inputIds.shape.count == 2, inputIds.dim(0) == 1, inputIds.dim(1) > 0 else {
            throw Qwen3VLTextKVCacheError.invalidInputShape(actual: inputIds.shape)
        }
        let step = try cache.planPrefill(tokenCount: inputIds.dim(1))
        return try cachedNextTokenLogits(inputIds: inputIds, cache: cache, step: step)
    }

    /// Parity-oriented one-token decode. The real query is left-padded with zero dummy rows to
    /// the cached key length so fused SDPA sees the same Q/K dimensions and causal-mask geometry
    /// as the legacy full-prefix path. Only the final query output reaches `o_proj` and residuals.
    /// - Returns: (1, vocab) logits for the token after `tokenId`.
    public func decodeNextTokenLogits(
        tokenId: Int32,
        cache: Qwen3VLTextKVCache,
        computeDType: DType = .bfloat16
    ) throws -> MLXArray {
        try decodeNextTokenLogits(
            tokenId: tokenId,
            cache: cache,
            computeDType: computeDType,
            mode: .parityPaddedQueries
        )
    }

    /// Internal diagnostic seam retaining the faster qLength=1 decode for A/B measurements.
    func decodeNextTokenLogits(
        tokenId: Int32,
        cache: Qwen3VLTextKVCache,
        computeDType: DType,
        mode: Qwen3VLKVCacheDecodeMode
    ) throws -> MLXArray {
        try validate(cache: cache, computeDType: computeDType)
        let step = try cache.planDecode(mode: mode)
        let inputIds = MLXArray([tokenId]).reshaped([1, 1])
        return try cachedNextTokenLogits(inputIds: inputIds, cache: cache, step: step)
    }

    private func validate(cache: Qwen3VLTextKVCache, computeDType: DType) throws {
        guard cache.owner == ObjectIdentifier(self) else {
            throw Qwen3VLTextKVCacheError.incompatibleCache
        }
        guard computeDType == .bfloat16 else {
            throw Qwen3VLTextKVCacheError.bfloat16Required
        }
    }

    private func cachedNextTokenLogits(
        inputIds: MLXArray,
        cache: Qwen3VLTextKVCache,
        step: Qwen3VLKVCacheStep
    ) throws -> MLXArray {
        let queryLength = inputIds.dim(1)
        var h = embed_tokens(inputIds).asType(.bfloat16)
        let (cos, sin) = Qwen3RoPE.tables(
            length: queryLength,
            offset: step.positions.lowerBound,
            headDim: config.headDim,
            theta: config.ropeTheta
        )

        let mask: MLXArray?
        switch step.attentionMask {
        case .causal(let plannedShape):
            precondition(
                plannedShape == [1, 1, step.attentionQueryLength, step.keyLength]
                    && step.attentionQueryLength == step.keyLength,
                "causal KV cache attention must use square Q/K geometry"
            )
            let validMask = MLXArray.ones([1, step.keyLength])
            mask = Self.additiveCausalPaddingMask(validMask: validMask, dtype: .bfloat16)
        case .none:
            // Internal fast mode: the newest one-token query has no future cached keys.
            mask = nil
        }

        var nextStorage: [Qwen3VLTextLayerKV] = []
        nextStorage.reserveCapacity(layers.count)
        for (index, layer) in layers.enumerated() {
            let past: Qwen3VLTextLayerKV? = step.kind == .decode ? cache.storage[index] : nil
            let result = layer.callWithCache(
                h,
                cos: cos,
                sin: sin,
                mask: mask,
                cachedKeys: past?.keys,
                cachedValues: past?.values,
                dummyQueryCount: step.dummyQueryCount
            )
            h = result.hiddenStates
            nextStorage.append(Qwen3VLTextLayerKV(keys: result.keys, values: result.values))
        }

        let normalized = norm(h)
        let lastHidden = normalized[0..., queryLength - 1, 0...]
        let logits = embed_tokens.asLinear(lastHidden)

        // Break the lazy graph between generated tokens. This also ensures replacing storage
        // releases the previous cache arrays instead of retaining the whole decode history.
        var outputs = [logits]
        outputs.reserveCapacity(1 + 2 * nextStorage.count)
        for layer in nextStorage {
            outputs.append(layer.keys)
            outputs.append(layer.values)
        }
        eval(outputs)
        try cache.commit(step, storage: nextStorage)
        return logits
    }



    public static func additiveCausalPaddingMask(validMask: MLXArray, dtype: DType) -> MLXArray {
        let b = validMask.dim(0)
        let l = validMask.dim(1)
        let idx = MLXArray(Array(stride(from: Float(0), to: Float(l), by: 1)))
        let causal = MLX.where(
            idx.expandedDimensions(axis: 0) .> idx.expandedDimensions(axis: 1),
            MLXArray(Float(-1e9)),
            MLXArray(Float(0))
        )                                                                   // (L, L)
        let pad = (1.0 - validMask.asType(.float32)) * Float(-1e9)          // (B, L)
        let mask = causal.reshaped([1, 1, l, l]) + pad.reshaped([b, 1, 1, l])
        return mask.asType(dtype)
    }
}
