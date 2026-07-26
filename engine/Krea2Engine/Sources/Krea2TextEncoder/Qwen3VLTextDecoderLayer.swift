// Qwen3VLTextDecoderLayer.swift
//


// Sources/FluxTextEncoders/Model/Qwen3VL/Qwen3VLDecoderLayer.swift.

// post_attention_layernorm / mlp).

import Foundation
import MLX
import MLXNN

public final class Qwen3VLTextDecoderLayer: Module {
    public var input_layernorm: Qwen3RMSNorm
    public var self_attn: Qwen3VLTextAttention
    public var post_attention_layernorm: Qwen3RMSNorm
    public var mlp: Qwen3VLTextMLP

    public init(config: Krea2TextEncoderConfig) {
        self.input_layernorm = Qwen3RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self.self_attn = Qwen3VLTextAttention(config: config)
        self.post_attention_layernorm = Qwen3RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self.mlp = Qwen3VLTextMLP(config: config)
        super.init()
    }

    public func callAsFunction(
        _ x: MLXArray,
        cos: MLXArray,
        sin: MLXArray,
        mask: MLXArray?
    ) -> MLXArray {
        var h = x + self_attn(input_layernorm(x), cos: cos, sin: sin, mask: mask)
        h = h + mlp(post_attention_layernorm(h))
        return h
    }

    func callWithCache(
        _ x: MLXArray,
        cos: MLXArray,
        sin: MLXArray,
        mask: MLXArray?,
        cachedKeys: MLXArray?,
        cachedValues: MLXArray?,
        dummyQueryCount: Int
    ) -> (hiddenStates: MLXArray, keys: MLXArray, values: MLXArray) {
        let attention = self_attn.callWithCache(
            input_layernorm(x),
            cos: cos,
            sin: sin,
            mask: mask,
            cachedKeys: cachedKeys,
            cachedValues: cachedValues,
            dummyQueryCount: dummyQueryCount
        )
        var h = x + attention.output
        h = h + mlp(post_attention_layernorm(h))
        return (h, attention.keys, attention.values)
    }
}
