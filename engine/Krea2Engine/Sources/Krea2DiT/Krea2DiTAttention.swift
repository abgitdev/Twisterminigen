// Krea2DiTAttention.swift
//


//   out = wo( SDPA(qnorm(q)⊙rope, knorm(k)⊙rope, v) · σ(gate(x)) ).


import Foundation
import MLX
import MLXNN


public final class Krea2QKNorm: Module {
    @ModuleInfo public var qnorm: Krea2DiTRMSNorm
    @ModuleInfo public var knorm: Krea2DiTRMSNorm

    public init(headDim: Int, eps: Float) {
        self._qnorm = ModuleInfo(wrappedValue: Krea2DiTRMSNorm(dimensions: headDim, eps: eps))
        self._knorm = ModuleInfo(wrappedValue: Krea2DiTRMSNorm(dimensions: headDim, eps: eps))
        super.init()
    }
}

public final class Krea2DiTAttention: Module {
    let heads: Int
    let kvheads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo public var wq: Linear
    @ModuleInfo public var wk: Linear
    @ModuleInfo public var wv: Linear
    @ModuleInfo public var gate: Linear
    @ModuleInfo public var qknorm: Krea2QKNorm
    @ModuleInfo public var wo: Linear

    public init(dim: Int, heads: Int, kvheads: Int, eps: Float) {
        self.heads = heads
        self.kvheads = kvheads
        self.headDim = dim / heads
        self.scale = 1.0 / Float(headDim).squareRoot()
        self._wq = ModuleInfo(wrappedValue: Linear(dim, headDim * heads, bias: false))
        self._wk = ModuleInfo(wrappedValue: Linear(dim, headDim * kvheads, bias: false))
        self._wv = ModuleInfo(wrappedValue: Linear(dim, headDim * kvheads, bias: false))
        self._gate = ModuleInfo(wrappedValue: Linear(dim, dim, bias: false))
        self._qknorm = ModuleInfo(wrappedValue: Krea2QKNorm(headDim: headDim, eps: eps))
        self._wo = ModuleInfo(wrappedValue: Linear(dim, dim, bias: false))
        super.init()
    }


    /// mask is additive and broadcastable to (B,H,L,L): ordinary compact masks use
    /// (B,1,1,L), while regional visibility keeps its existing (B,1,L,L) representation.
    public func callAsFunction(
        _ qkv: MLXArray,
        cos: MLXArray? = nil,
        sin: MLXArray? = nil,
        mask: MLXArray? = nil
    ) -> MLXArray {
        let b = qkv.dim(0), l = qkv.dim(1)
        var q = wq(qkv).reshaped([b, l, heads, headDim]).transposed(0, 2, 1, 3)
        var k = wk(qkv).reshaped([b, l, kvheads, headDim]).transposed(0, 2, 1, 3)
        let v = wv(qkv).reshaped([b, l, kvheads, headDim]).transposed(0, 2, 1, 3)
        let g = gate(qkv)

        q = qknorm.qnorm(q)
        k = qknorm.knorm(k)

        if let cos, let sin {
            q = Krea2DiTMath.applyRope(q, cos: cos, sin: sin)
            k = Krea2DiTMath.applyRope(k, cos: cos, sin: sin)
        }




        let out = MLX.scaledDotProductAttention(
            queries: q, keys: k, values: v, scale: scale, mask: mask?.asType(q.dtype))
        let merged = out.transposed(0, 2, 1, 3).reshaped([b, l, heads * headDim])
        return wo(merged * MLX.sigmoid(g))
    }
}
