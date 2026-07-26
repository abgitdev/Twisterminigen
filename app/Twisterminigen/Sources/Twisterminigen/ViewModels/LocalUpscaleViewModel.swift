import Foundation
import Observation

struct LocalUpscalePreparedResult: Sendable, Hashable {
    let output: ReviewablePNG
    let destinationURL: URL
    let pixelSize: LocalUpscalePixelSize
    let model: LocalUpscaleModel
}

/// App-level owner for the optional local 4× model and every long-running upscale task.
///
/// Keeping this view model alive with the shared `InferenceCoordinator` lets AppKit cancellation
/// stop downloads or inference while the coordinator continues blocking termination until the
/// underlying in-memory worker has actually exited. Reviewed publication is a separate explicit
/// activity and is the only step that receives an external destination URL.
@MainActor
@Observable
final class LocalUpscaleViewModel {
    enum Activity: Equatable {
        case idle
        case installing
        case removing
        case upscaling
        case publishing
    }

    static var defaultWeightsDirectory: URL {
        AppPaths.optionalModels
            .appendingPathComponent("LocalUpscaler", isDirectory: true)
            .appendingPathComponent("RealESRGANGeneralX4V3", isDirectory: true)
    }

    private(set) var weightState: LocalUpscaleWeightState = .licenseRequired
    private(set) var activity: Activity = .idle
    private(set) var progressFraction: Double?
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var preparedResult: LocalUpscalePreparedResult?
    private(set) var lastResult: LocalUpscaleResult?

    @ObservationIgnored private let coordinator: InferenceCoordinator
    @ObservationIgnored private let store: any LocalUpscaleWeightManaging
    @ObservationIgnored private let upscalerFactory: LocalUpscalerFactory
    @ObservationIgnored private let weightsDirectory: URL
    @ObservationIgnored private let manifest: LocalUpscaleWeightManifest
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let acceptanceKey: String
    @ObservationIgnored private var acceptance: LocalUpscaleLicenseAcceptance?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var inferenceLease: InferenceCoordinator.Lease?

    init(
        coordinator: InferenceCoordinator,
        weightsDirectory: URL = LocalUpscaleViewModel.defaultWeightsDirectory,
        manifest: LocalUpscaleWeightManifest = .realESRGANGeneralX4V3,
        defaults: UserDefaults = .standard,
        store: (any LocalUpscaleWeightManaging)? = nil,
        upscalerFactory: @escaping LocalUpscalerFactory = { directory, manifest, acceptance in
            SRVGGLocalUpscaler(
                weightsDirectory: directory,
                manifest: manifest,
                acceptance: acceptance)
        }
    ) {
        self.coordinator = coordinator
        self.manifest = manifest
        self.weightsDirectory = weightsDirectory.standardizedFileURL
        self.defaults = defaults
        self.upscalerFactory = upscalerFactory
        self.acceptanceKey = "local-upscaler-license-\(manifest.identity)"
        self.store = store ?? LocalUpscaleWeightStore(
            directory: weightsDirectory,
            manifest: manifest)
        if defaults.string(forKey: acceptanceKey) == manifest.identity {
            acceptance = .accepting(manifest)
        }
    }

    var isBusy: Bool { activity != .idle }
    var licenseIsAccepted: Bool { acceptance != nil }
    var license: LocalUpscaleLicenseEvidence { manifest.license }
    var model: LocalUpscaleModel { manifest.model }
    var expectedDownloadBytes: Int64 {
        manifest.artifacts.reduce(0) { $0 + $1.expectedBytes }
    }
    var modelIsReady: Bool { weightState == .ready }
    var canUpscale: Bool {
        activity == .idle && modelIsReady && coordinator.canStartInference
    }

    func refresh() async {
        weightState = await store.state(acceptance: acceptance)
    }

    func acceptLicense() {
        let accepted = LocalUpscaleLicenseAcceptance.accepting(manifest)
        acceptance = accepted
        defaults.set(manifest.identity, forKey: acceptanceKey)
        errorMessage = nil
        Task { await refresh() }
    }

    func startInstall() {
        guard activity == .idle else { return }
        guard let acceptance else {
            errorMessage = LocalUpscaleManifestError.licenseNotAccepted.localizedDescription
            return
        }
        guard let mutation = coordinator.beginModelMutation(key: "local-upscaler-weights") else {
            errorMessage = modelMutationBusyMessage()
            return
        }

        let id = begin(.installing, message: "Preparing model download…")
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.coordinator.finishModelMutation(mutation) }
            do {
                try await self.store.download(acceptance: acceptance) { [weak self] fraction, message in
                    Task { @MainActor in
                        guard let self, self.operationID == id else { return }
                        self.progressFraction = min(1, max(0, fraction))
                        self.statusMessage = message
                    }
                }
                self.weightState = await self.store.state(acceptance: acceptance)
                self.statusMessage = "4× model installed"
            } catch is CancellationError {
                self.weightState = await self.store.state(acceptance: acceptance)
                self.statusMessage = "Download paused"
            } catch {
                self.weightState = await self.store.state(acceptance: acceptance)
                self.errorMessage = error.localizedDescription
            }
            self.finish(id)
        }
    }

    func startRemove() {
        guard activity == .idle else { return }
        guard let mutation = coordinator.beginModelMutation(key: "local-upscaler-weights") else {
            errorMessage = modelMutationBusyMessage()
            return
        }

        let id = begin(.removing, message: "Removing local 4× model…")
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.coordinator.finishModelMutation(mutation) }
            do {
                _ = try await self.store.delete()
                self.weightState = await self.store.state(acceptance: self.acceptance)
                self.statusMessage = "Model removed"
            } catch is CancellationError {
                self.weightState = await self.store.state(acceptance: self.acceptance)
            } catch {
                self.weightState = await self.store.state(acceptance: self.acceptance)
                self.errorMessage = error.localizedDescription
            }
            self.finish(id)
        }
    }

    /// Starts a real native 4× SRVGG pass from Gallery-verified PNG bytes. Inference and encoding
    /// remain in memory; only the later reviewed publisher receives the selected destination URL.
    func startUpscale(
        sourcePNGData: Data,
        sourceSize: LocalUpscalePixelSize,
        destinationURL: URL,
        sourceGeneration: Generation
    ) {
        guard activity == .idle else { return }
        guard let acceptance else {
            errorMessage = LocalUpscaleManifestError.licenseNotAccepted.localizedDescription
            return
        }
        guard modelIsReady else {
            errorMessage = "Install and verify the optional local 4× model first."
            return
        }
        guard let lease = coordinator.begin(.upscale) else {
            errorMessage = coordinator.busyMessage(for: .upscale)
            return
        }

        let id = begin(.upscaling, message: "Running tiled SRVGG 4×…")
        inferenceLease = lease
        let weightsDirectory = self.weightsDirectory
        let manifest = manifest
        let upscalerFactory = self.upscalerFactory
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Self.runUpscale(
                    sourcePNGData: sourcePNGData,
                    sourceSize: sourceSize,
                    destinationURL: destinationURL,
                    weightsDirectory: weightsDirectory,
                    manifest: manifest,
                    acceptance: acceptance,
                    sourceGeneration: sourceGeneration,
                    upscalerFactory: upscalerFactory)
                self.preparedResult = result
                self.statusMessage = "4× result ready for review"
                self.coordinator.finish(lease)
            } catch is CancellationError {
                self.statusMessage = "Upscale cancelled"
                self.coordinator.finish(lease)
            } catch {
                self.errorMessage = error.localizedDescription
                self.coordinator.fail(error.localizedDescription, lease: lease)
            }
            if self.inferenceLease == lease { self.inferenceLease = nil }
            self.finish(id)
        }
    }

    func cancel() {
        guard activity != .idle else { return }
        if activity == .publishing {
            statusMessage = "Finishing collision-safe publication…"
            return
        }
        if let inferenceLease { coordinator.markStopping(inferenceLease) }
        statusMessage = "Stopping…"
        task?.cancel()
    }

    func clearMessages() {
        errorMessage = nil
        statusMessage = nil
    }

    /// Gallery reuses this app-level owner across detail sheets. Do not let a completed export or
    /// error from one image appear to belong to the next image that opens Image Tools.
    func prepareForImageTools() {
        guard activity == .idle else { return }
        errorMessage = nil
        statusMessage = nil
        preparedResult = nil
        lastResult = nil
    }

    func discardPreparedResult() {
        guard activity == .idle else { return }
        preparedResult = nil
        statusMessage = nil
    }

    func publishPreparedResult(
        receipt: OutputReviewGate.ReviewReceipt,
        protectedRoots: [URL]
    ) async {
        guard activity == .idle, let preparedResult else { return }
        activity = .publishing
        statusMessage = "Publishing reviewed 4× PNG…"
        defer { activity = .idle }
        do {
            let outcome = try await ValidatedExternalPublisher.publishReviewedPNG(
                preparedResult.output,
                to: preparedResult.destinationURL,
                receipt: receipt,
                kind: .localAIUpscale,
                protectedRoots: protectedRoots)
            switch outcome {
            case .publishedDurable(let visibleURL):
                lastResult = LocalUpscaleResult(
                    outputURL: visibleURL,
                    pixelSize: preparedResult.pixelSize,
                    model: preparedResult.model)
                self.preparedResult = nil
                statusMessage = "Saved \(preparedResult.pixelSize.width) × \(preparedResult.pixelSize.height) reviewed PNG"
                errorMessage = nil
            case .publishedDurabilityWarning(let visibleURL, let code):
                lastResult = LocalUpscaleResult(
                    outputURL: visibleURL,
                    pixelSize: preparedResult.pixelSize,
                    model: preparedResult.model)
                self.preparedResult = nil
                statusMessage = "Reviewed 4× PNG is visible at the selected destination"
                errorMessage = "Filesystem durability could not be confirmed (POSIX \(code)). Inspect the destination before retrying."
            case .failedBeforeVisibility(_, let error):
                statusMessage = "Reviewed 4× PNG was not published"
                errorMessage = "Publication failed before visibility: \(error.localizedDescription)"
            case .stateUnknown(let destination, let error):
                statusMessage = "Reviewed 4× PNG publication was not confirmed"
                errorMessage = "Inspect \(destination.path) before retrying. The app cannot confirm whether its exact reviewed bytes are present. \(error.localizedDescription)"
            }
        } catch {
            errorMessage = "4× export failed: \(error.localizedDescription)"
        }
    }

    private func begin(_ next: Activity, message: String) -> UUID {
        let id = UUID()
        operationID = id
        activity = next
        progressFraction = next == .installing ? 0 : nil
        statusMessage = message
        errorMessage = nil
        preparedResult = nil
        lastResult = nil
        return id
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        activity = .idle
        progressFraction = nil
        task = nil
    }

    private func modelMutationBusyMessage() -> String {
        if coordinator.isTerminationRequested {
            return "Can't change the local 4× model while Twisterminigen is preparing to quit."
        }
        return "Can't change the local 4× model while another model or MLX operation is active."
    }

    /// Keeps PNG decoding, manifest hashing, weight loading, and the executor away from the main
    /// actor. Cancelling the app-level task propagates into this worker before the coordinator lease
    /// is released. No temporary pathname is created or cleaned up.
    private nonisolated static func runUpscale(
        sourcePNGData: Data,
        sourceSize: LocalUpscalePixelSize,
        destinationURL: URL,
        weightsDirectory: URL,
        manifest: LocalUpscaleWeightManifest,
        acceptance: LocalUpscaleLicenseAcceptance,
        sourceGeneration: Generation,
        upscalerFactory: @escaping LocalUpscalerFactory
    ) async throws -> LocalUpscalePreparedResult {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let service = upscalerFactory(weightsDirectory, manifest, acceptance)
            let request = LocalUpscaleRequest(
                sourcePNGData: sourcePNGData,
                sourceSize: sourceSize,
                factor: .fourX,
                model: manifest.model)
            let result = try await service.upscale(request)
            try result.validate(against: request)
            try Task.checkCancellation()

            let reviewedOutput = try ReviewablePNGFactory.data(
                from: result.pngData,
                sourceGeneration: sourceGeneration,
                derivation: .localAIUpscale4x)
            try Task.checkCancellation()
            return LocalUpscalePreparedResult(
                output: reviewedOutput,
                destinationURL: destinationURL,
                pixelSize: result.pixelSize,
                model: result.model)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
