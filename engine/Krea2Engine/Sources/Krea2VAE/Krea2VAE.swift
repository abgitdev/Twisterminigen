// Krea2VAE.swift
//

// production one-way models; Krea2VAE retains decode+encode for Remix/img2img.








import Foundation
import MLX
import MLXNN

private enum Krea2VAELayout {
    static let spatialScale = 8
    static let latentChannels = 16

    // Per-channel latent normalization constants. These are model constants, not parameters.
    static let meanValues: [Float] = [
        -0.7571, -0.7089, -0.9113, 0.1075, -0.1745, 0.9653, -0.1517, 1.5508,
        0.4134, -0.0715, 0.5517, -0.3632, -0.1922, -0.9497, 0.2503, -0.2921,
    ]
    static let stdValues: [Float] = [
        2.8184, 1.4541, 2.3275, 2.6558, 1.2196, 1.7708, 2.6052, 2.0743,
        3.2687, 2.1526, 2.8652, 1.5579, 1.6382, 1.1253, 2.8251, 1.916,
    ]
}


public final class Krea2VAEDecoder3D: Module {
    @ModuleInfo public var conv_in: Krea2VAECausalConv3D
    @ModuleInfo public var mid_block: Krea2VAEMidBlock3D
    @ModuleInfo public var up_blocks: [Krea2VAEUpBlock3D]
    @ModuleInfo public var norm_out: Krea2VAERMSNorm
    @ModuleInfo public var conv_out: Krea2VAECausalConv3D

    public override init() {
        self._conv_in = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(inChannels: 16, outChannels: 384))
        self._mid_block = ModuleInfo(wrappedValue: Krea2VAEMidBlock3D(dim: 384, numLayers: 1))
        self._up_blocks = ModuleInfo(wrappedValue: [
            Krea2VAEUpBlock3D(inChannels: 384, outChannels: 384, upsampleMode: "upsample3d"),
            Krea2VAEUpBlock3D(inChannels: 192, outChannels: 384, upsampleMode: "upsample3d"),
            Krea2VAEUpBlock3D(inChannels: 192, outChannels: 192, upsampleMode: "upsample2d"),
            Krea2VAEUpBlock3D(inChannels: 96, outChannels: 96, upsampleMode: nil),
        ])
        self._norm_out = ModuleInfo(wrappedValue: Krea2VAERMSNorm(channels: 96, images: false))
        self._conv_out = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(inChannels: 96, outChannels: 3))
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = conv_in(x)
        h = mid_block(h)
        for ub in up_blocks { h = ub(h) }
        h = conv_out(silu(norm_out(h)))
        return h
    }
}

/// Production decode-only VAE. Its parameter tree intentionally has exactly two roots matching
/// the checkpoint: `post_quant_conv.*` and `decoder.*`.
public final class Krea2VAEDecoderModel: Module {
    @ModuleInfo public var decoder: Krea2VAEDecoder3D
    @ModuleInfo public var post_quant_conv: Krea2VAECausalConv3D

    static let parameterRoots = ["decoder", "post_quant_conv"]
    public static let spatialScale = Krea2VAELayout.spatialScale
    public static let latentChannels = Krea2VAELayout.latentChannels

    public override init() {
        self._decoder = ModuleInfo(wrappedValue: Krea2VAEDecoder3D())
        self._post_quant_conv = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(
            inChannels: 16, outChannels: 16, kernel: (1, 1, 1), stride: (1, 1, 1),
            padding: (0, 0, 0)))
        super.init()
    }



    public func decode(_ latent: MLXArray) throws -> MLXArray {
        try Krea2VAE.decode(
            latent, postQuantConv: post_quant_conv, decoder: decoder)
    }
}



///





public final class Krea2VAEEncoder3D: Module {
    @ModuleInfo public var conv_in: Krea2VAECausalConv3D
    @ModuleInfo public var down_blocks: [Krea2VAEDownBlock3D]
    @ModuleInfo public var mid_block: Krea2VAEMidBlock3D
    @ModuleInfo public var norm_out: Krea2VAERMSNorm
    @ModuleInfo public var conv_out: Krea2VAECausalConv3D

    public override init() {
        self._conv_in = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(inChannels: 3, outChannels: 96))
        self._down_blocks = ModuleInfo(wrappedValue: [
            Krea2VAEDownBlock3D(inChannels: 96, outChannels: 96, downsampleMode: "downsample2d"),
            Krea2VAEDownBlock3D(inChannels: 96, outChannels: 192, downsampleMode: "downsample3d"),
            Krea2VAEDownBlock3D(inChannels: 192, outChannels: 384, downsampleMode: "downsample3d"),
            Krea2VAEDownBlock3D(inChannels: 384, outChannels: 384, downsampleMode: nil),
        ])
        self._mid_block = ModuleInfo(wrappedValue: Krea2VAEMidBlock3D(dim: 384, numLayers: 1))
        self._norm_out = ModuleInfo(wrappedValue: Krea2VAERMSNorm(channels: 384, images: false))
        self._conv_out = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(inChannels: 384, outChannels: 32))
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = conv_in(x)
        for db in down_blocks { h = db(h) }
        h = mid_block(h)
        h = conv_out(silu(norm_out(h)))
        return h
    }
}

/// Production encode-only VAE. Its parameter tree intentionally has exactly two roots matching
/// the checkpoint: `encoder.*` and `quant_conv.*`.
public final class Krea2VAEEncoderModel: Module {
    @ModuleInfo public var encoder: Krea2VAEEncoder3D
    @ModuleInfo public var quant_conv: Krea2VAECausalConv3D

    static let parameterRoots = ["encoder", "quant_conv"]
    public static let spatialScale = Krea2VAELayout.spatialScale
    public static let latentChannels = Krea2VAELayout.latentChannels

    public override init() {
        self._encoder = ModuleInfo(wrappedValue: Krea2VAEEncoder3D())
        self._quant_conv = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(
            inChannels: 32, outChannels: 32, kernel: (1, 1, 1), stride: (1, 1, 1),
            padding: (0, 0, 0)))
        super.init()
    }

    /// Encodes pixels in approximately [-1, 1] to normalized `(B, 16, H/8, W/8)` latents.
    public func encode(_ pixels: MLXArray) -> MLXArray {
        Krea2VAE.encode(pixels, encoder: encoder, quantConv: quant_conv)
    }
}

public final class Krea2VAE: Module {
    @ModuleInfo public var decoder: Krea2VAEDecoder3D
    @ModuleInfo public var post_quant_conv: Krea2VAECausalConv3D
    @ModuleInfo public var encoder: Krea2VAEEncoder3D
    @ModuleInfo public var quant_conv: Krea2VAECausalConv3D

    static let parameterRoots = ["decoder", "post_quant_conv", "encoder", "quant_conv"]
    public static let spatialScale = Krea2VAELayout.spatialScale
    public static let latentChannels = Krea2VAELayout.latentChannels

    // Kept on the full model for source compatibility; they are constants, not parameters.
    static let meanValues = Krea2VAELayout.meanValues
    static let stdValues = Krea2VAELayout.stdValues

    public override init() {
        self._decoder = ModuleInfo(wrappedValue: Krea2VAEDecoder3D())
        self._post_quant_conv = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(
            inChannels: 16, outChannels: 16, kernel: (1, 1, 1), stride: (1, 1, 1), padding: (0, 0, 0)))
        self._encoder = ModuleInfo(wrappedValue: Krea2VAEEncoder3D())
        self._quant_conv = ModuleInfo(wrappedValue: Krea2VAECausalConv3D(
            inChannels: 32, outChannels: 32, kernel: (1, 1, 1), stride: (1, 1, 1), padding: (0, 0, 0)))
        super.init()
    }






    public func encode(_ pixels: MLXArray) -> MLXArray {
        Self.encode(pixels, encoder: encoder, quantConv: quant_conv)
    }

    /// Shared exact encode implementation for the production encoder-only and full Remix models.
    fileprivate static func encode(
        _ pixels: MLXArray,
        encoder: Krea2VAEEncoder3D,
        quantConv: Krea2VAECausalConv3D
    ) -> MLXArray {
        var x = pixels
        if x.ndim == 4 {
            x = x.reshaped([x.dim(0), x.dim(1), 1, x.dim(2), x.dim(3)])
        }
        var z = encoder(x)                                          // (n,32,1,H/8,W/8)
        z = quantConv(z)
        z = z[0..., 0 ..< Krea2VAE.latentChannels, 0..., 0..., 0...]
        let mean = MLXArray(Krea2VAE.meanValues).reshaped([1, 16, 1, 1, 1]).asType(z.dtype)
        let std = MLXArray(Krea2VAE.stdValues).reshaped([1, 16, 1, 1, 1]).asType(z.dtype)
        z = (z - mean) / std
        return z[0..., 0..., 0, 0..., 0...]
    }

    // MARK: - Tiled decode (roadmap item 8)
    //
    // Krea2VAEAttention3D's mid-block does dense (HW×HW) self-attention with no notion of
    // tiles — its cost is quadratic in the LATENT's own H×W. Empirically (2026-07-09, M4/32GB
    // Krea2CLI probes), a single-shot decode is safe up to 1344px (168 latent px) and hard-
    // crashes Metal's max buffer size at 1408px — a real cliff, not a gradual slowdown. Above
    // that, split the latent into overlapping tiles, run each tile through the FULL decoder
    // (so its own attention only ever sees ≤168 latent px), and feather-blend the pixel results
    // back together so tile seams don't show. This sacrifices the attention's global context at
    // tile boundaries — an accepted tradeoff also made by other tiled-VAE implementations —
    // but keeps every intermediate tensor bounded regardless of output resolution.
    static let tileMax = 168                // M: proven-safe latent window ceiling
    static let tileOverlap = 24             // O: context contributed by each side of a seam
    static let tileFeather = 2 * tileOverlap // F: exact overlap between neighboring windows



    public func decode(_ latent: MLXArray) throws -> MLXArray {
        try Self.decode(latent, postQuantConv: post_quant_conv, decoder: decoder)
    }

    /// Shared exact decode implementation for the production decoder-only and full Remix models.
    fileprivate static func decode(
        _ latent: MLXArray,
        postQuantConv: Krea2VAECausalConv3D,
        decoder: Krea2VAEDecoder3D
    ) throws -> MLXArray {
        try Task.checkCancellation()
        var z = latent
        if z.ndim == 4 {
            z = z.reshaped([z.dim(0), z.dim(1), 1, z.dim(2), z.dim(3)])
        }
        let mean = MLXArray(Krea2VAE.meanValues).reshaped([1, 16, 1, 1, 1]).asType(z.dtype)
        let std = MLXArray(Krea2VAE.stdValues).reshaped([1, 16, 1, 1, 1]).asType(z.dtype)
        z = z * std + mean
        z = postQuantConv(z)

        let latH = z.dim(3), latW = z.dim(4)
        if max(latH, latW) > Self.tileMax {
            return try decodeTiled(z, decoder: decoder)
        }
        let decoded = decoder(z)                    // (n,3,1,H,W)
        eval(decoded)
        try Task.checkCancellation()
        return decoded[0..., 0..., 0, 0..., 0...]
    }

    /// Minimal balanced windows covering one latent axis. Neighboring windows overlap by exactly
    /// `tileFeather`; their widths differ by at most one and never exceed `tileMax`.
    static func tileWindows(total: Int) -> [Range<Int>] {
        precondition(total > 0)
        guard total > tileMax else { return [0 ..< total] }

        let stride = tileMax - tileFeather
        let excess = total - tileMax
        let windowCount = 1 + (excess + stride - 1) / stride
        let combinedWidth = total + (windowCount - 1) * tileFeather
        let baseWidth = combinedWidth / windowCount
        let widerWindowCount = combinedWidth % windowCount

        var windows: [Range<Int>] = []
        windows.reserveCapacity(windowCount)
        var start = 0
        for index in 0 ..< windowCount {
            let width = baseWidth + (index < widerWindowCount ? 1 : 0)
            let end = start + width
            windows.append(start ..< end)
            start = end - tileFeather
        }
        return windows
    }

    /// Strictly-positive 1D blend weight. Paired outgoing/incoming ramps are complementary at
    /// every overlap sample, so neighboring windows form a partition of unity without zero edges.
    static func ramp1D(length: Int, rampIn: Int, rampOut: Int) -> [Float] {
        var w = [Float](repeating: 1, count: length)
        if rampIn > 0 {
            for i in 0 ..< min(rampIn, length) { w[i] = Float(i + 1) / Float(rampIn + 1) }
        }
        if rampOut > 0 {
            for i in 0 ..< min(rampOut, length) {
                let v = Float(i + 1) / Float(rampOut + 1)
                w[length - 1 - i] = min(w[length - 1 - i], v)
            }
        }
        return w
    }

    /// Splits `z` (already denormalized + post_quant_conv'd) into overlapping latent tiles,
    /// decodes each through the full decoder independently, and feather-blends the pixel-space
    /// results into one canvas via a weighted running sum (accumulator ÷ weight-sum).
    private static func decodeTiled(
        _ z: MLXArray, decoder: Krea2VAEDecoder3D
    ) throws -> MLXArray {
        let latH = z.dim(3), latW = z.dim(4)
        let rowWindows = Self.tileWindows(total: latH)
        let colWindows = Self.tileWindows(total: latW)
        let scale = Krea2VAE.spatialScale
        let n = z.dim(0)
        let outH = latH * scale, outW = latW * scale

        var canvasSum = MLXArray.zeros([n, 3, outH, outW], dtype: .float32)
        var canvasWeight = MLXArray.zeros([1, 1, outH, outW], dtype: .float32)

        for (rowIndex, rowWindow) in rowWindows.enumerated() {
            for (colIndex, colWindow) in colWindows.enumerated() {
                try Task.checkCancellation()

                let tileLatent = z[
                    0..., 0..., 0..., rowWindow.lowerBound ..< rowWindow.upperBound,
                    colWindow.lowerBound ..< colWindow.upperBound]
                var tilePixels = decoder(tileLatent)[0..., 0..., 0, 0..., 0...].asType(.float32)
                eval(tilePixels)   // force this tile's (large, transient) decode work to finish and
                                   // free before the next tile starts — that's the whole point of tiling.
                try Task.checkCancellation()

                let rowRamp = Self.ramp1D(
                    length: rowWindow.count * scale,
                    rampIn: rowIndex == 0 ? 0 : Self.tileFeather * scale,
                    rampOut: rowIndex == rowWindows.count - 1 ? 0 : Self.tileFeather * scale)
                let colRamp = Self.ramp1D(
                    length: colWindow.count * scale,
                    rampIn: colIndex == 0 ? 0 : Self.tileFeather * scale,
                    rampOut: colIndex == colWindows.count - 1 ? 0 : Self.tileFeather * scale)
                let mask = (MLXArray(rowRamp).reshaped([rowRamp.count, 1])
                    * MLXArray(colRamp).reshaped([1, colRamp.count]))
                    .reshaped([1, 1, rowRamp.count, colRamp.count])

                tilePixels = tilePixels * mask
                let widths = [
                    IntOrPair((0, 0)), IntOrPair((0, 0)),
                    IntOrPair((rowWindow.lowerBound * scale, outH - rowWindow.upperBound * scale)),
                    IntOrPair((colWindow.lowerBound * scale, outW - colWindow.upperBound * scale)),
                ]
                canvasSum = canvasSum + padded(tilePixels, widths: widths)
                canvasWeight = canvasWeight + padded(mask, widths: widths)
                eval(canvasSum, canvasWeight)
                try Task.checkCancellation()
            }
        }
        let blended = canvasSum / maximum(canvasWeight, MLXArray(Float(1e-6)))
        return blended.asType(z.dtype)
    }
}
