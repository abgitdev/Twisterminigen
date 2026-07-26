// Krea2DiTMath.swift
//







import Foundation
import MLX
import MLXNN

/// Controls the ordinary (non-regional) combined text+image attention layout. The compact
/// strategy is the sampler default after an exact mixed-4/8 real-weight parity gate.
public enum Krea2DiTSequenceStrategy: Sendable, Equatable {
    case legacy
    case compactKeyPaddingWithPadTo256
}

/// Host-only shape plan shared by `prepare(...)` and `step(...)`.
public struct Krea2DiTSequencePlan: Sendable, Equatable {
    public static let officialPaddingMultiple = 256

    public let strategy: Krea2DiTSequenceStrategy
    public let textLength: Int
    public let imageLength: Int
    public let unpaddedLength: Int
    public let paddingLength: Int
    public let modelLength: Int

    public init(
        textLength: Int,
        imageLength: Int,
        strategy: Krea2DiTSequenceStrategy
    ) {
        precondition(textLength >= 0 && imageLength >= 0, "sequence lengths must be non-negative")

        let unpaddedLength = textLength + imageLength
        let paddingLength: Int
        switch strategy {
        case .legacy:
            paddingLength = 0
        case .compactKeyPaddingWithPadTo256:
            let remainder = unpaddedLength % Self.officialPaddingMultiple
            paddingLength = remainder == 0 ? 0 : Self.officialPaddingMultiple - remainder
        }

        self.strategy = strategy
        self.textLength = textLength
        self.imageLength = imageLength
        self.unpaddedLength = unpaddedLength
        self.paddingLength = paddingLength
        self.modelLength = unpaddedLength + paddingLength
    }

    /// Returned image tokens always precede the dummy padding suffix.
    public var imageRange: Range<Int> {
        textLength ..< (textLength + imageLength)
    }

    public var paddingRange: Range<Int> {
        unpaddedLength ..< modelLength
    }
}



public final class Krea2DiTRMSNorm: Module, UnaryLayer {
    public let scale: MLXArray
    public let eps: Float

    public init(dimensions: Int, eps: Float = 1e-5) {
        self.scale = MLXArray.zeros([dimensions])
        self.eps = eps
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let dt = x.dtype
        let t = x.asType(.float32)
        let normed = t * rsqrt(mean(t * t, axis: -1, keepDims: true) + MLXArray(eps))
        return (normed * (1.0 + scale.asType(.float32))).asType(dt)
    }
}



public final class Krea2GELUTanh: Module, UnaryLayer {
    public func callAsFunction(_ x: MLXArray) -> MLXArray { Krea2DiTMath.geluTanh(x) }
}

public enum Krea2DiTMath {
    static let sqrt2OverPi = Float((2.0 / Double.pi).squareRoot())


    public static func geluTanh(_ x: MLXArray) -> MLXArray {
        0.5 * x * (1.0 + MLX.tanh(sqrt2OverPi * (x + 0.044715 * x * x * x)))
    }



    public static func ropeTables(pos: MLXArray, axes: [Int], theta: Float)
        -> (cos: MLXArray, sin: MLXArray)
    {
        let l = pos.dim(0)
        var cosParts: [MLXArray] = []
        var sinParts: [MLXArray] = []
        for (i, d) in axes.enumerated() {
            let expo = MLXArray(Array(stride(from: Float(0), to: Float(d), by: 2))) / Float(d) // (d/2)
            let omega = 1.0 / MLX.pow(MLXArray(theta), expo)                                   // (d/2)
            let posI = pos[0..., i].reshaped([l, 1])                                            // (L,1)
            let freqs = posI * omega.reshaped([1, d / 2])                                       // (L,d/2)
            cosParts.append(MLX.cos(freqs))
            sinParts.append(MLX.sin(freqs))
        }
        return (concatenated(cosParts, axis: -1), concatenated(sinParts, axis: -1))
    }



    public static func applyRope(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
        let b = x.dim(0), h = x.dim(1), l = x.dim(2), d = x.dim(3)
        let xf = x.asType(.float32).reshaped([b, h, l, d / 2, 2])
        let x0 = xf[.ellipsis, 0]                       // (B,H,L,D/2)
        let x1 = xf[.ellipsis, 1]
        let c = cos.reshaped([1, 1, l, d / 2])
        let s = sin.reshaped([1, 1, l, d / 2])
        let o0 = x0 * c - x1 * s
        let o1 = x0 * s + x1 * c
        let out = stacked([o0, o1], axis: -1).reshaped([b, h, l, d])
        return out.asType(x.dtype)
    }


    /// args=(t·tfactor)⊗freqs; concat(cos, sin). t: (B,) → (B,1,dim).
    public static func timestepEmbed(
        _ t: MLXArray, dim: Int, period: Float = 1e4, tfactor: Float = 1e3
    ) -> MLXArray {
        let half = dim / 2
        let idx = MLXArray(Array(stride(from: Float(0), to: Float(half), by: 1)))
        let freqs = MLX.exp(-Foundation.log(period) * idx / Float(half))          // (half)
        let args = (t.asType(.float32) * tfactor).reshaped([t.dim(0), 1, 1]) * freqs.reshaped([1, 1, half])
        return concatenated([MLX.cos(args), MLX.sin(args)], axis: -1)             // (B,1,dim)
    }




    public static func additiveMask(valid: MLXArray, dtype: DType) -> MLXArray? {
        let allValid = MLX.all(valid .>= 0.5).item(Bool.self)
        if allValid { return nil }
        let m = valid.asType(.float32)
        let b = valid.dim(0), l = valid.dim(1)
        let full = m.reshaped([b, l, 1]) * m.reshaped([b, 1, l])                  // (B,L,L)
        let add = (1.0 - full) * Float(-1e9)
        return add.reshaped([b, 1, l, l]).asType(dtype)
    }

    /// Host-only shape helper used by the compact mask builder and planner tests.
    public static func keyPaddingMaskShape(batchSize: Int, keyLength: Int) -> [Int] {
        precondition(batchSize >= 0 && keyLength >= 0, "mask dimensions must be non-negative")
        return [batchSize, 1, 1, keyLength]
    }

    /// Compact additive key-padding mask: valid (B,L) 0/1 -> (B,1,1,L).
    /// The singleton query axis broadcasts in SDPA, so this path stays O(B*L) and never
    /// materializes an LxL mask. Invalid query rows may differ from `additiveMask`, but those
    /// rows are either discarded text padding or the discarded combined-sequence dummy suffix.
    public static func additiveKeyPaddingMask(valid: MLXArray, dtype: DType) -> MLXArray? {
        let allValid = MLX.all(valid .>= 0.5).item(Bool.self)
        if allValid { return nil }
        let m = valid.asType(.float32)
        let b = valid.dim(0), l = valid.dim(1)
        let add = (1.0 - m) * Float(-1e9)
        return add.reshaped(keyPaddingMaskShape(batchSize: b, keyLength: l)).asType(dtype)
    }
}
