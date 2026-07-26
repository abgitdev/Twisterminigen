// EnhanceKVCacheTests.swift
//
// Cache geometry/state tests are host-only. Numerical prefill/decode parity uses a tiny random
// model and is explicitly Metal-gated; it never reads official weights.

import Foundation
import Testing
import MLX
import MLXNN
@testable import Krea2TextEncoder

private struct KVLogitMetrics {
    let cosine: Float
    let maximumAbsoluteError: Float
    let meanAbsoluteError: Float

    static func measure(reference: MLXArray, candidate: MLXArray) -> KVLogitMetrics {
        let reference = reference.asType(.float32)
        let candidate = candidate.asType(.float32)
        let difference = MLX.abs(reference - candidate)
        let dot = MLX.sum(reference * candidate)
        let denominator = MLX.sqrt(
            MLX.sum(reference * reference) * MLX.sum(candidate * candidate)
        )
        return KVLogitMetrics(
            cosine: (dot / denominator).item(Float.self),
            maximumAbsoluteError: MLX.max(difference).item(Float.self),
            meanAbsoluteError: difference.mean().item(Float.self)
        )
    }
}

private struct KVLogitMetricSummary {
    private(set) var minimumCosine = Float(1)
    private(set) var maximumAbsoluteError = Float(0)
    private(set) var maximumMeanAbsoluteError = Float(0)

    mutating func record(reference: MLXArray, candidate: MLXArray) -> KVLogitMetrics {
        let metrics = KVLogitMetrics.measure(reference: reference, candidate: candidate)
        minimumCosine = min(minimumCosine, metrics.cosine)
        maximumAbsoluteError = max(maximumAbsoluteError, metrics.maximumAbsoluteError)
        maximumMeanAbsoluteError = max(maximumMeanAbsoluteError, metrics.meanAbsoluteError)
        return metrics
    }

    var report: String {
        "minimum cosine=\(minimumCosine), maximum abs error=\(maximumAbsoluteError), "
            + "maximum mean abs error=\(maximumMeanAbsoluteError)"
    }
}

@Test func kvCachePrefillAndDecodeTrackGrowthPositionsAndMask() throws {
    var state = try Qwen3VLKVCacheState(layerCount: 3, maxSequenceLength: 6)
    #expect(state.layerCount == 3)
    #expect(state.maxSequenceLength == 6)
    #expect(state.sequenceLength == 0)
    #expect(state.phase == .empty)

    let prefill = try state.planPrefill(tokenCount: 4)
    #expect(prefill.kind == .prefill)
    #expect(prefill.positions == 0 ..< 4)
    #expect(prefill.keyLength == 4)
    #expect(prefill.decodeMode == nil)
    #expect(prefill.dummyQueryCount == 0)
    #expect(prefill.attentionQueryLength == 4)
    #expect(prefill.attentionMask == .causal(shape: [1, 1, 4, 4]))
    #expect(prefill.layerStorageShape(numKVHeads: 2, headDim: 8) == [1, 2, 4, 8])
    #expect(prefill.attentionQueryShape(numHeads: 4, headDim: 8) == [1, 4, 4, 8])
    try state.commit(prefill)

    #expect(state.sequenceLength == 4)
    #expect(state.phase == .prefilled)

    let fastDecode = try state.planDecode(tokenCount: 1, mode: .fastSingleQuery)
    #expect(fastDecode.decodeMode == .fastSingleQuery)
    #expect(fastDecode.dummyQueryCount == 0)
    #expect(fastDecode.attentionQueryLength == 1)
    #expect(fastDecode.attentionMask == .none)
    #expect(fastDecode.attentionQueryShape(numHeads: 4, headDim: 8) == [1, 4, 1, 8])

    let firstDecode = try state.planDecode(tokenCount: 1)
    #expect(firstDecode.kind == .decode)
    #expect(firstDecode.positions == 4 ..< 5)
    #expect(firstDecode.keyLength == 5)
    #expect(firstDecode.decodeMode == .parityPaddedQueries)
    #expect(firstDecode.dummyQueryCount == 4)
    #expect(firstDecode.attentionQueryLength == 5)
    #expect(firstDecode.attentionMask == .causal(shape: [1, 1, 5, 5]))
    #expect(firstDecode.layerStorageShape(numKVHeads: 2, headDim: 8) == [1, 2, 5, 8])
    #expect(firstDecode.attentionQueryShape(numHeads: 4, headDim: 8) == [1, 4, 5, 8])
    try state.commit(firstDecode)

    #expect(state.sequenceLength == 5)
    #expect(state.phase == .decoding)

    let secondDecode = try state.planDecode(tokenCount: 1)
    #expect(secondDecode.positions == 5 ..< 6)
    #expect(secondDecode.keyLength == 6)
    #expect(secondDecode.dummyQueryCount == 5)
    #expect(secondDecode.attentionQueryLength == 6)
    #expect(secondDecode.attentionMask == .causal(shape: [1, 1, 6, 6]))
    try state.commit(secondDecode)
    #expect(state.sequenceLength == 6)
}

@Test func kvCacheStateRejectsInvalidOrderingAndDecodeWidth() throws {
    var empty = try Qwen3VLKVCacheState(layerCount: 2, maxSequenceLength: 8)
    #expect(throws: Qwen3VLTextKVCacheError.self) {
        _ = try empty.planDecode(tokenCount: 1)
    }
    #expect(throws: Qwen3VLTextKVCacheError.self) {
        _ = try empty.planPrefill(tokenCount: 0)
    }

    let prefill = try empty.planPrefill(tokenCount: 3)
    try empty.commit(prefill)
    #expect(throws: Qwen3VLTextKVCacheError.self) {
        _ = try empty.planPrefill(tokenCount: 1)
    }
    #expect(throws: Qwen3VLTextKVCacheError.self) {
        _ = try empty.planDecode(tokenCount: 2)
    }
}

@Test func kvCacheStateIsStrictlyBounded() throws {
    var state = try Qwen3VLKVCacheState(layerCount: 1, maxSequenceLength: 3)
    let prefill = try state.planPrefill(tokenCount: 2)
    try state.commit(prefill)

    let decode = try state.planDecode(tokenCount: 1)
    try state.commit(decode)
    #expect(state.sequenceLength == state.maxSequenceLength)
    #expect(throws: Qwen3VLTextKVCacheError.self) {
        _ = try state.planDecode(tokenCount: 1)
    }
}

@Test func kvCacheStateRejectsStaleSteps() throws {
    var state = try Qwen3VLKVCacheState(layerCount: 1, maxSequenceLength: 4)
    let prefill = try state.planPrefill(tokenCount: 2)
    try state.commit(prefill)

    let decode = try state.planDecode(tokenCount: 1)
    try state.commit(decode)
    #expect(throws: Qwen3VLTextKVCacheError.self) {
        try state.commit(decode)
    }
}

@Test func kvCacheStateValidatesConstruction() {
    #expect(throws: Qwen3VLTextKVCacheError.self) {
        _ = try Qwen3VLKVCacheState(layerCount: 0, maxSequenceLength: 4)
    }
    #expect(throws: Qwen3VLTextKVCacheError.self) {
        _ = try Qwen3VLKVCacheState(layerCount: 1, maxSequenceLength: 0)
    }
}

@Test func kvCacheTinyModelMatchesFullPrefixWhenMetalIsEnabled() throws {
    guard ProcessInfo.processInfo.environment["TWISTER_RUN_METAL_TESTS"] == "1" else {
        return
    }

    let config = Krea2TextEncoderConfig(
        vocabSize: 32,
        hiddenSize: 8,
        intermediateSize: 16,
        numHiddenLayers: 2,
        numAttentionHeads: 2,
        numKeyValueHeads: 1,
        headDim: 4,
        rmsNormEps: 1e-6,
        ropeTheta: 10_000,
        tieWordEmbeddings: true
    )
    let model = Qwen3VLTextModel(config: config)
    model.update(parameters: model.mapParameters { $0.asType(.bfloat16) })
    eval(model)

    var tokenIds: [Int32] = [1, 7, 3]
    let decodeSteps = 4
    let promptArray = MLXArray(tokenIds).reshaped([1, tokenIds.count])
    let parityCache = try model.makeKVCache(maxSequenceLength: tokenIds.count + decodeSteps)
    let fastCache = try model.makeKVCache(maxSequenceLength: tokenIds.count + decodeSteps)
    var referenceLogits = model.nextTokenLogits(inputIds: promptArray, computeDType: .bfloat16)
    var parityLogits = try model.prefillNextTokenLogits(
        inputIds: promptArray,
        cache: parityCache,
        computeDType: .bfloat16
    )
    var fastLogits = try model.prefillNextTokenLogits(
        inputIds: promptArray,
        cache: fastCache,
        computeDType: .bfloat16
    )
    var referenceTokens: [Int32] = []
    var parityTokens: [Int32] = []
    var parityMetrics = KVLogitMetricSummary()
    var fastMetrics = KVLogitMetricSummary()
    var fastGreedyMatches = 0

    #expect(parityCache.layerCount == config.numHiddenLayers)
    #expect(parityCache.sequenceLength == tokenIds.count)
    #expect(parityCache.phase == .prefilled)

    for step in 0 ... decodeSteps {
        eval(referenceLogits, parityLogits, fastLogits)
        let parityStepMetrics = parityMetrics.record(
            reference: referenceLogits,
            candidate: parityLogits
        )
        let fastStepMetrics = fastMetrics.record(
            reference: referenceLogits,
            candidate: fastLogits
        )
        #expect(parityStepMetrics.cosine.isFinite)
        #expect(parityStepMetrics.maximumAbsoluteError.isFinite)
        #expect(parityStepMetrics.meanAbsoluteError.isFinite)
        #expect(fastStepMetrics.cosine.isFinite)

        let referenceToken = referenceLogits.argMax(axis: -1).asType(.int32).item(Int32.self)
        let parityToken = parityLogits.argMax(axis: -1).asType(.int32).item(Int32.self)
        let fastToken = fastLogits.argMax(axis: -1).asType(.int32).item(Int32.self)
        referenceTokens.append(referenceToken)
        parityTokens.append(parityToken)
        #expect(parityToken == referenceToken, "tiny greedy token diverged at step \(step)")
        if fastToken == referenceToken { fastGreedyMatches += 1 }
        #expect(parityCache.sequenceLength == tokenIds.count)
        #expect(fastCache.sequenceLength == tokenIds.count)

        guard step < decodeSteps else { break }
        tokenIds.append(referenceToken)
        referenceLogits = model.nextTokenLogits(
            inputIds: MLXArray(tokenIds).reshaped([1, tokenIds.count]),
            computeDType: .bfloat16
        )
        parityLogits = try model.decodeNextTokenLogits(
            tokenId: referenceToken,
            cache: parityCache,
            computeDType: .bfloat16
        )
        fastLogits = try model.decodeNextTokenLogits(
            tokenId: referenceToken,
            cache: fastCache,
            computeDType: .bfloat16,
            mode: .fastSingleQuery
        )
    }

    #expect(parityTokens == referenceTokens)
    print("KV tiny parity padded: \(parityMetrics.report)")
    print(
        "KV tiny fast q=1: \(fastMetrics.report), greedy matches="
            + "\(fastGreedyMatches)/\(decodeSteps + 1)"
    )
}

/// Final production-default gate. It is intentionally separate from the ordinary Metal gate so
/// no checkpoint can be loaded by a routine test run.
@Test func kvCacheOfficialWeightsMatchFullPrefixWhenExplicitlyEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["TWISTER_RUN_METAL_TESTS"] == "1",
          environment["TWISTER_RUN_KV_LIVE_PARITY"] == "1"
    else {
        return
    }
    guard let directoryPath = environment["KREA2_TEXT_ENCODER_DIR"] else {
        Issue.record("KREA2_TEXT_ENCODER_DIR is required for live KV parity")
        return
    }

    let directory = URL(fileURLWithPath: directoryPath)
    let config = try Krea2TextEncoderConfig.load(
        from: directory.appendingPathComponent("config.json")
    )
    let model = Qwen3VLTextModel(config: config)
    _ = try Krea2TextEncoderWeightLoader.load(
        into: model,
        directory: directory,
        computeDType: .bfloat16
    )
    defer { MLX.Memory.clearCache() }

    var tokenIds: [Int32] = [151_644, 8948, 198, 42, 151_645]
    // Eight official tokens were insufficient to catch the observed long-run Enhance drift.
    let decodeSteps = 64
    let cache = try model.makeKVCache(maxSequenceLength: tokenIds.count + decodeSteps)
    var referenceLogits = model.nextTokenLogits(
        inputIds: MLXArray(tokenIds).reshaped([1, tokenIds.count]),
        computeDType: .bfloat16
    )
    var cachedLogits = try model.prefillNextTokenLogits(
        inputIds: MLXArray(tokenIds).reshaped([1, tokenIds.count]),
        cache: cache,
        computeDType: .bfloat16
    )
    var referenceTokens: [Int32] = []
    var cachedTokens: [Int32] = []
    var metrics = KVLogitMetricSummary()

    for step in 0 ... decodeSteps {
        eval(referenceLogits, cachedLogits)
        let stepMetrics = metrics.record(reference: referenceLogits, candidate: cachedLogits)
        #expect(stepMetrics.cosine.isFinite, "official BF16 logit cosine was not finite at step \(step)")
        #expect(
            stepMetrics.maximumAbsoluteError.isFinite,
            "official BF16 maximum logit error was not finite at step \(step)"
        )
        #expect(
            stepMetrics.meanAbsoluteError.isFinite,
            "official BF16 mean logit error was not finite at step \(step)"
        )

        let referenceToken = referenceLogits.argMax(axis: -1).asType(.int32).item(Int32.self)
        let cachedToken = cachedLogits.argMax(axis: -1).asType(.int32).item(Int32.self)
        referenceTokens.append(referenceToken)
        cachedTokens.append(cachedToken)
        #expect(cachedToken == referenceToken, "greedy token diverged at decode step \(step)")
        #expect(cache.sequenceLength == tokenIds.count)

        guard step < decodeSteps else { break }
        tokenIds.append(referenceToken)
        referenceLogits = model.nextTokenLogits(
            inputIds: MLXArray(tokenIds).reshaped([1, tokenIds.count]),
            computeDType: .bfloat16
        )
        cachedLogits = try model.decodeNextTokenLogits(
            tokenId: referenceToken,
            cache: cache,
            computeDType: .bfloat16
        )
    }
    #expect(cachedTokens == referenceTokens)
    print("KV live parity: exact greedy tokens; \(metrics.report)")
}
