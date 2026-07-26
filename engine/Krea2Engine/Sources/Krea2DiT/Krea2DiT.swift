// Krea2DiT.swift
//


//   img→first; t→timestep→tmlp→t_emb→tproj→tvec; context→txtfusion→txtmlp;



import Foundation
import MLX
import MLXNN



public final class Krea2SingleStreamDiT: Module {
    public let config: Krea2DiTConfig

    @ModuleInfo public var first: Linear
    @ModuleInfo public var blocks: [Krea2SingleStreamBlock]


    @ModuleInfo public var tmlp: [UnaryLayer]
    @ModuleInfo public var txtfusion: Krea2TextFusionTransformer
    @ModuleInfo public var txtmlp: [UnaryLayer]
    @ModuleInfo public var last: Krea2LastLayer
    @ModuleInfo public var tproj: [UnaryLayer]

    public init(config: Krea2DiTConfig = Krea2DiTConfig()) {
        self.config = config
        let f = config.features
        self._first = ModuleInfo(wrappedValue: Linear(config.inChannels, f, bias: true))
        self._blocks = ModuleInfo(wrappedValue: (0 ..< config.layers).map { _ in
            Krea2SingleStreamBlock(config: config)
        })
        // tmlp[0,1,2]: Linear, GELU, Linear
        self._tmlp = ModuleInfo(wrappedValue: [
            Linear(config.tdim, f, bias: true), Krea2GELUTanh(), Linear(f, f, bias: true),
        ])
        self._txtfusion = ModuleInfo(wrappedValue: Krea2TextFusionTransformer(
            numTxtLayers: config.txtlayers, txtDim: config.txtdim,
            heads: config.txtheads, kvheads: config.txtkvheads,
            multiplier: config.multiplier, eps: config.normEps))
        // txtmlp[0,1,2,3]: RMSNorm, Linear, GELU, Linear
        self._txtmlp = ModuleInfo(wrappedValue: [
            Krea2DiTRMSNorm(dimensions: config.txtdim, eps: config.normEps),
            Linear(config.txtdim, f, bias: true), Krea2GELUTanh(), Linear(f, f, bias: true),
        ])
        self._last = ModuleInfo(wrappedValue: Krea2LastLayer(
            features: f, patch: config.patch, channels: config.channels, eps: config.normEps))
        // tproj[0,1]: GELU, Linear
        self._tproj = ModuleInfo(wrappedValue: [Krea2GELUTanh(), Linear(f, f * 6, bias: true)])
        super.init()
    }

    private func runSeq(_ layers: [UnaryLayer], _ x: MLXArray) -> MLXArray {
        var h = x
        for layer in layers { h = layer(h) }
        return h
    }

    /// The text-conditioning path (txtfusion+txtmlp), RoPE tables, and the additive padding
    /// mask — depend ONLY on context/pos/mask, none of which change across a sampling loop's
    /// steps. `prepare(...)` computes them once; `step(...)` reuses the result on every denoise
    /// step instead of recomputing the same tensors from scratch each time.
    public struct Conditioning {
        public let context: MLXArray   // (B, seq, features) — post txtfusion + txtmlp
        public let cos: MLXArray
        public let sin: MLXArray
        public let mask: MLXArray?     // additive, SDPA-broadcastable; nil when fully valid
        public let txtlen: Int
        public let sequencePlan: Krea2DiTSequencePlan
    }

    /// One-time setup — call before the denoise loop, not inside it.



    public func prepare(
        context contextIn: MLXArray,
        pos: MLXArray,
        mask: MLXArray,
        strategy: Krea2DiTSequenceStrategy = .legacy
    ) -> Conditioning {
        let dt = contextIn.dtype
        let txtlen = contextIn.dim(1)
        let plan = Krea2DiTSequencePlan(
            textLength: txtlen,
            imageLength: pos.dim(0) - txtlen,
            strategy: strategy)
        let txtValid = mask[0..., 0 ..< txtlen]
        let txtmask: MLXArray?
        let fullMask: MLXArray?
        let preparedPos: MLXArray

        switch strategy {
        case .legacy:
            txtmask = Krea2DiTMath.additiveMask(valid: txtValid, dtype: dt)
            fullMask = Krea2DiTMath.additiveMask(valid: mask, dtype: dt)
            preparedPos = pos
        case .compactKeyPaddingWithPadTo256:
            txtmask = Krea2DiTMath.additiveKeyPaddingMask(valid: txtValid, dtype: dt)

            if plan.paddingLength == 0 {
                fullMask = Krea2DiTMath.additiveKeyPaddingMask(valid: mask, dtype: dt)
                preparedPos = pos
            } else {
                let maskPadding = MLXArray.zeros([mask.dim(0), plan.paddingLength]).asType(mask.dtype)
                let paddedValid = concatenated([mask, maskPadding], axis: 1)
                fullMask = Krea2DiTMath.additiveKeyPaddingMask(valid: paddedValid, dtype: dt)

                let posPadding = MLXArray.zeros([plan.paddingLength, pos.dim(1)]).asType(pos.dtype)
                preparedPos = concatenated([pos, posPadding], axis: 0)
            }
        }

        return prepareConditioning(
            context: contextIn,
            pos: preparedPos,
            txtMask: txtmask,
            fullMask: fullMask,
            sequencePlan: plan)
    }





    public func prepare(
        context contextIn: MLXArray, pos: MLXArray, txtMask: MLXArray?, fullMask: MLXArray?
    ) -> Conditioning {
        let txtlen = contextIn.dim(1)
        let plan = Krea2DiTSequencePlan(
            textLength: txtlen,
            imageLength: pos.dim(0) - txtlen,
            strategy: .legacy)
        return prepareConditioning(
            context: contextIn,
            pos: pos,
            txtMask: txtMask,
            fullMask: fullMask,
            sequencePlan: plan)
    }

    private func prepareConditioning(
        context contextIn: MLXArray,
        pos: MLXArray,
        txtMask: MLXArray?,
        fullMask: MLXArray?,
        sequencePlan: Krea2DiTSequencePlan
    ) -> Conditioning {
        let txtlen = contextIn.dim(1)
        var context = txtfusion(contextIn, mask: txtMask)                            // (B, seq, features)
        context = runSeq(txtmlp, context)
        let (cos, sin) = Krea2DiTMath.ropeTables(pos: pos.asType(.float32), axes: config.ropeAxes, theta: config.theta)
        return Conditioning(
            context: context,
            cos: cos,
            sin: sin,
            mask: fullMask,
            txtlen: txtlen,
            sequencePlan: sequencePlan)
    }

    /// Per-step forward — only the timestep-dependent path (t-embedding + the 28 blocks + last
    /// layer). Pair with a single `prepare(...)` call shared across all steps of one sample.



    public func step(img imgIn: MLXArray, t: MLXArray, conditioning: Conditioning) -> MLXArray {
        let img = first(imgIn)
        let dt = img.dtype

        let tEmb = runSeq(tmlp, Krea2DiTMath.timestepEmbed(t, dim: config.tdim).asType(dt)) // (B,1,features)
        let tvec = runSeq(tproj, tEmb)                                               // (B,1,6·features)

        var combined = concatenated([conditioning.context, img], axis: 1)            // (B, L, features)
        if conditioning.sequencePlan.paddingLength > 0 {
            let padding = MLXArray.zeros([
                combined.dim(0), conditioning.sequencePlan.paddingLength, combined.dim(2),
            ]).asType(combined.dtype)
            combined = concatenated([combined, padding], axis: 1)
        }
        for block in blocks {
            combined = block(combined, vec: tvec, cos: conditioning.cos, sin: conditioning.sin, mask: conditioning.mask)
        }

        let final = last(combined, tvec: tEmb)                                       // (B, L, channels·patch²)
        let imageRange = conditioning.sequencePlan.imageRange
        return final[0..., imageRange.lowerBound ..< imageRange.upperBound, 0...]
    }

    /// Single-call convenience, bit-identical to `prepare(...)` + `step(...)` — kept for callers
    /// (golden-gate CLI dumps, unit tests) that run one forward pass without a multi-step loop.
    public func callAsFunction(
        img imgIn: MLXArray,
        context contextIn: MLXArray,
        t: MLXArray,
        pos: MLXArray,
        mask: MLXArray,
        strategy: Krea2DiTSequenceStrategy = .legacy
    ) -> MLXArray {
        step(
            img: imgIn,
            t: t,
            conditioning: prepare(context: contextIn, pos: pos, mask: mask, strategy: strategy))
    }
}
