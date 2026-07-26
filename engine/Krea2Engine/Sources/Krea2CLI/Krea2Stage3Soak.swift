import ArgumentParser
import Darwin
import Foundation
import Krea2Core
import Krea2DiT
import Krea2Pipeline
import Krea2Sampler
import MLX

struct Krea2Stage3Soak: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stage3-soak",
        abstract: "Run 20–30 serial generations in one process and record post-cycle memory.")

    @Option(name: .long) var outDir: String
    @Option(name: .long) var count: Int = 20
    @Option(name: .long) var prompt = "A small matte red cube on a neutral studio background."
    @Option(name: .long) var width = 512
    @Option(name: .long) var height = 512
    @Option(name: .long) var steps = 8
    @Option(name: .long) var baseSeed: UInt64 = 30_000
    @Option(name: .long) var officialDir: String = Krea2CLIPaths.official
    @Option(name: .long) var ditQuant: String = Krea2CLIPaths.turboMixed
    @Option(name: .long) var vae: String = Krea2CLIPaths.vae
    @Option(name: .long) var loraPath: String?
    @Flag(name: .long, help: "Also cancel once at each engine phase before the full soak.")
    var cancellationProbes = false

    mutating func validate() throws {
        guard (20 ... 30).contains(count) else {
            throw ValidationError("--count must be in 20...30.")
        }
        try Generate.validateCanvas(width: width, height: height)
        try Generate.validateStepCount(steps)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--prompt must not be empty.")
        }
        let output = URL(fileURLWithPath: outDir).standardizedFileURL
        if FileManager.default.fileExists(atPath: output.path) {
            let contents = try FileManager.default.contentsOfDirectory(
                at: output,
                includingPropertiesForKeys: nil)
            guard contents.isEmpty else {
                throw ValidationError("--out-dir must be absent or empty.")
            }
        }
    }

    func run() async throws {
        let output = URL(fileURLWithPath: outDir).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reportURL = output.appendingPathComponent("stage3-soak-report.json")
        let baseWeights = Krea2Pipeline.Weights(
            officialDir: URL(fileURLWithPath: officialDir),
            ditQuantFile: URL(fileURLWithPath: ditQuant),
            vaeFile: URL(fileURLWithPath: vae),
            ditQuantization: .mixed4And8)

        var cancellations: [CancellationRecord] = []
        if cancellationProbes {
            for target in CancellationTarget.allCases {
                cancellations.append(try await runCancellationProbe(
                    target: target,
                    weights: baseWeights))
            }
        }

        var cycles: [Cycle] = []
        for index in 0 ..< count {
            try Task.checkCancellation()
            var params = Krea2Sampler.Params()
            params.width = width
            params.height = height
            params.steps = steps
            params.seed = baseSeed &+ UInt64(index)
            params.dtype = .bfloat16
            var weights = baseWeights
            if let loraPath, index.isMultiple(of: 2) {
                weights.loraAdapters = [
                    .init(path: URL(fileURLWithPath: loraPath), scale: 1),
                ]
            }

            let monitor = Krea2CLIOSMonitor()
            monitor.start()
            MLX.Memory.peakMemory = 0
            let started = Date()
            let pngURL = output.appendingPathComponent(
                String(format: "cycle-%02d-seed-%llu.png", index + 1, params.seed))
            let outputSHA256 = try await renderAndPersist(
                weights: weights,
                params: params,
                to: pngURL)
            Stream.cpu.synchronize()
            Stream.gpu.synchronize()
            MLX.Memory.clearCache()
            Stream.cpu.synchronize()
            Stream.gpu.synchronize()
            _ = malloc_zone_pressure_relief(nil, 0)
            let os = await monitor.stop()
            let mlx = MLX.Memory.snapshot()
            let cycle = Cycle(
                index: index + 1,
                seed: params.seed,
                usedLoRA: !weights.loraAdapters.isEmpty,
                seconds: Date().timeIntervalSince(started),
                output: pngURL.lastPathComponent,
                outputSHA256: outputSHA256,
                processPeakBytes: os.processPeakBytes,
                processFinalBytes: os.processFinalBytes,
                mlxPeakBytes: Int64(mlx.peakMemory),
                mlxActiveBytes: Int64(mlx.activeMemory),
                mlxCacheBytes: Int64(mlx.cacheMemory),
                swapIncreaseBytes: os.swapIncreaseBytes,
                memoryPressureWorst: os.memoryPressureWorst,
                thermalWorst: os.thermalWorst)
            cycles.append(cycle)
            try Report(
                status: "running",
                countRequested: count,
                width: width,
                height: height,
                steps: steps,
                cancellations: cancellations,
                cycles: cycles).write(to: reportURL)
            print("stage3 cycle \(index + 1)/\(count): final=\(os.processFinalBytes) "
                + "mlx-active=\(mlx.activeMemory) cache=\(mlx.cacheMemory)")
        }

        let report = Report(
            status: "complete",
            countRequested: count,
            width: width,
            height: height,
            steps: steps,
            cancellations: cancellations,
            cycles: cycles)
        try report.write(to: reportURL)
        guard report.passesMemoryPlateau else {
            throw ValidationError(
                "Post-warmup memory grew too quickly: slope \(Int64(report.finalSlopeBytesPerCycle)) bytes/cycle.")
        }
        print("stage3 soak passed: \(cycles.count) cycles, "
            + "post-warmup slope \(Int64(report.finalSlopeBytesPerCycle)) bytes/cycle")
    }

    /// Keep the returned MLX image and ImageIO autoreleased temporaries outside the post-cycle
    /// sample. Without this boundary the CLI harness itself looks like a leak even when the
    /// pipeline has released every model and cache.
    private func renderAndPersist(
        weights: Krea2Pipeline.Weights,
        params: Krea2Sampler.Params,
        to pngURL: URL
    ) async throws -> String {
        let image = try await Krea2Pipeline.generate(
            prompt: prompt,
            weights: weights,
            params: params)
        return try autoreleasepool {
            try Generate.writePNG(image, to: pngURL)
            return Krea2StableDigest.sha256(
                try Data(contentsOf: pngURL, options: .mappedIfSafe))
        }
    }

    private func runCancellationProbe(
        target: CancellationTarget,
        weights: Krea2Pipeline.Weights
    ) async throws -> CancellationRecord {
        var params = Krea2Sampler.Params()
        params.width = width
        params.height = height
        params.steps = steps
        params.seed = baseSeed &- UInt64(target.rawValue)
        let started = Date()
        let worker = Task { () throws -> Void in
            _ = try await Krea2Pipeline.generate(
                prompt: prompt,
                weights: weights,
                params: params,
                phaseCallback: { phase in
                    guard target.matches(phase) else { return }
                    withUnsafeCurrentTask { task in task?.cancel() }
                })
        }
        do {
            _ = try await worker.value
            throw ValidationError("Cancellation probe \(target.title) unexpectedly completed.")
        } catch is CancellationError {
            Stream.cpu.synchronize()
            Stream.gpu.synchronize()
            MLX.Memory.clearCache()
            return CancellationRecord(
                phase: target.title,
                seconds: Date().timeIntervalSince(started),
                recovered: true)
        }
    }
}

private extension Krea2Stage3Soak {
    enum CancellationTarget: Int, CaseIterable {
        case encodingPrompt = 1
        case loadingTransformer
        case denoising
        case decoding

        var title: String {
            switch self {
            case .encodingPrompt: "encodingPrompt"
            case .loadingTransformer: "loadingTransformer"
            case .denoising: "denoising"
            case .decoding: "decoding"
            }
        }

        func matches(_ phase: Krea2Pipeline.Phase) -> Bool {
            switch (self, phase) {
            case (.encodingPrompt, .encodingPrompt),
                 (.loadingTransformer, .loadingTransformer),
                 (.denoising, .denoising),
                 (.decoding, .decoding):
                true
            default:
                false
            }
        }
    }

    struct CancellationRecord: Encodable {
        let phase: String
        let seconds: Double
        let recovered: Bool
    }

    struct Cycle: Encodable {
        let index: Int
        let seed: UInt64
        let usedLoRA: Bool
        let seconds: Double
        let output: String
        let outputSHA256: String
        let processPeakBytes: Int64
        let processFinalBytes: Int64
        let mlxPeakBytes: Int64
        let mlxActiveBytes: Int64
        let mlxCacheBytes: Int64
        let swapIncreaseBytes: Int64
        let memoryPressureWorst: Int
        let thermalWorst: Int
    }

    struct Report: Encodable {
        let schema = "twisterminigen.stage3-soak"
        let version = 1
        let status: String
        let countRequested: Int
        let width: Int
        let height: Int
        let steps: Int
        let cancellations: [CancellationRecord]
        let cycles: [Cycle]

        var finalSlopeBytesPerCycle: Double {
            // The first three cycles may establish stable framework and allocator caches.
            let values = cycles.dropFirst(min(3, cycles.count)).map {
                Double($0.processFinalBytes)
            }
            guard values.count >= 2 else { return 0 }
            let xMean = Double(values.count - 1) / 2
            let yMean = values.reduce(0, +) / Double(values.count)
            var numerator = 0.0
            var denominator = 0.0
            for (index, value) in values.enumerated() {
                let x = Double(index) - xMean
                numerator += x * (value - yMean)
                denominator += x * x
            }
            return denominator == 0 ? 0 : numerator / denominator
        }

        var passesMemoryPlateau: Bool {
            guard cycles.count == countRequested, countRequested >= 20 else { return false }
            let postWarmup = cycles.dropFirst(min(3, cycles.count))
            guard let first = postWarmup.first, let last = postWarmup.last else { return false }
            let totalGrowth = last.processFinalBytes - first.processFinalBytes
            return finalSlopeBytesPerCycle <= Double(16 * 1_024 * 1_024)
                && totalGrowth <= Int64(512 * 1_024 * 1_024)
        }

        func write(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(self)
            data.append(0x0a)
            try data.write(to: url, options: .atomic)
        }

        private enum CodingKeys: String, CodingKey {
            case schema
            case version
            case status
            case countRequested
            case width
            case height
            case steps
            case cancellations
            case cycles
            case finalSlopeBytesPerCycle
            case passesMemoryPlateau
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schema, forKey: .schema)
            try container.encode(version, forKey: .version)
            try container.encode(status, forKey: .status)
            try container.encode(countRequested, forKey: .countRequested)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encode(steps, forKey: .steps)
            try container.encode(cancellations, forKey: .cancellations)
            try container.encode(cycles, forKey: .cycles)
            try container.encode(finalSlopeBytesPerCycle, forKey: .finalSlopeBytesPerCycle)
            try container.encode(passesMemoryPlateau, forKey: .passesMemoryPlateau)
        }
    }
}
