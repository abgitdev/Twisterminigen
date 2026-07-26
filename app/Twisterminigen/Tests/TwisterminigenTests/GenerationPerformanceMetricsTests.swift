import Foundation
import Testing
@testable import Twisterminigen

@Suite("Generation performance metrics")
struct GenerationPerformanceMetricsTests {
    @Test("Named monitor phases map to explicit TE, DiT, and VAE fields")
    func phaseMapping() throws {
        let metrics = GenerationPerformanceMetrics(
            sessionItemCount: 3,
            phaseDurations: [
                "preparing": .milliseconds(250),
                "encodingPrompt": .seconds(2),
                "encodingImage": .milliseconds(500),
                "loadingTransformer": .seconds(3),
                "denoising": .seconds(12),
                "decoding": .seconds(4),
                "encodingPNG": .milliseconds(750),
                "futurePhase": .seconds(99),
            ],
            processBaselineBytes: 100,
            processPeakBytes: 500,
            processFinalBytes: 300,
            mlxPeakBytes: 400,
            mlxActiveBytes: 250,
            mlxCacheBytes: 100,
            swapBaselineBytes: 10,
            swapPeakBytes: 30,
            swapFinalBytes: 20,
            worstMemoryPressure: .warning,
            thermalBaselineState: 0,
            worstThermalState: 2,
            thermalFinalState: 1)

        try metrics.validate()
        #expect(metrics.scope == .plannedSession)
        #expect(metrics.sessionItemCount == 3)
        #expect(metrics.preparationSeconds == 0.25)
        #expect(metrics.textEncoderSeconds == 2)
        #expect(metrics.imageEncoderSeconds == 0.5)
        #expect(metrics.transformerLoadSeconds == 3)
        #expect(metrics.denoisingSeconds == 12)
        #expect(metrics.vaeDecodeSeconds == 4)
        #expect(metrics.pngEncodingSeconds == 0.75)
        #expect(metrics.measuredPhaseSeconds == 22.5)
        #expect(metrics.swapIncreaseBytes == 20)
        #expect(metrics.worstThermalState == 2)
        #expect(GenerationPerformanceMetrics.thermalStateTitle(2) == "Serious")
    }

    @Test("Validation rejects inconsistent or non-finite evidence")
    func validation() {
        let invalidScope = metrics(sessionItemCount: 0)
        #expect(throws: GenerationPerformanceMetrics.ValidationError.invalidSessionItemCount(0)) {
            try invalidScope.validate()
        }

        let invalidTiming = GenerationPerformanceMetrics(
            sessionItemCount: 1,
            preparationSeconds: .nan,
            textEncoderSeconds: 0,
            imageEncoderSeconds: 0,
            transformerLoadSeconds: 0,
            denoisingSeconds: 0,
            vaeDecodeSeconds: 0,
            pngEncodingSeconds: 0,
            processBaselineBytes: 0,
            processPeakBytes: 0,
            processFinalBytes: 0,
            mlxPeakBytes: 0,
            mlxActiveBytes: 0,
            mlxCacheBytes: 0,
            swapBaselineBytes: 0,
            swapPeakBytes: 0,
            swapFinalBytes: 0,
            worstMemoryPressure: .normal)
        #expect(throws: GenerationPerformanceMetrics.ValidationError.invalidTiming) {
            try invalidTiming.validate()
        }

        let invalidMemory = GenerationPerformanceMetrics(
            sessionItemCount: 1,
            preparationSeconds: 0,
            textEncoderSeconds: 0,
            imageEncoderSeconds: 0,
            transformerLoadSeconds: 0,
            denoisingSeconds: 1,
            vaeDecodeSeconds: 0,
            pngEncodingSeconds: 0,
            processBaselineBytes: 200,
            processPeakBytes: 100,
            processFinalBytes: 0,
            mlxPeakBytes: 0,
            mlxActiveBytes: 0,
            mlxCacheBytes: 0,
            swapBaselineBytes: 0,
            swapPeakBytes: 0,
            swapFinalBytes: 0,
            worstMemoryPressure: .normal)
        #expect(throws: GenerationPerformanceMetrics.ValidationError.invalidMemory) {
            try invalidMemory.validate()
        }

        let invalidThermal = GenerationPerformanceMetrics(
            sessionItemCount: 1,
            preparationSeconds: 0,
            textEncoderSeconds: 0,
            imageEncoderSeconds: 0,
            transformerLoadSeconds: 0,
            denoisingSeconds: 1,
            vaeDecodeSeconds: 0,
            pngEncodingSeconds: 0,
            processBaselineBytes: 0,
            processPeakBytes: 0,
            processFinalBytes: 0,
            mlxPeakBytes: 0,
            mlxActiveBytes: 0,
            mlxCacheBytes: 0,
            swapBaselineBytes: 0,
            swapPeakBytes: 0,
            swapFinalBytes: 0,
            worstMemoryPressure: .normal,
            thermalBaselineState: 0,
            worstThermalState: 4,
            thermalFinalState: 1)
        #expect(throws: GenerationPerformanceMetrics.ValidationError.invalidThermalState) {
            try invalidThermal.validate()
        }
    }

    @Test("MLX active and cache bytes are independent from peak-active evidence")
    func mlxMemoryCountersAreIndependent() throws {
        let evidence = GenerationPerformanceMetrics(
            sessionItemCount: 1,
            preparationSeconds: 0,
            textEncoderSeconds: 0,
            imageEncoderSeconds: 0,
            transformerLoadSeconds: 0,
            denoisingSeconds: 1,
            vaeDecodeSeconds: 0,
            pngEncodingSeconds: 0,
            processBaselineBytes: 100,
            processPeakBytes: 200,
            processFinalBytes: 150,
            mlxPeakBytes: 64,
            mlxActiveBytes: 128,
            mlxCacheBytes: 256,
            swapBaselineBytes: 0,
            swapPeakBytes: 0,
            swapFinalBytes: 0,
            worstMemoryPressure: .normal)

        // MLX peak tracks peak active allocations for its own reset window. Active and cache are
        // point-in-time counters with different semantics, so neither is bounded by that peak.
        try evidence.validate()
    }

    @Test("Generation decoding remains compatible when the metrics key is absent")
    func legacyGenerationDecode() throws {
        let identifier = UUID()
        let generation = Generation(
            id: identifier,
            prompt: "legacy metrics",
            width: 512,
            height: 512,
            steps: 8,
            seed: 9,
            durationSeconds: 1,
            imageFileName: ManagedGenerationFileName(identifier: identifier, seed: 9).rawValue,
            performance: metrics())
        let encoded = try JSONEncoder().encode(generation)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "performance")

        let decoded = try JSONDecoder().decode(
            Generation.self,
            from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.id == generation.id)
        #expect(decoded.performance == nil)
    }

    @Test("Store persists and recovers exact performance evidence")
    func storeRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterPerformance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(root: root)
        let evidence = metrics(sessionItemCount: 2)
        let store = GenerationStore(paths: paths)

        let saved = try await store.save(
            pngData: Data("performance".utf8),
            prompt: "persist metrics",
            width: 512,
            height: 512,
            steps: 8,
            seed: 17,
            duration: 4,
            performance: evidence)

        #expect(saved.performance == evidence)
        let reopened = GenerationStore(paths: paths)
        #expect((await reopened.all()).first?.performance == evidence)
    }

    @Test("Store rejects invalid metrics before writing image data")
    func storeRejectsInvalidMetrics() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterBadPerformance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(root: root)
        let store = GenerationStore(paths: paths)
        let invalid = metrics(sessionItemCount: 0)

        do {
            _ = try await store.save(
                pngData: Data("must-not-write".utf8),
                prompt: "bad metrics",
                width: 512,
                height: 512,
                steps: 8,
                seed: 18,
                duration: 1,
                performance: invalid)
            Issue.record("Invalid performance evidence was accepted")
        } catch let error as GenerationStoreError {
            guard case .invalidPerformance = error else {
                Issue.record("Unexpected store error: \(error)")
                return
            }
        }

        #expect((await store.all()).isEmpty)
        let imageFiles = try FileManager.default.contentsOfDirectory(
            at: paths.images,
            includingPropertiesForKeys: nil)
        #expect(imageFiles.isEmpty)
    }

    private func metrics(sessionItemCount: Int = 1) -> GenerationPerformanceMetrics {
        GenerationPerformanceMetrics(
            sessionItemCount: sessionItemCount,
            preparationSeconds: 0.1,
            textEncoderSeconds: 0.2,
            imageEncoderSeconds: 0,
            transformerLoadSeconds: 0.3,
            denoisingSeconds: 2,
            vaeDecodeSeconds: 0.4,
            pngEncodingSeconds: 0.1,
            processBaselineBytes: 100,
            processPeakBytes: 500,
            processFinalBytes: 300,
            mlxPeakBytes: 400,
            mlxActiveBytes: 250,
            mlxCacheBytes: 100,
            swapBaselineBytes: 10,
            swapPeakBytes: 30,
            swapFinalBytes: 20,
            worstMemoryPressure: .normal)
    }
}
