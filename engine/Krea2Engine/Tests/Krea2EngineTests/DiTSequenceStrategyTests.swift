import Foundation
import Krea2DiT
import Krea2Sampler
import MLX
import Testing

@Suite(.serialized) struct DiTSequenceStrategyTests {
    @Test func strategyIsSendableAndSamplerDefaultsToValidatedCompactLayout() {
        Self.requireSendable(Krea2DiTSequenceStrategy.legacy)
        Self.requireSendable(Krea2DiTSequenceStrategy.compactKeyPaddingWithPadTo256)

        let params = Krea2Sampler.Params()
        #expect(params.sequenceStrategy == .compactKeyPaddingWithPadTo256)
    }

    @Test func officialPaddingPlanMatchesModulo256Boundaries() {
        let expected: [(length: Int, padding: Int)] = [
            (0, 0),
            (1, 255),
            (255, 1),
            (256, 0),
            (257, 255),
            (511, 1),
            (512, 0),
            (767, 1),
            (768, 0),
        ]

        for item in expected {
            let plan = Krea2DiTSequencePlan(
                textLength: 0,
                imageLength: item.length,
                strategy: .compactKeyPaddingWithPadTo256)
            #expect(plan.paddingLength == item.padding)
            #expect(plan.modelLength == item.length + item.padding)
            if plan.modelLength > 0 {
                #expect(plan.modelLength % Krea2DiTSequencePlan.officialPaddingMultiple == 0)
            }
        }
    }

    @Test func imageRangeStopsBeforeDummySuffix() {
        let plan = Krea2DiTSequencePlan(
            textLength: 512,
            imageLength: 255,
            strategy: .compactKeyPaddingWithPadTo256)

        #expect(plan.unpaddedLength == 767)
        #expect(plan.paddingLength == 1)
        #expect(plan.modelLength == 768)
        #expect(plan.imageRange == 512 ..< 767)
        #expect(plan.paddingRange == 767 ..< 768)
        #expect(plan.imageRange.upperBound == plan.paddingRange.lowerBound)
    }

    @Test func legacyPlanNeverPads() {
        let plan = Krea2DiTSequencePlan(
            textLength: 512,
            imageLength: 255,
            strategy: .legacy)

        #expect(plan.unpaddedLength == 767)
        #expect(plan.paddingLength == 0)
        #expect(plan.modelLength == 767)
        #expect(plan.imageRange == 512 ..< 767)
        #expect(plan.paddingRange.isEmpty)
    }

    @Test func compactMaskShapeIsLinearAndBroadcastable() {
        let batchSize = 1
        let sequenceLength = 767
        let maskShape = Krea2DiTMath.keyPaddingMaskShape(
            batchSize: batchSize,
            keyLength: sequenceLength)
        let attentionShape = [batchSize, 48, sequenceLength, sequenceLength]

        #expect(maskShape == [batchSize, 1, 1, sequenceLength])
        #expect(maskShape.reduce(1, *) == batchSize * sequenceLength)
        #expect(Self.isBroadcastable(maskShape, to: attentionShape))
    }

    @Test func compactMaskRuntimeValues() throws {
        guard ProcessInfo.processInfo.environment["KREA2_SESSION7_METAL_TESTS"] == "1" else {
            return
        }

        try Device.withDefaultDevice(.cpu) {
            let valid = MLXArray([Float(1), 0, 1]).reshaped([1, 3])
            let compact = try #require(
                Krea2DiTMath.additiveKeyPaddingMask(valid: valid, dtype: .float32))
            let legacy = try #require(Krea2DiTMath.additiveMask(valid: valid, dtype: .float32))

            #expect(compact.shape == [1, 1, 1, 3])
            #expect(legacy.shape == [1, 1, 3, 3])
            #expect(compact.asArray(Float.self) == [0, -1e9, 0])

            let attentionScores = MLXArray.zeros([1, 2, 3, 3]) + compact
            eval(attentionScores)
            #expect(attentionScores.shape == [1, 2, 3, 3])
            #expect(attentionScores[0, 1, 2].asArray(Float.self) == [0, -1e9, 0])
        }
    }

    @Test func allValidCompactMaskUsesNilFastPath() {
        guard ProcessInfo.processInfo.environment["KREA2_SESSION7_METAL_TESTS"] == "1" else {
            return
        }

        Device.withDefaultDevice(.cpu) {
            let valid = MLXArray.ones([1, 17])
            #expect(Krea2DiTMath.additiveKeyPaddingMask(valid: valid, dtype: .float32) == nil)
        }
    }

    @Test func compactPadStrategySupportsSeparateCFGBranches() throws {
        guard ProcessInfo.processInfo.environment["KREA2_SESSION7_METAL_TESTS"] == "1" else {
            return
        }

        var config = Krea2DiTConfig()
        config.features = 16
        config.tdim = 16
        config.txtdim = 16
        config.heads = 1
        config.kvheads = 1
        config.multiplier = 1
        config.layers = 1
        config.patch = 2
        config.channels = 1
        config.txtheads = 1
        config.txtkvheads = 1
        config.txtlayers = 1

        var params = Krea2Sampler.Params()
        params.width = 16
        params.height = 16
        params.steps = 1
        params.dtype = .float32
        params.guidance = 3.5
        params.sequenceStrategy = .compactKeyPaddingWithPadTo256

        let sampler = Krea2Sampler(dit: Krea2SingleStreamDiT(config: config))
        let output = try sampler.sample(
            context: MLXArray.zeros([1, 1, 1, config.txtdim]),
            mask: MLXArray.ones([1, 1]),
            negativeContext: MLXArray.ones([1, 1, 1, config.txtdim]) * 0.1,
            negativeMask: MLXArray.ones([1, 1]),
            params: params,
            initNoise: MLXArray.zeros([1, config.channels, 2, 2]))
        eval(output)

        #expect(output.shape == [1, config.channels, 2, 2])
        #expect(MLX.all(MLX.isFinite(output)).item(Bool.self))
    }

    /// Opt-in only: compares the experiment against the current legacy path using the same
    /// full Krea 2 model. The existing mixed-4/8 artifact is preferred so the gate needs no new
    /// download; a BF16 directory remains available as a diagnostic alternative.
    @Test func realWeightSequenceParityGate() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KREA2_SESSION7_REAL_WEIGHT_GATE"] == "1" else { return }

        let config = Krea2DiTConfig()
        let model = Krea2SingleStreamDiT(config: config)
        if let quantPath = environment["KREA2_DIT_QUANT"] {
            Krea2DiTQuantRecipe.quantizeMixed48(model)
            try Krea2DiTWeightLoader.loadQuantized(
                into: model,
                file: URL(fileURLWithPath: quantPath))
        } else {
            let weightsPath = try #require(environment["KREA2_DIT_WEIGHTS"])
            try Krea2DiTWeightLoader.load(
                into: model,
                directory: URL(fileURLWithPath: weightsPath),
                computeDType: .bfloat16)
        }

        let textLength = 512
        let imageHeight = 15
        let imageWidth = 17
        let imageLength = imageHeight * imageWidth

        let tokenAxis = MLXArray(0 ..< textLength).asType(.float32).reshaped([1, textLength, 1, 1])
        let layerAxis = MLXArray(0 ..< config.txtlayers).asType(.float32)
            .reshaped([1, 1, config.txtlayers, 1])
        let featureAxis = MLXArray(0 ..< config.txtdim).asType(.float32)
            .reshaped([1, 1, 1, config.txtdim])
        let context = (MLX.sin(tokenAxis * 0.001 + layerAxis * 0.1 + featureAxis * 0.01) * 0.05)
            .asType(.bfloat16)

        let img = MLX.sin(
            MLXArray(0 ..< (imageLength * config.inChannels)).asType(.float32) * 0.01)
            .reshaped([1, imageLength, config.inChannels])
            .asType(.bfloat16)
        let pos = Krea2Patchify.buildPositions(
            txtlen: textLength,
            h: imageHeight,
            w: imageWidth)
        let textValid = concatenated([
            MLXArray.ones([1, 64]),
            MLXArray.zeros([1, textLength - 64]),
        ], axis: 1)
        let mask = concatenated([textValid, MLXArray.ones([1, imageLength])], axis: 1)
            .asType(.bfloat16)
        let t = MLXArray([Float(0.5)]).asType(.bfloat16)

        let legacyStart = ContinuousClock.now
        let legacy = model(
            img: img,
            context: context,
            t: t,
            pos: pos,
            mask: mask,
            strategy: .legacy).asType(.float32)
        eval(legacy)
        let legacyDuration = legacyStart.duration(to: .now)

        let experimentStart = ContinuousClock.now
        let experiment = model(
            img: img,
            context: context,
            t: t,
            pos: pos,
            mask: mask,
            strategy: .compactKeyPaddingWithPadTo256).asType(.float32)
        eval(experiment)
        let experimentDuration = experimentStart.duration(to: .now)

        let dot = MLX.sum(legacy * experiment)
        let norms = MLX.sqrt(MLX.sum(legacy * legacy) * MLX.sum(experiment * experiment))
        let cosine = (dot / norms).item(Float.self)
        let maxAbs = MLX.max(MLX.abs(legacy - experiment)).item(Float.self)

        #expect(legacy.shape == experiment.shape)
        #expect(cosine.isFinite)
        #expect(maxAbs.isFinite)
        #expect(cosine > 0.999)
        print(
            "DiT sequence live parity: cosine=\(cosine), maxAbs=\(maxAbs), "
                + "legacy=\(legacyDuration), compact=\(experimentDuration)"
        )

        guard environment["KREA2_SESSION7_COMPILE_GATE"] == "1" else { return }

        let conditioning = model.prepare(
            context: context,
            pos: pos,
            mask: mask,
            strategy: .compactKeyPaddingWithPadTo256)
        var conditioningArrays = [conditioning.context, conditioning.cos, conditioning.sin]
        if let conditioningMask = conditioning.mask {
            conditioningArrays.append(conditioningMask)
        }
        eval(conditioningArrays)

        let compiledStep = MLX.compile { (image: MLXArray, time: MLXArray) -> MLXArray in
            model.step(img: image, t: time, conditioning: conditioning)
        }
        MLX.Memory.peakMemory = 0

        let compiledColdStart = ContinuousClock.now
        let compiledCold = compiledStep(img, t).asType(.float32)
        eval(compiledCold)
        let compiledColdDuration = compiledColdStart.duration(to: .now)

        let warmTime = MLXArray([Float(0.25)]).asType(.bfloat16)
        let compiledWarmStart = ContinuousClock.now
        let compiledWarm = compiledStep(img, warmTime).asType(.float32)
        eval(compiledWarm)
        let compiledWarmDuration = compiledWarmStart.duration(to: .now)

        let eagerWarmStart = ContinuousClock.now
        let eagerWarm = model.step(img: img, t: warmTime, conditioning: conditioning).asType(.float32)
        eval(eagerWarm)
        let eagerWarmDuration = eagerWarmStart.duration(to: .now)

        let compiledDot = MLX.sum(eagerWarm * compiledWarm)
        let compiledNorms = MLX.sqrt(
            MLX.sum(eagerWarm * eagerWarm) * MLX.sum(compiledWarm * compiledWarm))
        let compiledCosine = (compiledDot / compiledNorms).item(Float.self)
        let compiledMaxAbs = MLX.max(MLX.abs(eagerWarm - compiledWarm)).item(Float.self)
        let compiledPeakBytes = MLX.Memory.peakMemory

        #expect(compiledCosine.isFinite)
        #expect(compiledMaxAbs.isFinite)
        #expect(compiledCosine > 0.999)
        print(
            "DiT compile live parity: cosine=\(compiledCosine), maxAbs=\(compiledMaxAbs), "
                + "cold=\(compiledColdDuration), warm=\(compiledWarmDuration), "
                + "eager=\(eagerWarmDuration), peakBytes=\(compiledPeakBytes)"
        )
    }

    private static func requireSendable<T: Sendable>(_ value: T) {}

    private static func isBroadcastable(_ source: [Int], to target: [Int]) -> Bool {
        guard source.count <= target.count else { return false }
        return zip(source.reversed(), target.reversed()).allSatisfy { sourceDim, targetDim in
            sourceDim == 1 || sourceDim == targetDim
        }
    }
}
