// Qwen3VLTextAttention.swift
//


//

// Sources/FluxTextEncoders/Model/Qwen3VL/Qwen3VLAttention.swift.








import Foundation
import MLX
import MLXNN

public final class Qwen3VLTextAttention: Module {
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo public var q_proj: Linear
    @ModuleInfo public var k_proj: Linear
    @ModuleInfo public var v_proj: Linear
    @ModuleInfo public var o_proj: Linear


    @ModuleInfo public var q_norm: Qwen3RMSNorm
    @ModuleInfo public var k_norm: Qwen3RMSNorm

    public init(config: Krea2TextEncoderConfig) {
        self.numHeads = config.numAttentionHeads
        self.numKVHeads = config.numKeyValueHeads
        self.headDim = config.headDim
        self.scale = 1.0 / sqrt(Float(config.headDim))


        self._q_proj = ModuleInfo(wrappedValue: Linear(config.hiddenSize, numHeads * headDim, bias: false))
        self._k_proj = ModuleInfo(wrappedValue: Linear(config.hiddenSize, numKVHeads * headDim, bias: false))
        self._v_proj = ModuleInfo(wrappedValue: Linear(config.hiddenSize, numKVHeads * headDim, bias: false))
        self._o_proj = ModuleInfo(wrappedValue: Linear(numHeads * headDim, config.hiddenSize, bias: false))

        self._q_norm = ModuleInfo(wrappedValue: Qwen3RMSNorm(dimensions: headDim, eps: config.rmsNormEps))
        self._k_norm = ModuleInfo(wrappedValue: Qwen3RMSNorm(dimensions: headDim, eps: config.rmsNormEps))

        super.init()
    }


    public func callAsFunction(
        _ x: MLXArray,
        cos: MLXArray,
        sin: MLXArray,
        mask: MLXArray?
    ) -> MLXArray {
        let b = x.dim(0)
        let l = x.dim(1)


        var queries = q_norm(q_proj(x).reshaped([b, l, numHeads, headDim])).transposed(0, 2, 1, 3)
        var keys = k_norm(k_proj(x).reshaped([b, l, numKVHeads, headDim])).transposed(0, 2, 1, 3)
        let values = v_proj(x).reshaped([b, l, numKVHeads, headDim]).transposed(0, 2, 1, 3)

        queries = Qwen3RoPE.apply(queries, cos: cos, sin: sin)
        keys = Qwen3RoPE.apply(keys, cos: cos, sin: sin)




        let output = MLX.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: scale,
            mask: mask
        )

        return o_proj(output.transposed(0, 2, 1, 3).reshaped([b, l, numHeads * headDim]))
    }

    /// Cached variant used only by autoregressive Enhance. `cachedKeys` contain post-RoPE
    /// keys, while values are stored as projected. Both cache tensors are always BF16 and have
    /// shape (1, kv_heads, cached_length, head_dim).
    func callWithCache(
        _ x: MLXArray,
        cos: MLXArray,
        sin: MLXArray,
        mask: MLXArray?,
        cachedKeys: MLXArray?,
        cachedValues: MLXArray?,
        dummyQueryCount: Int
    ) -> (output: MLXArray, keys: MLXArray, values: MLXArray) {
        let b = x.dim(0)
        let l = x.dim(1)
        precondition(dummyQueryCount >= 0, "dummy query count must be non-negative")

        var queries = q_norm(q_proj(x).reshaped([b, l, numHeads, headDim])).transposed(0, 2, 1, 3)
        var currentKeys = k_norm(k_proj(x).reshaped([b, l, numKVHeads, headDim]))
            .transposed(0, 2, 1, 3)
        let currentValues = v_proj(x).reshaped([b, l, numKVHeads, headDim])
            .transposed(0, 2, 1, 3)
            .asType(.bfloat16)

        queries = Qwen3RoPE.apply(queries, cos: cos, sin: sin)
        currentKeys = Qwen3RoPE.apply(currentKeys, cos: cos, sin: sin).asType(.bfloat16)

        if dummyQueryCount > 0 {
            let dummyQueries = MLXArray.zeros(
                [b, numHeads, dummyQueryCount, headDim],
                dtype: queries.dtype
            )
            queries = concatenated([dummyQueries, queries], axis: 2)
        }

        let keys: MLXArray
        let values: MLXArray
        switch (cachedKeys, cachedValues) {
        case (nil, nil):
            keys = currentKeys
            values = currentValues
        case (.some(let pastKeys), .some(let pastValues)):
            keys = concatenated([pastKeys, currentKeys], axis: 2)
            values = concatenated([pastValues, currentValues], axis: 2)
        default:
            preconditionFailure("Qwen3-VL KV cache must contain both keys and values")
        }

        var attended = MLX.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: scale,
            mask: mask
        )

        if dummyQueryCount > 0 {
            // Attention rows are independent. Discard every synthetic row before projection so
            // dummy computations cannot enter the residual stream or the next decoder layer.
            attended = attended[0..., 0..., dummyQueryCount..., 0...]
        }
        let output = o_proj(attended.transposed(0, 2, 1, 3).reshaped([b, l, numHeads * headDim]))
        return (output, keys, values)
    }
}


public enum Qwen3RoPE {

    /// inv_freq = θ^(-2i/d), emb = concat([freqs, freqs], axis=-1).
    public static func tables(
        length: Int,
        offset: Int = 0,
        headDim: Int,
        theta: Float
    ) -> (cos: MLXArray, sin: MLXArray) {
        precondition(length > 0, "RoPE length must be positive")
        precondition(offset >= 0, "RoPE offset must be non-negative")
        let exponents = MLXArray(Array(stride(from: Float(0), to: Float(headDim), by: 2))) / Float(headDim)
        let invFreq = 1.0 / MLX.pow(MLXArray(theta), exponents)                       // (d/2)
        let positions = MLXArray(Array(stride(
            from: Float(offset),
            to: Float(offset + length),
            by: 1
        )))
        let freqs = positions.expandedDimensions(axis: 1) * invFreq.expandedDimensions(axis: 0) // (L, d/2)
        let emb = concatenated([freqs, freqs], axis: -1)                              // (L, d)
        return (MLX.cos(emb), MLX.sin(emb))
    }

    /// Krea 2 packs text as `[prefix | prompt | PAD | assistant suffix]`.  The suffix is valid,
    /// but physically follows a large padding hole, so raw sequence indices give it the wrong
    /// rotary phase.  Match the official Diffusers Krea 2 pipeline exactly: cumulative valid-token
    /// positions, clamped at zero.  Padding therefore consumes no position.
    ///
    /// - Parameter validMask: `(B, L)` 0/1 attention mask.
    /// - Returns: `(B, L)` int32 position ids.
    public static func cumulativePositionIds(validMask: MLXArray) -> MLXArray {
        precondition(validMask.ndim == 2, "Krea 2 position ids require a (B, L) mask")
        let cumulative = validMask.asType(.int32).cumsum(axis: -1) - Int32(1)
        return maximum(cumulative, MLXArray(Int32(0)))
    }

    /// RoPE tables for arbitrary per-token positions.  Text-only Qwen3-VL uses the same ids on
    /// all three MRoPE axes, which reduces to the usual 1D frequencies while retaining a batch
    /// dimension for prompts with different valid lengths.
    ///
    /// - Parameter positionIds: `(B, L)` positions, normally from `cumulativePositionIds`.
    /// - Returns: `(B, L, head_dim)` float32 cos/sin tables.
    public static func tables(
        positionIds: MLXArray,
        headDim: Int,
        theta: Float
    ) -> (cos: MLXArray, sin: MLXArray) {
        precondition(positionIds.ndim == 2, "RoPE position ids must have shape (B, L)")
        let exponents = MLXArray(Array(stride(from: Float(0), to: Float(headDim), by: 2))) / Float(headDim)
        let invFreq = 1.0 / MLX.pow(MLXArray(theta), exponents) // (d/2)
        let freqs = positionIds.asType(.float32).expandedDimensions(axis: -1)
            * invFreq.reshaped([1, 1, -1])                    // (B, L, d/2)
        let emb = concatenated([freqs, freqs], axis: -1)      // (B, L, d)
        return (MLX.cos(emb), MLX.sin(emb))
    }





    /// x: (B, H, L, d); cos/sin: `(L, d)` or `(B, L, d)` float32.
    public static func apply(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
        precondition(cos.shape == sin.shape, "RoPE cos/sin shapes must match")
        let c: MLXArray
        let s: MLXArray
        switch cos.ndim {
        case 2:
            c = cos.reshaped([1, 1, cos.dim(0), cos.dim(1)]).asType(x.dtype)
            s = sin.reshaped([1, 1, sin.dim(0), sin.dim(1)]).asType(x.dtype)
        case 3:
            c = cos.expandedDimensions(axis: 1).asType(x.dtype)
            s = sin.expandedDimensions(axis: 1).asType(x.dtype)
        default:
            preconditionFailure("RoPE tables must have shape (L, d) or (B, L, d)")
        }
        return x * c + rotateHalf(x) * s
    }

    /// rotate_half: (..., d) → concat([-x[d/2:], x[:d/2]]).
    static func rotateHalf(_ x: MLXArray) -> MLXArray {
        let half = x.dim(-1) / 2
        let first = x[.ellipsis, 0 ..< half]
        let second = x[.ellipsis, half...]
        return concatenated([-second, first], axis: -1)
    }
}
