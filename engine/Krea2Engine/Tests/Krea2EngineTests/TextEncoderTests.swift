// TextEncoderTests.swift
//



import Foundation
import Testing
import MLX
@testable import Krea2TextEncoder



@Test func configPresetMatchesPortMap() {
    let c = Krea2TextEncoderConfig.qwen3VL4B
    #expect(c.vocabSize == 151_936)
    #expect(c.hiddenSize == 2560)
    #expect(c.intermediateSize == 9728)
    #expect(c.numHiddenLayers == 36)
    #expect(c.numAttentionHeads == 32)
    #expect(c.numKeyValueHeads == 8)
    #expect(c.headDim == 128)
    #expect(c.rmsNormEps == 1e-6)
    #expect(c.ropeTheta == 5_000_000)
    #expect(c.tieWordEmbeddings)
}


@Test func configParsesOfficialSchema() throws {
    let json = """
    {
      "architectures": ["Qwen3VLModel"],
      "model_type": "qwen3_vl",
      "text_config": {
        "attention_bias": false,
        "head_dim": 128,
        "hidden_size": 2560,
        "intermediate_size": 9728,
        "num_attention_heads": 32,
        "num_hidden_layers": 36,
        "num_key_value_heads": 8,
        "rms_norm_eps": 1e-06,
        "rope_parameters": {
          "mrope_interleaved": true,
          "mrope_section": [24, 20, 20],
          "rope_theta": 5000000,
          "rope_type": "default"
        },
        "tie_word_embeddings": true,
        "vocab_size": 151936
      }
    }
    """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("krea2-te-config-\(UUID().uuidString).json")
    try json.data(using: .utf8)!.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let c = try Krea2TextEncoderConfig.load(from: url)
    #expect(c.hiddenSize == 2560)
    #expect(c.numHiddenLayers == 36)
    #expect(c.numAttentionHeads == 32)
    #expect(c.numKeyValueHeads == 8)
    #expect(c.headDim == 128)
    #expect(c.ropeTheta == 5_000_000)
    #expect(c.rmsNormEps == 1e-6)
}


@Test func configParsesRealOfficialFile() throws {
    guard let weights = ProcessInfo.processInfo.environment["KREA2_OFFICIAL_WEIGHTS"] else {
        return
    }
    let url = URL(fileURLWithPath: weights)
        .appendingPathComponent("text_encoder/config.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let c = try Krea2TextEncoderConfig.load(from: url)
    #expect(c.vocabSize == 151_936)
    #expect(c.hiddenSize == 2560)
    #expect(c.numHiddenLayers == 36)
    #expect(c.ropeTheta == 5_000_000)
}



@Test func tapListMatchesOracle() {
    let taps = Krea2PromptTemplate.selectLayers
    #expect(taps == [2, 5, 8, 11, 14, 17, 20, 23, 26, 29, 32, 35]) // encoder.py select_layers
    #expect(taps.count == 12)
    #expect(taps.first == 2)
    #expect(taps.max()! < 36)
    for pair in zip(taps, taps.dropFirst()) {
        #expect(pair.1 - pair.0 == 3)
    }
}



@Test func templateAssembly() {
    let prompt = "a red cube"
    let text = Krea2PromptTemplate.templatedText(prompt: prompt)
    #expect(text == Krea2PromptTemplate.prefix + prompt)
    #expect(text.hasPrefix("<|im_start|>system\nDescribe the image by detailing the color, shape, size, texture, quantity, text, spatial relationships of the objects and background:<|im_end|>\n<|im_start|>user\n"))
    #expect(text.hasSuffix(prompt))

    #expect(!text.contains(Krea2PromptTemplate.suffix))
    #expect(Krea2PromptTemplate.suffix == "<|im_end|>\n<|im_start|>assistant\n")
}



@Test func packShortPromptOfficialScheme() {

    let body = (0 ..< 40).map(Int32.init)
    let suffix: [Int32] = [151_645, 198, 151_644, 77_091, 198] // <|im_end|>\n<|im_start|>assistant\n
    let (ids, mask) = Krea2PromptTemplate.pack(prefixAndPromptIds: body, suffixIds: suffix)

    #expect(ids.count == 546) // 541 + 5
    #expect(mask.count == 546)

    #expect(Array(ids[0 ..< 40]) == body)
    #expect(mask[0 ..< 40].allSatisfy { $0 == 1 })
    #expect(mask[40 ..< 541].allSatisfy { $0 == 0 })
    #expect(ids[40 ..< 541].allSatisfy { $0 == Krea2PromptTemplate.padTokenId })

    #expect(Array(ids[541 ..< 546]) == suffix)
    #expect(mask[541 ..< 546].allSatisfy { $0 == 1 })

    let validAfterSlice = mask.dropFirst(34).reduce(0) { $0 + Int($1) }
    #expect(validAfterSlice == 11)
}

@Test func packLongPromptTruncates() {
    let body = (0 ..< 600).map(Int32.init)
    let suffix: [Int32] = [1, 2, 3, 4, 5]
    let (ids, mask) = Krea2PromptTemplate.pack(prefixAndPromptIds: body, suffixIds: suffix)

    #expect(ids.count == 546)
    #expect(Array(ids[0 ..< 541]) == Array(body[0 ..< 541])) // truncation=True
    #expect(mask[0 ..< 541].allSatisfy { $0 == 1 })
    #expect(Array(ids[541 ..< 546]) == suffix)

    let validAfterSlice = mask.dropFirst(34).reduce(0) { $0 + Int($1) }
    #expect(validAfterSlice == Krea2PromptTemplate.maxConditioningTokens)
}

// MARK: - Official Krea 2 position ids

@Test func cumulativePositionIdsSkipMiddlePadding() {
    // Official Diffusers formula:
    //   (attention_mask.cumsum(-1) - 1).clamp(min=0)
    let valid = MLXArray([Int32(1), 1, 1, 0, 0, 1, 1]).reshaped([1, 7])
    let positions = Qwen3RoPE.cumulativePositionIds(validMask: valid)

    #expect(positions.shape == [1, 7])
    #expect(positions.asArray(Int32.self) == [0, 1, 2, 2, 2, 3, 4])
}

@Test func packedSuffixContinuesAfterPromptInsteadOfPhysicalPadding() {
    // Same geometry as a short real Krea prompt: 40 valid body tokens, padding to 541,
    // then five valid assistant-suffix tokens at physical indices 541...545.
    let body = (0 ..< 40).map(Int32.init)
    let suffix: [Int32] = [151_645, 198, 151_644, 77_091, 198]
    let (_, mask) = Krea2PromptTemplate.pack(prefixAndPromptIds: body, suffixIds: suffix)
    let validMask = MLXArray(mask).reshaped([1, mask.count])
    let positions = Qwen3RoPE.cumulativePositionIds(validMask: validMask)
        .asArray(Int32.self)

    #expect(Array(positions[0 ..< 40]) == Array(0 ..< 40).map(Int32.init))
    #expect(positions[40] == 39)
    #expect(positions[540] == 39)
    #expect(Array(positions[541 ..< 546]) == [40, 41, 42, 43, 44])
    #expect(Array(positions[541 ..< 546]) != [541, 542, 543, 544, 545])
}

@Test func arbitraryPositionRoPETablesPreserveBatchAndRepeatedPositions() {
    let positions = MLXArray([Int32(0), 1, 1, 2]).reshaped([1, 4])
    let (cos, sin) = Qwen3RoPE.tables(positionIds: positions, headDim: 8, theta: 10_000)

    #expect(cos.shape == [1, 4, 8])
    #expect(sin.shape == [1, 4, 8])
    #expect(cos[0, 1].asArray(Float.self) == cos[0, 2].asArray(Float.self))
    #expect(sin[0, 1].asArray(Float.self) == sin[0, 2].asArray(Float.self))
    #expect(cos[0, 2].asArray(Float.self) != cos[0, 3].asArray(Float.self))
}

@Test func maskAwareRoPEHandlesDifferentPaddingHolesInOneBatch() {
    let valid = MLXArray([
        Int32(1), 1, 0, 0, 1,
        1, 0, 1, 1, 1,
    ]).reshaped([2, 5])
    let positions = Qwen3RoPE.cumulativePositionIds(validMask: valid)
    #expect(positions.asArray(Int32.self) == [
        0, 1, 1, 1, 2,
        0, 0, 1, 2, 3,
    ])

    let (cos, sin) = Qwen3RoPE.tables(positionIds: positions, headDim: 8, theta: 10_000)
    let input = MLXArray.ones([2, 2, 5, 8])
    let rotated = Qwen3RoPE.apply(input, cos: cos, sin: sin)

    #expect(cos.shape == [2, 5, 8])
    #expect(sin.shape == [2, 5, 8])
    #expect(rotated.shape == input.shape)
    // Batch row 0's last token is position 2; row 1's is position 3.
    #expect(rotated[0, 0, 4].asArray(Float.self) != rotated[1, 0, 4].asArray(Float.self))
}

@Test func hiddenStateTapsIgnorePhysicalMiddlePaddingForValidTokens() {
    let config = Krea2TextEncoderConfig(
        vocabSize: 16,
        hiddenSize: 8,
        intermediateSize: 16,
        numHiddenLayers: 1,
        numAttentionHeads: 2,
        numKeyValueHeads: 1,
        headDim: 4,
        rmsNormEps: 1e-6,
        ropeTheta: 10_000,
        tieWordEmbeddings: true
    )
    let model = Qwen3VLTextModel(config: config)

    let paddedIDs = MLXArray([Int32(2), 3, 0, 0, 4, 5]).reshaped([1, 6])
    let paddedMask = MLXArray([Int32(1), 1, 0, 0, 1, 1]).reshaped([1, 6])
    let compactIDs = MLXArray([Int32(2), 3, 4, 5]).reshaped([1, 4])
    let compactMask = MLXArray.ones([1, 4], type: Int32.self)

    let padded = model.hiddenStateTaps(
        inputIds: paddedIDs,
        validMask: paddedMask,
        taps: [1],
        computeDType: .float32)[0]
    let compact = model.hiddenStateTaps(
        inputIds: compactIDs,
        validMask: compactMask,
        taps: [1],
        computeDType: .float32)[0]
    let paddedValid = stacked([
        padded[0, 0], padded[0, 1], padded[0, 4], padded[0, 5],
    ], axis: 0)
    let compactValid = compact[0]
    eval(paddedValid, compactValid)

    let maximumError = MLX.max(MLX.abs(paddedValid - compactValid)).item(Float.self)
    #expect(maximumError < 1e-5, "valid hidden states changed across a middle padding hole: \(maximumError)")
}



@Test func prefixSliceOnStackedTaps() {

    let total = Krea2PromptTemplate.maxConditioningTokens + Krea2PromptTemplate.prefixTokenCount // 546
    let stackedTaps = MLXArray.zeros([1, total, 12, 4])
    let sliced = stackedTaps[0..., Krea2PromptTemplate.prefixTokenCount...]
    #expect(sliced.shape == [1, Krea2PromptTemplate.maxConditioningTokens, 12, 4])
}



@Test func additiveMaskCausalAndPadding() {

    let valid = MLXArray([Int32(1), 1, 0, 1]).reshaped([1, 4])
    let mask = Qwen3VLTextModel.additiveCausalPaddingMask(validMask: valid, dtype: .float32)
    #expect(mask.shape == [1, 1, 4, 4])

    func at(_ i: Int, _ j: Int) -> Float {
        mask[0, 0, i, j].item(Float.self)
    }
    #expect(at(0, 0) == 0)
    #expect(at(0, 1) == -1e9)
    #expect(at(1, 0) == 0)
    #expect(at(3, 2) == -1e9)
    #expect(at(3, 3) == 0)
    #expect(at(2, 1) == 0)
}
