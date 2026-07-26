import ArgumentParser
import Foundation
import Krea2Core
import Krea2Pipeline
import Krea2Sampler
import MLX

enum Krea2BenchmarkCase: String, CaseIterable, ExpressibleByArgument {
    case square512 = "512"
    case square1024 = "1024"
    case landscape1280x720 = "1280x720"
    case short
    case long
    case repeatRun = "repeat"
    case batch4
    case queue4
}

struct Krea2Benchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark",
        abstract: "Run one explicit safe benchmark case and atomically write its JSON report.")

    @Option(
        name: .customLong("case"),
        help: "Required benchmark case: \(Krea2BenchmarkCase.allCases.map(\.rawValue).joined(separator: ", ")).")
    var selectedCase: Krea2BenchmarkCase

    @Option(name: .customLong("output"), help: "Required destination for the benchmark JSON report.")
    var outputPath: String

    @Option(
        name: .customLong("baseline"),
        help: "Optional compatible report whose canonical pixel digests must match.")
    var baselinePath: String?

    @Option(name: .long, help: "Official model directory containing text_encoder/ and tokenizer/.")
    var officialDir: String

    @Option(name: .long, help: "Mixed quantized transformer artifact.")
    var ditQuant: String

    @Option(name: .long, help: "VAE safetensors artifact.")
    var vae: String

    @Option(name: .long, help: "Model revision recorded in the report identity.")
    var modelRevision: String

    @Option(name: .long, help: "Required precomputed SHA-256 of the transformer artifact.")
    var modelDigest: String

    @Option(name: .long, help: "Engine revision recorded in the environment identity.")
    var engineRevision: String = "working-tree"

    @Option(name: .long, help: "Linked MLX version recorded in the environment identity.")
    var mlxVersion: String = "0.31.6"

    mutating func validate() throws {
        guard !outputPath.isEmpty else {
            throw ValidationError("--output must not be empty.")
        }
        guard URL(fileURLWithPath: outputPath).pathExtension.lowercased() == "json" else {
            throw ValidationError("--output must name a .json file.")
        }
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        try Self.requireDirectory(outputURL.deletingLastPathComponent(), option: "--output parent")

        if let baselinePath {
            let baselineURL = URL(fileURLWithPath: baselinePath).standardizedFileURL
            guard baselineURL.pathExtension.lowercased() == "json" else {
                throw ValidationError("--baseline must name a .json file.")
            }
            try Self.requireFile(baselineURL, option: "--baseline")
            guard baselineURL.resolvingSymlinksInPath()
                    != outputURL.resolvingSymlinksInPath()
            else {
                throw ValidationError("--baseline and --output must be different files.")
            }
        }

        try Self.requireDirectory(
            URL(fileURLWithPath: officialDir).standardizedFileURL,
            option: "--official-dir")
        try Self.requireFile(
            URL(fileURLWithPath: ditQuant).standardizedFileURL,
            option: "--dit-quant")
        try Self.requireFile(
            URL(fileURLWithPath: vae).standardizedFileURL,
            option: "--vae")

        guard !modelRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--model-revision must not be empty.")
        }
        modelDigest = modelDigest.lowercased()
        guard modelDigest.count == 64,
              modelDigest.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              })
        else {
            throw ValidationError("--model-digest must be a 64-character SHA-256 hex digest.")
        }
        guard !engineRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--engine-revision must not be empty.")
        }
        guard !mlxVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--mlx-version must not be empty.")
        }
    }

    func run() async throws {
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        let baseline = try baselinePath.map {
            try Krea2PerformanceReportJSON.read(
                from: URL(fileURLWithPath: $0).standardizedFileURL)
        }
        let weights = Krea2Pipeline.Weights(
            officialDir: URL(fileURLWithPath: officialDir),
            ditQuantFile: URL(fileURLWithPath: ditQuant),
            vaeFile: URL(fileURLWithPath: vae),
            verifiedModelIdentity: Krea2StableDigest.sha256(
                utf8: "\(modelRevision)|\(modelDigest)"))
        let conditioningCache = Krea2ConditioningCache()
        let items = Self.workItems(for: selectedCase)
        var runs: [Krea2BenchmarkRunReport] = []
        runs.reserveCapacity(items.count)

        print("== benchmark \(selectedCase.rawValue) ==")
        print("filesystem cache state: uncontrolled")
        if items.count > 1 {
            print("planned group: \(items.count) resident-sequential jobs")
            runs = try await runPlannedGroup(
                items: items,
                weights: weights,
                conditioningCache: conditioningCache)
        } else {
            for item in items {
                print("run \(item.ordinal + 1)/\(items.count): \(item.width)x\(item.height), seed \(item.seed)")
                runs.append(try await run(
                    item: item,
                    weights: weights,
                    conditioningCache: conditioningCache))
            }
        }

        let report = Krea2PerformanceReport(
            generatedAt: Self.timestamp(),
            environment: .current(engineRevision: engineRevision, mlxVersion: mlxVersion),
            model: Krea2BenchmarkModelIdentity(
                family: "krea-2",
                checkpoint: "turbo",
                revision: modelRevision,
                quantization: "mixed-4-8",
                artifactName: URL(fileURLWithPath: ditQuant).lastPathComponent,
                artifactDigest: modelDigest),
            runs: runs)
        try Krea2PerformanceReportJSON.write(report, to: outputURL)
        print("report: \(outputURL.path)")
        if let baseline {
            try report.validateBaseline(with: baseline)
            print("baseline: compatible; canonical pixels match")
        }
    }

    private func run(
        item: WorkItem,
        weights: Krea2Pipeline.Weights,
        conditioningCache: Krea2ConditioningCache
    ) async throws -> Krea2BenchmarkRunReport {
        let runID = UUID().uuidString.lowercased()
        let trace = Krea2PerformanceTrace(runID: runID)
        let processMonitor = Krea2ProcessMemoryMonitor()
        processMonitor.start()
        MLX.Memory.peakMemory = 0

        let root = trace.beginSpan("benchmark-run")
        trace.recordMemory(
            phase: "baseline",
            kind: .baseline,
            memory: Krea2MemorySampler.capturePhase())

        do {
            var cacheEvent = Krea2Pipeline.ConditioningCacheEvent.disabled
            var params = Krea2Sampler.Params()
            params.width = item.width
            params.height = item.height
            params.steps = Krea2Constants.defaultSteps
            params.seed = item.seed
            params.dtype = .bfloat16

            let pixels = try await Krea2Pipeline.generate(
                prompt: item.prompt,
                weights: weights,
                params: params,
                conditioningCache: conditioningCache,
                cacheEventCallback: { cacheEvent = $0 },
                performanceStageCallback: { stage in
                    let phase = "pipeline.\(stage.rawValue)"
                    trace.transition(to: phase, in: "pipeline-detail", parent: root)
                    trace.recordMemory(
                        phase: "\(phase)-start",
                        memory: Krea2MemorySampler.capturePhase())
                },
                phaseCallback: { phase in
                    let phaseName = Self.phaseName(phase)
                    trace.transition(to: phaseName, in: "pipeline", parent: root)
                    trace.recordMemory(
                        phase: "\(phaseName)-start",
                        memory: Krea2MemorySampler.capturePhase())
                    if case .denoising = phase {
                        trace.beginStepSequence(
                            phase: "denoise",
                            totalSteps: params.steps,
                            in: "denoise")
                    }
                },
                stepCallback: { step, total in
                    trace.completeStep(step, totalSteps: total, in: "denoise")
                })

            trace.transition(to: "canonical-pixel-digest", in: "pipeline", parent: root)
            trace.finishSequence(in: "pipeline-detail")
            trace.recordMemory(
                phase: "pipeline-complete",
                memory: Krea2MemorySampler.capturePhase())
            let pixelDigest = try Self.canonicalPixelDigest(pixels)
            trace.finishSequence(in: "pipeline")
            trace.recordMemory(
                phase: "final",
                kind: .final,
                memory: Krea2MemorySampler.capturePhase())
            trace.endSpan(root)

            let processSummary = await processMonitor.stop()
            let snapshot = trace.snapshot()
            return Krea2BenchmarkRunReport(
                identity: Self.identity(for: item, runID: runID),
                cacheHit: cacheEvent == .hit,
                canonicalPixelDigest: pixelDigest,
                spans: snapshot.spans,
                stepDurations: snapshot.stepDurations,
                memorySamples: snapshot.memorySamples,
                memorySummary: Krea2MemorySummary(
                    phaseSamples: snapshot.memorySamples,
                    processSummary: processSummary))
        } catch {
            trace.finishSequence(in: "pipeline")
            trace.finishSequence(in: "pipeline-detail")
            trace.recordMemory(
                phase: "failed",
                kind: .final,
                memory: Krea2MemorySampler.capturePhase())
            trace.endSpan(root)
            _ = await processMonitor.stop()
            throw error
        }
    }

    private func runPlannedGroup(
        items: [WorkItem],
        weights: Krea2Pipeline.Weights,
        conditioningCache: Krea2ConditioningCache
    ) async throws -> [Krea2BenchmarkRunReport] {
        let runID = UUID().uuidString.lowercased()
        let trace = Krea2PerformanceTrace(runID: runID)
        let processMonitor = Krea2ProcessMemoryMonitor()
        processMonitor.start()
        MLX.Memory.peakMemory = 0

        let root = trace.beginSpan("benchmark-planned-group")
        trace.recordMemory(
            phase: "baseline",
            kind: .baseline,
            memory: Krea2MemorySampler.capturePhase())

        do {
            let requests = items.map { item in
                var params = Krea2Sampler.Params()
                params.width = item.width
                params.height = item.height
                params.steps = Krea2Constants.defaultSteps
                params.seed = item.seed
                params.dtype = .bfloat16
                return Krea2Pipeline.PlannedRequest(prompt: item.prompt, params: params)
            }
            var cacheEvents = [Krea2Pipeline.ConditioningCacheEvent](
                repeating: .disabled,
                count: items.count)
            let outputs = try await Krea2Pipeline.generatePlanned(
                requests: requests,
                weights: weights,
                conditioningCache: conditioningCache,
                cacheEventCallback: { index, event in
                    cacheEvents[index] = event
                },
                performanceStageCallback: { stage in
                    let phase = "pipeline.\(stage.rawValue)"
                    trace.transition(to: phase, in: "pipeline-detail", parent: root)
                    trace.recordMemory(
                        phase: "\(phase)-start",
                        memory: Krea2MemorySampler.capturePhase())
                },
                phaseCallback: { phase in
                    let phaseName = Self.phaseName(phase)
                    trace.transition(to: phaseName, in: "pipeline", parent: root)
                    trace.recordMemory(
                        phase: "\(phaseName)-start",
                        memory: Krea2MemorySampler.capturePhase())
                },
                itemPhaseCallback: { index, phase in
                    if case .denoising = phase {
                        trace.beginStepSequence(
                            phase: "denoise-\(index)",
                            totalSteps: requests[index].params.steps,
                            in: "denoise-\(index)")
                    }
                },
                itemStepCallback: { index, step, total in
                    trace.completeStep(
                        step,
                        totalSteps: total,
                        in: "denoise-\(index)")
                })

            trace.finishSequence(in: "pipeline")
            trace.finishSequence(in: "pipeline-detail")
            trace.recordMemory(
                phase: "pipeline-complete",
                memory: Krea2MemorySampler.capturePhase())
            let digests = try Dictionary(uniqueKeysWithValues: outputs.map { output in
                (output.requestIndex, try Self.canonicalPixelDigest(output.pixels))
            })
            trace.recordMemory(
                phase: "final",
                kind: .final,
                memory: Krea2MemorySampler.capturePhase())
            trace.endSpan(root)

            let processSummary = await processMonitor.stop()
            let snapshot = trace.snapshot()
            let memory = Krea2MemorySummary(
                phaseSamples: snapshot.memorySamples,
                processSummary: processSummary)
            return try items.indices.map { index in
                guard let digest = digests[index] else {
                    throw ValidationError("Planned output \(index) is missing.")
                }
                return Krea2BenchmarkRunReport(
                    identity: Self.identity(for: items[index], runID: runID),
                    cacheHit: cacheEvents[index] == .hit,
                    canonicalPixelDigest: digest,
                    spans: snapshot.spans,
                    stepDurations: snapshot.stepDurations,
                    memorySamples: snapshot.memorySamples,
                    memorySummary: memory)
            }
        } catch {
            trace.finishSequence(in: "pipeline")
            trace.finishSequence(in: "pipeline-detail")
            trace.recordMemory(
                phase: "failed",
                kind: .final,
                memory: Krea2MemorySampler.capturePhase())
            trace.endSpan(root)
            _ = await processMonitor.stop()
            throw error
        }
    }

    private static func identity(for item: WorkItem, runID: String) -> Krea2BenchmarkRunIdentity {
        Krea2BenchmarkRunIdentity(
            id: runID,
            ordinal: item.ordinal,
            benchmarkCase: item.benchmarkCase.rawValue,
            promptKind: item.promptKind,
            prompt: item.prompt,
            promptDigest: Krea2StableDigest.sha256(utf8: item.prompt),
            seed: item.seed,
            width: item.width,
            height: item.height,
            steps: Krea2Constants.defaultSteps,
            workloadSize: item.workloadSize,
            queueDepth: item.queueDepth,
            executionMode: item.workloadSize == 1 ? .single : .sequential,
            filesystemCacheState: item.filesystemCacheState)
    }

    private static func canonicalPixelDigest(_ pixels: MLXArray) throws -> Krea2CanonicalPixelDigest {
        let shape = pixels.shape
        guard shape.count == 4, shape[0] == 1, shape[1] == 3 else {
            throw ValidationError("Pipeline returned pixels with unexpected shape \(shape).")
        }
        let height = shape[2]
        let width = shape[3]
        let hwc = pixels[0].transposed(1, 2, 0)
        let rgb8 = clip(hwc * 255, min: 0, max: 255).asType(.uint8)
        eval(rgb8)
        return try Krea2CanonicalPixelDigest.make(
            width: width,
            height: height,
            rgb8: rgb8.asArray(UInt8.self))
    }

    private static func phaseName(_ phase: Krea2Pipeline.Phase) -> String {
        switch phase {
        case .encodingPrompt: "text-encoding"
        case .encodingImage: "image-encoding"
        case .loadingTransformer: "transformer-load"
        case .denoising: "denoise"
        case .decoding: "vae-decode"
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static let baseSeed: UInt64 = 13_711
    private static let shortPrompt = "A glossy red sphere on a matte black table, soft studio light."
    private static let secondShortPrompt = "A blue ceramic cup beside a folded white linen napkin."
    private static let landscapePrompt = "A quiet coastal road at sunrise, low clouds, crisp natural detail."
    private static let longPrompt = "A precise editorial photograph of a hand-built reading room at dusk, "
        + "with walnut shelves, green wool upholstery, rain on tall windows, and warm practical lamps. "
        + "Use a balanced wide composition, natural material texture, restrained contrast, and no visible text."

    private static func workItems(for benchmarkCase: Krea2BenchmarkCase) -> [WorkItem] {
        let definitions: [(String, String, Int, Int, UInt64)]
        let queueDepth: Int
        switch benchmarkCase {
        case .square512:
            definitions = [(shortPrompt, "short", 512, 512, baseSeed)]
            queueDepth = 1
        case .square1024:
            definitions = [(shortPrompt, "short", 1024, 1024, baseSeed)]
            queueDepth = 1
        case .landscape1280x720:
            definitions = [(landscapePrompt, "short", 1280, 720, baseSeed)]
            queueDepth = 1
        case .short:
            definitions = [(shortPrompt, "short", 1024, 1024, baseSeed)]
            queueDepth = 1
        case .long:
            definitions = [(longPrompt, "long", 1024, 1024, baseSeed)]
            queueDepth = 1
        case .repeatRun:
            definitions = [
                (shortPrompt, "short", 512, 512, baseSeed),
                (shortPrompt, "short", 512, 512, baseSeed + 1),
            ]
            queueDepth = 1
        case .batch4:
            definitions = (0 ..< 4).map {
                (shortPrompt, "short", 512, 512, baseSeed + UInt64($0))
            }
            queueDepth = 1
        case .queue4:
            definitions = [
                (shortPrompt, "short", 512, 512, baseSeed),
                (secondShortPrompt, "short", 512, 512, baseSeed + 1),
                (shortPrompt, "short", 512, 512, baseSeed + 2),
                (secondShortPrompt, "short", 512, 512, baseSeed + 3),
            ]
            queueDepth = 4
        }

        return definitions.enumerated().map { ordinal, definition in
            WorkItem(
                ordinal: ordinal,
                benchmarkCase: benchmarkCase,
                prompt: definition.0,
                promptKind: definition.1,
                width: definition.2,
                height: definition.3,
                seed: definition.4,
                workloadSize: definitions.count,
                queueDepth: queueDepth,
                filesystemCacheState: ordinal == 0 ? .uncontrolled : .processWarm)
        }
    }

    private struct WorkItem {
        let ordinal: Int
        let benchmarkCase: Krea2BenchmarkCase
        let prompt: String
        let promptKind: String
        let width: Int
        let height: Int
        let seed: UInt64
        let workloadSize: Int
        let queueDepth: Int
        let filesystemCacheState: Krea2FilesystemCacheState
    }

    private static func requireDirectory(_ url: URL, option: String) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ValidationError("\(option) must name an existing directory: \(url.path)")
        }
    }

    private static func requireFile(_ url: URL, option: String) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw ValidationError("\(option) must name an existing file: \(url.path)")
        }
    }
}
