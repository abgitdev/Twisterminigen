// Krea2VAEPrimitives.swift
//





import Foundation
import MLX
import MLXNN



public final class Krea2VAECausalConv3D: Module {
    public let weight: MLXArray
    public let bias: MLXArray
    let stride: (Int, Int, Int)
    let padding: (Int, Int, Int)

    public init(
        inChannels: Int, outChannels: Int,
        kernel: (Int, Int, Int) = (3, 3, 3),
        stride: (Int, Int, Int) = (1, 1, 1),
        padding: (Int, Int, Int) = (1, 1, 1)
    ) {
        self.weight = MLXArray.zeros([outChannels, kernel.0, kernel.1, kernel.2, inChannels])
        self.bias = MLXArray.zeros([outChannels])
        self.stride = stride
        self.padding = padding
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var y = x
        let (pt, ph, pw) = padding
        if pt > 0 || ph > 0 || pw > 0 {

            y = padded(y, widths: [
                IntOrPair((0, 0)), IntOrPair((0, 0)),
                IntOrPair((2 * pt, 0)), IntOrPair((ph, ph)), IntOrPair((pw, pw)),
            ])
        }
        y = y.transposed(0, 2, 3, 4, 1)                       // channels-last (B,T,H,W,C)
        y = conv3d(y, weight, stride: IntOrTriple((stride.0, stride.1, stride.2)), padding: 0)
        y = y + bias
        return y.transposed(0, 4, 1, 2, 3)
    }
}



public final class Krea2VAERMSNorm: Module {
    public let gamma: MLXArray
    let eps: Float
    let scale: Float


    public init(channels: Int, eps: Float = 1e-12, images: Bool = false) {
        self.gamma = images ? MLXArray.ones([channels, 1, 1]) : MLXArray.ones([channels, 1, 1, 1])
        self.eps = eps
        self.scale = Float(channels).squareRoot()
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let dt = x.dtype
        let xf = x.asType(.float32)
        let l2 = sqrt(sum(xf * xf, axis: 1, keepDims: true))
        let denom = maximum(l2, MLXArray(eps))
        let normed = xf / denom

        var shape = [Int](repeating: 1, count: x.ndim)
        shape[1] = gamma.size
        let g = gamma.asType(.float32).reshaped(shape)
        return (normed * scale * g).asType(dt)
    }
}
