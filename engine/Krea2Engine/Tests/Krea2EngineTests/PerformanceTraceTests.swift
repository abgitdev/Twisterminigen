import Foundation
import Testing
@testable import Krea2Core

@Suite struct PerformanceTraceTests {
    @Test func canonicalPixelDigestHasStableDomainAndValidatesShape() throws {
        let bytes: [UInt8] = [0, 1, 2, 253, 254, 255]
        let digest = try Krea2CanonicalPixelDigest.make(width: 2, height: 1, rgb8: bytes)

        #expect(digest.algorithm == "sha256")
        #expect(digest.pixelFormat == "rgb8-hwc-clamped-truncate-v1")
        #expect(digest.value == "a3c80acb96431582f34503b217dc43c6b0ae855e508d60e9ff7c3eaf910beb69")
        #expect(
            try Krea2CanonicalPixelDigest.make(width: 1, height: 2, rgb8: bytes).value
                != digest.value
        )

        do {
            _ = try Krea2CanonicalPixelDigest.make(width: 0, height: 1, rgb8: [])
            Issue.record("Expected invalid dimensions to fail")
        } catch let error as Krea2PixelDigestError {
            #expect(error == .invalidDimensions(width: 0, height: 1))
        }

        do {
            _ = try Krea2CanonicalPixelDigest.make(width: 2, height: 1, rgb8: [0])
            Issue.record("Expected an invalid byte count to fail")
        } catch let error as Krea2PixelDigestError {
            #expect(error == .invalidByteCount(expected: 6, actual: 1))
        }
    }

    @Test func traceRecordsOwnedSpansValidatedStepsAndChronologicalSnapshots() throws {
        let clock = SequenceClock(nanoseconds: stride(from: 100, through: 1_100, by: 100))
        let trace = Krea2PerformanceTrace(runID: "run-a", now: clock.next)
        let root = trace.beginSpan("root")
        _ = trace.transition(to: "encode", in: "pipeline", parent: root)
        trace.beginStepSequence(phase: "denoise", totalSteps: 2, in: "denoise")

        #expect(trace.completeStep(1, totalSteps: 2, in: "denoise")?.durationNanoseconds == 100)
        #expect(trace.completeStep(2, totalSteps: 9, in: "denoise") == nil)
        #expect(trace.completeStep(2, totalSteps: 2, in: "denoise")?.durationNanoseconds == 200)
        #expect(trace.completeStep(2, totalSteps: 2, in: "denoise") == nil)

        trace.recordMemory(phase: "denoise", memory: Self.memory(active: 7))
        _ = trace.transition(to: "decode", in: "pipeline", parent: root)
        #expect(trace.finishSequence(in: "pipeline")?.durationNanoseconds == 100)
        #expect(trace.endSpan(root)?.durationNanoseconds == 1_000)

        let snapshot = trace.snapshot()
        #expect(snapshot.spans.map(\.name) == ["root", "encode", "decode"])
        #expect(snapshot.spans.map(\.startedNanoseconds) == [100, 200, 900])
        #expect(snapshot.spans.dropFirst().allSatisfy { $0.parentSequence == root.sequence })
        #expect(snapshot.stepDurations.map(\.stepIndex) == [1, 2])
        #expect(snapshot.stepDurations.map(\.durationNanoseconds) == [100, 200])
        #expect(snapshot.memorySamples.map(\.sequence) == [0])
        #expect(snapshot.memorySamples[0].elapsedNanoseconds == 800)
    }

    @Test func spanTokensCannotCloseOrParentAnotherTrace() {
        let firstClock = SequenceClock(nanoseconds: [100, 300])
        let secondClock = SequenceClock(nanoseconds: [200, 400, 500, 600, 700])
        let first = Krea2PerformanceTrace(runID: "first", now: firstClock.next)
        let second = Krea2PerformanceTrace(runID: "second", now: secondClock.next)
        let firstRoot = first.beginSpan("first-root")
        let secondRoot = second.beginSpan("second-root")

        #expect(second.endSpan(firstRoot) == nil)
        let child = second.beginSpan("child", parent: firstRoot)
        #expect(second.endSpan(child)?.parentSequence == nil)
        #expect(first.endSpan(firstRoot) != nil)
        #expect(second.endSpan(secondRoot) != nil)
    }

    @Test func memorySummaryUsesFinalSampleAndMaximaRegardlessOfInputOrder() {
        let baseline = Self.sample(
            sequence: 0,
            kind: .baseline,
            active: 10,
            cache: 20,
            mlxPeak: 30,
            footprint: 100,
            swap: 4
        )
        let phase = Self.sample(
            sequence: 1,
            kind: .phase,
            active: 40,
            cache: 50,
            mlxPeak: 90,
            footprint: 300,
            swap: 12
        )
        let final = Self.sample(
            sequence: 2,
            kind: .final,
            active: 60,
            cache: 70,
            mlxPeak: 80,
            footprint: 200,
            swap: 8
        )
        let process = Krea2ProcessMemorySummary(
            processBaselineBytes: 90,
            processPeakBytes: 250,
            processFinalBytes: 180,
            swapBaselineBytes: 3,
            swapPeakBytes: 10,
            swapDeltaBytes: 7
        )

        let summary = Krea2MemorySummary(
            phaseSamples: [final, baseline, phase],
            processSummary: process
        )

        #expect(summary.mlxActiveBytes == 60)
        #expect(summary.mlxCacheBytes == 70)
        #expect(summary.mlxPeakBytes == 90)
        #expect(summary.processPeakBytes == 300)
        #expect(summary.swapPeakBytes == 12)
        #expect(summary.swapDeltaBytes == 9)
    }

    @Test func baselineGateSeparatesCompatibilityFromCanonicalQuality() throws {
        let baseline = Self.report(engineRevision: "baseline", runID: "baseline-run")
        var candidate = Self.report(engineRevision: "candidate", runID: "candidate-run")
        candidate.generatedAt = "2026-07-11T01:00:00.000Z"
        candidate.runs[0].cacheHit = true
        candidate.runs[0].memorySummary.mlxPeakBytes = 999

        try candidate.validateBaselineCompatibility(with: baseline)
        try candidate.validateBaseline(with: baseline)

        var wrongModel = candidate
        wrongModel.model.revision = "different-model"
        #expect(
            Self.baselineError { try wrongModel.validateBaselineCompatibility(with: baseline) }
                == .modelMismatch
        )

        var wrongConfiguration = candidate
        wrongConfiguration.runs[0].identity.seed += 1
        #expect(
            Self.baselineError {
                try wrongConfiguration.validateBaselineCompatibility(with: baseline)
            } == .runConfigurationMismatch(index: 0)
        )

        var wrongPixels = candidate
        wrongPixels.runs[0].canonicalPixelDigest.value = String(repeating: "f", count: 64)
        try wrongPixels.validateBaselineCompatibility(with: baseline)
        #expect(
            Self.baselineError { try wrongPixels.validateBaseline(with: baseline) }
                == .canonicalPixelDigestMismatch(index: 0)
        )
    }

    @Test func jsonIsVersionedCanonicalSortedAndAtomicallyReplaceable() throws {
        let later = Self.run(ordinal: 1, runID: "later", seed: 2)
        var earlier = Self.run(ordinal: 0, runID: "earlier", seed: 1)
        earlier.spans = [
            Krea2PerformanceSpan(
                runID: "earlier",
                sequence: 2,
                parentSequence: nil,
                name: "later-span",
                startedNanoseconds: 20,
                durationNanoseconds: 1
            ),
            Krea2PerformanceSpan(
                runID: "earlier",
                sequence: 1,
                parentSequence: nil,
                name: "earlier-span",
                startedNanoseconds: 10,
                durationNanoseconds: 1
            ),
        ]
        var report = Self.report(runs: [later, earlier])

        let firstEncoding = try Krea2PerformanceReportJSON.encode(report)
        #expect(firstEncoding == (try Krea2PerformanceReportJSON.encode(report)))
        #expect(firstEncoding.last == 0x0A)
        let decoded = try Krea2PerformanceReportJSON.decode(firstEncoding)
        #expect(decoded.runs.map(\.identity.ordinal) == [0, 1])
        #expect(decoded.runs[0].spans.map(\.sequence) == [1, 2])

        let json = String(decoding: firstEncoding, as: UTF8.self)
        let benchmarkKey = try #require(json.range(of: "\"benchmarkVersion\""))
        let schemaKey = try #require(json.range(of: "\"schemaVersion\""))
        #expect(benchmarkKey.lowerBound < schemaKey.lowerBound)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Krea2PerformanceTraceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportURL = directory.appendingPathComponent("report.json")

        try Krea2PerformanceReportJSON.write(report, to: reportURL)
        report.generatedAt = "2026-07-11T02:00:00.000Z"
        try Krea2PerformanceReportJSON.write(report, to: reportURL)
        #expect(try Krea2PerformanceReportJSON.read(from: reportURL) == report.canonicalized())
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["report.json"])

        var unsupported = report
        unsupported.benchmarkVersion += 1
        #expect(
            Self.baselineError { _ = try Krea2PerformanceReportJSON.encode(unsupported) }
                == .unsupportedBenchmarkVersion(unsupported.benchmarkVersion)
        )
    }

    private static func report(
        engineRevision: String = "engine",
        runID: String = "run",
        runs: [Krea2BenchmarkRunReport]? = nil
    ) -> Krea2PerformanceReport {
        Krea2PerformanceReport(
            generatedAt: "2026-07-11T00:00:00.000Z",
            environment: Krea2BenchmarkEnvironment(
                operatingSystem: "macOS 26.0",
                architecture: "arm64",
                hardwareModel: "Mac16,10",
                processorCount: 10,
                physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
                engineRevision: engineRevision,
                mlxVersion: "0.30.6"
            ),
            model: Krea2BenchmarkModelIdentity(
                family: "krea-2",
                checkpoint: "turbo",
                revision: "model-revision",
                quantization: "mixed-4-8",
                artifactName: "krea2.safetensors",
                artifactDigest: String(repeating: "a", count: 64)
            ),
            runs: runs ?? [Self.run(ordinal: 0, runID: runID, seed: 13_711)]
        )
    }

    private static func run(ordinal: Int, runID: String, seed: UInt64) -> Krea2BenchmarkRunReport {
        let prompt = "A fixed benchmark prompt."
        return Krea2BenchmarkRunReport(
            identity: Krea2BenchmarkRunIdentity(
                id: runID,
                ordinal: ordinal,
                benchmarkCase: "512",
                promptKind: "short",
                prompt: prompt,
                promptDigest: Krea2StableDigest.sha256(utf8: prompt),
                seed: seed,
                width: 512,
                height: 512,
                steps: 8,
                workloadSize: 1,
                queueDepth: 1,
                executionMode: .single,
                filesystemCacheState: .uncontrolled
            ),
            cacheHit: false,
            canonicalPixelDigest: Krea2CanonicalPixelDigest(
                value: "a3c80acb96431582f34503b217dc43c6b0ae855e508d60e9ff7c3eaf910beb69"
            ),
            spans: [],
            stepDurations: [],
            memorySamples: [],
            memorySummary: Self.memorySummary()
        )
    }

    private static func memory(active: Int64) -> Krea2MemorySnapshot {
        Krea2MemorySnapshot(
            mlx: Krea2MLXMemorySnapshot(activeBytes: active, cacheBytes: 0, peakBytes: active),
            process: Krea2ProcessMemorySnapshot(footprintBytes: 0, swapUsedBytes: 0)
        )
    }

    private static func sample(
        sequence: Int,
        kind: Krea2MemorySampleKind,
        active: Int64,
        cache: Int64,
        mlxPeak: Int64,
        footprint: Int64,
        swap: Int64
    ) -> Krea2PhaseMemorySample {
        Krea2PhaseMemorySample(
            runID: "run",
            sequence: sequence,
            phase: kind.rawValue,
            kind: kind,
            elapsedNanoseconds: Int64(sequence),
            memory: Krea2MemorySnapshot(
                mlx: Krea2MLXMemorySnapshot(
                    activeBytes: active,
                    cacheBytes: cache,
                    peakBytes: mlxPeak
                ),
                process: Krea2ProcessMemorySnapshot(
                    footprintBytes: footprint,
                    swapUsedBytes: swap
                )
            )
        )
    }

    private static func memorySummary() -> Krea2MemorySummary {
        Krea2MemorySummary(
            mlxActiveBytes: 0,
            mlxCacheBytes: 0,
            mlxPeakBytes: 0,
            processBaselineBytes: 0,
            processPeakBytes: 0,
            processFinalBytes: 0,
            swapBaselineBytes: 0,
            swapPeakBytes: 0,
            swapDeltaBytes: 0
        )
    }

    private static func baselineError(
        _ operation: () throws -> Void
    ) -> Krea2BaselineCompatibilityError? {
        do {
            try operation()
            return nil
        } catch let error as Krea2BaselineCompatibilityError {
            return error
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }
}

private final class SequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [Duration]
    private var index = 0

    init<S: Sequence>(nanoseconds: S) where S.Element == Int {
        values = nanoseconds.map(Duration.nanoseconds)
    }

    func next() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        precondition(index < values.count, "Test clock exhausted")
        defer { index += 1 }
        return values[index]
    }
}
