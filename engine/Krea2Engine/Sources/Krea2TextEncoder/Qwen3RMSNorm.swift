// Qwen3RMSNorm.swift
//





// (`*.input_layernorm.weight`, `*.q_norm.weight`, `norm.weight`, ...).

import Foundation
import MLX
import MLXNN

public final class Qwen3RMSNorm: Module, UnaryLayer {
    public let weight: MLXArray
    public let eps: Float

    public init(dimensions: Int, eps: Float = 1e-6) {
        self.weight = MLXArray.ones([dimensions])
        self.eps = eps
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let inputDType = x.dtype
        let xf = x.asType(.float32)
        let variance = mean(xf * xf, axis: -1, keepDims: true)
        let normalized = xf * rsqrt(variance + MLXArray(eps))
        return (normalized * weight.asType(.float32)).asType(inputDType)
    }
}
