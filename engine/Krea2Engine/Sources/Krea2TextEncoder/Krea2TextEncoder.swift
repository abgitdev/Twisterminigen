// Krea2TextEncoder.swift
//








import Foundation
import Krea2Core
import MLX
import Tokenizers

public enum Krea2TextEncoderError: Error, CustomStringConvertible {
    case tokenizerDrift(prefixTokens: Int, suffixTokens: Int)

    public var description: String {
        switch self {
        case .tokenizerDrift(let p, let s):
            return "Tokenizer drift: prefix = \(p) tokens (expected \(Krea2PromptTemplate.prefixTokenCount)), "
                + "suffix = \(s) (expected \(Krea2PromptTemplate.suffixTokenCount)); the 34-token slice would be invalid"
        }
    }
}

/// Enhance decoding modes. `.kvCache` is the production default after tiny-model, official-weight,
/// and full prompt-expansion parity gates; `.legacy` remains available as a diagnostic fallback.
public enum Krea2EnhanceDecodingStrategy: Sendable, Equatable {
    case legacy
    case kvCache
}


public struct Krea2TextConditioning {

    public let embeddings: MLXArray


    public let mask: MLXArray

    public let validTokenCount: Int
}



public struct Krea2TextConditioningDebug {
    public let embeddings: MLXArray
    public let mask: MLXArray
    public let validTokenCount: Int

    public let slicedTokenIds: [Int32]

    public let slicedMaskValues: [Int32]
    /// (512,) official Diffusers cumulative-valid position ids after the same prefix slice.
    public let slicedPositionIds: [Int32]
}




public struct Krea2Region: Sendable {
    public var prompt: String
    public var bbox: Krea2RegionBBox
    public init(prompt: String, bbox: Krea2RegionBBox) {
        self.prompt = prompt
        self.bbox = bbox
    }
}



public struct Krea2RegionalConditioning {
    public let embeddings: MLXArray
    public let txtLabels: MLXArray
    public let regionCount: Int
}

public final class Krea2TextEncoder {
    public let config: Krea2TextEncoderConfig
    public let model: Qwen3VLTextModel
    public let maxLength: Int

    public let computeDType: DType

    public let weightStats: Krea2TextEncoderWeightLoader.Stats

    private let tokenizer: any Tokenizer
    private let suffixTokenIds: [Int32]

    private let imEndTokenId: Int32

    private init(
        config: Krea2TextEncoderConfig,
        model: Qwen3VLTextModel,
        tokenizer: any Tokenizer,
        suffixTokenIds: [Int32],
        imEndTokenId: Int32,
        maxLength: Int,
        computeDType: DType,
        weightStats: Krea2TextEncoderWeightLoader.Stats
    ) {
        self.config = config
        self.model = model
        self.tokenizer = tokenizer
        self.suffixTokenIds = suffixTokenIds
        self.imEndTokenId = imEndTokenId
        self.maxLength = maxLength
        self.computeDType = computeDType
        self.weightStats = weightStats
    }


    /// - Parameters:


    public static func load(
        textEncoderDirectory: URL,
        tokenizerDirectory: URL,
        maxLength: Int = Krea2PromptTemplate.maxConditioningTokens,
        computeDType: DType = .bfloat16
    ) async throws -> Krea2TextEncoder {
        let config = try Krea2TextEncoderConfig.load(
            from: textEncoderDirectory.appendingPathComponent("config.json")
        )
        let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerDirectory)


        let prefixIds = tokenizer.encode(text: Krea2PromptTemplate.prefix)
        let suffixIds = tokenizer.encode(text: Krea2PromptTemplate.suffix)
        guard prefixIds.count == Krea2PromptTemplate.prefixTokenCount,
              suffixIds.count == Krea2PromptTemplate.suffixTokenCount
        else {
            throw Krea2TextEncoderError.tokenizerDrift(
                prefixTokens: prefixIds.count,
                suffixTokens: suffixIds.count
            )
        }

        let model = Qwen3VLTextModel(config: config)
        let stats = try Krea2TextEncoderWeightLoader.load(
            into: model,
            directory: textEncoderDirectory,
            computeDType: computeDType
        )

        let imEndTokenId = Int32(tokenizer.encode(text: "<|im_end|>").last!)

        return Krea2TextEncoder(
            config: config,
            model: model,
            tokenizer: tokenizer,
            suffixTokenIds: suffixIds.map(Int32.init),
            imEndTokenId: imEndTokenId,
            maxLength: maxLength,
            computeDType: computeDType,
            weightStats: stats
        )
    }










    public func enhance(
        prompt: String,
        maxNewTokens: Int = 400,
        strategy: Krea2EnhanceDecodingStrategy = .kvCache
    ) throws -> String {
        guard maxNewTokens > 0 else { return "" }

        let promptIds = tokenizer
            .encode(text: Krea2PromptTemplate.enhanceChatText(prompt: prompt))
            .map(Int32.init)
        let generatedIds: [Int32]
        switch strategy {
        case .legacy:
            generatedIds = try enhanceLegacy(promptIds: promptIds, maxNewTokens: maxNewTokens)
        case .kvCache:
            generatedIds = try enhanceWithKVCache(promptIds: promptIds, maxNewTokens: maxNewTokens)
        }

        return tokenizer.decode(tokens: generatedIds.map(Int.init), skipSpecialTokens: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func enhanceLegacy(promptIds: [Int32], maxNewTokens: Int) throws -> [Int32] {
        var ids = promptIds
        for _ in 0 ..< maxNewTokens {
            try Task.checkCancellation()
            let idsArray = MLXArray(ids).reshaped([1, ids.count])
            let logits = model.nextTokenLogits(inputIds: idsArray, computeDType: computeDType)
            let nextId = logits.argMax(axis: -1).asType(.int32).item(Int32.self)
            if nextId == imEndTokenId { break }
            ids.append(nextId)
        }
        return Array(ids.dropFirst(promptIds.count))
    }

    private func enhanceWithKVCache(promptIds: [Int32], maxNewTokens: Int) throws -> [Int32] {
        // The final emitted token is returned directly; only the preceding N-1 generated tokens
        // are fed back through decode and therefore occupy cache slots.
        let (capacity, overflow) = promptIds.count.addingReportingOverflow(maxNewTokens - 1)
        guard !overflow else {
            throw Qwen3VLTextKVCacheError.invalidCapacity(maxNewTokens)
        }

        // Deliberately local: no prompt or generated K/V persists across Enhance calls.
        let cache = try model.makeKVCache(maxSequenceLength: capacity)
        var generated: [Int32] = []
        var previousToken: Int32?

        for tokenIndex in 0 ..< maxNewTokens {
            try Task.checkCancellation()

            let logits: MLXArray
            if tokenIndex == 0 {
                let inputIds = MLXArray(promptIds).reshaped([1, promptIds.count])
                logits = try model.prefillNextTokenLogits(
                    inputIds: inputIds,
                    cache: cache,
                    computeDType: computeDType
                )
            } else {
                logits = try model.decodeNextTokenLogits(
                    tokenId: previousToken!,
                    cache: cache,
                    computeDType: computeDType
                )
            }

            let nextId = logits.argMax(axis: -1).asType(.int32).item(Int32.self)
            if nextId == imEndTokenId { break }
            generated.append(nextId)
            previousToken = nextId
        }
        return generated
    }


    private func packedIds(prompt: String) -> (inputIds: [Int32], mask: [Int32]) {
        let bodyIds = tokenizer
            .encode(text: Krea2PromptTemplate.templatedText(prompt: prompt))
            .map(Int32.init)
        return Krea2PromptTemplate.pack(
            prefixAndPromptIds: bodyIds,
            suffixIds: suffixTokenIds,
            maxLength: maxLength
        )
    }


    private func runTaps(inputIds: [Int32], mask: [Int32]) -> (MLXArray, MLXArray) {
        let totalLength = inputIds.count
        let idsArray = MLXArray(inputIds).reshaped([1, totalLength])
        let maskArray = MLXArray(mask).reshaped([1, totalLength])

        let taps = model.hiddenStateTaps(
            inputIds: idsArray,
            validMask: maskArray,
            taps: Krea2PromptTemplate.selectLayers,
            computeDType: computeDType
        )


        let stacked = stacked(taps, axis: 2)                                   // (1, 546, 12, 2560)
        let sliced = stacked[0..., Krea2PromptTemplate.prefixTokenCount...]    // (1, 512, 12, 2560)
        let slicedMask = maskArray[0..., Krea2PromptTemplate.prefixTokenCount...]
        eval(sliced, slicedMask)
        return (sliced, slicedMask)
    }


    public func encode(prompt: String) -> Krea2TextConditioning {
        let (inputIds, mask) = packedIds(prompt: prompt)
        let (sliced, slicedMask) = runTaps(inputIds: inputIds, mask: mask)
        let validCount = mask.dropFirst(Krea2PromptTemplate.prefixTokenCount).reduce(0) { $0 + Int($1) }
        return Krea2TextConditioning(
            embeddings: sliced,
            mask: slicedMask,
            validTokenCount: validCount
        )
    }





    public func encodeRegional(globalPrompt: String, regions: [Krea2Region]) -> Krea2RegionalConditioning {
        let prefixIds = tokenizer.encode(text: Krea2PromptTemplate.prefix).map(Int32.init)
        let globalIds = tokenizer.encode(text: globalPrompt).map(Int32.init)

        var body = prefixIds + globalIds

        var labels = [Int32](repeating: 0, count: body.count)
        for (i, region) in regions.enumerated() {
            let ids = tokenizer.encode(text: region.prompt).map(Int32.init)
            body += ids
            labels += [Int32](repeating: Int32(i + 1), count: ids.count)
        }

        let (inputIds, mask) = Krea2PromptTemplate.pack(
            prefixAndPromptIds: body, suffixIds: suffixTokenIds, maxLength: maxLength)



        let paddedLength = maxLength + Krea2PromptTemplate.prefixTokenCount - Krea2PromptTemplate.suffixTokenCount
        if labels.count > paddedLength { labels = Array(labels.prefix(paddedLength)) }
        if labels.count < paddedLength {
            labels += [Int32](repeating: -1, count: paddedLength - labels.count)
        }
        labels += [Int32](repeating: 0, count: suffixTokenIds.count)

        let (sliced, _) = runTaps(inputIds: inputIds, mask: mask)
        let cut = Krea2PromptTemplate.prefixTokenCount
        let slicedLabels = MLXArray(Array(labels.dropFirst(cut)))

        return Krea2RegionalConditioning(embeddings: sliced, txtLabels: slicedLabels, regionCount: regions.count)
    }


    public func encodeDebug(prompt: String) -> Krea2TextConditioningDebug {
        let (inputIds, mask) = packedIds(prompt: prompt)
        let (sliced, slicedMask) = runTaps(inputIds: inputIds, mask: mask)
        let cut = Krea2PromptTemplate.prefixTokenCount
        let validCount = mask.dropFirst(cut).reduce(0) { $0 + Int($1) }
        let fullPositionIds = Qwen3RoPE.cumulativePositionIds(
            validMask: MLXArray(mask).reshaped([1, mask.count]))
        eval(fullPositionIds)
        return Krea2TextConditioningDebug(
            embeddings: sliced,
            mask: slicedMask,
            validTokenCount: validCount,
            slicedTokenIds: Array(inputIds.dropFirst(cut)),
            slicedMaskValues: Array(mask.dropFirst(cut)),
            slicedPositionIds: Array(fullPositionIds.asArray(Int32.self).dropFirst(cut))
        )
    }
}
