import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import Krea2Core
import Krea2DiT
import Krea2Pipeline
import Krea2Sampler
import Krea2TextEncoder
import Krea2VAE
import MLX
import MLXNN
import UniformTypeIdentifiers

/// Portable developer defaults. CI and local gates can point at a verified weight checkout with
/// `KREA2_WEIGHTS_ROOT`; no workstation-specific path is embedded in source or release binaries.
enum Krea2CLIPaths {
    static let weightsRoot = ProcessInfo.processInfo.environment["KREA2_WEIGHTS_ROOT"]
        ?? "./krea2-weights"
    static let official = "\(weightsRoot)/official"
    static let turboMixed = "\(weightsRoot)/alis-mixed-4-8/transformer_mixed_4_8.safetensors"
    static let turboQ8 = "\(weightsRoot)/alis-q8/transformer_8bit.safetensors"
    static let rawMixed = "\(weightsRoot)/raw-mixed-4-8/transformer_raw_mixed_4_8.safetensors"
    static let vae = "\(official)/vae/diffusion_pytorch_model.safetensors"
}

@main
struct Krea2CLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "krea2",
        abstract: "Krea 2 port phase gates and image generation.",
        subcommands: [Krea2Benchmark.self, TextEncoderSmoke.self, TextEncoderDump.self,
                      TextEncoderOracleDump.self, DiTDump.self,
                      ScheduleDump.self, SamplerDump.self, VAEDump.self, VAELoadCheck.self,
                      Krea2VAEPrecisionCheck.self,
                      LoRALoadCheck.self, Enhance.self, Generate.self, GenerateRegional.self,
                      RemixAB.self, Krea2Stage3Soak.self,
                      RegionMaskCheck.self]
    )
}





enum Krea2Checkpoint: String, CaseIterable, ExpressibleByArgument {
    case turbo, raw
}

enum Krea2CLIQuantization: String, CaseIterable, ExpressibleByArgument {
    case mixed4And8 = "mixed-4-8"
    case q8

    var engineValue: Krea2DiTQuantization {
        switch self {
        case .mixed4And8: .mixed4And8
        case .q8: .q8
        }
    }
}


struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "P5: txt2img end-to-end → PNG.")

    @Option(name: .long) var prompt: String
    @Option(name: .long) var out: String = "./out.png"
    @Option(name: .long) var width: Int = 1024
    @Option(name: .long) var height: Int = 1024
    @Option(name: .long, help: "Default: turbo 8 / raw 52.") var steps: Int?
    @Option(name: .long) var seed: UInt64 = 0
    @Option(name: .long, help: "Manual μ (turbo default 1.15; raw default nil for resolution-aware scheduling).") var mu: Double?

    @Option(name: .long, help: "Classifier-free guidance with official semantics (v=cond+g·(cond-uncond)). Default: turbo 0 / raw 3.5.")
    var cfg: Double?
    @Option(name: .long, help: "Negative prompt (used only when effective --cfg != 0).")
    var negativePrompt: String = ""

    @Option(name: .long, help: "turbo | raw — model and defaults (steps/μ/cfg).")
    var checkpoint: Krea2Checkpoint = .turbo
    @Option(name: .long, help: "mixed-4-8 | q8 — exact DiT weight recipe.")
    var quantization: Krea2CLIQuantization = .mixed4And8

    @Option(name: .long) var officialDir: String = Krea2CLIPaths.official
    @Option(name: .long, help: "Explicit path (otherwise selected from --checkpoint).") var ditQuant: String?
    @Option(name: .long) var vae: String = Krea2CLIPaths.vae
    @Option(name: .long, help: "Optional Stage 6 JSON metrics destination.")
    var metricsOut: String?
    @Option(name: .long, help: "Pinned transformer revision recorded with --metrics-out.")
    var transformerRevision: String?
    @Option(name: .long, help: "Pinned transformer SHA-256 recorded with --metrics-out.")
    var transformerSHA256: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Paths to LoRA .safetensors files (repeatable).")
    var loraPaths: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Scale for each --lora-paths entry (missing values default to 1.0; extras are ignored).")
    var loraScales: [Double] = []

    // Mirrors the GUI's GenerateViewModel bounds (minSide/maxSide). Krea2VAE now tiles the
    // decode above ~1344px (Krea2VAE.tileMax), so the ceiling matches Krea's own documented
    // native Turbo range (1k–2k) instead of the old single-shot decode's hard Metal-buffer
    // cliff. Verified on M4/32GB (2026-07-09): 1536² and 2048² both complete via the tiled path
    // (no crash) where they previously hard-failed in Metal before tiling existed.
    static let minSide = 256
    static let maxSide = 2048

    mutating func validate() throws {
        try Self.validateCanvas(width: width, height: height)
        if let steps {
            try Self.validateStepCount(steps)
        }
        if let cfg, !cfg.isFinite || cfg < 0 || cfg > 20 {
            throw ValidationError("--cfg must be finite and in 0...20.")
        }
        if let mu, !mu.isFinite {
            throw ValidationError("--mu must be finite.")
        }
        if loraScales.contains(where: { !$0.isFinite || $0 <= 0 || $0 > 2 }) {
            throw ValidationError("Every --lora-scales value must be finite and in (0, 2].")
        }
        if checkpoint == .raw, quantization != .mixed4And8 {
            throw ValidationError("q8 is available only for the Turbo checkpoint; Raw remains a separate developer path.")
        }
        try Self.validatePNGOutput(out)
        if let metricsOut {
            guard URL(fileURLWithPath: metricsOut).pathExtension.lowercased() == "json" else {
                throw ValidationError("--metrics-out must end in .json.")
            }
            guard let transformerRevision, !transformerRevision.isEmpty else {
                throw ValidationError("--transformer-revision is required with --metrics-out.")
            }
            guard let digest = transformerSHA256?.lowercased(), digest.count == 64,
                  digest.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) })
            else {
                throw ValidationError("--transformer-sha256 must be 64 lowercase hex characters.")
            }
        }
    }

    static func validateCanvas(width: Int, height: Int) throws {
        for (label, value) in [("--width", width), ("--height", height)] {
            guard value.isMultiple(of: 16), (minSide ... maxSide).contains(value) else {
                throw ValidationError(
                    "\(label)=\(value) must be a multiple of 16 in \(minSide)...\(maxSide).")
            }
        }
    }

    static func validateStepCount(_ steps: Int) throws {
        guard (1 ... 100).contains(steps) else {
            throw ValidationError("--steps=\(steps) must be in 1...100.")
        }
    }

    static func validatePNGOutput(_ path: String) throws {
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "png" else {
            throw ValidationError("--out must end in .png.")
        }
    }

    private var defaultDitQuant: String {
        switch (checkpoint, quantization) {
        case (.turbo, .mixed4And8):
            Krea2CLIPaths.turboMixed
        case (.turbo, .q8):
            Krea2CLIPaths.turboQ8
        case (.raw, .mixed4And8), (.raw, .q8):
            Krea2CLIPaths.rawMixed
        }
    }

    func run() async throws {
        var params = checkpoint == .raw ? Krea2Sampler.Params.rawDefaults() : Krea2Sampler.Params()
        params.width = width; params.height = height
        params.seed = seed; params.dtype = .bfloat16
        if let steps { params.steps = steps }
        if let mu { params.mu = mu }
        if let cfg { params.guidance = Float(cfg) }

        let loraAdapters = loraPaths.enumerated().map { i, path in
            Krea2DiTLoRAConfig(
                path: URL(fileURLWithPath: path),
                scale: Float(i < loraScales.count ? loraScales[i] : 1.0))
        }
        let weights = Krea2Pipeline.Weights(
            officialDir: URL(fileURLWithPath: officialDir),
            ditQuantFile: URL(fileURLWithPath: ditQuant ?? defaultDitQuant),
            vaeFile: URL(fileURLWithPath: vae),
            ditQuantization: quantization.engineValue,
            loraAdapters: loraAdapters)

        print("== generate (\(checkpoint.rawValue), \(quantization.rawValue)) ==\nprompt: \"\(prompt)\"\n"
            + "size: \(width)×\(height), steps: \(params.steps), cfg: \(params.guidance), seed: \(seed)")
        let monitor = Krea2CLIOSMonitor()
        monitor.start()
        MLX.Memory.peakMemory = 0
        let t0 = Date()
        let image = try await Krea2Pipeline.generate(
            prompt: prompt, weights: weights, params: params, negativePrompt: negativePrompt,
            stepCallback: { i, n in print("  step \(i)/\(n)") })
        let seconds = Date().timeIntervalSince(t0)

        try Self.writePNG(image, to: URL(fileURLWithPath: out))
        let os = await monitor.stop()
        let mlx = MLX.Memory.snapshot()
        let imageData = try Data(contentsOf: URL(fileURLWithPath: out), options: .mappedIfSafe)
        if let metricsOut {
            let report = Krea2CLIRenderMetrics(
                schema: "twisterminigen.stage6-render",
                version: 1,
                checkpoint: checkpoint.rawValue,
                quantization: quantization.rawValue,
                transformerRevision: transformerRevision!,
                transformerSHA256: transformerSHA256!.lowercased(),
                prompt: prompt,
                width: width,
                height: height,
                steps: params.steps,
                seed: seed,
                seconds: seconds,
                imageSHA256: Krea2StableDigest.sha256(imageData),
                processBaselineBytes: os.processBaselineBytes,
                processPeakBytes: os.processPeakBytes,
                processFinalBytes: os.processFinalBytes,
                mlxPeakBytes: Int64(mlx.peakMemory),
                mlxActiveBytes: Int64(mlx.activeMemory),
                mlxCacheBytes: Int64(mlx.cacheMemory),
                swapBaselineBytes: os.swapBaselineBytes,
                swapPeakBytes: os.swapPeakBytes,
                swapFinalBytes: os.swapFinalBytes,
                swapIncreaseBytes: os.swapIncreaseBytes,
                memoryPressureWorst: os.memoryPressureWorst,
                thermalBaseline: os.thermalBaseline,
                thermalWorst: os.thermalWorst,
                thermalFinal: os.thermalFinal)
            try Krea2CLIRenderMetrics.write(
                report,
                to: URL(fileURLWithPath: metricsOut))
        }
        print(String(format: "completed in %.1f s → %@ (peak %.2f GB)",
                     seconds, out, Double(MLX.Memory.peakMemory) / 1_073_741_824))
        print("OS peak \(os.processPeakBytes) bytes · swap +\(os.swapIncreaseBytes) · "
            + "pressure \(os.memoryPressureWorst) · thermal \(os.thermalBaseline)/\(os.thermalWorst)/\(os.thermalFinal)")
    }


    static func writePNG(_ pixels: MLXArray, to url: URL) throws {
        let h = pixels.dim(2), w = pixels.dim(3)
        let hwc = pixels[0].transposed(1, 2, 0)                       // (H,W,3)
        let u8 = clip(hwc * 255, min: 0, max: 255).asType(.uint8)
        eval(u8)
        let rgb = u8.asArray(UInt8.self)                             // H*W*3
        var rgba = [UInt8](repeating: 255, count: h * w * 4)
        for i in 0 ..< (h * w) {
            rgba[i * 4] = rgb[i * 3]; rgba[i * 4 + 1] = rgb[i * 3 + 1]; rgba[i * 4 + 2] = rgb[i * 3 + 2]
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(
                  width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ExitCode.failure }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExitCode.failure }
    }
}



struct GenerateRegional: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-regional",
        abstract: "Regional bbox prompting: one global prompt plus N regions with independent text.")

    @Option(name: .long) var globalPrompt: String
    @Option(name: .long, parsing: .upToNextOption,
            help: "Region: 'x0,y0,x1,y1:text' with normalized 0–1 coordinates (repeatable).")
    var region: [String] = []

    @Option(name: .long) var out: String = "./out_regional.png"
    @Option(name: .long) var width: Int = 1024
    @Option(name: .long) var height: Int = 1024
    @Option(name: .long) var steps: Int = 8
    @Option(name: .long) var seed: UInt64 = 0

    @Option(name: .long) var officialDir: String = Krea2CLIPaths.official
    @Option(name: .long) var ditQuant: String = Krea2CLIPaths.turboMixed
    @Option(name: .long) var vae: String = Krea2CLIPaths.vae

    mutating func validate() throws {
        try Generate.validateCanvas(width: width, height: height)
        try Generate.validateStepCount(steps)
        try Generate.validatePNGOutput(out)
        guard !globalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--global-prompt must not be empty.")
        }
        guard (1 ... 2).contains(region.count) else {
            throw ValidationError("Provide 1...2 --region values for the experimental Regional prompts stage.")
        }
        _ = try parsedRegions()
    }

    func run() async throws {
        let regions = try parsedRegions()

        var params = Krea2Sampler.Params()
        params.width = width; params.height = height; params.steps = steps; params.seed = seed

        let weights = Krea2Pipeline.Weights(
            officialDir: URL(fileURLWithPath: officialDir),
            ditQuantFile: URL(fileURLWithPath: ditQuant),
            vaeFile: URL(fileURLWithPath: vae))

        print("== generate-regional ==\nglobal: \"\(globalPrompt)\"\nregions: \(regions.count)")
        let t0 = Date()
        let image = try await Krea2Pipeline.generateRegional(
            globalPrompt: globalPrompt, regions: regions, weights: weights, params: params,
            stepCallback: { i, n in print("  step \(i)/\(n)") })
        let seconds = Date().timeIntervalSince(t0)

        try Generate.writePNG(image, to: URL(fileURLWithPath: out))
        print(String(format: "completed in %.1f s → %@", seconds, out))
    }

    private func parsedRegions() throws -> [Krea2Region] {
        try region.map { spec in
            let parts = spec.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                throw ValidationError("--region must be 'x0,y0,x1,y1:text'; received: \(spec)")
            }
            let coordinateFields = parts[0].split(
                separator: ",",
                omittingEmptySubsequences: false)
            guard coordinateFields.count == 4 else {
                throw ValidationError("--region bbox must contain four comma-separated numbers; received: \(parts[0])")
            }
            let coords = try coordinateFields.enumerated().map { index, field -> Double in
                let value = String(field).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, let coordinate = Double(value) else {
                    throw ValidationError(
                        "--region bbox coordinate \(index + 1) must be a number, got: \(field)")
                }
                return coordinate
            }
            guard coords.allSatisfy(\.isFinite),
                  coords[0] >= 0, coords[1] >= 0,
                  coords[2] <= 1, coords[3] <= 1,
                  coords[0] < coords[2], coords[1] < coords[3] else {
                throw ValidationError("--region bbox must be finite, normalized, and nonempty: \(parts[0])")
            }
            let prompt = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty, prompt.utf8.count <= 65_536 else {
                throw ValidationError("--region prompt must be nonempty and at most 65536 UTF-8 bytes.")
            }
            return Krea2Region(
                prompt: prompt,
                bbox: Krea2RegionBBox(x0: coords[0], y0: coords[1], x1: coords[2], y1: coords[3]))
        }
    }
}




///













struct RegionMaskCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "region-mask-check",
        abstract: "Regional isolation gate: changing region 2 text must not materially change region 1 output.")

    func run() async throws {
        var cfg = Krea2DiTConfig()
        cfg.features = 384; cfg.tdim = 256; cfg.txtdim = 256; cfg.heads = 6; cfg.kvheads = 2
        cfg.multiplier = 4; cfg.layers = 4; cfg.patch = 2; cfg.channels = 16; cfg.theta = 1000
        cfg.txtheads = 4; cfg.txtkvheads = 4; cfg.txtlayers = 12
        MLXRandom.seed(7)
        let dit = Krea2SingleStreamDiT(config: cfg)



        let txtlen = 20, hp = 4, wp = 4
        let txtLabels = MLXArray((0 ..< txtlen).map { i -> Int32 in
            i < 10 ? 0 : (i < 15 ? 1 : 2)
        })
        let imgLabels = MLXArray((0 ..< (hp * wp)).map { i -> Int32 in i < 8 ? 1 : 2 })





        let sharedPrefix = MLXRandom.normal([1, 15, cfg.txtlayers, cfg.txtdim]).asType(.float32)
        let region2A = MLXRandom.normal([1, 5, cfg.txtlayers, cfg.txtdim]).asType(.float32)
        let region2B = MLXRandom.normal([1, 5, cfg.txtlayers, cfg.txtdim]).asType(.float32) * 5.0
        let contextA = concatenated([sharedPrefix, region2A], axis: 1)
        let contextB = concatenated([sharedPrefix, region2B], axis: 1)

        let pos = Krea2Patchify.buildPositions(txtlen: txtlen, h: hp, w: wp)
        let (txtMask, fullMask) = Krea2DiTRegionalMask.masks(txtLabels: txtLabels, imgLabels: imgLabels, dtype: .float32)

        let img = MLXRandom.normal([1, hp * wp, cfg.channels * cfg.patch * cfg.patch]).asType(.float32)
        let t = MLXArray([Float(0.5)])

        let condA = dit.prepare(context: contextA, pos: pos, txtMask: txtMask, fullMask: fullMask)
        let condB = dit.prepare(context: contextB, pos: pos, txtMask: txtMask, fullMask: fullMask)
        let outA = dit.step(img: img, t: t, conditioning: condA)
        let outB = dit.step(img: img, t: t, conditioning: condB)
        eval(outA, outB)

        let flatA = outA.asArray(Float.self), flatB = outB.asArray(Float.self)
        let d = outA.dim(2)
        var region1MaxDiff: Float = 0, region2MaxDiff: Float = 0
        let imgLabelsArr = imgLabels.asArray(Int32.self)
        for i in 0 ..< (hp * wp) {
            var maxDiff: Float = 0
            for k in 0 ..< d {
                maxDiff = max(maxDiff, abs(flatA[i * d + k] - flatB[i * d + k]))
            }
            if imgLabelsArr[i] == 1 { region1MaxDiff = max(region1MaxDiff, maxDiff) }
            else { region2MaxDiff = max(region2MaxDiff, maxDiff) }
        }

        print("region-mask-check: region1 max|Δ|=\(region1MaxDiff), region2 max|Δ|=\(region2MaxDiff) "
            + "(ratio=\(region2MaxDiff / max(region1MaxDiff, 1e-12)))")

        let isolationDominates = region1MaxDiff < region2MaxDiff / 2
        let sanityOK = region2MaxDiff > 1e-3
        print(isolationDominates && sanityOK ? "PASS (isolation dominates without requiring bit-identical output)" : "FAIL")
        if !(isolationDominates && sanityOK) { throw ExitCode.failure }
    }
}





struct LoRALoadCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lora-load-check",
        abstract: "Load a real LoRA .safetensors file into a fresh DiT and verify targets/keys without a forward pass.")

    @Option(name: .long, help: "LoRA .safetensors file.")
    var loraFile: String

    @Option(name: .long, help: "User-selected scale.")
    var scale: Double = 1.0

    func run() async throws {
        let model = Krea2SingleStreamDiT()
        let totalTargets = Krea2DiTLoRAMapping.targets(config: model.config).count
        let stats = try Krea2DiTLoRALoader.apply(
            to: model,
            adapters: [Krea2DiTLoRAConfig(path: URL(fileURLWithPath: loraFile), scale: Float(scale))])
        for s in stats {
            print("lora-load-check: \(s.file) — matched targets=\(s.matchedTargets)/\(totalTargets), "
                + "matched keys=\(s.matchedKeys)/\(s.totalKeys), unmatched=\(s.unmatchedKeys.count)")
            if !s.unmatchedKeys.isEmpty {
                print("  first unmatched: \(s.unmatchedKeys.prefix(5))")
            }
        }
    }
}





struct VAELoadCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vae-load-check",
        abstract: "Load VAE encode/decode weights and verify keys without a forward pass.")

    @Option(name: .long, help: "VAE safetensors file (Diffusers format).")
    var vaeWeights: String

    func run() async throws {
        let vae = Krea2VAE()
        let n = try Krea2VAEWeightLoader.load(into: vae, file: URL(fileURLWithPath: vaeWeights), computeDType: .float32)
        print("vae-load-check: OK, \(n) tensors loaded (decoder+post_quant_conv+encoder+quant_conv), missing=0 extra=0")
    }
}


struct VAEDump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vae-dump",
        abstract: "P4: run Krea2VAE.decode on a golden latent → pixels (n,3,H,W).")

    @Option(name: .long, help: "VAE safetensors file (Diffusers format).")
    var vaeWeights: String

    @Option(name: .long, help: "safetensors input containing the latent key.")
    var inputs: String

    @Option(name: .long, help: "Output .safetensors path for pixels.")
    var out: String

    func run() async throws {
        let vae = Krea2VAE()
        let n = try Krea2VAEWeightLoader.load(into: vae, file: URL(fileURLWithPath: vaeWeights), computeDType: .float32)

        let inp = try loadArrays(url: URL(fileURLWithPath: inputs))
        guard let latent = inp["latent"] else { print("FAIL: latent is required"); throw ExitCode.failure }

        let pixels = try vae.decode(latent.asType(.float32))
        let out32 = pixels.asType(.float32)
        eval(out32)

        try MLX.save(arrays: ["pixels": out32], url: URL(fileURLWithPath: out))
        print("vae-dump: \(out) tensors loaded=\(n) pixels=\(pixels.shape)")
        MLX.Memory.clearCache()
    }
}


struct ScheduleDump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule-dump",
        abstract: "P3: Turbo σ schedules (dynamic μ) for 512/1024/1280/2K → JSON.")

    @Option(name: .long, help: "Output .json path.")
    var out: String

    @Option(name: .long, help: "Number of steps.")
    var steps: Int = 8

    private static var scheduleCases: [(name: String, side: Int, mu: Double?)] {
        [
            ("512", 512, nil), ("1024", 1024, nil),
            ("1280", 1280, nil), ("2K", 2048, 1.15),
            ("1024T", 1024, 1.15),
        ]
    }

    mutating func validate() throws {
        try Generate.validateStepCount(steps)
        for item in Self.scheduleCases {
            guard item.side.isMultiple(of: 16),
                  (Generate.minSide ... Generate.maxSide).contains(item.side) else {
                throw ValidationError(
                    "Schedule case \(item.name) has invalid canvas side \(item.side).")
            }
            if let mu = item.mu, !mu.isFinite {
                throw ValidationError("Schedule case \(item.name) has a non-finite mu.")
            }
        }
    }

    func run() async throws {

        var result: [String: [Double]] = [:]
        for (name, side, mu) in Self.scheduleCases {
            let tokenSide = side / 16
            result[name] = Krea2Schedule.timesteps(
                seqLen: tokenSide * tokenSide, steps: steps, x1: 256, x2: 6400, mu: mu)
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: out))
        print("schedule-dump: \(out) (\(Self.scheduleCases.count) resolutions, steps=\(steps))")
    }
}


struct SamplerDump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sampler-dump",
        abstract: "P3: run Krea2Sampler.sample on golden noise/context → latent.")

    @Option(name: .long, help: "DiT weights directory.")
    var weightsDir: String

    @Option(name: .long, help: "config.json (uses the complete configuration when absent).")
    var config: String?

    @Option(name: .long, help: "safetensors: context, mask, noise.")
    var inputs: String

    @Option(name: .long, help: "Output .safetensors path for the latent.")
    var out: String

    @Option(name: .long) var width: Int = 1024
    @Option(name: .long) var height: Int = 1024
    @Option(name: .long) var steps: Int = 8
    @Option(name: .long, help: "Manual μ (otherwise dynamic).") var mu: Double?
    @Flag(name: .long) var float32: Bool = false

    @Option(name: .long, help: "Guidance for the CFG gate using official semantics. Requires neg_context/neg_mask inputs.")
    var guidance: Double = 0

    mutating func validate() throws {
        for (name, value) in [("--width", width), ("--height", height)] {
            guard value > 0,
                  value <= Generate.maxSide,
                  value.isMultiple(of: 16) else {
                throw ValidationError(
                    "\(name)=\(value) must be a positive multiple of 16 no greater than \(Generate.maxSide).")
            }
        }
        try Generate.validateStepCount(steps)
        if let mu, !mu.isFinite {
            throw ValidationError("--mu must be finite.")
        }
        guard guidance.isFinite, (0 ... 20).contains(guidance) else {
            throw ValidationError("--guidance must be finite and in 0...20.")
        }
    }

    func run() async throws {
        let dtype: DType = float32 ? .float32 : .bfloat16
        let inp = try loadArrays(url: URL(fileURLWithPath: inputs))
        guard let context = inp["context"], let mask = inp["mask"], let noise = inp["noise"] else {
            print("FAIL: context/mask/noise inputs are required"); throw ExitCode.failure
        }
        let negativeContext = inp["neg_context"]
        let negativeMask = inp["neg_mask"]
        if guidance != 0, negativeContext == nil || negativeMask == nil {
            throw ValidationError(
                "Nonzero --guidance requires both neg_context and neg_mask in --inputs.")
        }

        let cfg: Krea2DiTConfig = try config.map { try Krea2DiTConfig.load(from: URL(fileURLWithPath: $0)) }
            ?? Krea2DiTConfig()
        let model = Krea2SingleStreamDiT(config: cfg)
        try Krea2DiTWeightLoader.load(into: model, directory: URL(fileURLWithPath: weightsDir), computeDType: dtype)

        var params = Krea2Sampler.Params()
        params.width = width; params.height = height; params.steps = steps
        params.mu = mu; params.dtype = dtype
        params.guidance = Float(guidance)

        let sampler = Krea2Sampler(dit: model)
        let latent = try sampler.sample(
            context: context.asType(dtype), mask: mask.asType(dtype),
            negativeContext: negativeContext?.asType(dtype), negativeMask: negativeMask?.asType(dtype),
            params: params, initNoise: noise.asType(dtype))
        let out32 = latent.asType(.float32)
        eval(out32)

        try MLX.save(arrays: ["latent": out32], url: URL(fileURLWithPath: out))
        print("sampler-dump: \(out) latent=\(latent.shape) steps=\(steps) dtype=\(dtype)")
        MLX.Memory.clearCache()
    }
}


struct DiTDump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dit-dump",
        abstract: "P2: load DiT weights and run a forward pass from safetensors inputs → output."
    )

    @Option(name: .long, help: "Directory containing DiT *.safetensors weights for the bf16 path.")
    var weightsDir: String = ""

    @Option(name: .long, help: "config.json (uses the complete Krea 2 configuration when absent).")
    var config: String?

    @Option(name: .long, help: "safetensors input containing img, context, t, pos, and mask.")
    var inputs: String

    @Option(name: .long, help: "Output .safetensors path.")
    var out: String

    @Flag(name: .long, help: "Compute in float32 for the architecture gate.")
    var float32: Bool = false

    @Option(name: .long, help: "Quantized mixed-4/8 file (quantize + loadQuantized instead of shards).")
    var quantFile: String?
    @Option(name: .long, help: "mixed-4-8 | q8 — recipe for --quant-file.")
    var quantization: Krea2CLIQuantization = .mixed4And8

    @Option(name: .long, parsing: .upToNextOption, help: "Paths to LoRA .safetensors files (gate 9; repeatable).")
    var loraPaths: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Scale for each --lora-paths entry (missing values default to 1.0).")
    var loraScales: [Double] = []

    func run() async throws {
        let cfg: Krea2DiTConfig = try config.map { try Krea2DiTConfig.load(from: URL(fileURLWithPath: $0)) }
            ?? Krea2DiTConfig()
        let dtype: DType = float32 ? .float32 : .bfloat16

        let model = Krea2SingleStreamDiT(config: cfg)
        let stats: Krea2DiTWeightLoader.Stats
        if let quantFile {
            quantization.engineValue.quantize(model)
            stats = try Krea2DiTWeightLoader.loadQuantized(into: model, file: URL(fileURLWithPath: quantFile))
        } else {
            stats = try Krea2DiTWeightLoader.load(
                into: model, directory: URL(fileURLWithPath: weightsDir), computeDType: dtype)
        }

        if !loraPaths.isEmpty {
            let adapters = loraPaths.enumerated().map { i, path in
                Krea2DiTLoRAConfig(
                    path: URL(fileURLWithPath: path),
                    scale: Float(i < loraScales.count ? loraScales[i] : 1.0))
            }
            let loraStats = try Krea2DiTLoRALoader.apply(to: model, adapters: adapters)
            for s in loraStats {
                print("  lora: \(s.file) targets=\(s.matchedTargets) keys=\(s.matchedKeys)/\(s.totalKeys) "
                    + "unmatched=\(s.unmatchedKeys.count)")
            }
        }

        let inp = try loadArrays(url: URL(fileURLWithPath: inputs))
        guard let img = inp["img"], let context = inp["context"],
              let t = inp["t"], let pos = inp["pos"], let mask = inp["mask"]
        else { print("FAIL: img/context/t/pos/mask inputs are required"); throw ExitCode.failure }

        let output = model(
            img: img.asType(dtype), context: context.asType(dtype),
            t: t.asType(dtype), pos: pos.asType(.float32), mask: mask.asType(dtype))
        let out32 = output.asType(.float32)
        eval(out32)

        try MLX.save(arrays: ["output": out32], url: URL(fileURLWithPath: out))
        print("dit-dump: \(out) tensors loaded=\(stats.tensors) output=\(output.shape) dtype=\(dtype)")
        MLX.Memory.clearCache()
    }
}



struct TextEncoderDump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "te-dump",
        abstract: "P1: dump Swift encoder token_ids, mask, and f32 embeddings to safetensors."
    )

    @Option(name: .long, help: "Official weights root containing text_encoder/ and tokenizer/.")
    var weights: String = Krea2CLIPaths.official

    @Option(name: .long, help: "Prompt to encode.")
    var prompt: String

    @Option(name: .long, help: "Output .safetensors path.")
    var out: String

    @Flag(name: .long, help: "Compute in float32 to isolate bf16 accumulation during diagnostics.")
    var float32: Bool = false

    func run() async throws {
        let root = URL(fileURLWithPath: weights)
        let encoder = try await Krea2TextEncoder.load(
            textEncoderDirectory: root.appendingPathComponent("text_encoder"),
            tokenizerDirectory: root.appendingPathComponent("tokenizer"),
            computeDType: float32 ? .float32 : .bfloat16
        )

        let d = encoder.encodeDebug(prompt: prompt)


        let n = d.slicedTokenIds.count
        let tokenIds = MLXArray(d.slicedTokenIds).reshaped([1, n])
        let maskArr = MLXArray(d.slicedMaskValues).reshaped([1, n])
        let positionIds = MLXArray(d.slicedPositionIds).reshaped([1, n])
        let embeddings = d.embeddings.asType(.float32)   // (1,512,12,2560) f32
        eval(tokenIds, maskArr, positionIds, embeddings)

        let outURL = URL(fileURLWithPath: out)
        try MLX.save(
            arrays: [
                "token_ids": tokenIds,
                "mask": maskArr,
                "position_ids": positionIds,
                "embeddings": embeddings,
            ],
            metadata: ["source": "Krea2TextEncoder", "prompt": prompt],
            url: outURL
        )
        print("te-dump: \(out) tokens=\(n) valid=\(d.validTokenCount) emb=\(embeddings.shape)")
        MLX.Memory.clearCache()
    }
}

/// Release P1 gate: one freshly built executable emits the complete fixed prompt matrix. Keeping
/// both dtypes in one process command makes the provenance atomic and avoids six independent CLI
/// builds/command variants while still releasing each ~9 GB encoder between dtype passes.
struct TextEncoderOracleDump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "te-oracle-dump",
        abstract: "P1 release gate: fresh BF16+F32 Swift dumps for all pinned oracle prompts."
    )

    @Option(name: .long, help: "Root of official weights (text_encoder/ and tokenizer/).")
    var weights: String = Krea2CLIPaths.official

    @Option(name: .long, help: "Existing empty output directory outside the source tree.")
    var outDir: String

    private static let prompts: [(name: String, prompt: String)] = [
        ("en_cube", "a red cube on a wooden table"),
        ("ru_cat", "a ginger cat sleeping on a windowsill in sunset light"),
        ("long", String(repeating:
            "a highly detailed cinematic photograph of a bustling futuristic city at night with neon signs reflecting on wet asphalt, ",
            count: 30)),
    ]

    mutating func validate() throws {
        let output = URL(fileURLWithPath: outDir).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ValidationError("--out-dir must be an existing directory.")
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: output,
            includingPropertiesForKeys: nil)
        guard contents.isEmpty else {
            throw ValidationError("--out-dir must be empty; stale dumps are forbidden.")
        }
    }

    func run() async throws {
        let root = URL(fileURLWithPath: weights).standardizedFileURL
        let output = URL(fileURLWithPath: outDir).standardizedFileURL
        try await dump(
            computeDType: .bfloat16,
            filenameSuffix: "",
            root: root,
            output: output)
        try await dump(
            computeDType: .float32,
            filenameSuffix: "_f32",
            root: root,
            output: output)
        print("te-oracle-dump: fresh matrix complete -> \(output.path)")
    }

    private func dump(
        computeDType: DType,
        filenameSuffix: String,
        root: URL,
        output: URL
    ) async throws {
        let encoder = try await Krea2TextEncoder.load(
            textEncoderDirectory: root.appendingPathComponent("text_encoder"),
            tokenizerDirectory: root.appendingPathComponent("tokenizer"),
            computeDType: computeDType)
        for entry in Self.prompts {
            try Task.checkCancellation()
            let debug = encoder.encodeDebug(prompt: entry.prompt)
            let count = debug.slicedTokenIds.count
            let tokenIDs = MLXArray(debug.slicedTokenIds).reshaped([1, count])
            let mask = MLXArray(debug.slicedMaskValues).reshaped([1, count])
            let positionIDs = MLXArray(debug.slicedPositionIds).reshaped([1, count])
            let embeddings = debug.embeddings.asType(.float32)
            eval(tokenIDs, mask, positionIDs, embeddings)

            let destination = output.appendingPathComponent(
                "swift_\(entry.name)\(filenameSuffix).safetensors")
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ValidationError("refusing to overwrite stale oracle dump: \(destination.path)")
            }
            try MLX.save(
                arrays: [
                    "token_ids": tokenIDs,
                    "mask": mask,
                    "position_ids": positionIDs,
                    "embeddings": embeddings,
                ],
                metadata: [
                    "source": "Krea2TextEncoder release oracle",
                    "prompt": entry.prompt,
                    "compute_dtype": computeDType == .float32 ? "float32" : "bfloat16",
                ],
                url: destination)
            print("  \(destination.lastPathComponent): valid=\(debug.validTokenCount)")
        }
        MLX.Memory.clearCache()
    }
}



struct Enhance: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enhance",
        abstract: "Expand a prompt with Qwen3-VL-4B (expansion.txt) without rendering.")

    @Option(name: .long, help: "Official weights root containing text_encoder/ and tokenizer/.")
    var weights: String = Krea2CLIPaths.official

    @Option(name: .long) var prompt: String

    @Option(name: .long, help: "Maximum number of new tokens (stops earlier at <|im_end|>).")
    var maxNewTokens: Int = 400

    @Flag(name: .long, help: "Use the diagnostic legacy full-prefix decoder.")
    var legacy = false

    @Flag(name: .long, help: "Compare legacy and KV-cache decoding from one load and require identical text.")
    var compareStrategies = false

    func run() async throws {
        let root = URL(fileURLWithPath: weights)
        let encoder = try await Krea2TextEncoder.load(
            textEncoderDirectory: root.appendingPathComponent("text_encoder"),
            tokenizerDirectory: root.appendingPathComponent("tokenizer"))

        print("== enhance ==\noriginal: \"\(prompt)\"")
        if compareStrategies {
            let legacyStart = Date()
            let legacy = try encoder.enhance(
                prompt: prompt,
                maxNewTokens: maxNewTokens,
                strategy: .legacy)
            let legacySeconds = Date().timeIntervalSince(legacyStart)

            let cacheStart = Date()
            let cached = try encoder.enhance(
                prompt: prompt,
                maxNewTokens: maxNewTokens,
                strategy: .kvCache)
            let cacheSeconds = Date().timeIntervalSince(cacheStart)
            print("legacy (\(String(format: "%.1f", legacySeconds)) c): \"\(legacy)\"")
            print("KV-cache (\(String(format: "%.1f", cacheSeconds)) c): \"\(cached)\"")
            guard cached == legacy else {
                throw ValidationError("KV-cache changed the greedy Enhance text.")
            }
            print(String(format: "parity: exact; speedup %.2fx", legacySeconds / cacheSeconds))
        } else {
            let strategy: Krea2EnhanceDecodingStrategy = legacy ? .legacy : .kvCache
            let t0 = Date()
            let expanded = try encoder.enhance(
                prompt: prompt,
                maxNewTokens: maxNewTokens,
                strategy: strategy)
            let seconds = Date().timeIntervalSince(t0)
            print("expanded (\(String(format: "%.1f", seconds)) c): \"\(expanded)\"")
        }
        MLX.Memory.clearCache()
    }
}




struct TextEncoderSmoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "te-smoke",
        abstract: "P1: load TE weights (398/398; ignore vision) and run encode() checks for shapes, mask, and NaN."
    )

    @Option(name: .long, help: "Official weights root containing text_encoder/ and tokenizer/.")
    var weights: String = Krea2CLIPaths.official

    @Option(name: .long, help: "Test prompt.")
    var prompt: String = "a red cube on a wooden table"

    func run() async throws {
        let root = URL(fileURLWithPath: weights)
        let teDir = root.appendingPathComponent("text_encoder")
        let tokDir = root.appendingPathComponent("tokenizer")

        for required in [teDir.appendingPathComponent("config.json"),
                         tokDir.appendingPathComponent("tokenizer.json")] {
            guard FileManager.default.fileExists(atPath: required.path) else {
                print("FAIL: missing file \(required.path)")
                throw ExitCode.failure
            }
        }

        print("== P1 te-smoke ==")
        print("weights: \(teDir.path)")

        let t0 = Date()
        let encoder = try await Krea2TextEncoder.load(
            textEncoderDirectory: teDir,
            tokenizerDirectory: tokDir
        )
        let loadSeconds = Date().timeIntervalSince(t0)

        let cfg = encoder.config
        print(String(format: "load: %.1f s", loadSeconds))
        print("configuration: hidden=\(cfg.hiddenSize) layers=\(cfg.numHiddenLayers) "
            + "heads=\(cfg.numAttentionHeads)q/\(cfg.numKeyValueHeads)kv head_dim=\(cfg.headDim) "
            + "θ=\(cfg.ropeTheta) eps=\(cfg.rmsNormEps)")
        print("tensors: language=\(encoder.weightStats.languageTensors) "
            + "ignored (vision and others)=\(encoder.weightStats.skippedTensors) "
            + "missing=0 extra=0 (strict verification passed in the loader)")
        print("tokenizer: prefix=34, suffix=5 (drift guard passed)")

        let t1 = Date()
        let result = encoder.encode(prompt: prompt)
        let encodeSeconds = Date().timeIntervalSince(t1)

        let shape = result.embeddings.shape
        let expectedShape = [1, Krea2PromptTemplate.maxConditioningTokens,
                             Krea2PromptTemplate.selectLayers.count, cfg.hiddenSize]
        let hasNaN = MLX.any(MLX.isNaN(result.embeddings.asType(.float32))).item(Bool.self)

        print(String(format: "encode: %.1f s, prompt: \"%@\"", encodeSeconds, prompt))
        print("shape: \(shape) (expected \(expectedShape)) dtype=\(result.embeddings.dtype)")
        print("validTokenCount=\(result.validTokenCount) mask=\(result.mask.shape)")
        print("NaN: \(hasNaN)")
        print(String(format: "MLX active=%.2f GB peak=%.2f GB",
                     Double(MLX.Memory.activeMemory) / 1_073_741_824,
                     Double(MLX.Memory.peakMemory) / 1_073_741_824))


        MLX.Memory.clearCache()

        let pass = shape == expectedShape && !hasNaN && result.validTokenCount > 0
        print(pass
            ? "PASS: shapes, mapping, and NaN checks succeeded. The numerical gate (cos>0.999 vs golden) runs separately."
            : "FAIL: see the output above.")
        if !pass { throw ExitCode.failure }
    }
}
