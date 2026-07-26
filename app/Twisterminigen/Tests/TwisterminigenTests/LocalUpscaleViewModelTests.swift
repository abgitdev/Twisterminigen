import Foundation
import Testing
@testable import Twisterminigen

@Suite("Local upscale orchestration")
struct LocalUpscaleViewModelTests {
    @Test("Cancellation holds the upscale lease until the backend exits")
    @MainActor
    func cancellationKeepsLease() async throws {
        let manifest = LocalUpscaleWeightManifest.realESRGANGeneralX4V3
        let coordinator = InferenceCoordinator()
        let weights = StubUpscaleWeightManager(state: .ready)
        let backend = BlockingUpscalerProbe(
            model: manifest.model,
            cancellationDelay: .milliseconds(80))
        let defaults = VolatileUserDefaults()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Twister-upscale-probe-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }
        let viewModel = LocalUpscaleViewModel(
            coordinator: coordinator,
            weightsDirectory: FileManager.default.temporaryDirectory,
            manifest: manifest,
            defaults: defaults,
            store: weights,
            upscalerFactory: { _, _, _ in backend })

        viewModel.acceptLicense()
        await viewModel.refresh()
        #expect(viewModel.modelIsReady)

        viewModel.startUpscale(
            sourcePNGData: Data("orchestration-only fixture".utf8),
            sourceSize: .init(width: 2, height: 2),
            destinationURL: destination,
            sourceGeneration: Self.sourceGeneration)
        await backend.waitUntilStarted()
        #expect(coordinator.activeOperation == .upscale)
        #expect(viewModel.activity == .upscaling)

        viewModel.cancel()
        #expect(coordinator.phase == .stopping)
        #expect(coordinator.activeOperation == .upscale)
        try? await Task.sleep(for: .milliseconds(15))
        #expect(coordinator.phase == .stopping)
        #expect(coordinator.activeOperation == .upscale)
        #expect(viewModel.activity == .upscaling)

        await backend.waitUntilFinished()
        for _ in 0 ..< 100 where coordinator.activeOperation != nil {
            await Task.yield()
        }
        #expect(coordinator.activeOperation == nil)
        #expect(coordinator.phase == .idle)
        #expect(viewModel.activity == .idle)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("A successful 4x pass stays private until the visible result receives a bound review")
    @MainActor
    func successfulExportCarriesProvenance() async throws {
        let manifest = LocalUpscaleWeightManifest.realESRGANGeneralX4V3
        let coordinator = InferenceCoordinator()
        let weights = StubUpscaleWeightManager(state: .ready)
        let defaults = VolatileUserDefaults()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Twister-upscale-reviewed-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }
        let viewModel = LocalUpscaleViewModel(
            coordinator: coordinator,
            weightsDirectory: FileManager.default.temporaryDirectory,
            manifest: manifest,
            defaults: defaults,
            store: weights,
            upscalerFactory: { _, _, _ in SuccessfulUpscalerProbe(model: manifest.model) })
        let temporaryPathnamesBefore = Self.productionUpscaleTemporaryPathnames()

        viewModel.acceptLicense()
        await viewModel.refresh()
        viewModel.startUpscale(
            sourcePNGData: Self.onePixelPNG,
            sourceSize: .init(width: 1, height: 1),
            destinationURL: destination,
            sourceGeneration: Self.sourceGeneration)

        for _ in 0 ..< 1_000 where viewModel.activity != .idle {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(viewModel.activity == .idle)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.lastResult == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(Self.productionUpscaleTemporaryPathnames() == temporaryPathnamesBefore)
        let prepared = try #require(viewModel.preparedResult)
        let receipt = OutputReviewGate.reviewedForTesting(
            outputs: [prepared.output],
            kind: .localAIUpscale)
        await viewModel.publishPreparedResult(receipt: receipt, protectedRoots: [])
        #expect(viewModel.preparedResult == nil)
        #expect(viewModel.lastResult?.outputURL == destination)

        let exported = try Data(contentsOf: destination)
        let text = String(decoding: exported, as: UTF8.self)
        #expect(text.contains("AIGenerated\0true"))
        #expect(text.contains("Transformation\0\(PNGOutputProvenance.Derivation.localAIUpscale4x.rawValue)"))
        #expect(text.contains("SourceGenerationIDs\0\(Self.sourceGeneration.id.uuidString)"))
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    private static let sourceGeneration = Generation(
        id: UUID(uuidString: "1308A5FC-B7B7-4B76-96F4-A13F90E3892F")!,
        prompt: "a safe source",
        width: 1,
        height: 1,
        steps: 8,
        seed: 7,
        durationSeconds: 1,
        imageFileName: "source.png")

    private static func productionUpscaleTemporaryPathnames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter {
            $0.hasPrefix("Twisterminigen-upscale-")
                || $0.hasPrefix("Twisterminigen-upscale-output-")
        })
    }
}

private actor StubUpscaleWeightManager: LocalUpscaleWeightManaging {
    private var currentState: LocalUpscaleWeightState

    init(state: LocalUpscaleWeightState) { currentState = state }

    func state(
        acceptance: LocalUpscaleLicenseAcceptance?
    ) async -> LocalUpscaleWeightState {
        acceptance == nil ? .licenseRequired : currentState
    }

    func download(
        acceptance _: LocalUpscaleLicenseAcceptance,
        onProgress: @escaping ModelDownloadProgress
    ) async throws {
        onProgress(1, "ready")
        currentState = .ready
    }

    func delete() async throws -> Int64 {
        currentState = .missing
        return 0
    }
}

private actor BlockingUpscalerProbe: LocalImageUpscaling {
    nonisolated let availability: LocalUpscalerAvailability
    private let model: LocalUpscaleModel
    private let cancellationDelay: Duration
    private var started = false
    private var finished = false

    init(model: LocalUpscaleModel, cancellationDelay: Duration) {
        self.model = model
        self.cancellationDelay = cancellationDelay
        availability = .ready(models: [model])
    }

    func upscale(_ request: LocalUpscaleRequest) async throws -> LocalUpscaleDataResult {
        started = true
        do {
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch is CancellationError {
            let delay = cancellationDelay
            await Task.detached {
                try? await Task.sleep(for: delay)
            }.value
            finished = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func waitUntilFinished() async {
        while !finished { await Task.yield() }
    }
}

private struct SuccessfulUpscalerProbe: LocalImageUpscaling {
    let availability: LocalUpscalerAvailability
    private let model: LocalUpscaleModel

    init(model: LocalUpscaleModel) {
        self.model = model
        availability = .ready(models: [model])
    }

    func upscale(_ request: LocalUpscaleRequest) async throws -> LocalUpscaleDataResult {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let result = LocalUpscaleDataResult(
            pngData: png,
            pixelSize: try request.expectedOutputSize,
            model: model)
        try result.validate(against: request)
        return result
    }
}
