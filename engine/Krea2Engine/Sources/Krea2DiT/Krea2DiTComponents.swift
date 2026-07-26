// Krea2DiTComponents.swift
//




import Foundation
import MLX
import MLXNN

/// SwiGLU: down(silu(gate(x)) * up(x)); mlpdim = round128(2·features/3 · multiplier).
public final class Krea2SwiGLU: Module {
    @ModuleInfo public var gate: Linear
    @ModuleInfo public var up: Linear
    @ModuleInfo public var down: Linear

    public init(features: Int, multiplier: Int, multiple: Int = 128) {
        let inter = 2 * features / 3 * multiplier
        let mlpdim = ((inter + multiple - 1) / multiple) * multiple
        self._gate = ModuleInfo(wrappedValue: Linear(features, mlpdim, bias: false))
        self._up = ModuleInfo(wrappedValue: Linear(features, mlpdim, bias: false))
        self._down = ModuleInfo(wrappedValue: Linear(mlpdim, features, bias: false))
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}


/// vec: (B,1,6·features) → 6 × (B,1,features).
public final class Krea2DoubleSharedModulation: Module {
    public let lin: MLXArray

    public init(dim: Int) {
        self.lin = MLXArray.zeros([6 * dim])
        super.init()
    }

    public func callAsFunction(_ vec: MLXArray) -> [MLXArray] {
        split(vec + lin, parts: 6, axis: -1)
    }
}

/// SimpleModulation: lin (2, features); out = vec + lin[None]; split axis=1 → (scale, shift).
public final class Krea2SimpleModulation: Module {
    public let lin: MLXArray

    public init(dim: Int) {
        self.lin = MLXArray.zeros([2, dim])
        super.init()
    }

    public func callAsFunction(_ vec: MLXArray) -> (scale: MLXArray, shift: MLXArray) {
        let out = vec + lin.expandedDimensions(axis: 0)          // (B,1,d)+(1,2,d) → (B,2,d)
        let parts = split(out, parts: 2, axis: 1)
        return (parts[0], parts[1])
    }
}


public final class Krea2SingleStreamBlock: Module {
    @ModuleInfo public var mod: Krea2DoubleSharedModulation
    @ModuleInfo public var prenorm: Krea2DiTRMSNorm
    @ModuleInfo public var postnorm: Krea2DiTRMSNorm
    @ModuleInfo public var attn: Krea2DiTAttention
    @ModuleInfo public var mlp: Krea2SwiGLU

    public init(config: Krea2DiTConfig) {
        let f = config.features
        self._mod = ModuleInfo(wrappedValue: Krea2DoubleSharedModulation(dim: f))
        self._prenorm = ModuleInfo(wrappedValue: Krea2DiTRMSNorm(dimensions: f, eps: config.normEps))
        self._postnorm = ModuleInfo(wrappedValue: Krea2DiTRMSNorm(dimensions: f, eps: config.normEps))
        self._attn = ModuleInfo(wrappedValue: Krea2DiTAttention(
            dim: f, heads: config.heads, kvheads: config.kvheads, eps: config.normEps))
        self._mlp = ModuleInfo(wrappedValue: Krea2SwiGLU(features: f, multiplier: config.multiplier))
        super.init()
    }

    public func callAsFunction(
        _ x: MLXArray, vec: MLXArray, cos: MLXArray, sin: MLXArray, mask: MLXArray?
    ) -> MLXArray {
        let m = mod(vec)
        let prescale = m[0], preshift = m[1], pregate = m[2]
        let postscale = m[3], postshift = m[4], postgate = m[5]
        var out = x + pregate * attn((1 + prescale) * prenorm(x) + preshift, cos: cos, sin: sin, mask: mask)
        out = out + postgate * mlp((1 + postscale) * postnorm(out) + postshift)
        return out
    }
}


public final class Krea2TextFusionBlock: Module {
    @ModuleInfo public var prenorm: Krea2DiTRMSNorm
    @ModuleInfo public var postnorm: Krea2DiTRMSNorm
    @ModuleInfo public var attn: Krea2DiTAttention
    @ModuleInfo public var mlp: Krea2SwiGLU

    public init(features: Int, heads: Int, kvheads: Int, multiplier: Int, eps: Float) {
        self._prenorm = ModuleInfo(wrappedValue: Krea2DiTRMSNorm(dimensions: features, eps: eps))
        self._postnorm = ModuleInfo(wrappedValue: Krea2DiTRMSNorm(dimensions: features, eps: eps))
        self._attn = ModuleInfo(wrappedValue: Krea2DiTAttention(
            dim: features, heads: heads, kvheads: kvheads, eps: eps))
        self._mlp = ModuleInfo(wrappedValue: Krea2SwiGLU(features: features, multiplier: multiplier))
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, mask: MLXArray?) -> MLXArray {
        var out = x + attn(prenorm(x), mask: mask)
        out = out + mlp(postnorm(out))
        return out
    }
}



public final class Krea2TextFusionTransformer: Module {
    @ModuleInfo public var layerwise_blocks: [Krea2TextFusionBlock]
    @ModuleInfo public var projector: Linear
    @ModuleInfo public var refiner_blocks: [Krea2TextFusionBlock]

    public init(numTxtLayers: Int, txtDim: Int, heads: Int, kvheads: Int, multiplier: Int, eps: Float) {
        self._layerwise_blocks = ModuleInfo(wrappedValue: (0 ..< 2).map { _ in
            Krea2TextFusionBlock(features: txtDim, heads: heads, kvheads: kvheads, multiplier: multiplier, eps: eps)
        })
        self._projector = ModuleInfo(wrappedValue: Linear(numTxtLayers, 1, bias: false))
        self._refiner_blocks = ModuleInfo(wrappedValue: (0 ..< 2).map { _ in
            Krea2TextFusionBlock(features: txtDim, heads: heads, kvheads: kvheads, multiplier: multiplier, eps: eps)
        })
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, mask: MLXArray?) -> MLXArray {
        let b = x.dim(0), l = x.dim(1), n = x.dim(2), d = x.dim(3)
        var h = x.reshaped([b * l, n, d])
        for block in layerwise_blocks { h = block(h, mask: nil) }

        h = h.reshaped([b, l, n, d]).transposed(0, 1, 3, 2)     // (b,l,d,n)
        h = projector(h)                                        // (b,l,d,1)
        h = h[.ellipsis, 0]                                     // (b,l,d)
        for block in refiner_blocks { h = block(h, mask: mask) }
        return h
    }
}


public final class Krea2LastLayer: Module {
    @ModuleInfo public var norm: Krea2DiTRMSNorm
    @ModuleInfo public var linear: Linear
    @ModuleInfo public var modulation: Krea2SimpleModulation

    public init(features: Int, patch: Int, channels: Int, eps: Float) {
        self._norm = ModuleInfo(wrappedValue: Krea2DiTRMSNorm(dimensions: features, eps: eps))
        self._linear = ModuleInfo(wrappedValue: Linear(features, patch * patch * channels, bias: true))
        self._modulation = ModuleInfo(wrappedValue: Krea2SimpleModulation(dim: features))
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, tvec: MLXArray) -> MLXArray {
        let (scale, shift) = modulation(tvec)
        let modded = (1 + scale) * norm(x) + shift
        return linear(modded)
    }
}
