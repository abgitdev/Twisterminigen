import Foundation
import Krea2Core
import Krea2DiT
import MLX
import Testing
@testable import Krea2Sampler

@Suite struct SamplerTests {
    private enum SamplingPath: Sendable {
        case standard
        case regional
    }

    private struct CancellationResult: Sendable {
        let caughtCancellation: Bool
        let completedSteps: Int
    }

    private struct TinyFixture {
        let sampler: Krea2Sampler
        let params: Krea2Sampler.Params
        let context: MLXArray
        let mask: MLXArray
        let txtLabels: MLXArray
        let noise: MLXArray
    }


    @Test func patchifyIdentity() {
        let b = 1, c = 16, h = 8, w = 6, p = 2
        let x = MLXArray(0 ..< (b * c * h * w)).reshaped([b, c, h, w]).asType(.float32)
        let patched = Krea2Patchify.patchify(x, patch: p)
        #expect(patched.shape == [b, (h / p) * (w / p), c * p * p])
        let restored = Krea2Patchify.unpatchify(patched, patch: p, h: h / p, w: w / p, channels: c)
        #expect(restored.shape == [b, c, h, w])
        let maxDiff = MLX.max(MLX.abs(restored - x)).item(Float.self)
        #expect(maxDiff == 0)
    }


    @Test func buildPositions() {
        let pos = Krea2Patchify.buildPositions(txtlen: 3, h: 2, w: 2)   // L=3+4=7
        #expect(pos.shape == [7, 3])
        let arr = pos.asType(.float32).asArray(Float.self)

        for i in 0 ..< 9 { #expect(arr[i] == 0) }

        #expect(Array(arr[9 ..< 21]) == [0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1])
    }


    @Test func scheduleControl1024() {
        let ts = Krea2Schedule.timesteps(seqLen: 4096, steps: 8, x1: 256, x2: 6400)
        let expected: [Double] = [1.0, 0.9454, 0.8813, 0.8049, 0.7122, 0.5976, 0.4521, 0.2612, 0.0]
        #expect(ts.count == 9)
        for (a, b) in zip(ts, expected) { #expect(abs(a - b) < 1e-3) }

        #expect(ts[0] == 1.0 && ts[8] == 0.0)
    }

    @Test func img2imgStrengthOneIsPureTxt2Img() throws {
        let noise = MLXArray([Float(1), 2]).reshaped([1, 1, 1, 2])
        let clean = MLXArray([Float(100), 200]).reshaped([1, 1, 1, 2])
        let plan = try Self.makeDenoisingPlan(
            noise: noise,
            initLatent: clean,
            strength: 1,
            timesteps: [1, 0.8, 0.5, 0.2, 0])

        #expect(plan.startIndex == 0)
        #expect(plan.effectiveSteps == 4)
        #expect(plan.sigma == 1)
        #expect(plan.startLatent.asArray(Float.self) == noise.asArray(Float.self))
    }

    @Test func img2imgSelectsFirstSigmaAndBlendsCleanWithNoise() throws {
        let noise = MLXArray([Float(2), 4]).reshaped([1, 1, 1, 2])
        let clean = MLXArray([Float(10), 20]).reshaped([1, 1, 1, 2])
        let timesteps = [1.0, 0.8, 0.55, 0.2, 0.0]
        let plan = try Self.makeDenoisingPlan(
            noise: noise,
            initLatent: clean,
            strength: 0.6,
            timesteps: timesteps)

        #expect(plan.startIndex == 2)
        #expect(plan.effectiveSteps == 2)
        #expect(plan.sigma == 0.55)
        let expected: [Float] = [5.6, 11.2]
        for (actual, expected) in zip(plan.startLatent.asArray(Float.self), expected) {
            #expect(abs(actual - expected) < 1e-5)
        }

        let minimumPlan = try Self.makeDenoisingPlan(
            noise: noise,
            initLatent: clean,
            strength: 0.01,
            timesteps: timesteps)
        #expect(minimumPlan.startIndex == 3)
        #expect(minimumPlan.effectiveSteps == 1)
        #expect(minimumPlan.sigma == 0.2)
    }

    @Test func img2imgBroadcastsSingletonCleanBatch() throws {
        let noise = MLXArray([Float(1), 2, 3, 4]).reshaped([2, 1, 1, 2])
        let clean = MLXArray([Float(10), 20]).reshaped([1, 1, 1, 2])
        let plan = try Self.makeDenoisingPlan(
            noise: noise,
            initLatent: clean,
            strength: 0.5,
            timesteps: [1, 0.5, 0])

        #expect(plan.startLatent.shape == noise.shape)
        let expected: [Float] = [5.5, 11, 6.5, 12]
        for (actual, expected) in zip(plan.startLatent.asArray(Float.self), expected) {
            #expect(abs(actual - expected) < 1e-6)
        }
    }

    @Test func img2imgRejectsInvalidInputsAndOneStepSchedule() {
        let noise = MLXArray.zeros([2, 1, 1, 2])
        let clean = MLXArray.ones([2, 1, 1, 2])

        for strength in [0.0, -0.1, 1.01, Double.infinity, Double.nan] {
            #expect(throws: Krea2SamplerError.self) {
                _ = try Self.makeDenoisingPlan(
                    noise: noise,
                    initLatent: clean,
                    strength: strength,
                    timesteps: [1, 0.5, 0])
            }
        }

        let wrongBatch = MLXArray.ones([3, 1, 1, 2])
        #expect(throws: Krea2SamplerError.invalidInitLatentShape(
            expected: noise.shape,
            actual: wrongBatch.shape
        )) {
            _ = try Self.makeDenoisingPlan(
                noise: noise,
                initLatent: wrongBatch,
                strength: 0.5,
                timesteps: [1, 0.5, 0])
        }

        let nonFinite = MLXArray([Float.nan, 0]).reshaped([1, 1, 1, 2])
        #expect(throws: Krea2SamplerError.nonFiniteInitLatent) {
            _ = try Self.makeDenoisingPlan(
                noise: noise,
                initLatent: nonFinite,
                strength: 0.5,
                timesteps: [1, 0.5, 0])
        }

        #expect(throws: Krea2SamplerError.img2imgRequiresAtLeastTwoSteps) {
            _ = try Self.makeDenoisingPlan(
                noise: noise,
                initLatent: clean,
                strength: 0.5,
                timesteps: [1, 0])
        }
    }

    @Test func img2imgCallbacksReportEffectiveStepsForBothPaths() throws {
        let fixture = Self.makeTinyFixture()
        var params = fixture.params
        params.steps = 4
        let clean = MLXArray.ones(fixture.noise.shape)

        for path in [SamplingPath.standard, .regional] {
            var completed: [Int] = []
            var totals: [Int] = []
            let callback: (Int, Int) -> Void = { step, total in
                completed.append(step)
                totals.append(total)
            }

            switch path {
            case .standard:
                _ = try fixture.sampler.sample(
                    context: fixture.context,
                    mask: fixture.mask,
                    params: params,
                    initNoise: fixture.noise,
                    initLatent: clean,
                    strength: 0.8,
                    stepCallback: callback)
            case .regional:
                _ = try fixture.sampler.sampleRegional(
                    context: fixture.context,
                    txtLabels: fixture.txtLabels,
                    regions: [],
                    params: params,
                    initNoise: fixture.noise,
                    initLatent: clean,
                    strength: 0.8,
                    stepCallback: callback)
            }

            #expect(completed == [1, 2])
            #expect(totals == [2, 2])
        }
    }

    @Test func latentPreviewIsThrottledAndCannotChangeFinalOutput() throws {
        let fixture = Self.makeTinyFixture(channels: 16)
        var params = fixture.params
        params.steps = 3
        let baseline = try fixture.sampler.sample(
            context: fixture.context,
            mask: fixture.mask,
            params: params,
            initNoise: fixture.noise)
        var previews: [Krea2LatentPreviewFrame] = []
        let withPreview = try fixture.sampler.sample(
            context: fixture.context,
            mask: fixture.mask,
            params: params,
            initNoise: fixture.noise,
            previewEverySteps: 2,
            previewCallback: { previews.append($0) })

        #expect(previews.map(\.step) == [1, 2, 3])
        #expect(previews.allSatisfy { $0.totalSteps == 3 })
        #expect(previews.allSatisfy { $0.width == 2 && $0.height == 2 })
        #expect(previews.allSatisfy { $0.rgb.count == 12 })
        #expect(MLX.max(MLX.abs(baseline - withPreview)).item(Float.self) == 0)
    }

    @Test func latentPreviewRejectsInvalidShapeAndStep() {
        let neutral = try? Krea2LatentPreviewRenderer.render(
            latent: MLXArray.zeros([1, 16, 2, 2]),
            step: 1,
            totalSteps: 1)
        #expect(neutral?.rgb == [UInt8](repeating: 127, count: 12))

        #expect(throws: Krea2LatentPreviewError.invalidShape([1, 3, 2, 2])) {
            _ = try Krea2LatentPreviewRenderer.render(
                latent: MLXArray.zeros([1, 3, 2, 2]),
                step: 1,
                totalSteps: 1)
        }
        #expect(throws: Krea2LatentPreviewError.invalidStep(step: 0, total: 2)) {
            _ = try Krea2LatentPreviewRenderer.render(
                latent: MLXArray.zeros([1, 16, 2, 2]),
                step: 0,
                totalSteps: 2)
        }
        #expect(throws: Krea2LatentPreviewError.invalidShape([2, 16, 2, 2])) {
            _ = try Krea2LatentPreviewRenderer.render(
                latent: MLXArray.zeros([2, 16, 2, 2]),
                step: 1,
                totalSteps: 2)
        }
    }

    @Test func samplerRejectsInvalidPreviewAndGuidanceConfiguration() {
        let fixture = Self.makeTinyFixture()

        #expect(throws: Krea2SamplerError.invalidPreviewInterval(-1)) {
            _ = try fixture.sampler.sample(
                context: fixture.context,
                mask: fixture.mask,
                params: fixture.params,
                initNoise: fixture.noise,
                previewEverySteps: -1)
        }

        var guided = fixture.params
        guided.guidance = 3.5
        #expect(throws: Krea2SamplerError.missingNegativeConditioning) {
            _ = try fixture.sampler.sample(
                context: fixture.context,
                mask: fixture.mask,
                params: guided,
                initNoise: fixture.noise)
        }

        #expect(throws: Krea2SamplerError.incompleteNegativeConditioning) {
            _ = try fixture.sampler.sample(
                context: fixture.context,
                mask: fixture.mask,
                negativeContext: fixture.context,
                params: fixture.params,
                initNoise: fixture.noise)
        }

        var nonFinite = fixture.params
        nonFinite.guidance = .nan
        #expect(throws: Krea2SamplerError.nonFiniteGuidance) {
            _ = try fixture.sampler.sample(
                context: fixture.context,
                mask: fixture.mask,
                params: nonFinite,
                initNoise: fixture.noise)
        }

        #expect(throws: Krea2SamplerError.regionalGuidanceUnsupported) {
            _ = try fixture.sampler.sampleRegional(
                context: fixture.context,
                txtLabels: fixture.txtLabels,
                regions: [],
                params: guided,
                initNoise: fixture.noise)
        }
    }

    @Test func regionalSamplerAcceptsEightRegions() throws {
        let fixture = Self.makeTinyFixture()
        let regions = (0 ..< 8).map { index in
            Krea2RegionBBox(
                x0: Double(index) / 8,
                y0: 0,
                x1: Double(index + 1) / 8,
                y1: 1)
        }

        let output = try fixture.sampler.sampleRegional(
            context: fixture.context,
            txtLabels: fixture.txtLabels,
            regions: regions,
            params: fixture.params,
            initNoise: fixture.noise)

        #expect(output.shape == fixture.noise.shape)
    }

    @Test func sampleChecksCancellationBeforeDenoising() async {
        let result = await Self.runCancellation(path: .standard, cancelBeforeSampling: true)
        #expect(result.caughtCancellation)
        #expect(result.completedSteps == 0)
    }

    @Test func sampleRegionalChecksCancellationBeforeDenoising() async {
        let result = await Self.runCancellation(path: .regional, cancelBeforeSampling: true)
        #expect(result.caughtCancellation)
        #expect(result.completedSteps == 0)
    }

    @Test func sampleChecksCancellationAfterCurrentStep() async {
        let result = await Self.runCancellation(path: .standard, cancelBeforeSampling: false)
        #expect(result.caughtCancellation)
        #expect(result.completedSteps == 1)
    }

    @Test func sampleRegionalChecksCancellationAfterCurrentStep() async {
        let result = await Self.runCancellation(path: .regional, cancelBeforeSampling: false)
        #expect(result.caughtCancellation)
        #expect(result.completedSteps == 1)
    }

    private static func makeTinyFixture(channels: Int = 1) -> TinyFixture {
        var config = Krea2DiTConfig()
        config.features = 16
        config.tdim = 16
        config.txtdim = 16
        config.heads = 1
        config.kvheads = 1
        config.multiplier = 1
        config.layers = 0
        config.patch = 2
        config.channels = channels
        config.txtheads = 1
        config.txtkvheads = 1
        config.txtlayers = 1

        var params = Krea2Sampler.Params()
        params.width = 16
        params.height = 16
        params.steps = 1
        params.dtype = .float32

        return TinyFixture(
            sampler: Krea2Sampler(dit: Krea2SingleStreamDiT(config: config)),
            params: params,
            context: MLXArray.zeros([1, 1, 1, config.txtdim]),
            mask: MLXArray.ones([1, 1]),
            txtLabels: MLXArray([Int32(0)]),
            noise: MLXArray.zeros([1, config.channels, 2, 2]))
    }

    private static func makeDenoisingPlan(
        noise: MLXArray,
        initLatent: MLXArray?,
        strength: Double,
        timesteps: [Double]
    ) throws -> Krea2DenoisingPlan {
        try Krea2Sampler.makeDenoisingPlan(
            noise: noise,
            expectedShape: noise.shape,
            initLatent: initLatent,
            strength: strength,
            timesteps: timesteps,
            dtype: .float32)
    }

    private static func runCancellation(
        path: SamplingPath,
        cancelBeforeSampling: Bool
    ) async -> CancellationResult {
        await Task {
            let fixture = makeTinyFixture()
            var completedSteps = 0

            if cancelBeforeSampling {
                withUnsafeCurrentTask { $0?.cancel() }
            }

            do {
                let callback: (Int, Int) -> Void = { step, _ in
                    completedSteps = step
                    if !cancelBeforeSampling {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }

                switch path {
                case .standard:
                    _ = try fixture.sampler.sample(
                        context: fixture.context,
                        mask: fixture.mask,
                        params: fixture.params,
                        initNoise: fixture.noise,
                        stepCallback: callback)
                case .regional:
                    _ = try fixture.sampler.sampleRegional(
                        context: fixture.context,
                        txtLabels: fixture.txtLabels,
                        regions: [],
                        params: fixture.params,
                        initNoise: fixture.noise,
                        stepCallback: callback)
                }
                return CancellationResult(caughtCancellation: false, completedSteps: completedSteps)
            } catch {
                return CancellationResult(
                    caughtCancellation: error is CancellationError,
                    completedSteps: completedSteps)
            }
        }.value
    }
}
