import ArgumentParser
import Foundation
import Krea2Pipeline
import Krea2Sampler
import Krea2VAE
import MLX

enum Krea2VAEPrecisionSource: String, CaseIterable, ExpressibleByArgument {
    case random
    case krea
}

struct Krea2VAEPrecisionCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vae-precision-check",
        abstract: "Compare decoder-only FP32 and BF16 output on one bounded latent.")

    @Option(name: .long, help: "VAE diffusers safetensors file.")
    var vaeWeights: String

    @Option(name: .long, help: "random or krea. Krea runs TE + one Turbo latent first.")
    var source: Krea2VAEPrecisionSource = .random

    @Option(name: .long, help: "Official model directory; required for --source krea.")
    var officialDir: String?

    @Option(name: .long, help: "Mixed quantized transformer; required for --source krea.")
    var ditQuant: String?

    @Option(name: .long, help: "Prompt used only for --source krea.")
    var prompt = "A glossy red sphere on a matte black table, soft studio light."

    @Option(name: .long) var width = 512
    @Option(name: .long) var height = 512
    @Option(name: .long) var steps = 8
    @Option(name: .long) var seed: UInt64 = 13_711

    mutating func validate() throws {
        for (name, value) in [("width", width), ("height", height)] {
            guard (256 ... 1_024).contains(value), value.isMultiple(of: 16) else {
                throw ValidationError("--\(name) must be a multiple of 16 in 256...1024.")
            }
        }
        guard (1 ... 12).contains(steps) else {
            throw ValidationError("--steps must be in 1...12.")
        }
        if source == .krea {
            guard let officialDir, !officialDir.isEmpty,
                  let ditQuant, !ditQuant.isEmpty
            else {
                throw ValidationError(
                    "--source krea requires --official-dir and --dit-quant.")
            }
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("--prompt must not be empty.")
            }
        }
    }

    func run() async throws {
        MLX.Memory.cacheLimit = Krea2Pipeline.defaultCacheLimitBytes
        MLX.Memory.peakMemory = 0
        defer { MLX.Memory.clearCache() }

        let session = Krea2PipelineSession()
        let latent: Krea2MaterializedLatent
        switch source {
        case .random:
            latent = try Self.randomLatent(width: width, height: height, seed: seed)
        case .krea:
            guard let officialDir, let ditQuant else {
                throw ValidationError("Missing Krea source paths.")
            }
            latent = try await Self.kreaLatent(
                session: session,
                officialDirectory: URL(fileURLWithPath: officialDir),
                transformer: URL(fileURLWithPath: ditQuant),
                prompt: prompt,
                width: width,
                height: height,
                steps: steps,
                seed: seed)
        }

        let weightsURL = URL(fileURLWithPath: vaeWeights)
        let reference = try Self.decode(
            latent: latent,
            dtype: .float32,
            weights: weightsURL,
            session: session)
        let candidate = try Self.decode(
            latent: latent,
            dtype: .bfloat16,
            weights: weightsURL,
            session: session)
        guard reference.shape == candidate.shape else {
            throw ValidationError(
                "Decoder shapes differ: \(reference.shape) vs \(candidate.shape).")
        }

        let metrics = try Krea2VAEPrecisionComparator.compare(
            reference: reference.pixels,
            candidate: candidate.pixels,
            shape: reference.shape)
        print("vae-precision-check: source=\(source.rawValue) shape=\(reference.shape)")
        print(String(format: "  cosine=%.9f", metrics.cosineSimilarity))
        print(String(format: "  PSNR=%.3f dB", metrics.peakSignalToNoiseRatio))
        print(String(format: "  global-SSIM=%.9f", metrics.globalSSIM))
        print(String(format: "  MAE=%.8f RMSE=%.8f max-abs=%.8f",
                     metrics.meanAbsoluteError,
                     metrics.rootMeanSquaredError,
                     metrics.maximumAbsoluteError))
        guard metrics.passesProductionGate else {
            throw ValidationError(
                "BF16 decoder failed production thresholds: cosine>=0.999, PSNR>=40, global-SSIM>=0.995.")
        }
        print("  gate: PASS")
    }

    private static func kreaLatent(
        session: Krea2PipelineSession,
        officialDirectory: URL,
        transformer: URL,
        prompt: String,
        width: Int,
        height: Int,
        steps: Int,
        seed: UInt64
    ) async throws -> Krea2MaterializedLatent {
        let conditioning = try await session.withTextEncoder(
            officialDirectory: officialDirectory
        ) { encoder in
            try encoder.materialize(prompt: prompt)
        }
        var params = Krea2Sampler.Params()
        params.width = width
        params.height = height
        params.steps = steps
        params.seed = seed
        return try session.withTransformer(quantizedWeights: transformer) { stage in
            try stage.sample(conditioning: conditioning, params: params)
        }
    }

    private static func randomLatent(
        width: Int,
        height: Int,
        seed: UInt64
    ) throws -> Krea2MaterializedLatent {
        let count = Krea2VAEDecoderModel.latentChannels * (height / 8) * (width / 8)
        var generator = SplitMix64(seed: seed)
        var values: [Float] = []
        values.reserveCapacity(count)
        while values.count < count {
            let first = max(generator.nextUnit(), Double.leastNonzeroMagnitude)
            let second = generator.nextUnit()
            let radius = sqrt(-2 * log(first))
            values.append(Float(radius * cos(2 * .pi * second)))
            if values.count < count {
                values.append(Float(radius * sin(2 * .pi * second)))
            }
        }
        let array = MLXArray(values).reshaped([
            1,
            Krea2VAEDecoderModel.latentChannels,
            height / 8,
            width / 8,
        ])
        return try Krea2MaterializedLatent(materializing: array)
    }

    private static func decode(
        latent: Krea2MaterializedLatent,
        dtype: DType,
        weights: URL,
        session: Krea2PipelineSession
    ) throws -> (shape: [Int], pixels: [Float]) {
        try session.withDecoder(weights: weights, computeDType: dtype) { decoder in
            let image = try decoder.decode(latent).asType(.float32)
            eval(image)
            return (image.shape, image.asArray(Float.self))
        }
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUnit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) * 0x1.0p-53
    }
}
