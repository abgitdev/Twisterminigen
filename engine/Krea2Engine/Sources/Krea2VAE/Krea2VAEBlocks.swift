// Krea2VAEBlocks.swift
//



import Foundation
import MLX
import MLXNN


public final class Krea2VAEResBlock3D: Module {
    @ModuleInfo public var norm1: Krea2VAERMSNorm
    @ModuleInfo public var conv1: Krea2VAECausalConv3D
    @ModuleInfo public var norm2: Krea2VAERMSNorm
    @ModuleInfo public var conv2: Krea2VAECausalConv3D
    @ModuleInfo public var conv_shortcut: Krea2VAECausalConv3D?

    public init(inChannels: Int, outChannels: Int) {
        self._norm1 = ModuleInfo(wrappedValue: Krea2VAERMSNorm(channels: inChannels, images: false))
        self._conv1 = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(inChannels: inChannels, outChannels: outChannels))
        self._norm2 = ModuleInfo(wrappedValue: Krea2VAERMSNorm(channels: outChannels, images: false))
        self._conv2 = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(inChannels: outChannels, outChannels: outChannels))
        if inChannels != outChannels {
            self._conv_shortcut = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(
                inChannels: inChannels, outChannels: outChannels,
                kernel: (1, 1, 1), stride: (1, 1, 1), padding: (0, 0, 0)))
        } else {
            self._conv_shortcut = ModuleInfo(wrappedValue: nil)
        }
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var residual = x
        var h = conv1(silu(norm1(x)))
        h = conv2(silu(norm2(h)))
        if let sc = conv_shortcut { residual = sc(residual) }
        return h + residual
    }
}

/// Resample3D: decode (upsample3d/2d) — nearest-2× → resample_conv (dim→dim/2, stride1/pad1);
/// encode (downsample3d/2d) — asymmetric (0,1) pad on H/W → resample_conv (dim→dim, stride2/pad0).


public final class Krea2VAEResample3D: Module {
    let mode: String
    @ModuleInfo public var time_conv: Krea2VAECausalConv3D?
    @ModuleInfo public var resample_conv: Conv2d

    public init(dim: Int, mode: String) {
        self.mode = mode
        let isDown = mode == "downsample2d" || mode == "downsample3d"
        if mode == "upsample3d" {
            self._time_conv = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(
                inChannels: dim, outChannels: dim * 2,
                kernel: (3, 1, 1), stride: (1, 1, 1), padding: (1, 0, 0)))
        } else if mode == "downsample3d" {
            self._time_conv = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(
                inChannels: dim, outChannels: dim,
                kernel: (3, 1, 1), stride: (2, 1, 1), padding: (0, 0, 0)))
        } else {
            self._time_conv = ModuleInfo(wrappedValue: nil)
        }
        self._resample_conv = ModuleInfo(wrappedValue: isDown
            ? Conv2d(inputChannels: dim, outputChannels: dim, kernelSize: 3, stride: 2, padding: 0)
            : Conv2d(inputChannels: dim, outputChannels: dim / 2, kernelSize: 3, stride: 1, padding: 1))
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let b = x.dim(0), c = x.dim(1), t = x.dim(2), h = x.dim(3), w = x.dim(4)
        var y = x.transposed(0, 2, 1, 3, 4).reshaped([b * t, c, h, w])   // (B·T,C,H,W)
        y = y.transposed(0, 2, 3, 1)                                     // channels-last (B·T,H,W,C)
        if mode == "upsample3d" || mode == "upsample2d" {
            y = repeated(y, count: 2, axis: 1)
            y = repeated(y, count: 2, axis: 2)
        } else {

            y = padded(y, widths: [
                IntOrPair((0, 0)), IntOrPair((0, 1)), IntOrPair((0, 1)), IntOrPair((0, 0)),
            ])
        }
        y = resample_conv(y)                                            // (B·T,H',W',C')
        y = y.transposed(0, 3, 1, 2)                                    // (B·T,C',H',W')
        let nc = y.dim(1), nh = y.dim(2), nw = y.dim(3)
        return y.reshaped([b, t, nc, nh, nw]).transposed(0, 2, 1, 3, 4) // (B,C',T,H',W')
    }
}


public final class Krea2VAEAttention3D: Module {
    let dim: Int
    @ModuleInfo public var norm: Krea2VAERMSNorm
    @ModuleInfo public var to_qkv: Conv2d
    @ModuleInfo public var proj: Conv2d

    public init(dim: Int) {
        self.dim = dim
        self._norm = ModuleInfo(wrappedValue: Krea2VAERMSNorm(channels: dim, images: true))
        self._to_qkv = ModuleInfo(wrappedValue: Conv2d(inputChannels: dim, outputChannels: dim * 3, kernelSize: 1))
        self._proj = ModuleInfo(wrappedValue: Conv2d(inputChannels: dim, outputChannels: dim, kernelSize: 1))
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let identity = x
        let b = x.dim(0), c = x.dim(1), t = x.dim(2), h = x.dim(3), w = x.dim(4)
        var y = x.transposed(0, 2, 1, 3, 4).reshaped([b * t, c, h, w])       // (B·T,C,H,W)
        let normed = norm(y.expandedDimensions(axis: 2)).squeezed(axis: 2)
        y = normed.transposed(0, 2, 3, 1)                                    // channels-last
        var qkv = to_qkv(y).transposed(0, 3, 1, 2)                          // (B·T,3C,H,W)
        qkv = qkv.reshaped([b * t, 1, c * 3, h * w]).transposed(0, 1, 3, 2)  // (B·T,1,H·W,3C)
        let parts = split(qkv, parts: 3, axis: -1)
        let q = parts[0], k = parts[1], v = parts[2]                        // (B·T,1,H·W,C)
        let scale = 1.0 / Float(c).squareRoot()
        // Same fused kernel as the DiT (Krea2DiTAttention) instead of materializing the full
        // (B·T,1,HW,HW) score matrix by hand — MLX's SDPA accumulates the softmax internally
        // without ever holding the whole matrix at once, which is exactly the tensor that used
        // to blow past Metal's max buffer size before tiled decode existed.
        let attnOut = MLX.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: nil)
        var out = attnOut.squeezed(axis: 1)                                 // (B·T,HW,C)
        out = out.transposed(0, 2, 1).reshaped([b * t, c, h, w])           // (B·T,C,H,W)
        out = proj(out.transposed(0, 2, 3, 1)).transposed(0, 3, 1, 2)      // proj (channels-last)
        return out.reshaped([b, t, c, h, w]).transposed(0, 2, 1, 3, 4) + identity
    }
}

/// MidBlock: ResBlock → Attention → ResBlock (num_layers=1).
public final class Krea2VAEMidBlock3D: Module {
    @ModuleInfo public var attentions: [Krea2VAEAttention3D]
    @ModuleInfo public var resnets: [Krea2VAEResBlock3D]

    public init(dim: Int, numLayers: Int = 1) {
        var rs = [Krea2VAEResBlock3D(inChannels: dim, outChannels: dim)]
        var at: [Krea2VAEAttention3D] = []
        for _ in 0 ..< numLayers {
            at.append(Krea2VAEAttention3D(dim: dim))
            rs.append(Krea2VAEResBlock3D(inChannels: dim, outChannels: dim))
        }
        self._attentions = ModuleInfo(wrappedValue: at)
        self._resnets = ModuleInfo(wrappedValue: rs)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = resnets[0](x)
        for (attn, resnet) in zip(attentions, resnets.dropFirst()) {
            h = resnet(attn(h))
        }
        return h
    }
}


public final class Krea2VAEUpBlock3D: Module {
    @ModuleInfo public var resnets: [Krea2VAEResBlock3D]
    @ModuleInfo public var upsamplers: [Krea2VAEResample3D]?

    public init(inChannels: Int, outChannels: Int, numResBlocks: Int = 2, upsampleMode: String?) {
        var rs: [Krea2VAEResBlock3D] = []
        var cur = inChannels
        for _ in 0 ..< (numResBlocks + 1) {
            rs.append(Krea2VAEResBlock3D(inChannels: cur, outChannels: outChannels))
            cur = outChannels
        }
        self._resnets = ModuleInfo(wrappedValue: rs)
        if let mode = upsampleMode {
            self._upsamplers = ModuleInfo(wrappedValue: [Krea2VAEResample3D(dim: outChannels, mode: mode)])
        } else {
            self._upsamplers = ModuleInfo(wrappedValue: nil)
        }
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for r in resnets { h = r(h) }
        if let up = upsamplers { h = up[0](h) }
        return h
    }
}



public final class Krea2VAEDownBlock3D: Module {
    @ModuleInfo public var resnets: [Krea2VAEResBlock3D]
    @ModuleInfo public var downsamplers: [Krea2VAEResample3D]?

    public init(inChannels: Int, outChannels: Int, numResBlocks: Int = 2, downsampleMode: String?) {
        var rs: [Krea2VAEResBlock3D] = []
        var cur = inChannels
        for _ in 0 ..< numResBlocks {
            rs.append(Krea2VAEResBlock3D(inChannels: cur, outChannels: outChannels))
            cur = outChannels
        }
        self._resnets = ModuleInfo(wrappedValue: rs)
        if let mode = downsampleMode {
            self._downsamplers = ModuleInfo(wrappedValue: [Krea2VAEResample3D(dim: outChannels, mode: mode)])
        } else {
            self._downsamplers = ModuleInfo(wrappedValue: nil)
        }
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for r in resnets { h = r(h) }
        if let down = downsamplers { h = down[0](h) }
        return h
    }
}
