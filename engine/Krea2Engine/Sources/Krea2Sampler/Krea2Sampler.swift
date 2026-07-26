// Krea2Sampler.swift
//




import Foundation
import Krea2Core
import Krea2DiT
import MLX
import MLXRandom

public enum Krea2SamplerError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidStepCount(Int)
    case invalidPreviewInterval(Int)
    case nonFiniteGuidance
    case incompleteNegativeConditioning
    case missingNegativeConditioning
    case regionalGuidanceUnsupported
    case invalidNoiseShape(expected: [Int], actual: [Int])
    case nonFiniteNoise
    case invalidStrength(Double)
    case invalidInitLatentShape(expected: [Int], actual: [Int])
    case nonFiniteInitLatent
    case img2imgRequiresAtLeastTwoSteps
    case invalidSchedule

    public var description: String {
        switch self {
        case .invalidStepCount(let steps):
            return "steps must be at least 1, got \(steps)"
        case .invalidPreviewInterval(let interval):
            return "preview interval must be nonnegative, got \(interval)"
        case .nonFiniteGuidance:
            return "guidance must be finite"
        case .incompleteNegativeConditioning:
            return "negative context and mask must be supplied together"
        case .missingNegativeConditioning:
            return "nonzero guidance requires negative context and mask"
        case .regionalGuidanceUnsupported:
            return "regional sampling does not support guidance"
        case .invalidNoiseShape(let expected, let actual):
            return "initNoise shape \(actual) does not match expected latents \(expected)"
        case .nonFiniteNoise:
            return "initNoise contains non-finite values"
        case .invalidStrength(let strength):
            return "strength must be in (0, 1], got \(strength)"
        case .invalidInitLatentShape(let expected, let actual):
            return "initLatent shape \(actual) must match \(expected), with batch 1 also accepted"
        case .nonFiniteInitLatent:
            return "initLatent contains non-finite values"
        case .img2imgRequiresAtLeastTwoSteps:
            return "img2img needs steps >= 2 because a 1-step schedule has no entry below sigma 1"
        case .invalidSchedule:
            return "sampling schedule must contain finite sigma values in [0, 1]"
        }
    }
}

struct Krea2DenoisingPlan {
    let startLatent: MLXArray
    let startIndex: Int
    let effectiveSteps: Int
    let sigma: Double
}

public struct Krea2Sampler {
    public let dit: Krea2SingleStreamDiT

    public init(dit: Krea2SingleStreamDiT) { self.dit = dit }

    public struct Params: Sendable {
        public var width = 1024
        public var height = 1024
        public var steps = 8
        public var seed: UInt64 = 0
        public var minres = 256
        public var maxres = 1280
        public var y1 = 0.5
        public var y2 = 1.15




        public var mu: Double?
        public var dtype: DType = .bfloat16
        /// Production layout after tiny and mixed-4/8 real-weight parity gates returned exact
        /// outputs. The legacy square-mask path remains available for diagnostics.
        public var sequenceStrategy: Krea2DiTSequenceStrategy = .compactKeyPaddingWithPadTo256



        public var guidance: Float = 0
        public init() { self.mu = 1.15 }



        public static func rawDefaults() -> Params {
            var p = Params()
            p.steps = 52
            p.mu = nil
            p.guidance = 3.5
            return p
        }
    }






    public func sample(
        context: MLXArray,
        mask: MLXArray,
        negativeContext: MLXArray? = nil,
        negativeMask: MLXArray? = nil,
        params: Params,
        initNoise: MLXArray? = nil,
        initLatent: MLXArray? = nil,
        strength: Double = 1.0,
        previewEverySteps: Int = 0,
        previewCallback: ((Krea2LatentPreviewFrame) -> Void)? = nil,
        stepCallback: ((Int, Int) -> Void)? = nil
    ) throws -> MLXArray {
        try Task.checkCancellation()
        guard params.steps >= 1 else { throw Krea2SamplerError.invalidStepCount(params.steps) }
        guard previewEverySteps >= 0 else {
            throw Krea2SamplerError.invalidPreviewInterval(previewEverySteps)
        }
        guard params.guidance.isFinite else { throw Krea2SamplerError.nonFiniteGuidance }
        guard (negativeContext == nil) == (negativeMask == nil) else {
            throw Krea2SamplerError.incompleteNegativeConditioning
        }
        guard params.guidance == 0 || negativeContext != nil else {
            throw Krea2SamplerError.missingNegativeConditioning
        }

        let cfg = dit.config
        let patch = cfg.patch
        let align = patch * 8                                    // VAE spatial_scale 8 · patch
        let width = Krea2Patchify.roundup(params.width, align)
        let height = Krea2Patchify.roundup(params.height, align)
        let n = context.dim(0)
        let latH = height / 8, latW = width / 8

        let noise: MLXArray
        if let initNoise {
            noise = initNoise.asType(params.dtype)
        } else {
            MLXRandom.seed(params.seed)
            noise = MLXRandom.normal([n, cfg.channels, latH, latW]).asType(params.dtype)
        }

        let hp = latH / patch, wp = latW / patch
        let a1 = params.minres / align, a2 = params.maxres / align
        let ts = Krea2Schedule.timesteps(
            seqLen: hp * wp, steps: params.steps, x1: a1 * a1, x2: a2 * a2,
            y1: params.y1, y2: params.y2, mu: params.mu)
        let plan = try Self.makeDenoisingPlan(
            noise: noise,
            expectedShape: [n, cfg.channels, latH, latW],
            initLatent: initLatent,
            strength: strength,
            timesteps: ts,
            dtype: params.dtype)

        var img = Krea2Patchify.patchify(plan.startLatent, patch: patch) // (n, hp·wp, channels·p²)
        let txtlen = context.dim(1)
        let pos = Krea2Patchify.buildPositions(txtlen: txtlen, h: hp, w: wp)
        let imgOnes = MLXArray.ones([n, hp * wp]).asType(params.dtype)
        let fullMask = concatenated([mask.asType(params.dtype), imgOnes], axis: 1)   // (n, L)

        let ctx = context.asType(params.dtype)
        // txtfusion/txtmlp + RoPE tables + additive mask only depend on ctx/pos/fullMask, which
        // are the same on every step — compute them once instead of on each of the `steps` calls.
        let conditioning = dit.prepare(
            context: ctx,
            pos: pos,
            mask: fullMask,
            strategy: params.sequenceStrategy)



        var negConditioning: Krea2SingleStreamDiT.Conditioning?
        if params.guidance != 0, let negativeContext, let negativeMask {
            let negCtx = negativeContext.asType(params.dtype)
            let negFullMask = concatenated([negativeMask.asType(params.dtype), imgOnes], axis: 1)
            negConditioning = dit.prepare(
                context: negCtx,
                pos: pos,
                mask: negFullMask,
                strategy: params.sequenceStrategy)
        }

        for step in 0 ..< plan.effectiveSteps {
            try Task.checkCancellation()

            let i = plan.startIndex + step
            let tc = ts[i], tp = ts[i + 1]
            let t = MLXArray([Float](repeating: Float(tc), count: n)).asType(params.dtype)
            var v = dit.step(img: img, t: t, conditioning: conditioning)
            try Task.checkCancellation()

            if let negConditioning {

                let vUncond = dit.step(img: img, t: t, conditioning: negConditioning)
                try Task.checkCancellation()
                v = v + (v - vUncond) * params.guidance
            }
            img = img + MLXArray(Float(tp - tc)) * v
            try Task.checkCancellation()
            eval(img)
            try Task.checkCancellation()
            stepCallback?(step + 1, plan.effectiveSteps)
            try Task.checkCancellation()
            let completedStep = step + 1
            if let previewCallback,
               previewEverySteps > 0,
               completedStep == 1
                    || completedStep == plan.effectiveSteps
                    || completedStep.isMultiple(of: previewEverySteps)
            {
                let latent = Krea2Patchify.unpatchify(
                    img,
                    patch: patch,
                    h: hp,
                    w: wp,
                    channels: cfg.channels)
                previewCallback(try Krea2LatentPreviewRenderer.render(
                    latent: latent,
                    step: completedStep,
                    totalSteps: plan.effectiveSteps))
                try Task.checkCancellation()
            }
        }

        return Krea2Patchify.unpatchify(img, patch: patch, h: hp, w: wp, channels: cfg.channels)
    }









    public func sampleRegional(
        context: MLXArray,
        txtLabels: MLXArray,
        regions: [Krea2RegionBBox],
        params: Params,
        initNoise: MLXArray? = nil,
        initLatent: MLXArray? = nil,
        strength: Double = 1.0,
        previewEverySteps: Int = 0,
        previewCallback: ((Krea2LatentPreviewFrame) -> Void)? = nil,
        stepCallback: ((Int, Int) -> Void)? = nil
    ) throws -> MLXArray {
        try Task.checkCancellation()
        guard params.steps >= 1 else { throw Krea2SamplerError.invalidStepCount(params.steps) }
        guard previewEverySteps >= 0 else {
            throw Krea2SamplerError.invalidPreviewInterval(previewEverySteps)
        }
        guard params.guidance.isFinite else { throw Krea2SamplerError.nonFiniteGuidance }
        guard params.guidance == 0 else {
            throw Krea2SamplerError.regionalGuidanceUnsupported
        }

        let cfg = dit.config
        let patch = cfg.patch
        let align = patch * 8
        let width = Krea2Patchify.roundup(params.width, align)
        let height = Krea2Patchify.roundup(params.height, align)
        let n = context.dim(0)
        let latH = height / 8, latW = width / 8

        let noise: MLXArray
        if let initNoise {
            noise = initNoise.asType(params.dtype)
        } else {
            MLXRandom.seed(params.seed)
            noise = MLXRandom.normal([n, cfg.channels, latH, latW]).asType(params.dtype)
        }

        let hp = latH / patch, wp = latW / patch
        let a1 = params.minres / align, a2 = params.maxres / align
        let ts = Krea2Schedule.timesteps(
            seqLen: hp * wp, steps: params.steps, x1: a1 * a1, x2: a2 * a2,
            y1: params.y1, y2: params.y2, mu: params.mu)
        let plan = try Self.makeDenoisingPlan(
            noise: noise,
            expectedShape: [n, cfg.channels, latH, latW],
            initLatent: initLatent,
            strength: strength,
            timesteps: ts,
            dtype: params.dtype)

        var img = Krea2Patchify.patchify(plan.startLatent, patch: patch)
        let txtlen = context.dim(1)
        let pos = Krea2Patchify.buildPositions(txtlen: txtlen, h: hp, w: wp)

        let ctx = context.asType(params.dtype)
        let imgLabels = Self.buildImageLabels(regions: regions, hp: hp, wp: wp)
        let (txtMask, fullMask) = Krea2DiTRegionalMask.masks(
            txtLabels: txtLabels.asType(.int32), imgLabels: imgLabels, dtype: params.dtype)
        let conditioning = dit.prepare(context: ctx, pos: pos, txtMask: txtMask, fullMask: fullMask)

        for step in 0 ..< plan.effectiveSteps {
            try Task.checkCancellation()

            let i = plan.startIndex + step
            let tc = ts[i], tp = ts[i + 1]
            let t = MLXArray([Float](repeating: Float(tc), count: n)).asType(params.dtype)
            let v = dit.step(img: img, t: t, conditioning: conditioning)
            try Task.checkCancellation()
            img = img + MLXArray(Float(tp - tc)) * v
            try Task.checkCancellation()
            eval(img)
            try Task.checkCancellation()
            stepCallback?(step + 1, plan.effectiveSteps)
            try Task.checkCancellation()
            let completedStep = step + 1
            if let previewCallback,
               previewEverySteps > 0,
               completedStep == 1
                    || completedStep == plan.effectiveSteps
                    || completedStep.isMultiple(of: previewEverySteps)
            {
                let latent = Krea2Patchify.unpatchify(
                    img,
                    patch: patch,
                    h: hp,
                    w: wp,
                    channels: cfg.channels)
                previewCallback(try Krea2LatentPreviewRenderer.render(
                    latent: latent,
                    step: completedStep,
                    totalSteps: plan.effectiveSteps))
                try Task.checkCancellation()
            }
        }

        return Krea2Patchify.unpatchify(img, patch: patch, h: hp, w: wp, channels: cfg.channels)
    }

    static func makeDenoisingPlan(
        noise: MLXArray,
        expectedShape: [Int],
        initLatent: MLXArray?,
        strength: Double,
        timesteps: [Double],
        dtype: DType
    ) throws -> Krea2DenoisingPlan {
        guard noise.shape == expectedShape else {
            throw Krea2SamplerError.invalidNoiseShape(
                expected: expectedShape,
                actual: noise.shape)
        }
        guard MLX.all(MLX.isFinite(noise)).item(Bool.self) else {
            throw Krea2SamplerError.nonFiniteNoise
        }
        guard timesteps.count >= 2,
              timesteps.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) })
        else {
            throw Krea2SamplerError.invalidSchedule
        }

        let fullStepCount = timesteps.count - 1
        guard let initLatent else {
            return Krea2DenoisingPlan(
                startLatent: noise,
                startIndex: 0,
                effectiveSteps: fullStepCount,
                sigma: timesteps[0])
        }
        guard strength.isFinite, strength > 0, strength <= 1 else {
            throw Krea2SamplerError.invalidStrength(strength)
        }

        // At strength 1 initLatent is deliberately ignored: this is exactly the txt2img path.
        guard strength < 1 else {
            return Krea2DenoisingPlan(
                startLatent: noise,
                startIndex: 0,
                effectiveSteps: fullStepCount,
                sigma: timesteps[0])
        }

        let lastStartIndex = timesteps.count - 2
        let startIndex = timesteps.dropLast()
            .firstIndex(where: { $0 <= strength }) ?? lastStartIndex
        let sigma = timesteps[startIndex]
        guard sigma < 1 else {
            throw Krea2SamplerError.img2imgRequiresAtLeastTwoSteps
        }

        let clean = initLatent.asType(dtype)
        let actualShape = clean.shape
        let canBroadcastBatch = actualShape.count == expectedShape.count
            && actualShape.first == 1
            && Array(actualShape.dropFirst()) == Array(expectedShape.dropFirst())
        guard actualShape == expectedShape || canBroadcastBatch else {
            throw Krea2SamplerError.invalidInitLatentShape(
                expected: expectedShape,
                actual: actualShape)
        }
        guard MLX.all(MLX.isFinite(clean)).item(Bool.self) else {
            throw Krea2SamplerError.nonFiniteInitLatent
        }

        let batchedClean = actualShape == expectedShape
            ? clean
            : MLX.broadcast(clean, to: expectedShape)
        let cleanWeight = MLXArray(Float(1 - sigma)).asType(dtype)
        let noiseWeight = MLXArray(Float(sigma)).asType(dtype)
        let startLatent = cleanWeight * batchedClean + noiseWeight * noise

        return Krea2DenoisingPlan(
            startLatent: startLatent,
            startIndex: startIndex,
            effectiveSteps: fullStepCount - startIndex,
            sigma: sigma)
    }




    private static func buildImageLabels(regions: [Krea2RegionBBox], hp: Int, wp: Int) -> MLXArray {
        var labels = [Int32](repeating: 0, count: hp * wp)
        for r in 0 ..< hp {
            for c in 0 ..< wp {
                let cx = (Double(c) + 0.5) / Double(wp)
                let cy = (Double(r) + 0.5) / Double(hp)
                for (i, region) in regions.enumerated() {
                    if cx >= region.x0, cx < region.x1, cy >= region.y0, cy < region.y1 {
                        labels[r * wp + c] = Int32(i + 1)
                        break
                    }
                }
            }
        }
        return MLXArray(labels)
    }
}
