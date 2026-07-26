import SwiftUI
import AppKit
import Observation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MLX
import Krea2DiT
import Krea2Pipeline
import Krea2Sampler
import Krea2TextEncoder

/// Injectable renderer used by deterministic queue contract tests. Production builds leave this
/// nil and use the real Krea pipeline; keeping the seam at the job boundary lets the tests prove
/// Gallery durability and queue acknowledgement ordering without loading multi-gigabyte weights.
struct QueueRenderedOutput: Sendable {
    let pngData: Data
    let seconds: Double
}

typealias QueueJobProgress = @Sendable (_ step: Int, _ total: Int) async -> Void
typealias QueueJobRenderer = @Sendable (
    _ job: QueueJob,
    _ progress: @escaping QueueJobProgress
) async throws -> QueueRenderedOutput
typealias RenderMonotonicNow = @Sendable () -> Double

private enum RenderMonotonicClock {
    static func makeNow() -> RenderMonotonicNow {
        let clock = ContinuousClock()
        let origin = clock.now
        return {
            let components = origin.duration(to: clock.now).components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
    }
}

/// Drives one text-to-image generation with the Krea 2 engine: inputs, live progress, result.
///
/// Concurrency model (Swift 6 strict): the VM is @MainActor, but the heavy `Krea2Pipeline.generate`
/// (minutes, ~20–27 GB peak) runs in a `Task.detached` so the UI never blocks. `MLXArray` is NOT
/// Sendable, so the pixel tensor is converted to PNG `Data` (Sendable) OFF the main actor and only
/// the bytes cross back. The step callback hops to the MainActor to update progress.
@MainActor
@Observable
final class GenerateViewModel {
    // MARK: Inputs (draft form persists; prompt + seed do NOT — privacy)
    var prompt: String = ""
    /// Advanced prompt inputs stay in the in-memory draft only, like the positive prompt.
    var negativePrompt: String = ""
    /// A string draft prevents SwiftUI's numeric formatter from rounding a stored recipe value
    /// or coercing partial/invalid input. `guidanceValue` is the sole validated numeric view.
    var guidanceText: String = "0"
    var exactText: String = ""
    nonisolated static let officialTurboSteps = 8
    var width: Int = 1024 {
        didSet {
            let clamped = Self.snap16(width)
            if clamped != width { width = clamped; return }
            defaults.set(width, forKey: Self.widthKey)
        }
    }
    var height: Int = 1024 {
        didSet {
            let clamped = Self.snap16(height)
            if clamped != height { height = clamped; return }
            defaults.set(height, forKey: Self.heightKey)
        }
    }
    var steps: Int = officialTurboSteps {
        didSet {
            let clamped = min(Self.maxSteps, max(Self.minSteps, steps))
            if clamped != steps { steps = clamped; return }
            defaults.set(steps, forKey: Self.stepsKey)
        }
    }
    var seedText: String = ""          // empty = random

    /// Matches the Generate screen's slider (Turbo is tuned for ~8 steps).
    nonisolated static let minSteps = 4
    nonisolated static let maxSteps = 12
    /// Size bounds mirror the sampler's minres/maxres; kept to a /16 stride. Krea2VAE now tiles
    /// the decode above ~1344px, so the ceiling matches Krea's documented native Turbo range
    /// (1k–2k) rather than the old single-shot decode's hard Metal-buffer cliff (verified on
    /// M4/32GB, 2026-07-09: 1536²/2048² both complete via the tiled path). Renders above ~1344²
    /// take noticeably longer — the DiT's attention cost grows with image-token count too.
    static let minSide = 256
    static let maxSide = 2048

    // Aspect presets (each a /16-aligned W×H near 1 MP) — 4 landscape/square + their 3 portrait
    // mirrors, matching the Aspect grid pattern from Typhoonminigen.
    struct AspectPreset: Identifiable, Sendable { let id: String; let w: Int; let h: Int }
    static let aspectPresets: [AspectPreset] = [
        .init(id: "1:1",  w: 1024, h: 1024),
        .init(id: "4:3",  w: 1152, h: 864),
        .init(id: "3:2",  w: 1200, h: 800),
        .init(id: "16:9", w: 1280, h: 720),
        .init(id: "3:4",  w: 864,  h: 1152),
        .init(id: "2:3",  w: 800,  h: 1200),
        .init(id: "9:16", w: 720,  h: 1280),
    ]

    /// Canvas tiers shown in More are intentionally allow-listed. A new tier belongs here only
    /// after its real Krea 2 path has passed the project's image, memory, and duration gates.
    enum VerifiedCanvasTier: String, CaseIterable, Identifiable, Sendable {
        case recommended1024

        var id: String { rawValue }
        var title: String { "1024" }
        var detail: String { "Verified · ~1 MP" }
    }

    func applyAspect(_ p: AspectPreset) { width = Self.snap16(p.w); height = Self.snap16(p.h) }
    func isAspectActive(_ p: AspectPreset) -> Bool { width == p.w && height == p.h }
    func randomizeSeed() { seedText = "" }

    /// Re-applies the verified 1024-class dimensions while preserving the nearest available
    /// aspect. This keeps Canvas tier and Aspect independent, like the compact Cyclon panel.
    func applyCanvasTier(_ tier: VerifiedCanvasTier) {
        switch tier {
        case .recommended1024:
            let ratio = Double(width) / Double(max(1, height))
            let nearest = Self.aspectPresets.min {
                abs(log((Double($0.w) / Double($0.h)) / ratio))
                    < abs(log((Double($1.w) / Double($1.h)) / ratio))
            } ?? Self.aspectPresets[0]
            applyAspect(nearest)
        }
    }

    func isCanvasTierActive(_ tier: VerifiedCanvasTier) -> Bool {
        switch tier {
        case .recommended1024:
            Self.aspectPresets.contains { isAspectActive($0) }
        }
    }

    /// Freeze one seed now. Prefer the latest resolved result when one exists; otherwise create a
    /// fresh UInt64 once and display it so the next render is deterministic.
    func useFixedSeed() {
        guard !isBusy else { return }
        if seedValue == nil {
            seedText = String(lastSeed ?? UInt64.random(in: UInt64.min ... UInt64.max))
        }
    }

    func useLastSeed() {
        guard !isBusy, let lastSeed else { return }
        seedText = String(lastSeed)
    }

    var batch: Int = 1
    var regions: [GenerationRecipe.BBoxRegion] = []
    var inputImageReference: GenerationRecipe.InputImageReference?
    var inputImagePreview: NSImage?
    var inputImageDimensions: String?
    var isImportingInputImage = false

    /// The latent thumbnail is deliberately diagnostic: it is not a VAE-decoded image. Keep the
    /// cadence explicit because each frame makes a small GPU → host copy during denoising.
    enum LivePreviewMode: String, CaseIterable, Sendable {
        case off
        case everyFourSteps
        case everyStep

        var previewEverySteps: Int {
            switch self {
            case .off: return 0
            case .everyFourSteps: return 4
            case .everyStep: return 1
            }
        }

        var displayName: String {
            switch self {
            case .off: return "Off"
            case .everyFourSteps: return "Every 4 steps"
            case .everyStep: return "Every step"
            }
        }
    }

    var livePreviewMode: LivePreviewMode = .everyFourSteps {
        didSet {
            defaults.set(livePreviewMode.rawValue, forKey: Self.livePreviewModeKey)
            if livePreviewMode == .off {
                clearLatentPreview()
            }
        }
    }

    /// `Off` is intentionally a live presentation action: it clears the currently visible
    /// diagnostic frame immediately. The running sampler may already have queued a callback, so
    /// preview delivery also checks the current mode before publishing another frame.
    func setLivePreviewMode(_ mode: LivePreviewMode) {
        livePreviewMode = mode
    }

    enum ResultSaveState {
        case none
        case saving
        case saved(URL)
        case failed
    }

    private enum GenerationFlowError: Error {
        case gallerySaveFailed
    }

    // MARK: State
    var isBusy: Bool {
        coordinator.activeOperation == .generate || coordinator.activeOperation == .queue
    }
    var isQueueRunning: Bool { coordinator.activeOperation == .queue }
    var isEnhancing: Bool { coordinator.activeOperation == .enhance }
    var isStopping: Bool { coordinator.phase == .stopping }
    var isEnhanceStopping: Bool { isEnhancing && isStopping }
    var showHighMemoryConfirmation = false
    var highMemoryConfirmationText = ""
    var currentStep = 0
    var totalSteps = 8
    var resultImage: NSImage? = nil
    var displayedGeneration: Generation? = nil
    var resultSaveState: ResultSaveState = .none
    var resultWidth: Int? = nil
    var resultHeight: Int? = nil
    var latentPreviewImage: NSImage? = nil
    var latentPreviewStep = 0
    var latentPreviewTotalSteps = 0
    var errorMessage: String? = nil
    var lastSeconds: Double? = nil
    var lastSeed: UInt64? = nil
    var lastPeakGB: Double? = nil
    var lastMLXPeakGB: Double? = nil
    var lastMLXActiveGB: Double? = nil
    var lastMLXCacheGB: Double? = nil
    var lastSwapPeakGB: Double? = nil
    var lastSwapIncreaseGB: Double? = nil
    var lastWorstThermalState: Int? = nil
    var lastPhaseDurations: [String: Duration] = [:]
    var savedImageCount = 0            // bumped once per gallery save — a signal the Gallery observes
    var currentImageIndex = 1          // 1-based — which image of the batch is rendering now
    var totalImages = 1                // the batch size captured when the current run started
    /// True when all three model components are present on disk.
    var modelsReady = false

    // MARK: Queue (pending jobs, run sequentially through the same engine call as `generate()`)
    var queue: [QueueJob] = []
    /// Non-nil only while `runQueue()` is actively rendering that job — distinguishes "the queue
    /// is running" from `isBusy`, which is also true for an ordinary `generate()`/batch call.
    var runningQueueJob: QueueJob? = nil
    var queueTotalCount = 0
    var queueCompletedCount = 0
    /// Checked once the running job finishes; if set, the queue halts instead of starting the next job.
    var stopAfterCurrentQueueJob = false

    var canAddToQueue: Bool {
        addToQueueUnavailableReason == nil
    }

    /// The primary composer remains actionable during rendering: idle submits start Generate,
    /// while active submits snapshot the form at the durable tail of the current work stream.
    var canSubmitCurrentRecipe: Bool {
        isBusy ? canAddToQueue : canGenerate
    }

    var submitCurrentRecipeUnavailableReason: String? {
        isBusy ? addToQueueUnavailableReason : generateUnavailableReason
    }

    var addToQueueUnavailableReason: String? {
        if let queueUnavailableMessage { return queueUnavailableMessage }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a prompt before adding this recipe to Queue."
        }
        if seedIsInvalid { return "Enter a valid non-negative seed, or leave Seed empty for random." }
        if let advancedInputsUnavailableReason { return advancedInputsUnavailableReason }
        if let finding = ReasonableContentFilter.firstFinding(in: currentSafetyScreeningTexts) {
            return finding.localizedDescription
        }
        return nil
    }

    var canRunQueue: Bool {
        runQueueUnavailableReason == nil
    }

    var runQueueUnavailableReason: String? {
        if let kreaLicenseUnavailableReason { return kreaLicenseUnavailableReason }
        if let queueUnavailableMessage { return queueUnavailableMessage }
        if queue.isEmpty { return "Add at least one saved recipe before running Queue." }
        if let queueContentPolicyViolation { return queueContentPolicyViolation }
        if queueJobRenderer == nil {
            let catalog = currentModelCatalog()
            if let missing = queue.first(where: {
                !Self.modelsReady(in: catalog, for: $0.recipe.model)
            }) {
                return "Queue needs \(missing.recipe.model.quantizationTier.qualityName) weights. Download them in Models first."
            }
        }
        if !coordinator.canStartInference { return coordinator.busyMessage(for: .queue) }
        return nil
    }

    private var queueContentPolicyViolation: String? {
        for job in queue {
            if let finding = ReasonableContentFilter.firstFinding(
                in: ReasonableContentFilter.screeningTexts(for: job.recipe))
            {
                return finding.localizedDescription
            }
        }
        return nil
    }

    // MARK: Internals
    private let store: GenerationStore
    private let queueStore: QueueStore?
    private let queueUnavailableMessage: String?
    private let coordinator: InferenceCoordinator
    private let memoryGovernor: MemoryGovernor
    private let conditioningCache: Krea2ConditioningCache
    private let loraLibrary: LoRAViewModel?
    private let inputImageStore: InputImageStore?
    private let inputImageUnavailableMessage: String?
    private let weightsRootProvider: @Sendable () -> URL
    private let modelQuality: ModelQualitySelection
    private let licensePreferences: KreaLicensePreferences
    private let queueJobRenderer: QueueJobRenderer?
    private var genTask: Task<Void, Never>? = nil
    private var shortcutTask: Task<[RenderedFrame], Error>? = nil
    private var queueTask: Task<Void, Never>? = nil
    private var enhanceTask: Task<Void, Never>? = nil
    private var genLease: InferenceCoordinator.Lease?
    private var queueLease: InferenceCoordinator.Lease?
    private var enhanceLease: InferenceCoordinator.Lease?
    private var activeQueueClaimID: UUID?
    /// A Generate/Queue submission made while rendering joins the existing logical work stream.
    /// The counter closes the durable-write/runner-finish race without admitting a second MLX
    /// lease; the boolean requests a fresh Queue lease only after the active render has released.
    private var activeRenderQueueAppendCount = 0
    private var shouldAutoRunQueuedWork = false
    private var automaticQueueContinuationEpoch: UInt64 = 0
    /// The failure owned by the current queue lease. Keep this separate from the shared UI error:
    /// an unrelated action must never turn an intentional queue stop into a failure notification.
    private var queueRunFailureMessage: String?
    private var displayedResultID: UUID?
    /// The complete recipe currently loaded into the form. Visible scalar controls overwrite
    /// their fields when a request is snapshotted; hidden/future fields remain intact.
    private var loadedRecipe: GenerationRecipe?
    @ObservationIgnored private let defaults: UserDefaults
    private let monotonicNow: RenderMonotonicNow
    private var queueJobStartedAt: Double?
    private var renderETASequence = -1
    private var renderETAEstimator = RenderETAEstimator(totalSteps: 0)
    private var queueTimingHistory: [QueueTimingSample] = []

    #if DEBUG
    /// Test-only scheduling seam for proving that a late Stop-after-current request cannot cross
    /// the durable claim boundary. Production has no hook or extra suspension at this point.
    var queueBeforeClaimForTesting: (@MainActor @Sendable () -> Void)?
    /// Exercises the final empty-boundary recheck: an append committed after the runner observed
    /// an empty snapshot must still stay inside the same Queue lease and progress sequence.
    var queueBeforeNaturalFinishForTesting: (@MainActor @Sendable () async -> Void)?
    /// Records the presentation preference resolved immediately before each Queue job. The
    /// production renderer uses the same value; tests can prove a mid-run change reaches the next
    /// job without loading model weights.
    var queuePreviewIntervalDidResolveForTesting:
        (@MainActor @Sendable (_ jobID: UUID, _ interval: Int) -> Void)?
    #endif

    private struct QueueTimingSample {
        let width: Int
        let height: Int
        let steps: Int
        let seconds: Double
    }

    init(
        store: GenerationStore,
        coordinator: InferenceCoordinator,
        memoryGovernor: MemoryGovernor,
        conditioningCache: Krea2ConditioningCache = Krea2ConditioningCache(),
        loraLibrary: LoRAViewModel? = nil,
        inputImageStore: InputImageStore? = nil,
        inputImageStartupWarning: String? = nil,
        queueStore: QueueStore? = nil,
        queueStartupWarning: String? = nil,
        weightsRootProvider: @escaping @Sendable () -> URL = { AppPaths.weightsRoot },
        defaults: UserDefaults = .standard,
        modelQuality: ModelQualitySelection = ModelQualitySelection(),
        queueJobRenderer: QueueJobRenderer? = nil,
        monotonicNow: @escaping RenderMonotonicNow = RenderMonotonicClock.makeNow(),
        licensePreferences: KreaLicensePreferences
    ) {
        self.defaults = defaults
        self.store = store
        self.queueStore = queueStore
        self.queueUnavailableMessage = queueStore == nil ? queueStartupWarning : nil
        self.coordinator = coordinator
        self.memoryGovernor = memoryGovernor
        self.conditioningCache = conditioningCache
        self.loraLibrary = loraLibrary
        self.inputImageStore = inputImageStore
        self.inputImageUnavailableMessage = inputImageStore == nil
            ? inputImageStartupWarning
            : nil
        self.weightsRootProvider = weightsRootProvider
        self.modelQuality = modelQuality
        self.queueJobRenderer = queueJobRenderer
        self.monotonicNow = monotonicNow
        self.licensePreferences = licensePreferences
        // Restore the draft form (prompt intentionally absent).
        let w = defaults.integer(forKey: Self.widthKey)
        let h = defaults.integer(forKey: Self.heightKey)
        let savedSteps = (defaults.object(forKey: Self.stepsKey) as? NSNumber)?.intValue
        if (Self.minSide...Self.maxSide).contains(w) { width = Self.snap16(w) }
        if (Self.minSide...Self.maxSide).contains(h) { height = Self.snap16(h) }
        steps = Self.restoredDraftSteps(savedSteps)
        if let rawMode = defaults.string(forKey: Self.livePreviewModeKey),
           let mode = LivePreviewMode(rawValue: rawMode) {
            livePreviewMode = mode
        }
        if let queueStartupWarning {
            errorMessage = queueStartupWarning
        } else if queueStore?.startupReport.restoredInterruptedClaim != nil {
            errorMessage = "Recovered an interrupted queue job at the front of the queue."
        }
    }

    #if DEBUG
    convenience init(
        store: GenerationStore,
        coordinator: InferenceCoordinator,
        memoryGovernor: MemoryGovernor,
        conditioningCache: Krea2ConditioningCache = Krea2ConditioningCache(),
        loraLibrary: LoRAViewModel? = nil,
        inputImageStore: InputImageStore? = nil,
        inputImageStartupWarning: String? = nil,
        queueStore: QueueStore? = nil,
        queueStartupWarning: String? = nil,
        weightsRootProvider: @escaping @Sendable () -> URL = { AppPaths.weightsRoot },
        defaults: UserDefaults = VolatileUserDefaults(),
        modelQuality: ModelQualitySelection = ModelQualitySelection(
            defaults: VolatileUserDefaults()),
        queueJobRenderer: QueueJobRenderer? = nil,
        monotonicNow: @escaping RenderMonotonicNow = RenderMonotonicClock.makeNow()
    ) {
        self.init(
            store: store,
            coordinator: coordinator,
            memoryGovernor: memoryGovernor,
            conditioningCache: conditioningCache,
            loraLibrary: loraLibrary,
            inputImageStore: inputImageStore,
            inputImageStartupWarning: inputImageStartupWarning,
            queueStore: queueStore,
            queueStartupWarning: queueStartupWarning,
            weightsRootProvider: weightsRootProvider,
            defaults: defaults,
            modelQuality: modelQuality,
            queueJobRenderer: queueJobRenderer,
            monotonicNow: monotonicNow,
            licensePreferences: .acceptedForTesting())
    }
    #endif

    private static let widthKey = "draftWidth"
    private static let heightKey = "draftHeight"
    // V2 deliberately ignores the historical key, whose prior UI default persisted 12 steps.
    // The first launch after this cleanup returns to Krea 2 Turbo's official 8-step default.
    private static let stepsKey = "stepsCount.officialTurbo8.v2"
    private static let livePreviewModeKey = "livePreviewMode"

    // MARK: Derived

    var denoisingProgress: Double? {
        guard case let .denoising(step, total) = coordinator.phase, total > 0 else { return nil }
        return min(1, Double(step) / Double(total))
    }
    var resultHasPersistedFile: Bool {
        if case .saved = resultSaveState { return true }
        return false
    }
    var persistedResultURL: URL? {
        if case .saved(let url) = resultSaveState { return url }
        return nil
    }
    var hasInputImage: Bool { inputImageReference != nil }
    var canImportInputImage: Bool {
        importInputImageUnavailableReason == nil
    }
    var importInputImageUnavailableReason: String? {
        if isImportingInputImage { return "Wait for the current Remix source import to finish." }
        if !coordinator.canChangeModels {
            return "Remix source import is unavailable while local inference is running."
        }
        if inputImageStore == nil {
            return inputImageUnavailableMessage ?? "The Remix source library is unavailable."
        }
        return nil
    }
    var remixStrength: Double {
        get { inputImageReference?.strength ?? 0.65 }
        set {
            guard var reference = inputImageReference else { return }
            reference.strength = min(1, max(0.05, newValue))
            inputImageReference = reference
        }
    }
    var remixResizeMode: GenerationRecipe.ResizeMode {
        get { inputImageReference?.resize ?? .fill }
        set {
            guard var reference = inputImageReference else { return }
            reference.resize = newValue
            inputImageReference = reference
        }
    }
    var remixCrop: GenerationRecipe.NormalizedRect? {
        get { inputImageReference?.crop }
        set {
            guard var reference = inputImageReference else { return }
            reference.crop = newValue.map { RemixCropGeometry.clamped($0) }
            inputImageReference = reference
        }
    }

    func reviewableDisplayedResult(
        derivation: PNGOutputProvenance.Derivation = .generatedImage
    ) async throws -> ReviewablePNG {
        guard let displayedGeneration else {
            throw GenerationExportError.staleGeneration(UUID())
        }
        return try await store.reviewablePNG(
            for: displayedGeneration,
            derivation: derivation)
    }

    func exportDisplayedResult(
        _ output: ReviewablePNG,
        to destination: URL,
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind
    ) async -> Bool {
        do {
            let paths = await store.libraryPaths()
            let outcome = try await ValidatedExternalPublisher.publishReviewedPNG(
                output,
                to: destination,
                receipt: receipt,
                kind: kind,
                protectedRoots: paths.protectedExportRoots)
            _ = try outcome.requireVisibleURL()
            if let code = outcome.durabilityWarningCode {
                errorMessage = "The PNG is visible at the selected destination, but filesystem durability could not be confirmed (POSIX \(code))."
            } else {
                errorMessage = nil
            }
            return true
        } catch {
            errorMessage = "Couldn't export the PNG: \(error.localizedDescription)"
            return false
        }
    }

    func displayedResultDragProvider() -> NSItemProvider {
        guard let displayedGeneration else { return NSItemProvider() }
        let store = self.store
        return CleanPNGItemProvider.make(
            suggestedName: "Twisterminigen-\(displayedGeneration.seed).png"
        ) {
            let output = try await store.reviewablePNG(for: displayedGeneration)
            guard let receipt = await OutputReviewGate.reviewBeforeExport(
                outputs: [output],
                kind: .dragAndDrop) else {
                throw CancellationError()
            }
            try await OutputReviewGate.consume(
                receipt,
                outputs: [output],
                kind: .dragAndDrop)
            return output.data
        }
    }

    /// Hides the current Generate preview without mutating its durable Gallery record or any
    /// exported copies. Last-run timing and seed remain available to the draft controls.
    func clearDisplayedResult() {
        guard !isBusy else { return }
        displayedGeneration = nil
        displayedResultID = nil
        resultImage = nil
        resultSaveState = .none
        resultWidth = nil
        resultHeight = nil
    }

    /// Removes only the currently displayed, managed Gallery record. Exported copies remain
    /// untouched, and the canvas is cleared only after the transaction commits.
    @discardableResult
    func deleteDisplayedResult() async -> Bool {
        guard !isBusy, resultHasPersistedFile, let generation = displayedGeneration else {
            errorMessage = "This result isn't available to delete yet."
            return false
        }
        do {
            _ = try await store.delete(id: generation.id)
            guard displayedGeneration?.id == generation.id else { return true }
            displayedGeneration = nil
            displayedResultID = nil
            resultImage = nil
            resultSaveState = .none
            resultWidth = nil
            resultHeight = nil
            lastSeed = nil
            lastSeconds = nil
            savedImageCount += 1 // Signals Gallery to reload after the managed item is removed.
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't delete this result: \(error.localizedDescription)"
            return false
        }
    }
    var activityText: String {
        switch coordinator.phase {
        case .preparing: return "Preparing..."
        case .enhancing: return "Enhancing prompt..."
        case .describing: return "Reading image..."
        case .encodingPrompt: return "Encoding prompt..."
        case .encodingImage: return "Encoding source..."
        case .loadingTransformer: return "Loading transformer..."
        case let .denoising(step, total):
            return total > 0 ? "Rendering · step \(step) / \(total)" : "Starting denoise..."
        case .decoding: return "Decoding image..."
        case .saving: return "Saving to gallery..."
        case .stopping: return "Stopping after current Metal operation..."
        case .idle: return "Ready"
        case .failed: return "Failed"
        }
    }

    // MARK: Live ETA

    /// The first denoise callback includes MLX warm-up and graph compilation. It is retained as a
    /// timing anchor but never extrapolated as an ordinary step; steady speed begins at step 2.
    /// A monotonically increasing item sequence rejects callbacks delivered after a later image
    /// has already begun, including resident Generate batches that share one work item.
    @discardableResult
    private func prepareDenoiseETA(sequence: Int, totalSteps: Int) -> Bool {
        guard sequence >= renderETASequence else { return false }
        let normalizedTotal = max(0, totalSteps)
        if sequence > renderETASequence || renderETAEstimator.totalSteps != normalizedTotal {
            renderETASequence = sequence
            renderETAEstimator.reset(totalSteps: normalizedTotal)
        }
        return true
    }

    private func recordDenoiseETA(
        sequence: Int,
        step: Int,
        totalSteps: Int,
        emittedAt: Double
    ) {
        guard prepareDenoiseETA(sequence: sequence, totalSteps: totalSteps) else { return }
        _ = renderETAEstimator.recordCompletedStep(step, at: emittedAt)
    }

    private var queueJobElapsedSeconds: Double {
        guard let queueJobStartedAt else { return 0 }
        let elapsed = monotonicNow() - queueJobStartedAt
        return elapsed.isFinite ? max(0, elapsed) : 0
    }

    var secondsPerStep: Double? {
        guard isBusy else { return nil }
        return renderETAEstimator.estimatedSecondsPerStep
    }

    /// Warm-up reports an honest estimating state. Numeric values begin only after a steady
    /// post-warm-up interval exists. While Queue is running this remains the ETA for the image
    /// currently being rendered; multiplying an early sample by every pending job makes the
    /// prominent progress ETA look like a wildly inflated single-image estimate.
    var etaText: String? {
        if runningQueueJob != nil {
            guard currentStep > 0, currentStep < totalSteps else { return nil }
            guard let remaining = renderETAEstimator.estimatedRemainingSeconds else {
                return "Estimating…"
            }
            return Self.etaString(remaining, queueWide: false)
        }
        guard isBusy, denoisingProgress != nil,
              currentStep > 0, currentStep < totalSteps else { return nil }
        guard let remaining = renderETAEstimator.estimatedRemainingSeconds else {
            return "Estimating…"
        }
        return Self.etaString(remaining, queueWide: false)
    }

    private var estimatedQueueRemainingSeconds: Double? {
        guard let running = runningQueueJob else { return nil }
        let elapsed = queueJobElapsedSeconds
        let denoiseRemaining = renderETAEstimator.estimatedRemainingSeconds
        let historyPrediction = predictedQueueSeconds(for: running)
        let currentRemaining: Double
        if let historyPrediction {
            currentRemaining = max(0, max(denoiseRemaining ?? 0, historyPrediction - elapsed))
        } else if let denoiseRemaining {
            currentRemaining = max(0, denoiseRemaining)
        } else {
            return nil
        }

        // Queue jobs are durable one-at-a-time transactions, so each future job pays its own
        // preparation/warm-up cost. Estimate that full cost from the current job without ever
        // treating warm-up as an ordinary denoise interval.
        let firstRunProjection = max(1, elapsed + (denoiseRemaining ?? 0))
        let pending = queue.reduce(0.0) { total, job in
            total + (predictedQueueSeconds(for: job)
                ?? Self.scaledQueueSeconds(
                    firstRunProjection,
                    sourceWidth: running.width,
                    sourceHeight: running.height,
                    sourceSteps: running.steps,
                    to: job))
        }
        return currentRemaining + pending
    }

    private func predictedQueueSeconds(for job: QueueJob) -> Double? {
        guard !queueTimingHistory.isEmpty else { return nil }
        let total = queueTimingHistory.reduce(0.0) { result, sample in
            result + Self.scaledQueueSeconds(
                sample.seconds,
                sourceWidth: sample.width,
                sourceHeight: sample.height,
                sourceSteps: sample.steps,
                to: job)
        }
        return total / Double(queueTimingHistory.count)
    }

    private nonisolated static func scaledQueueSeconds(
        _ seconds: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceSteps: Int,
        to target: QueueJob
    ) -> Double {
        let sourceWork = max(1, sourceWidth * sourceHeight * sourceSteps)
        let targetWork = max(1, target.width * target.height * target.steps)
        return seconds * Double(targetWork) / Double(sourceWork)
    }

    private nonisolated static func etaString(
        _ seconds: Double,
        queueWide: Bool
    ) -> String {
        let prefix = queueWide ? "Queue · " : ""
        if seconds < 90 { return "\(prefix)~\(Int(max(0, seconds).rounded())) s left" }
        return "\(prefix)~\(Int((max(0, seconds) / 60).rounded())) min left"
    }

    /// "2.1 s/step · image 2 of 4" — or "2.1 s/step · queue 2 of 3" while `runQueue()` is driving.
    var busySubline: String {
        let part = runningQueueJob != nil
            ? "queue \(queueCompletedCount + 1) of \(queueTotalCount)"
            : "image \(currentImageIndex) of \(totalImages)"
        if let sps = secondsPerStep { return String(format: "%.1f s/step · \(part)", sps) }
        return part
    }

    private var cleanedSeedText: String { seedText.trimmingCharacters(in: .whitespaces) }

    var seedValue: UInt64? {
        let t = cleanedSeedText
        return t.isEmpty ? nil : UInt64(t)
    }

    /// True when the seed field has non-empty text that isn't a valid non-negative integer.
    /// Validates the RAW text directly — "-42" or "12abc" must be rejected outright, not
    /// silently reinterpreted as 42/12 by stripping the characters that made them invalid.
    var seedIsInvalid: Bool {
        let raw = cleanedSeedText
        return !raw.isEmpty && UInt64(raw) == nil
    }

    var canGenerate: Bool {
        generateUnavailableReason == nil
    }
    var hasAcceptedKreaLicense: Bool {
        licensePreferences.isAccepted
    }
    var kreaLicenseUnavailableReason: String? {
        hasAcceptedKreaLicense
            ? nil
            : "Review and accept the Krea 2 Community License in Models before using the model."
    }
    var generateUnavailableReason: String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a prompt before generating."
        }
        if seedIsInvalid { return "Enter a valid non-negative seed, or leave Seed empty for random." }
        if let advancedInputsUnavailableReason { return advancedInputsUnavailableReason }
        if let finding = ReasonableContentFilter.firstFinding(in: currentSafetyScreeningTexts) {
            return finding.localizedDescription
        }
        if let kreaLicenseUnavailableReason { return kreaLicenseUnavailableReason }
        if !modelsReady { return "Install the active Krea 2 model in Models before generating." }
        if !coordinator.canStartInference {
            return coordinator.busyMessage(for: .generate)
        }
        return nil
    }

    /// Krea Turbo defaults to zero guidance. Input is intentionally locale-neutral so a value
    /// copied from a recipe JSON has one unambiguous interpretation and round-trips as a Double.
    var guidanceValue: Double? { Self.parseGuidance(guidanceText) }
    var guidanceIsInvalid: Bool { guidanceValue == nil }
    var negativePromptIsInvalid: Bool {
        negativePrompt.utf8.count > GenerationRecipe.maximumPromptUTF8Bytes
    }
    var negativePromptIsInactive: Bool {
        !negativePrompt.isEmpty && guidanceValue == 0
    }
    /// Lettering has no second enable switch: non-whitespace text is the complete source of truth.
    var letteringIsActive: Bool {
        !exactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var letteringUnavailableReason: String? {
        guard letteringIsActive else { return nil }
        do {
            _ = try ExactTextPrompt.compose(basePrompt: prompt, exactText: exactText)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    var guidanceConflictsWithRegionalPrompts: Bool {
        !regions.isEmpty && guidanceValue.map { $0 != 0 } == true
    }
    var advancedInputsAreValid: Bool {
        advancedInputsUnavailableReason == nil
    }
    var advancedInputsUnavailableReason: String? {
        if guidanceIsInvalid {
            return "Guidance must be a decimal from 0 to \(Int(GenerationRecipe.maximumGuidance))."
        }
        if negativePromptIsInvalid { return "The negative prompt exceeds the recipe size limit." }
        if let letteringUnavailableReason { return letteringUnavailableReason }
        if guidanceConflictsWithRegionalPrompts { return "Regional prompts require Turbo CFG 0." }
        return nil
    }
    var hasNondefaultAdvancedSettings: Bool {
        !negativePrompt.isEmpty || guidanceIsInvalid || guidanceValue.map { $0 != 0 } == true
    }

    nonisolated static func parseGuidance(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 32 else { return nil }
        let bytes = Array(value.utf8)
        var index = 0
        func isDigit(_ byte: UInt8) -> Bool { (48 ... 57).contains(byte) }
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        guard index > 0 else { return nil }
        if index < bytes.count, bytes[index] == 46 { // decimal point
            index += 1
            let fractionStart = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > fractionStart else { return nil }
        }
        if index < bytes.count, bytes[index] == 69 || bytes[index] == 101 { // E / e
            index += 1
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            let exponentStart = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > exponentStart else { return nil }
        }
        guard index == bytes.count else { return nil }
        guard let parsed = Double(value), parsed.isFinite,
              (0 ... GenerationRecipe.maximumGuidance).contains(parsed)
        else { return nil }
        return parsed
    }

    nonisolated static func guidanceDraft(for value: Double) -> String {
        guard value.isFinite else { return "" }
        return value.rounded(.towardZero) == value
            && value >= Double(Int.min)
            && value <= Double(Int.max)
            ? String(Int(value))
            : String(value)
    }

    func normalizeGuidanceText() {
        guard let guidanceValue else { return }
        guidanceText = Self.guidanceDraft(for: guidanceValue)
    }

    struct ActiveLoRATriggerGroup: Identifiable, Sendable, Equatable {
        let id: UUID
        let name: String
        let triggers: [String]
    }

    var activeLoRATriggerGroups: [ActiveLoRATriggerGroup] {
        guard let loraLibrary else { return [] }
        return loraLibrary.active.compactMap { selection in
            guard let asset = loraLibrary.assets.first(where: { $0.id == selection.assetID }) else {
                return nil
            }
            return ActiveLoRATriggerGroup(
                id: asset.id,
                name: asset.name,
                triggers: asset.triggers)
        }
    }

    var hasActiveLoRAsWithoutTriggers: Bool {
        activeLoRATriggerGroups.contains { $0.triggers.isEmpty }
    }

    nonisolated static func promptContainsLoRATrigger(_ trigger: String, in prompt: String) -> Bool {
        let phrase = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return false }
        let options: String.CompareOptions = [
            .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
        ]
        let phraseStartsWithWord = phrase.first.map(Self.isTriggerWordCharacter) ?? false
        let phraseEndsWithWord = phrase.last.map(Self.isTriggerWordCharacter) ?? false
        var searchStart = prompt.startIndex
        while searchStart < prompt.endIndex,
              let range = prompt.range(
                  of: phrase,
                  options: options,
                  range: searchStart ..< prompt.endIndex) {
            let leadingBoundary = !phraseStartsWithWord
                || range.lowerBound == prompt.startIndex
                || !Self.isTriggerWordCharacter(prompt[prompt.index(before: range.lowerBound)])
            let trailingBoundary = !phraseEndsWithWord
                || range.upperBound == prompt.endIndex
                || !Self.isTriggerWordCharacter(prompt[range.upperBound])
            if leadingBoundary && trailingBoundary { return true }
            searchStart = prompt.index(after: range.lowerBound)
        }
        return false
    }

    private nonisolated static func isTriggerWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0.value == 95 // underscore
        }
    }

    /// Shared, idempotent insertion primitive. It is called either by an explicit Insert chip or
    /// by the adapter's separately persisted, default-off auto-insert opt-in when that adapter is
    /// enabled. The resulting prompt text is always captured in the GenerationRecipe.
    @discardableResult
    func insertLoRATrigger(assetID: UUID, trigger: String) -> Bool {
        guard let group = activeLoRATriggerGroups.first(where: { $0.id == assetID }),
              let storedTrigger = group.triggers.first(where: { $0 == trigger }),
              !Self.promptContainsLoRATrigger(storedTrigger, in: prompt)
        else { return false }

        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if base.isEmpty {
            candidate = storedTrigger
        } else if base.hasSuffix(",") {
            candidate = "\(base) \(storedTrigger)"
        } else {
            candidate = "\(base), \(storedTrigger)"
        }
        guard candidate.utf8.count <= GenerationRecipe.maximumPromptUTF8Bytes else {
            errorMessage = "The trigger phrase would exceed the prompt size limit."
            return false
        }
        prompt = candidate
        return true
    }

    var activeLoRASummary: String? {
        guard let loraLibrary, !loraLibrary.active.isEmpty else { return nil }
        return loraLibrary.active.compactMap { selection in
            loraLibrary.assets.first(where: { $0.id == selection.assetID }).map { asset in
                "\(asset.name) \(String(format: "%.2f", selection.scale))"
            }
        }.joined(separator: " · ")
    }

    var activeModelDisplayName: String {
        "Krea 2 \(currentModelCatalog().descriptor(for: modelQuality.tier).displayName)"
    }

    /// Reasons the current sampler differs from the published Turbo inference path. Schedule and
    /// precision can arrive through a restored recipe even though More does not expose knobs for
    /// them; surfacing that state avoids a hidden noncanonical render.
    var noncanonicalTurboSettings: [String] {
        var settings: [String] = []
        if steps != Self.officialTurboSteps { settings.append("\(steps) steps") }
        if let guidanceValue, guidanceValue != 0 {
            settings.append("CFG \(Self.guidanceDraft(for: guidanceValue))")
        } else if guidanceIsInvalid {
            settings.append("invalid CFG")
        }
        if let loadedRecipe {
            if loadedRecipe.sampler.schedule != Self.canonicalTurboSchedule {
                settings.append("custom schedule")
            }
            if loadedRecipe.sampler.precision != .bfloat16 {
                settings.append(loadedRecipe.sampler.precision.rawValue)
            }
        }
        return settings
    }

    func restoreTurboRecommendedSettings() {
        guard !isBusy else { return }
        steps = Self.officialTurboSteps
        guidanceText = "0"
        negativePrompt = ""
        if var recipe = loadedRecipe {
            recipe.sampler.steps = Self.officialTurboSteps
            recipe.sampler.guidance = 0
            recipe.sampler.schedule = Self.canonicalTurboSchedule
            recipe.sampler.precision = .bfloat16
            recipe.prompts.negative = ""
            loadedRecipe = recipe
        }
    }

    var canEnhance: Bool {
        enhanceUnavailableReason == nil
    }
    var enhanceUnavailableReason: String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a prompt before using Enhance."
        }
        if let finding = ReasonableContentFilter.firstFinding(in: [prompt]) {
            return finding.localizedDescription
        }
        if let kreaLicenseUnavailableReason { return kreaLicenseUnavailableReason }
        if !modelsReady { return "Install the active Krea 2 model in Models before using Enhance." }
        if !coordinator.canStartInference {
            return coordinator.busyMessage(for: .enhance)
        }
        return nil
    }

    private var currentSafetyScreeningTexts: [String] {
        [prompt, exactText] + regions.map(\.prompt)
    }

    nonisolated static func restoredDraftSteps(_ persisted: Int?) -> Int {
        guard let persisted, (minSteps ... maxSteps).contains(persisted) else {
            return officialTurboSteps
        }
        return persisted
    }

    /// Re-check whether the model weights are on disk. Call after Models changes its snapshot.
    func refreshModelsReady() {
        modelsReady = Self.modelsReady(
            in: currentModelCatalog(),
            for: modelQuality.tier)
    }

    func clearConditioningCache() async {
        await conditioningCache.invalidateAll()
    }

    /// Human-friendly time of the last generation, e.g. "47 s" or "2 min 27 s".
    var lastGenText: String? {
        guard let s = lastSeconds else { return nil }
        if s < 60 { return String(format: "%.0f s", s) }
        return "\(Int(s) / 60) min \(Int(s) % 60) s"
    }

    var lastMemoryText: String? {
        guard let process = lastPeakGB else { return nil }
        var parts = [String(format: "peak %.1f GB", process)]
        if let mlx = lastMLXPeakGB { parts.append(String(format: "MLX %.1f GB", mlx)) }
        if let cache = lastMLXCacheGB, cache >= 0.05 {
            parts.append(String(format: "cache %.1f GB", cache))
        }
        if let swap = lastSwapPeakGB, let increase = lastSwapIncreaseGB {
            parts.append(String(format: "swap +%.1f GB (peak %.1f)", increase, swap))
        }
        if let thermal = lastWorstThermalState {
            parts.append("thermal \(GenerationPerformanceMetrics.thermalStateTitle(thermal).lowercased())")
        }
        return parts.joined(separator: " · ")
    }

    struct RenderEstimate: Sendable, Equatable {
        let time: String
        let memory: String
        let basis: String
    }

    /// Honest, locally calibrated estimate. Until this session has a completed render, the panel
    /// reports the governor's workload risk instead of inventing a duration or GB figure.
    var renderEstimate: RenderEstimate {
        let residentGroupSize = min(max(1, batch), RenderSessionPlanner.maxGroupSize)
        let job = memoryJob(
            width: width,
            height: height,
            batchSize: residentGroupSize,
            quantizationTier: modelQuality.tier,
            loras: currentRecipe(seed: .random).loras)
        let risk = MemoryGovernor.riskProfile(for: job).overall
        let riskLabel: String
        switch risk {
        case .low: riskLabel = "Low"
        case .medium: riskLabel = "Moderate"
        case .high: riskLabel = "High"
        }

        let memory: String
        if let lastPeakGB {
            memory = String(format: "%@ risk · last peak %.1f GB", riskLabel, lastPeakGB)
        } else {
            memory = "\(riskLabel) risk · peak measured after render"
        }

        guard let baseline = displayedGeneration,
              let seconds = Self.estimatedSeconds(
                baselineSeconds: baseline.durationSeconds,
                baselineWidth: baseline.width,
                baselineHeight: baseline.height,
                baselineSteps: baseline.steps,
                targetWidth: width,
                targetHeight: height,
                targetSteps: steps)
        else {
            return RenderEstimate(
                time: "Calibrates after the first completed render",
                memory: memory,
                basis: "Memory is a workload risk; no unmeasured GB value is invented.")
        }

        let perImage = Self.estimateDurationLabel(seconds)
        let total = Self.estimateDurationLabel(seconds * Double(max(1, batch)))
        return RenderEstimate(
            time: batch > 1 ? "≈ \(perImage) each · ≈ \(total) total" : "≈ \(perImage)",
            memory: memory,
            basis: "Scaled from the last completed render on this Mac.")
    }

    /// Compact Fine-tuning summary. Memory diagnostics stay in System instead of competing with
    /// the size controls; an ETA appears only after it has a measured local baseline.
    var compactRenderSummary: String {
        let settings = "\(steps) steps · Turbo"
        let time = renderEstimate.time
        return time.hasPrefix("≈") ? "\(time) · \(settings)" : settings
    }

    nonisolated static func estimatedSeconds(
        baselineSeconds: Double,
        baselineWidth: Int,
        baselineHeight: Int,
        baselineSteps: Int,
        targetWidth: Int,
        targetHeight: Int,
        targetSteps: Int
    ) -> Double? {
        guard baselineSeconds.isFinite, baselineSeconds > 0,
              baselineWidth > 0, baselineHeight > 0, baselineSteps > 0,
              targetWidth > 0, targetHeight > 0, targetSteps > 0
        else { return nil }
        let baselineWork = Double(baselineWidth) * Double(baselineHeight) * Double(baselineSteps)
        let targetWork = Double(targetWidth) * Double(targetHeight) * Double(targetSteps)
        let estimate = baselineSeconds * targetWork / baselineWork
        return estimate.isFinite && estimate > 0 ? estimate : nil
    }

    private nonisolated static func estimateDurationLabel(_ seconds: Double) -> String {
        let rounded = Int(max(1, seconds).rounded())
        if rounded < 60 { return "\(rounded) sec" }
        let minutes = rounded / 60
        let remainder = rounded % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) sec"
    }

    private nonisolated static let canonicalTurboSchedule = GenerationRecipe.Schedule(
        mu: 1.15,
        minres: 256,
        maxres: 1_280,
        y1: 0.5,
        y2: 1.15)

    func swapOrientation() {
        let w = width, h = height
        width = h; height = w
    }

    static func snap16(_ value: Int) -> Int {
        SteppedIntegerValue.normalized(
            value,
            in: minSide ... maxSide,
            step: 16)
    }

    // MARK: Weights

    private func currentModelCatalog() -> ModelCatalog {
        ModelCatalog(root: weightsRootProvider())
    }

    func applyRecipe(_ recipe: GenerationRecipe) throws {
        try recipe.validate(for: .request)
        if let loraLibrary {
            try loraLibrary.applyReferences(recipe.loras)
        }
        applyValidatedRecipe(recipe)
    }

    /// Builds the portable envelope from a single immutable snapshot of the current form. This
    /// never starts inference and never embeds managed file paths or private asset bytes.
    func portableRecipeDocument() async throws -> PortableRecipeDocument {
        let requestedSeed = seedValue.map(GenerationRecipe.Seed.fixed) ?? .random
        let recipe = currentRecipe(seed: requestedSeed)
        try recipe.validate(for: .request)
        let loraSnapshot = loraLibrary.map {
            LoRALibrarySnapshot(assets: $0.assets, active: $0.active)
        } ?? .empty
        let inputSnapshot = await inputImageStore?.snapshot() ?? .empty
        let document = PortableRecipeDocument(
            recipe: recipe,
            loraSnapshot: loraSnapshot,
            inputImageSnapshot: inputSnapshot)
        try document.validate()
        return document
    }

    func exportPortableRecipe(to destination: URL) async throws -> ExternalPublicationOutcome {
        let document = try await portableRecipeDocument()
        let protectedRoots = (await store.libraryPaths()).protectedExportRoots
        return try await Task.detached(priority: .utility) {
            try PortableRecipeService.write(
                document,
                to: destination,
                protectedRoots: protectedRoots)
        }.value
    }

    func exportQueueRecipeMetadata(
        _ job: QueueJob,
        to destination: URL
    ) async throws -> ExternalPublicationOutcome {
        let document = try QueueRecipeMetadataDocument(job: job)
        let protectedRoots = (await store.libraryPaths()).protectedExportRoots
        return try await Task.detached(priority: .utility) {
            try QueueRecipeMetadataService.write(
                document,
                to: destination,
                protectedRoots: protectedRoots)
        }.value
    }

    /// Inspects all dependencies first. The Generate form and active LoRA stack remain untouched
    /// when anything is missing or mismatched.
    func importPortableRecipe(from source: URL) async throws -> PortableRecipeImportReport {
        let decoded = try await Task.detached(priority: .utility) {
            try PortableRecipeService.read(from: source)
        }.value
        let loraSnapshot = loraLibrary.map {
            LoRALibrarySnapshot(assets: $0.assets, active: $0.active)
        } ?? .empty
        let inputSnapshot = await inputImageStore?.snapshot() ?? .empty
        let catalog = currentModelCatalog()
        let report = try PortableRecipeService.inspect(
            decoded.0,
            catalog: catalog,
            loraSnapshot: loraSnapshot,
            inputImageSnapshot: inputSnapshot,
            modelWeightsReady: Self.modelsReady(
                in: catalog,
                for: decoded.0.recipe.model),
            importedLegacyRecipe: decoded.1)
        guard report.canApply else { return report }
        guard coordinator.canStartInference else {
            throw PortableRecipeTransferError.busy
        }
        // Resolve the physical managed files as well as their catalog records before changing UI.
        try await validatePresetRecipeDependencies(report.document.recipe)
        try applyRecipe(report.document.recipe)
        return report
    }

    /// Applies a stored preset only after every managed dependency has been checked. This keeps
    /// the Generate form unchanged when a personal LoRA, Remix source, or model build is missing;
    /// silently dropping advanced settings would make a preset misleading.
    func applyPresetRecipe(_ recipe: GenerationRecipe) async throws {
        try await validatePresetRecipeDependencies(recipe)
        try applyRecipe(recipe)
    }

    private func validatePresetRecipeDependencies(_ recipe: GenerationRecipe) async throws {
        try GenerationRecipeRuntime.validateConfiguration(
            for: recipe,
            catalog: currentModelCatalog())
        if let loraLibrary {
            try loraLibrary.validateReferences(recipe.loras)
        } else if !recipe.loras.isEmpty {
            throw LoRAViewModelError.libraryUnavailable
        }
        if let reference = recipe.inputImage {
            guard let inputImageStore else {
                throw InputImageStoreError.unavailable(
                    inputImageUnavailableMessage ?? "The Remix source library is unavailable.")
            }
            _ = try await inputImageStore.resolve(reference)
        }
    }

    private func applyValidatedRecipe(_ recipe: GenerationRecipe) {
        modelQuality.select(recipe.model.quantizationTier)
        prompt = recipe.prompts.positive
        negativePrompt = recipe.prompts.negative
        guidanceText = Self.guidanceDraft(for: recipe.sampler.guidance)
        exactText = recipe.prompts.exactText ?? ""
        width = recipe.canvas.width
        height = recipe.canvas.height
        steps = recipe.sampler.steps
        switch recipe.sampler.seed {
        case .random: seedText = ""
        case .fixed(let seed): seedText = String(seed)
        }
        batch = 1
        regions = recipe.regions
        inputImageReference = recipe.inputImage
        inputImagePreview = nil
        inputImageDimensions = nil
        loadedRecipe = recipe
        if let reference = recipe.inputImage {
            Task { await loadInputImagePreview(reference) }
        }
    }

    func currentRecipe(
        seed: GenerationRecipe.Seed,
        catalog: ModelCatalog? = nil
    ) -> GenerationRecipe {
        let catalog = catalog ?? currentModelCatalog()
        var recipe = loadedRecipe ?? GenerationRecipeRuntime.currentTurboRecipe(
            prompt: prompt,
            width: width,
            height: height,
            steps: steps,
            seed: seed,
            catalog: catalog,
            quantizationTier: modelQuality.tier)
        recipe.model = catalog.generationReference(for: modelQuality.tier)
        recipe.prompts.positive = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.prompts.negative = negativePrompt
        let cleanedExactText = exactText.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.prompts.exactText = cleanedExactText.isEmpty ? nil : cleanedExactText
        recipe.canvas = .init(width: width, height: height)
        recipe.sampler.steps = steps
        recipe.sampler.seed = seed
        // Invalid text stays invalid rather than silently falling back to zero/another recipe.
        // All Generate/Queue entry points gate on `advancedInputsAreValid`; the NaN is a final
        // fail-closed value for any future caller that forgets that gate and then validates.
        recipe.sampler.guidance = guidanceValue ?? .nan
        if let loraLibrary {
            recipe.loras = loraLibrary.activeReferences
        }
        recipe.regions = regions
        recipe.inputImage = inputImageReference
        return recipe
    }

    /// Captures the Generate form once when Queue Lab opens.
    func queueLabBaseRecipe() -> GenerationRecipe {
        let requestedSeed = seedValue.map(GenerationRecipe.Seed.fixed) ?? .random
        return currentRecipe(seed: requestedSeed)
    }

    func addRegion() {
        guard regions.count < GenerationRecipe.maximumRegionCount else { return }
        // The experimental regional sampler is CFG-free. Make the supported mode explicit at the
        // moment the user opts in instead of leaving a newly created recipe in a blocked state.
        guidanceText = "0"
        regions.append(.init(
            id: UUID(),
            prompt: "New region",
            rect: RegionalPromptPlacement.initialRect(index: regions.count)))
    }

    func removeRegion(id: UUID) {
        regions.removeAll { $0.id == id }
    }

    func moveRegion(id: UUID, by offset: Int) {
        guard let source = regions.firstIndex(where: { $0.id == id })
        else { return }
        let destination = min(regions.count - 1, max(0, source + offset))
        guard destination != source else { return }
        let region = regions.remove(at: source)
        regions.insert(region, at: destination)
    }

    func importInputImage(from source: URL) async {
        guard let inputImageStore else {
            errorMessage = inputImageUnavailableMessage ?? "The Remix source library is unavailable."
            return
        }
        guard let mutation = coordinator.beginModelMutation(key: "input-images") else {
            errorMessage = "Can't import a Remix source while local inference is running."
            return
        }
        isImportingInputImage = true
        defer {
            isImportingInputImage = false
            coordinator.finishModelMutation(mutation)
        }
        do {
            let asset = try await importOrReuse(into: inputImageStore) {
                try await inputImageStore.import(sourceURL: source)
            }
            try await selectInputAsset(asset, sourceGenerationID: nil)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't import the Remix source: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func beginRemix(from generation: Generation) async -> Bool {
        guard let inputImageStore else {
            errorMessage = inputImageUnavailableMessage ?? "The Remix source library is unavailable."
            return false
        }
        guard let mutation = coordinator.beginModelMutation(key: "input-images") else {
            errorMessage = "Can't prepare Remix while local inference is running."
            return false
        }
        isImportingInputImage = true
        defer {
            isImportingInputImage = false
            coordinator.finishModelMutation(mutation)
        }
        do {
            let pngData = try await store.pngDataForExport(for: generation)
            let asset = try await importOrReuse(into: inputImageStore) {
                try await inputImageStore.importPNGData(pngData)
            }
            let reference = GenerationRecipe.InputImageReference(
                managedID: asset.id,
                sha256: asset.sha256,
                strength: 0.65,
                resize: .fill,
                sourceGenerationID: generation.id)
            var recipe = generation.recipe
            recipe.sampler.seed = .random
            recipe.inputImage = reference
            try applyRecipe(recipe)
            inputImagePreview = try await managedInputImagePreview(
                reference,
                in: inputImageStore)
            inputImageDimensions = "\(asset.width)×\(asset.height)"
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't prepare Remix: \(error.localizedDescription)"
            return false
        }
    }

    func remixDisplayedResult() async {
        guard let displayedGeneration else {
            errorMessage = "This result must be saved in Gallery before it can be remixed."
            return
        }
        _ = await beginRemix(from: displayedGeneration)
    }

    func clearInputImage() {
        guard !isBusy else { return }
        inputImageReference = nil
        inputImagePreview = nil
        inputImageDimensions = nil
    }

    private func importOrReuse(
        into store: InputImageStore,
        operation: () async throws -> InputImageAsset
    ) async throws -> InputImageAsset {
        do {
            return try await operation()
        } catch InputImageStoreError.duplicateContent(let id) {
            guard let asset = await store.snapshot().assets.first(where: { $0.id == id }) else {
                throw InputImageStoreError.assetNotFound(id)
            }
            return asset
        }
    }

    private func selectInputAsset(
        _ asset: InputImageAsset,
        sourceGenerationID: UUID?
    ) async throws {
        guard let inputImageStore else {
            throw InputImageStoreError.unavailable("The Remix source library is unavailable.")
        }
        let reference = GenerationRecipe.InputImageReference(
            managedID: asset.id,
            sha256: asset.sha256,
            strength: 0.65,
            resize: .fill,
            sourceGenerationID: sourceGenerationID)
        let preview = try await managedInputImagePreview(
            reference,
            in: inputImageStore)
        inputImageReference = reference
        inputImagePreview = preview
        inputImageDimensions = "\(asset.width)×\(asset.height)"
    }

    private func loadInputImagePreview(
        _ reference: GenerationRecipe.InputImageReference
    ) async {
        guard let inputImageStore else {
            errorMessage = inputImageUnavailableMessage ?? "The Remix source library is unavailable."
            return
        }
        do {
            let resolved = try await inputImageStore.resolve(reference)
            let preview = try await managedInputImagePreview(
                reference,
                in: inputImageStore)
            guard inputImageReference?.managedID == reference.managedID else { return }
            inputImagePreview = preview
            inputImageDimensions = "\(resolved.asset.width)×\(resolved.asset.height)"
        } catch {
            guard inputImageReference?.managedID == reference.managedID else { return }
            inputImagePreview = nil
            inputImageDimensions = nil
            errorMessage = error.localizedDescription
        }
    }

    private func managedInputImagePreview(
        _ reference: GenerationRecipe.InputImageReference,
        in store: InputImageStore
    ) async throws -> NSImage {
        let data = try await store.managedPreviewPNGData(reference)
        guard let preview = NSImage(data: data) else {
            throw InputImageStoreError.decodeFailed
        }
        return preview
    }

    nonisolated static func modelsReady(in catalog: ModelCatalog) -> Bool {
        modelsReady(in: catalog, for: .mixed4And8)
    }

    nonisolated static func modelsReady(
        in catalog: ModelCatalog,
        for tier: GenerationRecipe.QuantizationTier
    ) -> Bool {
        modelsReady(in: catalog, for: catalog.generationReference(for: tier))
    }

    nonisolated static func modelsReady(
        in catalog: ModelCatalog,
        for reference: GenerationRecipe.ModelReference
    ) -> Bool {
        guard let descriptor = catalog.descriptor(matching: reference) else { return false }
        let verifier = ModelVerifier(
            manifest: catalog.manifest,
            stampDirectory: AppPaths.weightsSource.isReadOnly
                ? AppPaths.linkedModelVerification
                : nil)
        return catalog.files(for: descriptor).allSatisfy {
            verifier.isVerifiedFromCache($0)
        }
    }

    nonisolated static func makeWeights(
        catalog: ModelCatalog,
        model: GenerationRecipe.ModelReference? = nil,
        resolvedLoRAs: [LoRAStore.ResolvedAdapter] = []
    ) -> Krea2Pipeline.Weights {
        let reference = model ?? catalog.generationReference
        let descriptor = catalog.descriptor(matching: reference)
            ?? catalog.descriptor(for: reference.quantizationTier)
        let transformerID = descriptor.componentIDs.first {
            $0.hasPrefix("dit-transformer")
        }!
        let identity = resolvedLoRAs.isEmpty ? nil : resolvedLoRAs.map { adapter in
            let scaleBits = String(adapter.reference.scale.bitPattern, radix: 16)
            return "\(adapter.reference.managedID.uuidString.lowercased()):\(adapter.reference.sha256.lowercased()):\(scaleBits)"
        }.joined(separator: "|")
        return Krea2Pipeline.Weights(
            officialDir: catalog.officialDirectory,
            ditQuantFile: catalog.component(id: transformerID)!.mainFile.localURL,
            vaeFile: catalog.component(id: "vae")!.mainFile.localURL,
            ditQuantization: reference.quantizationTier == .q8 ? .q8 : .mixed4And8,
            loraAdapters: resolvedLoRAs.map(\.engineConfig),
            verifiedModelIdentity: reference.manifestHash,
            orderedLoRAIdentity: identity,
            loadVerification: modelLoadVerification(
                catalog: catalog,
                descriptor: descriptor,
                resolvedLoRAs: resolvedLoRAs))
    }

    private nonisolated static func modelLoadVerification(
        catalog: ModelCatalog,
        descriptor: ModelDescriptor,
        resolvedLoRAs: [LoRAStore.ResolvedAdapter]
    ) -> Krea2Pipeline.ModelLoadVerification {
        let textEncoderFiles = catalog.component(id: "text-encoder")?.files ?? []
        let vaeFiles = catalog.component(id: "vae")?.files ?? []
        let transformerFiles = descriptor.componentIDs
            .filter { $0.hasPrefix("dit-transformer") }
            .compactMap { catalog.component(id: $0) }
            .flatMap(\.files)
        let adapterFiles = resolvedLoRAs.map {
            VerifiedModelSnapshotInput(
                sourceURL: $0.url,
                relativePath: "loras/\($0.asset.managedFilename)",
                expectedBytes: $0.asset.byteCount,
                expectedSHA256: $0.reference.sha256)
        }
        return { component in
            let files: [ModelFile]
            switch component {
            case .textEncoder:
                files = textEncoderFiles
            case .vaeEncoder, .vaeDecoder:
                files = vaeFiles
            case .transformer:
                files = transformerFiles
            case .loraAdapters:
                guard !adapterFiles.isEmpty else {
                    throw ModelWeightLoadVerificationError.unknownModel(component.rawValue)
                }
                let snapshot = try VerifiedModelSnapshot.create(inputs: adapterFiles)
                return snapshot.engineLease()
            }
            guard !files.isEmpty else {
                throw ModelWeightLoadVerificationError.unknownModel(component.rawValue)
            }
            let snapshot = try VerifiedModelSnapshot.create(
                inputs: files.map(VerifiedModelSnapshotInput.init))
            if component == .textEncoder {
                return snapshot.engineLease(directoryReplacements: [
                    catalog.officialDirectory: snapshot.root,
                ])
            }
            return snapshot.engineLease()
        }
    }

    /// Status/UI paths may use the stat-bound verification cache. This diagnostic entry point uses
    /// the same snapshot builder as inference, but production loading retains each returned lease
    /// through its complete resident stage.
    nonisolated static func verifyModelWeightsForLoad(
        catalog: ModelCatalog,
        references: [GenerationRecipe.ModelReference]
    ) throws {
        for reference in references {
            guard let descriptor = catalog.descriptor(matching: reference) else {
                throw ModelWeightLoadVerificationError.unknownModel(reference.variantID)
            }
            let verification = modelLoadVerification(
                catalog: catalog,
                descriptor: descriptor,
                resolvedLoRAs: [])
            withExtendedLifetime(try verification(.textEncoder)) {}
            withExtendedLifetime(try verification(.transformer)) {}
            withExtendedLifetime(try verification(.vaeDecoder)) {}
        }
    }

    nonisolated static func textEncoderLoadLease(
        catalog: ModelCatalog
    ) throws -> Krea2Pipeline.ModelLoadLease {
        let descriptor = catalog.descriptor(for: .mixed4And8)
        return try modelLoadVerification(
            catalog: catalog,
            descriptor: descriptor,
            resolvedLoRAs: [])(.textEncoder)
    }

    // MARK: Actions

    /// UI-free single-image entry point used only by the App Intent. It shares the same model
    /// catalog, memory governor, conditioning cache, coordinator and transactional Gallery store
    /// as the visible Generate flow, but does not mutate the current form or open a window.
    func renderShortcutRecipe(_ shortcut: ShortcutRecipe) async throws -> Generation {
        guard hasAcceptedKreaLicense else { throw ShortcutRenderError.licenseRequired }
        let catalog = currentModelCatalog()
        let recipe = try shortcut.generationRecipe(catalog: catalog)
        modelsReady = Self.modelsReady(in: catalog, for: recipe.model)
        guard modelsReady else { throw ShortcutRenderError.modelWeightsMissing }
        let memoryResult = memoryGovernor.preflight(for: .init(
            width: recipe.canvas.width,
            height: recipe.canvas.height,
            model: recipe.model.quantizationTier == .q8
                ? .eightBitQuantized
                : .mixed4And8Quantized,
            batchSize: 1))
        guard memoryResult.canStart else { throw ShortcutRenderError.unsafeMemory }
        guard let lease = coordinator.begin(.generate) else {
            throw ShortcutRenderError.busy(coordinator.busyMessage(for: .generate))
        }
        guard let workItem = coordinator.beginWorkItem(lease) else {
            coordinator.finish(lease)
            throw ShortcutRenderError.lostLease
        }

        genLease = lease
        let item = RenderSessionPlanner.Item(recipe: recipe)
        let conditioningCache = conditioningCache
        let weights = Self.makeWeights(catalog: catalog, model: recipe.model)
        let pressure = Self.cachePressurePolicy(for: memoryResult.status.level)
        await conditioningCache.setPressure(pressure)

        let task = Task.detached(priority: .userInitiated) {
            defer { MLXRuntimeSafety.drainCompletions() }
            return try await Self.renderPlannedFrames(
                items: [item],
                weights: weights,
                catalog: catalog,
                conditioningCache: conditioningCache,
                inputImageStore: nil,
                previewEverySteps: 0,
                onPhase: { index, phase in
                    Task { @MainActor in
                        guard self.coordinator.isActive(lease) else { return }
                        if case .denoising = phase, index != nil {
                            self.coordinator.beginDenoisingItem(
                                total: recipe.sampler.steps,
                                lease: lease,
                                workItem: workItem)
                        } else {
                            self.coordinator.transition(
                                to: Self.coordinatorPhase(for: phase),
                                lease: lease,
                                workItem: workItem)
                        }
                    }
                },
                onStep: { _, step, total in
                    Task { @MainActor in
                        self.coordinator.transition(
                            to: .denoising(step: step, total: total),
                            lease: lease,
                            workItem: workItem)
                    }
                },
                onPreview: { _, _, _, _ in },
                onHardStop: { _ in
                    Task { @MainActor in
                        self.coordinator.markStopping(lease)
                        self.shortcutTask?.cancel()
                    }
                })
        }
        shortcutTask = task

        do {
            let frames = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard let frame = frames.first else { throw ShortcutRenderError.missingOutput }
            coordinator.transition(to: .saving, lease: lease, workItem: workItem)
            let generation = try await store.save(
                pngData: frame.pngData,
                recipe: recipe,
                duration: frame.seconds,
                performance: frame.memory.persisted)
            savedImageCount += 1
            shortcutTask = nil
            genLease = nil
            coordinator.finish(lease)
            return generation
        } catch is CancellationError {
            shortcutTask = nil
            genLease = nil
            coordinator.finish(lease)
            throw CancellationError()
        } catch {
            shortcutTask = nil
            genLease = nil
            coordinator.fail(error.localizedDescription, lease: lease)
            throw error
        }
    }

    /// Resident-sequential batch: seed, seed+1, … without a true batch dimension. Groups are
    /// bounded to four images and reuse TE/DiT/VAE within each group.
    func generate(allowHighMemory: Bool = false) {
        let modelCatalog = currentModelCatalog()
        modelsReady = Self.modelsReady(in: modelCatalog, for: modelQuality.tier)
        guard modelsReady else {
            errorMessage = "The model weights aren't on disk yet — download them in the Models section first."
            return
        }
        guard canGenerate else { return }
        let baseSeed = seedValue ?? UInt64.random(in: 0 ... UInt64.max)
        let recipe = currentRecipe(seed: .fixed(baseSeed), catalog: modelCatalog)
        do {
            try GenerationRecipeRuntime.validateConfiguration(
                for: recipe,
                catalog: modelCatalog)
            try loraLibrary?.validateReferences(recipe.loras)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let residentGroupSize = min(max(1, batch), RenderSessionPlanner.maxGroupSize)
        let memoryResult = memoryGovernor.preflight(for: memoryJob(
            width: width,
            height: height,
            batchSize: residentGroupSize,
            quantizationTier: recipe.model.quantizationTier,
            loras: recipe.loras))
        guard memoryResult.canStart else {
            errorMessage = Self.memoryBlockMessage(memoryResult)
            return
        }
        if memoryResult.risk.overall == .high && !allowHighMemory {
            highMemoryConfirmationText = "\(width)×\(height) with batch \(batch) is an experimental high-memory run on this Mac. Automatic memory stop remains active."
            showHighMemoryConfirmation = true
            return
        }
        guard let lease = coordinator.begin(.generate) else {
            errorMessage = coordinator.busyMessage(for: .generate)
            return
        }
        genLease = lease
        let conditioningCache = conditioningCache
        let loraLibrary = loraLibrary
        let inputImageStore = inputImageStore
        let previewEverySteps = livePreviewMode.previewEverySteps
        let monotonicNow = monotonicNow
        let cachePressure = Self.cachePressurePolicy(for: memoryResult.status.level)
        let st = steps, n = max(1, batch)
        let batchGroupID = n > 1 ? UUID() : nil
        let groups = RenderSessionPlanner.directGroups(
            recipe: recipe,
            baseSeed: baseSeed,
            count: n)
        errorMessage = nil
        resultImage = nil
        displayedGeneration = nil
        resultSaveState = .none
        resultWidth = nil
        resultHeight = nil
        displayedResultID = nil
        clearLatentPreview()
        currentStep = 0
        totalSteps = st
        currentImageIndex = 1
        totalImages = n
        lastSeed = baseSeed
        renderETASequence = -1
        renderETAEstimator.reset(totalSteps: st)

        genTask = Task.detached(priority: .userInitiated) {
            defer { MLXRuntimeSafety.drainCompletions() }
            do {
                let resolvedLoRAs = try await GenerateViewModel.resolveLoRAs(
                    recipe.loras,
                    library: loraLibrary)
                let weights = GenerateViewModel.makeWeights(
                    catalog: modelCatalog,
                    model: recipe.model,
                    resolvedLoRAs: resolvedLoRAs)
                await conditioningCache.setPressure(cachePressure)
                var completedBeforeGroup = 0
                for group in groups {
                    try Task.checkCancellation()
                    let groupBaseIndex = completedBeforeGroup
                    let workItem = await MainActor.run { () -> InferenceCoordinator.WorkItem? in
                        guard let item = self.coordinator.beginWorkItem(lease) else { return nil }
                        self.currentImageIndex = groupBaseIndex + 1
                        self.currentStep = 0
                        self.totalSteps = group.first?.steps ?? 0
                        self.lastSeed = group.first?.seed
                        return item
                    }
                    guard let workItem else { throw CancellationError() }
                    let frames = try await GenerateViewModel.renderPlannedFrames(
                        items: group,
                        weights: weights,
                        catalog: modelCatalog,
                        conditioningCache: conditioningCache,
                        inputImageStore: inputImageStore,
                        previewEverySteps: previewEverySteps,
                        onPhase: { index, phase in
                            Task { @MainActor in
                                guard self.coordinator.isActive(workItem, lease: lease) else {
                                    return
                                }
                                if let index {
                                    let sequence = groupBaseIndex + index
                                    guard self.prepareDenoiseETA(
                                        sequence: sequence,
                                        totalSteps: group[index].steps) else { return }
                                    self.currentImageIndex = groupBaseIndex + index + 1
                                    self.lastSeed = group[index].seed
                                }
                                if case .denoising = phase, let index {
                                    self.currentStep = 0
                                    self.totalSteps = group[index].steps
                                    self.clearLatentPreview()
                                    self.coordinator.beginDenoisingItem(
                                        total: group[index].steps,
                                        lease: lease,
                                        workItem: workItem)
                                } else {
                                    self.coordinator.transition(
                                        to: GenerateViewModel.coordinatorPhase(for: phase),
                                        lease: lease, workItem: workItem)
                                }
                            }
                        },
                        onStep: { index, step, effectiveTotal in
                            let emittedAt = monotonicNow()
                            Task { @MainActor in
                                guard self.coordinator.isActive(workItem, lease: lease) else { return }
                                let sequence = groupBaseIndex + index
                                guard self.prepareDenoiseETA(
                                    sequence: sequence,
                                    totalSteps: effectiveTotal) else { return }
                                self.currentImageIndex = groupBaseIndex + index + 1
                                self.currentStep = step
                                self.totalSteps = effectiveTotal
                                self.recordDenoiseETA(
                                    sequence: sequence,
                                    step: step,
                                    totalSteps: effectiveTotal,
                                    emittedAt: emittedAt)
                                self.coordinator.transition(
                                    to: .denoising(step: step, total: effectiveTotal),
                                    lease: lease, workItem: workItem)
                            }
                        },
                        onPreview: { index, data, step, effectiveTotal in
                            Task { @MainActor in
                                let targetImageIndex = groupBaseIndex + index + 1
                                guard self.coordinator.isActive(workItem, lease: lease),
                                      self.currentImageIndex == targetImageIndex else { return }
                                self.receiveLatentPreview(
                                    data,
                                    step: step,
                                    totalSteps: effectiveTotal)
                            }
                        },
                        onHardStop: { status in
                            Task { @MainActor [weak self] in
                                guard let self,
                                      self.coordinator.isActive(workItem, lease: lease) else {
                                    return
                                }
                                self.requestMemoryStop(status)
                            }
                        })
                    for index in frames.indices {
                        let item = group[index]
                        let frame = frames[index]
                        let globalIndex = groupBaseIndex + index
                        let provenance = batchGroupID.map {
                            GenerationProvenance.batch(
                                groupID: $0,
                                itemIndex: globalIndex,
                                itemCount: n)
                        }
                        let persisted = await self.saveAndMaybeShow(
                            pngData: frame.pngData,
                            recipe: item.recipe,
                            seconds: frame.seconds,
                            memory: frame.memory,
                            isLast: globalIndex == n - 1,
                            lease: lease,
                            workItem: workItem,
                            provenance: provenance)
                        guard persisted else { throw GenerationFlowError.gallerySaveFailed }
                    }
                    await MainActor.run {
                        self.coordinator.finishWorkItem(workItem, lease: lease)
                    }
                    completedBeforeGroup += group.count
                }
                await MainActor.run {
                    self.finishBatch()
                    self.genLease = nil
                    self.coordinator.finish(lease)
                    self.continueQueuedWorkAfterSuccessfulRender()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.cancelAutomaticQueueContinuation()
                    self.finishCancelled()
                    self.genLease = nil
                    self.coordinator.finish(lease)
                }
            } catch GenerationFlowError.gallerySaveFailed {
                await MainActor.run {
                    self.cancelAutomaticQueueContinuation()
                    self.clearLatentPreview()
                    self.genTask = nil
                    self.genLease = nil
                    self.coordinator.fail("Gallery save failed", lease: lease)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.cancelAutomaticQueueContinuation()
                    self.errorMessage = "Generation failed: \(message)"
                    SystemLog.shared.log("Generation failed: \(message)")
                    self.clearLatentPreview()
                    self.genTask = nil
                    self.genLease = nil
                    self.coordinator.fail(message, lease: lease)
                }
            }
        }
    }

    func confirmHighMemoryGenerate() {
        showHighMemoryConfirmation = false
        generate(allowHighMemory: true)
    }

    func cancelHighMemoryGenerate() {
        showHighMemoryConfirmation = false
    }

    /// Expands the prompt in place via Qwen3-VL-4B generative mode (official expansion.txt system
    /// prompt — same text encoder weights the pipeline already uses, no extra download). Runs off
    /// the main actor like `generate()`; String is Sendable so no PNG-style bridging is needed.
    func enhance() {
        let modelCatalog = currentModelCatalog()
        modelsReady = Self.modelsReady(in: modelCatalog, for: modelQuality.tier)
        guard modelsReady else {
            errorMessage = "The model weights aren't on disk yet — download them in the Models section first."
            return
        }
        let memoryResult = memoryGovernor.preflight(for: memoryJob(
            width: 1_024, height: 1_024, batchSize: 1))
        guard memoryResult.canStart else {
            errorMessage = Self.memoryBlockMessage(memoryResult)
            return
        }
        guard canEnhance else { return }
        guard let lease = coordinator.begin(.enhance) else {
            errorMessage = coordinator.busyMessage(for: .enhance)
            return
        }
        enhanceLease = lease
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil

        enhanceTask = Task.detached(priority: .userInitiated) {
            defer { MLXRuntimeSafety.drainCompletions() }
            let monitor = GenerateViewModel.makeMemoryMonitor { status in
                Task { @MainActor [weak self] in self?.requestMemoryStop(status) }
            }
            monitor.start()
            monitor.markPhase("enhancing")
            do {
                MLX.Memory.cacheLimit = Krea2Pipeline.defaultCacheLimitBytes
                MLX.Memory.peakMemory = 0
                let expanded: String
                do {
                    let modelLease = try GenerateViewModel.textEncoderLoadLease(
                        catalog: modelCatalog)
                    let loadDirectory = try modelLease.replacementDirectory(
                        for: modelCatalog.officialDirectory)
                    var encoder: Krea2TextEncoder? = try await Krea2TextEncoder.load(
                        textEncoderDirectory: loadDirectory.appendingPathComponent("text_encoder"),
                        tokenizerDirectory: loadDirectory.appendingPathComponent("tokenizer"))
                    defer {
                        encoder = nil
                        MLX.Memory.clearCache()
                        withExtendedLifetime(modelLease) {}
                    }
                    expanded = try encoder!.enhance(prompt: promptText)
                }
                _ = await monitor.stop()
                MLX.Memory.clearCache()   // free the ~8.9 GB encoder — same discipline as Pipeline.generate
                await MainActor.run {
                    self.prompt = expanded
                    self.enhanceTask = nil
                    self.enhanceLease = nil
                    self.coordinator.finish(lease)
                }
            } catch is CancellationError {
                _ = await monitor.stop()
                MLX.Memory.clearCache()
                await MainActor.run {
                    self.enhanceTask = nil
                    self.enhanceLease = nil
                    self.coordinator.finish(lease)
                }
            } catch {
                let message = error.localizedDescription
                _ = await monitor.stop()
                MLX.Memory.clearCache()
                await MainActor.run {
                    self.errorMessage = "Enhance failed: \(message)"
                    SystemLog.shared.log("Enhance failed: \(message)")
                    self.enhanceTask = nil
                    self.enhanceLease = nil
                    self.coordinator.fail(message, lease: lease)
                }
            }
        }
    }

    /// Requests cooperative cancellation. The current Metal kernel finishes first; engine loops
    /// then observe cancellation before starting the next denoise step, VAE tile, or Enhance token.
    func cancel() {
        cancelAutomaticQueueContinuation()
        if let operation = coordinator.activeOperation, coordinator.phase != .stopping {
            SystemLog.shared.log(
                "Cancellation requested for \(operation.title) during \(coordinator.statusText).")
        }
        if let genLease { coordinator.markStopping(genLease) }
        if let queueLease { coordinator.markStopping(queueLease) }
        if let enhanceLease { coordinator.markStopping(enhanceLease) }
        genTask?.cancel()
        shortcutTask?.cancel()
        queueTask?.cancel()
        enhanceTask?.cancel()
    }

    // MARK: Queue

    /// Loads the durable queue after app startup. `QueueStore` already converts an interrupted
    /// running claim back to a pending first item during its synchronous recovery pass.
    func restorePersistedQueue() async {
        guard let queueStore else { return }
        let snapshot = await queueStore.snapshot()
        queue = snapshot.pending
        runningQueueJob = snapshot.running?.job
    }

    /// Snapshots the current Generate form into a new pending job — same fields `generate()`
    /// would use, captured now so later edits to the form don't retroactively change it.
    @discardableResult
    func addCurrentToQueue() async -> Int? {
        guard canAddToQueue else { return nil }
        let activeOperation = coordinator.activeOperation
        let joinsActiveRender = activeOperation == .generate || activeOperation == .queue
        let continuationEpoch = automaticQueueContinuationEpoch
        if joinsActiveRender {
            activeRenderQueueAppendCount += 1
        }
        defer {
            if joinsActiveRender {
                activeRenderQueueAppendCount = max(0, activeRenderQueueAppendCount - 1)
                continueQueuedWorkAfterSuccessfulRender()
            }
        }

        let requestedSeed = seedValue.map(GenerationRecipe.Seed.fixed) ?? .random
        let job = QueueJob(recipe: currentRecipe(seed: requestedSeed))
        guard let queueStore else {
            queue.append(job)
            if joinsActiveRender, continuationEpoch == automaticQueueContinuationEpoch {
                shouldAutoRunQueuedWork = true
            }
            refreshActiveQueueTotal()
            return queue.count
        }
        do {
            try await queueStore.enqueue(job)
            await refreshQueueSnapshot()
            if joinsActiveRender, continuationEpoch == automaticQueueContinuationEpoch {
                shouldAutoRunQueuedWork = true
            }
            refreshActiveQueueTotal()
            return queue.count
        } catch {
            reportQueueStoreError(error, action: "add the job")
            return nil
        }
    }

    /// Starts pending work only after the active Generate/Queue lease has ended. Calls made while
    /// a durable append is still in flight intentionally do nothing; the append's `defer` retries
    /// this handoff after QueueStore has committed and refreshed the MainActor snapshot.
    func continueQueuedWorkAfterSuccessfulRender() {
        guard shouldAutoRunQueuedWork else { return }
        guard activeRenderQueueAppendCount == 0 else { return }
        guard !isBusy else { return }
        guard !queue.isEmpty else {
            shouldAutoRunQueuedWork = false
            return
        }
        shouldAutoRunQueuedWork = false
        runQueue()
    }

    private func refreshActiveQueueTotal() {
        guard isQueueRunning else { return }
        queueTotalCount = queueCompletedCount
            + queue.count
            + (runningQueueJob == nil ? 0 : 1)
    }

    private func cancelAutomaticQueueContinuation() {
        shouldAutoRunQueuedWork = false
        automaticQueueContinuationEpoch &+= 1
    }

    /// Queues a stored preset recipe byte-for-byte without applying it to the Generate form.
    /// This intentionally shares QueueStore and QueueJob with the existing Generate action; it
    /// neither starts inference nor probes/loads model weights.
    func enqueuePresetRecipe(_ recipe: GenerationRecipe) async throws {
        guard !isQueueRunning else { throw PresetQueueError.queueIsRunning }
        if let queueUnavailableMessage {
            throw PresetQueueError.queueUnavailable(queueUnavailableMessage)
        }
        try await validatePresetRecipeDependencies(recipe)
        let job = QueueJob(recipe: recipe)
        if let queueStore {
            try await queueStore.enqueue(job)
            await refreshQueueSnapshot()
        } else {
            queue.append(job)
        }
    }

    /// Adds a generated grid with one durable QueueStore mutation.
    @discardableResult
    func enqueueQueueLab(_ preview: QueueLab.Preview) async -> Bool {
        guard !isQueueRunning, queueUnavailableMessage == nil else { return false }
        let jobs = preview.makeJobs()
        guard !jobs.isEmpty, jobs.count <= QueueLab.maximumJobCount else {
            errorMessage = "Couldn't add the Queue Lab grid: the grid must contain 1...\(QueueLab.maximumJobCount) jobs."
            return false
        }

        do {
            let catalog = currentModelCatalog()
            for job in jobs {
                try GenerationRecipeRuntime.validateConfiguration(
                    for: job.recipe,
                    catalog: catalog)
            }
            if let queueStore {
                try await queueStore.enqueue(jobs)
                await refreshQueueSnapshot()
            } else {
                var ids = Set(queue.map(\.id))
                if let runningQueueJob { ids.insert(runningQueueJob.id) }
                for job in jobs {
                    try job.recipe.validate(for: .request)
                    guard ids.insert(job.id).inserted else {
                        throw QueueStoreError.duplicateJobID(job.id)
                    }
                }
                queue.append(contentsOf: jobs)
            }
            errorMessage = nil
            return true
        } catch {
            reportQueueStoreError(error, action: "add the Queue Lab grid")
            return false
        }
    }

    func duplicateQueueJob(
        id: UUID,
        count: Int = 1,
        seedMode: QueueDuplicateSeedMode = .same
    ) async {
        guard !isQueueRunning,
              let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let queueStore {
                try await queueStore.duplicate(
                    id: id,
                    count: count,
                    seedMode: seedMode)
                await refreshQueueSnapshot()
            } else {
                guard (1 ... QueueLab.maximumJobCount).contains(count) else {
                    throw QueueJobDuplicationError.invalidCopyCount(count)
                }
                let source = queue[idx]
                let copies = try (1 ... count).map { offset in
                    try source.duplicate(
                        seedMode: seedMode,
                        sequenceOffset: offset)
                }
                queue.insert(contentsOf: copies, at: idx + 1)
            }
            errorMessage = nil
        } catch {
            reportQueueStoreError(
                error,
                action: count == 1 ? "duplicate the job" : "generate the job again")
        }
    }

    func removeQueueJob(id: UUID) async {
        guard queue.contains(where: { $0.id == id }) else { return }
        if let queueStore {
            do {
                try await queueStore.remove(id: id)
                await refreshQueueSnapshot()
                refreshActiveQueueTotal()
                errorMessage = nil
            } catch QueueStoreError.jobNotFound(_) {
                // The renderer won the claim boundary. Refresh the row instead of treating this
                // harmless race as a Queue run failure or touching the now-running job.
                await refreshQueueSnapshot()
                errorMessage = "That Queue job has already started rendering and can no longer be removed."
            } catch {
                reportQueueStoreError(error, action: "remove the job")
            }
            return
        }
        queue.removeAll { $0.id == id }
        refreshActiveQueueTotal()
        errorMessage = nil
    }

    /// Replaces one pending recipe without changing its position or identity. A manual edit clears
    /// experiment provenance because it is no longer the original Queue Lab/Batch coordinate.
    /// Pending jobs remain editable while another job is rendering: QueueStore serializes this
    /// mutation against the next durable claim and refuses to alter an already claimed job.
    @discardableResult
    func updateQueueJob(id: UUID, recipe: GenerationRecipe) async -> Bool {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return false }
        do {
            let updated = queue[index].replacingRecipe(recipe)
            try updated.recipe.validate(for: .request)
            if let queueStore {
                try await queueStore.update(id: id, recipe: recipe)
                await refreshQueueSnapshot()
            } else {
                queue[index] = updated
            }
            errorMessage = nil
            return true
        } catch {
            let message = error.localizedDescription
            errorMessage = "Couldn't save the edited job: \(message)"
            SystemLog.shared.log(
                "Queue persistence failed while trying to save the edited job: \(message)")
            return false
        }
    }

    /// Moves a pending job one row. Only ever touches `queue` (the pending list) — the actively
    /// rendering job already moved out to `runningQueueJob` and cannot be reordered.
    func moveQueueJobUp(id: UUID) async {
        await moveQueueJob(id: id, offset: -1)
    }

    func moveQueueJobDown(id: UUID) async {
        await moveQueueJob(id: id, offset: 1)
    }

    private func moveQueueJob(id: UUID, offset: Int) async {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let destination = idx + offset
        guard queue.indices.contains(destination) else { return }
        if let queueStore {
            do {
                try await queueStore.move(id: id, offset: offset)
                await refreshQueueSnapshot()
                errorMessage = nil
            } catch QueueStoreError.jobNotFound(_) {
                // Once claimed, a job belongs exclusively to the renderer and disappears from the
                // pending list. A late click must only refresh UI state, never disturb the run.
                await refreshQueueSnapshot()
                errorMessage = "That Queue job has already started rendering and can no longer be moved."
            } catch QueueStoreError.invalidDestination(_) {
                // A neighbouring job crossed the claim boundary before this click reached the
                // store, leaving the requested row at an edge. The durable order is already valid.
                await refreshQueueSnapshot()
                errorMessage = nil
            } catch {
                reportQueueStoreError(error, action: "reorder the queue")
            }
            return
        }
        queue.swapAt(idx, destination)
        errorMessage = nil
    }

    /// Loads a pending job's complete recipe as an editable Generate copy. The queued snapshot is
    /// intentionally left untouched; saving changes always creates a new QueueJob identity.
    @discardableResult
    func openQueueJobCopy(id: UUID) async -> Bool {
        guard !isQueueRunning,
              let idx = queue.firstIndex(where: { $0.id == id }) else { return false }
        do {
            try queue[idx].recipe.validate(for: .request)
        } catch {
            errorMessage = "Couldn't load this queue recipe: \(error.localizedDescription)"
            return false
        }
        let job = queue[idx]
        applyValidatedRecipe(job.recipe)
        return true
    }

    private func refreshQueueSnapshot() async {
        guard let queueStore else { return }
        let snapshot = await queueStore.snapshot()
        queue = snapshot.pending
        runningQueueJob = snapshot.running?.job
    }

    private func reportQueueStoreError(_ error: Error, action: String) {
        let message = error.localizedDescription
        let displayedMessage = "Couldn't \(action): \(message)"
        errorMessage = displayedMessage
        if isQueueRunning {
            queueRunFailureMessage = displayedMessage
        }
        SystemLog.shared.log("Queue persistence failed while trying to \(action): \(message)")
    }

    private struct QueueExecution: Sendable {
        let job: QueueJob
        let resolvedSeed: UInt64
        let claimID: UUID?
        let sequence: Int
    }

    /// Consumes a stop request only after at least one job completed. That preserves the meaning
    /// of "after current" when the button is pressed immediately after Run All, before job one is
    /// claimed, while making the next durable claim boundary authoritative.
    private func consumeStopBeforeNextQueueClaim() -> Bool {
        guard queueCompletedCount > 0, stopAfterCurrentQueueJob else { return false }
        stopAfterCurrentQueueJob = false
        return true
    }

    private func claimNextQueueExecution(
        lease: InferenceCoordinator.Lease
    ) async throws -> (QueueExecution, InferenceCoordinator.WorkItem)? {
        guard !queue.isEmpty else { return nil }
        guard !consumeStopBeforeNextQueueClaim() else { return nil }

        let execution: QueueExecution
        let workItem: InferenceCoordinator.WorkItem
        if let queueStore {
            guard let claim = try await queueStore.claimNext() else { return nil }
            activeQueueClaimID = claim.id

            // QueueStore is an actor, so MainActor can process the stop button while claimNext()
            // is suspended. Roll that just-created claim back before any render work begins.
            if consumeStopBeforeNextQueueClaim() {
                try await queueStore.retryClaim(claim.id)
                activeQueueClaimID = nil
                await refreshQueueSnapshot()
                return nil
            }
            guard let startedWorkItem = coordinator.beginWorkItem(lease) else {
                try await queueStore.retryClaim(claim.id)
                activeQueueClaimID = nil
                await refreshQueueSnapshot()
                return nil
            }
            workItem = startedWorkItem
            await refreshQueueSnapshot()
            execution = QueueExecution(
                job: claim.job,
                resolvedSeed: claim.resolvedSeed,
                claimID: claim.id,
                sequence: queueCompletedCount)
        } else {
            guard let startedWorkItem = coordinator.beginWorkItem(lease) else { return nil }
            workItem = startedWorkItem
            guard let job = queue.first else { return nil }
            queue.removeFirst()
            let seed = UInt64(job.seedText.trimmingCharacters(in: .whitespaces))
                ?? UInt64.random(in: UInt64.min ... UInt64.max)
            var recipe = job.recipe
            recipe.sampler.seed = .fixed(seed)
            let resolvedJob = QueueJob(
                id: job.id,
                recipe: recipe,
                provenance: job.provenance)
            runningQueueJob = resolvedJob
            execution = QueueExecution(
                job: resolvedJob,
                resolvedSeed: seed,
                claimID: nil,
                sequence: queueCompletedCount)
        }

        currentStep = 0
        totalSteps = execution.job.steps
        queueJobStartedAt = monotonicNow()
        _ = prepareDenoiseETA(
            sequence: execution.sequence,
            totalSteps: execution.job.steps)
        return (execution, workItem)
    }

    private func recordQueueTiming(for job: QueueJob, seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        queueTimingHistory.append(QueueTimingSample(
            width: job.width,
            height: job.height,
            steps: job.steps,
            seconds: seconds))
        if queueTimingHistory.count > 12 {
            queueTimingHistory.removeFirst(queueTimingHistory.count - 12)
        }
    }

    @discardableResult
    private func persistQueueResolution(
        _ execution: QueueExecution,
        as resolution: QueueJobResolution
    ) async -> Bool {
        guard let queueStore, let claimID = execution.claimID else {
            resolveQueueJob(execution.job, as: resolution)
            return true
        }
        guard activeQueueClaimID == claimID else { return true }

        do {
            switch resolution {
            case .persisted:
                try await queueStore.completeClaim(claimID)
                queueCompletedCount += 1
            case .retry:
                try await queueStore.retryClaim(claimID)
            }
            activeQueueClaimID = nil
            await refreshQueueSnapshot()
            return true
        } catch {
            reportQueueStoreError(error, action: "save the queue state")
            await refreshQueueSnapshot()
            return false
        }
    }

    private func finishQueueRun(
        lease: InferenceCoordinator.Lease,
        allowsAutomaticContinuation: Bool
    ) async {
        if let queueStore {
            if let claimID = activeQueueClaimID {
                do {
                    try await queueStore.retryClaim(claimID)
                    activeQueueClaimID = nil
                    await refreshQueueSnapshot()
                } catch {
                    reportQueueStoreError(error, action: "return the interrupted job")
                    await refreshQueueSnapshot()
                }
            }
        } else if let unfinished = runningQueueJob {
            restoreQueueJob(unfinished)
        }
        let notification = activeRenderQueueAppendCount == 0
            ? Self.queueTerminalNotification(
                totalCount: queueTotalCount,
                completedCount: queueCompletedCount,
                remainingCount: queue.count,
                failureMessage: queueRunFailureMessage,
                generationID: displayedGeneration?.id)
            : nil
        queueTask = nil
        queueLease = nil
        stopAfterCurrentQueueJob = false
        queueRunFailureMessage = nil
        clearLatentPreview()
        queueJobStartedAt = nil
        renderETASequence = -1
        coordinator.finish(lease)
        if allowsAutomaticContinuation {
            continueQueuedWorkAfterSuccessfulRender()
        } else {
            cancelAutomaticQueueContinuation()
        }
        switch notification {
        case let .finished(count, generationID):
            QueueNotifier.notifyFinished(count: count, generationID: generationID)
        case let .failed(message, generationID):
            QueueNotifier.notifyFailure(message, generationID: generationID)
        case nil:
            break
        }
    }

    enum QueueTerminalNotification: Equatable {
        case finished(count: Int, generationID: UUID?)
        case failed(message: String, generationID: UUID?)
    }

    /// Decides from an immutable snapshot captured while the queue still owns its lease. A user
    /// stop has pending work but no owned failure, so it deliberately produces no notification.
    static func queueTerminalNotification(
        totalCount: Int,
        completedCount: Int,
        remainingCount: Int,
        failureMessage: String?,
        generationID: UUID?
    ) -> QueueTerminalNotification? {
        if totalCount > 0, completedCount == totalCount, remainingCount == 0 {
            return .finished(count: completedCount, generationID: generationID)
        }
        if let failureMessage {
            let message = failureMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                return .failed(message: message, generationID: generationID)
            }
        }
        return nil
    }

    /// Runs one durable Queue transaction at a time. The next job is never claimed or rendered
    /// until the current image has been decoded, committed to Gallery, and acknowledged in the
    /// Queue store. This ordering is intentionally stricter than ordinary Generate batches:
    /// cancellation, save failure, and "stop after current" must never discard a finished image.
    func runQueue() {
        guard hasAcceptedKreaLicense else {
            errorMessage = kreaLicenseUnavailableReason
            return
        }
        if let queueContentPolicyViolation {
            errorMessage = queueContentPolicyViolation
            return
        }
        let modelCatalog = currentModelCatalog()
        if queueJobRenderer == nil {
            modelsReady = Self.modelsReady(in: modelCatalog, for: modelQuality.tier)
            if let missing = queue.first(where: {
                !Self.modelsReady(in: modelCatalog, for: $0.recipe.model)
            }) {
                errorMessage = "Queue needs \(missing.recipe.model.quantizationTier.qualityName) weights. Download them in Models first."
                return
            }
            do {
                for job in queue {
                    try GenerationRecipeRuntime.validateConfiguration(
                        for: job.recipe,
                        catalog: modelCatalog)
                    try loraLibrary?.validateReferences(job.recipe.loras)
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        if let unsafe = queue.first(where: {
            MemoryGovernor.riskProfile(for: memoryJob(
                width: $0.width,
                height: $0.height,
                batchSize: 1,
                quantizationTier: $0.recipe.model.quantizationTier,
                loras: $0.recipe.loras)).overall == .high
        }) {
            errorMessage = "Queue paused before \(unsafe.width)×\(unsafe.height): high-memory jobs must be started directly from Generate and confirmed once."
            return
        }
        if let first = queue.first {
            let memoryResult = memoryGovernor.preflight(for: memoryJob(
                width: first.width,
                height: first.height,
                batchSize: 1,
                quantizationTier: first.recipe.model.quantizationTier,
                loras: first.recipe.loras))
            guard memoryResult.canStart else {
                errorMessage = Self.memoryBlockMessage(memoryResult)
                return
            }
        }
        guard canRunQueue else { return }
        guard let lease = coordinator.begin(.queue) else {
            errorMessage = coordinator.busyMessage(for: .queue)
            return
        }
        QueueNotifier.prepareForQueueStart()
        queueLease = lease
        let conditioningCache = conditioningCache
        let loraLibrary = loraLibrary
        let inputImageStore = inputImageStore
        let queueJobRenderer = queueJobRenderer
        let monotonicNow = monotonicNow
        queueTotalCount = queue.count
        queueCompletedCount = 0
        renderETASequence = -1
        stopAfterCurrentQueueJob = false
        queueRunFailureMessage = nil
        errorMessage = nil
        resultImage = nil
        displayedGeneration = nil
        resultSaveState = .none
        resultWidth = nil
        resultHeight = nil
        displayedResultID = nil
        clearLatentPreview()

        queueTask = Task.detached(priority: .userInitiated) {
            defer {
                if queueJobRenderer == nil {
                    MLXRuntimeSafety.drainCompletions()
                }
            }
            var allowsAutomaticContinuation = true
            queueLoop: while true {
                if Task.isCancelled {
                    allowsAutomaticContinuation = false
                    break
                }
                let stopBeforeNextClaim = await MainActor.run { () -> Bool in
                    guard self.queueCompletedCount > 0,
                          self.stopAfterCurrentQueueJob else { return false }
                    self.stopAfterCurrentQueueJob = false
                    return true
                }
                if stopBeforeNextClaim {
                    allowsAutomaticContinuation = false
                    break
                }

                let nextPreflight = await MainActor.run {
                    () -> (
                        canProceed: Bool,
                        shouldWaitForAppend: Bool,
                        stoppedByFailure: Bool,
                        pressure: Krea2ConditioningCache.PressurePolicy?
                    ) in
                    guard let next = self.queue.first else {
                        return (
                            false,
                            self.activeRenderQueueAppendCount > 0,
                            false,
                            nil)
                    }
                    if let finding = ReasonableContentFilter.firstFinding(
                        in: ReasonableContentFilter.screeningTexts(for: next.recipe))
                    {
                        let message = finding.localizedDescription
                        self.errorMessage = message
                        self.queueRunFailureMessage = message
                        return (false, false, true, nil)
                    }
                    if queueJobRenderer != nil { return (true, false, false, nil) }
                    guard Self.modelsReady(in: modelCatalog, for: next.recipe.model) else {
                        let message = "Queue needs \(next.recipe.model.quantizationTier.qualityName) weights. Download them in Models first."
                        self.errorMessage = message
                        self.queueRunFailureMessage = message
                        return (false, false, true, nil)
                    }
                    do {
                        try GenerationRecipeRuntime.validateConfiguration(
                            for: next.recipe,
                            catalog: modelCatalog)
                        try self.loraLibrary?.validateReferences(next.recipe.loras)
                    } catch {
                        let message = error.localizedDescription
                        self.errorMessage = message
                        self.queueRunFailureMessage = message
                        return (false, false, true, nil)
                    }
                    if MemoryGovernor.riskProfile(for: self.memoryJob(
                        width: next.width,
                        height: next.height,
                        batchSize: 1,
                        quantizationTier: next.recipe.model.quantizationTier,
                        loras: next.recipe.loras)).overall == .high
                    {
                        let message = "Queue paused before \(next.width)×\(next.height): high-memory jobs must be started directly from Generate and confirmed once."
                        self.errorMessage = message
                        self.queueRunFailureMessage = message
                        return (false, false, true, nil)
                    }
                    let result = self.memoryGovernor.preflight(for: self.memoryJob(
                        width: next.width,
                        height: next.height,
                        batchSize: 1,
                        quantizationTier: next.recipe.model.quantizationTier,
                        loras: next.recipe.loras))
                    guard result.canStart else {
                        let message = Self.memoryBlockMessage(result)
                        self.errorMessage = message
                        self.queueRunFailureMessage = message
                        return (false, false, true, nil)
                    }
                    return (
                        true,
                        false,
                        false,
                        GenerateViewModel.cachePressurePolicy(for: result.status.level))
                }
                if nextPreflight.shouldWaitForAppend {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }
                guard nextPreflight.canProceed else {
                    if nextPreflight.stoppedByFailure {
                        allowsAutomaticContinuation = false
                        break
                    }
                    #if DEBUG
                    await self.queueBeforeNaturalFinishForTesting?()
                    #endif
                    let foundLateAppend = await MainActor.run {
                        !self.queue.isEmpty || self.activeRenderQueueAppendCount > 0
                    }
                    if foundLateAppend { continue }
                    break
                }
                if let pressure = nextPreflight.pressure {
                    await conditioningCache.setPressure(pressure)
                }

                #if DEBUG
                await MainActor.run {
                    self.queueBeforeClaimForTesting?()
                }
                #endif

                let selected: (QueueExecution, InferenceCoordinator.WorkItem)?
                do {
                    selected = try await self.claimNextQueueExecution(lease: lease)
                } catch {
                    await MainActor.run {
                        self.reportQueueStoreError(error, action: "claim the next queue job")
                    }
                    allowsAutomaticContinuation = false
                    break
                }
                guard let (execution, workItem) = selected else {
                    allowsAutomaticContinuation = false
                    break
                }

                let job = execution.job
                let item = RenderSessionPlanner.Item(
                    queueJobID: job.id,
                    recipe: job.recipe)
                let previewEverySteps = await MainActor.run {
                    let interval = self.livePreviewMode.previewEverySteps
                    #if DEBUG
                    self.queuePreviewIntervalDidResolveForTesting?(job.id, interval)
                    #endif
                    return interval
                }
                var didPersist = false

                do {
                    try Task.checkCancellation()
                    let frame: RenderedFrame
                    if let queueJobRenderer {
                        await MainActor.run {
                            self.runningQueueJob = job
                            self.lastSeed = execution.resolvedSeed
                            _ = self.prepareDenoiseETA(
                                sequence: execution.sequence,
                                totalSteps: job.steps)
                            self.currentStep = 0
                            self.totalSteps = job.steps
                            self.clearLatentPreview()
                            self.coordinator.beginDenoisingItem(
                                total: job.steps,
                                lease: lease,
                                workItem: workItem)
                        }
                        let rendered = try await queueJobRenderer(job) { step, total in
                            let emittedAt = monotonicNow()
                            await MainActor.run {
                                guard self.coordinator.isActive(workItem, lease: lease),
                                      self.prepareDenoiseETA(
                                        sequence: execution.sequence,
                                        totalSteps: total) else { return }
                                self.runningQueueJob = job
                                self.currentStep = step
                                self.totalSteps = total
                                self.recordDenoiseETA(
                                    sequence: execution.sequence,
                                    step: step,
                                    totalSteps: total,
                                    emittedAt: emittedAt)
                                self.coordinator.transition(
                                    to: .denoising(step: step, total: total),
                                    lease: lease,
                                    workItem: workItem)
                            }
                        }
                        let completedAt = monotonicNow()
                        await MainActor.run {
                            guard self.coordinator.isActive(workItem, lease: lease) else { return }
                            self.currentStep = job.steps
                            self.totalSteps = job.steps
                            self.recordDenoiseETA(
                                sequence: execution.sequence,
                                step: job.steps,
                                totalSteps: job.steps,
                                emittedAt: completedAt)
                            self.coordinator.transition(
                                to: .denoising(step: job.steps, total: job.steps),
                                lease: lease,
                                workItem: workItem)
                        }
                        frame = RenderedFrame(
                            pngData: rendered.pngData,
                            seconds: rendered.seconds,
                            memory: .empty)
                    } else {
                        let resolvedLoRAs = try await GenerateViewModel.resolveLoRAs(
                            item.recipe.loras,
                            library: loraLibrary)
                        let weights = GenerateViewModel.makeWeights(
                            catalog: modelCatalog,
                            model: item.recipe.model,
                            resolvedLoRAs: resolvedLoRAs)
                        let frames = try await GenerateViewModel.renderPlannedFrames(
                            items: [item],
                            weights: weights,
                            catalog: modelCatalog,
                            conditioningCache: conditioningCache,
                            inputImageStore: inputImageStore,
                            previewEverySteps: previewEverySteps,
                            onPhase: { index, phase in
                                Task { @MainActor in
                                    guard self.coordinator.isActive(workItem, lease: lease) else {
                                        return
                                    }
                                    if index != nil {
                                        guard self.prepareDenoiseETA(
                                            sequence: execution.sequence,
                                            totalSteps: job.steps) else { return }
                                        self.runningQueueJob = job
                                        self.lastSeed = execution.resolvedSeed
                                    }
                                    if case .denoising = phase, index != nil {
                                        self.currentStep = 0
                                        self.totalSteps = job.steps
                                        self.clearLatentPreview()
                                        self.coordinator.beginDenoisingItem(
                                            total: job.steps,
                                            lease: lease,
                                            workItem: workItem)
                                    } else {
                                        self.coordinator.transition(
                                            to: GenerateViewModel.coordinatorPhase(for: phase),
                                            lease: lease, workItem: workItem)
                                    }
                                }
                            },
                            onStep: { _, step, effectiveTotal in
                                let emittedAt = monotonicNow()
                                Task { @MainActor in
                                    guard self.coordinator.isActive(workItem, lease: lease) else { return }
                                    guard self.prepareDenoiseETA(
                                        sequence: execution.sequence,
                                        totalSteps: effectiveTotal) else { return }
                                    self.runningQueueJob = job
                                    self.currentStep = step
                                    self.totalSteps = effectiveTotal
                                    self.recordDenoiseETA(
                                        sequence: execution.sequence,
                                        step: step,
                                        totalSteps: effectiveTotal,
                                        emittedAt: emittedAt)
                                    self.coordinator.transition(
                                        to: .denoising(step: step, total: effectiveTotal),
                                        lease: lease, workItem: workItem)
                                }
                            },
                            onPreview: { _, data, step, effectiveTotal in
                                Task { @MainActor in
                                    guard self.coordinator.isActive(workItem, lease: lease),
                                          self.runningQueueJob?.id == job.id else { return }
                                    self.receiveLatentPreview(
                                        data,
                                        step: step,
                                        totalSteps: effectiveTotal)
                                }
                            },
                            onHardStop: { status in
                                Task { @MainActor [weak self] in
                                    guard let self,
                                          self.coordinator.isActive(workItem, lease: lease) else {
                                        return
                                    }
                                    self.requestMemoryStop(status)
                                }
                            })
                        guard let first = frames.first else {
                            throw Krea2Pipeline.PlannedGenerationError.missingImage(0)
                        }
                        frame = first
                    }

                    didPersist = await self.saveAndMaybeShow(
                        pngData: frame.pngData,
                        recipe: item.recipe,
                        seconds: frame.seconds,
                        memory: frame.memory,
                        isLast: true,
                        lease: lease,
                        workItem: workItem,
                        provenance: job.provenance,
                        completionID: job.id)
                    guard didPersist else {
                        _ = await self.persistQueueResolution(execution, as: .retry)
                        await MainActor.run {
                            self.coordinator.finishWorkItem(workItem, lease: lease)
                        }
                        allowsAutomaticContinuation = false
                        break queueLoop
                    }
                    await self.recordQueueTiming(for: job, seconds: frame.seconds)

                    // If cancellation arrived after Gallery committed, acknowledge this exact
                    // image before returning. A retried acknowledgement remains exactly-once
                    // because Gallery keys queue saves by QueueJob.id.
                    try Task.checkCancellation()
                    let resolved = await self.persistQueueResolution(
                        execution,
                        as: .persisted)
                    await MainActor.run {
                        self.coordinator.finishWorkItem(workItem, lease: lease)
                    }
                    guard resolved else { break queueLoop }
                    didPersist = false

                    let shouldStop = await MainActor.run { () -> Bool in
                        guard self.stopAfterCurrentQueueJob else { return false }
                        self.stopAfterCurrentQueueJob = false
                        return true
                    }
                    if shouldStop {
                        allowsAutomaticContinuation = false
                        break queueLoop
                    }
                } catch is CancellationError {
                    allowsAutomaticContinuation = false
                    _ = await self.persistQueueResolution(
                        execution,
                        as: didPersist ? .persisted : .retry)
                    await MainActor.run {
                        self.coordinator.finishWorkItem(workItem, lease: lease)
                    }
                    break
                } catch {
                    allowsAutomaticContinuation = false
                    let message = error.localizedDescription
                    _ = await self.persistQueueResolution(execution, as: .retry)
                    await MainActor.run {
                        self.coordinator.finishWorkItem(workItem, lease: lease)
                        let displayedMessage = "Queue job failed: \(message)"
                        self.errorMessage = displayedMessage
                        self.queueRunFailureMessage = displayedMessage
                        SystemLog.shared.log("Queue job failed: \(message)")
                    }
                    break
                }
            }
            await self.finishQueueRun(
                lease: lease,
                allowsAutomaticContinuation: allowsAutomaticContinuation)
        }
    }

    #if DEBUG
    /// Deterministic synchronization for Queue contract tests; production UI never waits on the
    /// render task from the main actor.
    func waitForQueueCompletionForTesting() async {
        let task = queueTask
        await task?.value
    }
    #endif

    private func memoryJob(
        width: Int,
        height: Int,
        batchSize: Int,
        quantizationTier: GenerationRecipe.QuantizationTier = .mixed4And8,
        loras: [GenerationRecipe.LoRAReference] = []
    ) -> MemoryGovernor.Job {
        let estimatedBytes: Int64
        if loras.isEmpty {
            estimatedBytes = 0
        } else {
            estimatedBytes = (try? loraLibrary?.estimatedResidentBytes(for: loras))
                ?? Int64.max
        }
        return .init(
            width: width,
            height: height,
            model: quantizationTier == .q8
                ? .eightBitQuantized
                : .mixed4And8Quantized,
            loraAdapterCount: loras.count,
            totalLoRABytes: estimatedBytes,
            batchSize: batchSize)
    }

    private nonisolated static func resolveLoRAs(
        _ references: [GenerationRecipe.LoRAReference],
        library: LoRAViewModel?
    ) async throws -> [LoRAStore.ResolvedAdapter] {
        guard !references.isEmpty else { return [] }
        guard let library else { throw LoRAViewModelError.libraryUnavailable }
        return try await library.resolve(references)
    }

    private nonisolated static func memoryBlockMessage(
        _ result: MemoryGovernor.PreflightResult
    ) -> String {
        let swap = Double(result.status.swapUsedBytes) / Double(MemoryGovernor.bytesPerGiB)
        return "Can't start safely: memory pressure is \(result.status.level == .red ? "red" : "high") with \(String(format: "%.1f", swap)) GB swap. Close memory-heavy apps or wait for pressure to fall."
    }

    private func requestMemoryStop(_ status: MemoryGovernor.Status) {
        Task { await conditioningCache.setPressure(.red) }
        guard coordinator.isBusy, coordinator.phase != .stopping else { return }
        let swap = Double(status.swapUsedBytes) / Double(MemoryGovernor.bytesPerGiB)
        let recovery = coordinator.activeOperation == .queue
            ? "The current queue job is ready to retry."
            : "The unfinished operation was not saved."
        let message = "Stopped automatically before memory became unsafe (swap \(String(format: "%.1f", swap)) GB). \(recovery)"
        errorMessage = message
        if coordinator.activeOperation == .queue {
            queueRunFailureMessage = message
        }
        SystemLog.shared.log("Memory governor requested stop at \(String(format: "%.2f", swap)) GB swap, pressure \(status.pressure).")
        cancel()
    }

    enum QueueJobResolution {
        case persisted
        case retry
    }

    /// Resolves the one claimed job exactly once. Only a successfully persisted image advances
    /// progress; every other terminal path puts the same job back at the head for an explicit retry.
    func resolveQueueJob(_ job: QueueJob, as resolution: QueueJobResolution) {
        switch resolution {
        case .persisted:
            guard runningQueueJob?.id == job.id else { return }
            runningQueueJob = nil
            queueCompletedCount += 1
        case .retry:
            restoreQueueJob(job)
        }
    }

    /// Returns an interrupted/failed running job to the head exactly once so Run can retry it.
    func restoreQueueJob(_ job: QueueJob) {
        if !queue.contains(where: { $0.id == job.id }) {
            queue.insert(job, at: 0)
        }
        if runningQueueJob?.id == job.id {
            runningQueueJob = nil
        }
    }

    /// Persists one rendered image; the LAST image of the batch also becomes the on-screen result.
    private func saveAndMaybeShow(
        pngData: Data, recipe: GenerationRecipe,
        seconds: Double, memory: RenderMemoryMetrics, isLast: Bool,
        lease: InferenceCoordinator.Lease,
        workItem: InferenceCoordinator.WorkItem,
        provenance: GenerationProvenance? = nil,
        completionID: UUID? = nil
    ) async -> Bool {
        coordinator.transition(to: .saving, lease: lease, workItem: workItem)
        guard let seed = recipe.sampler.seed.fixedValue else {
            let message = GenerationRecipeRuntime.RuntimeError.unresolvedSeed.localizedDescription
            errorMessage = message
            if isQueueRunning { queueRunFailureMessage = message }
            return false
        }
        lastSeed = seed
        let resultID: UUID?
        if isLast {
            let id = UUID()
            resultID = id
            displayedResultID = id
            resultImage = NSImage(data: pngData)
            resultSaveState = .saving
            resultWidth = recipe.canvas.width
            resultHeight = recipe.canvas.height
            lastPeakGB = Self.gibibytes(memory.processPeakBytes)
            lastMLXPeakGB = Self.gibibytes(memory.mlxPeakBytes)
            lastMLXActiveGB = Self.gibibytes(memory.mlxActiveBytes)
            lastMLXCacheGB = Self.gibibytes(memory.mlxCacheBytes)
            lastSwapPeakGB = Self.gibibytes(memory.maxSwapUsedBytes)
            lastSwapIncreaseGB = Self.gibibytes(memory.maxSwapIncreaseBytes)
            lastWorstThermalState = memory.worstThermalState
            lastPhaseDurations = memory.phaseDurations
            lastSeconds = seconds
        } else {
            resultID = nil
        }
        do {
            let typographyQA: TypographyQAResult?
            if let expected = recipe.prompts.exactText {
                typographyQA = try await Task.detached(priority: .utility) {
                    try TypographyQAService.evaluate(
                        pngData: pngData,
                        expectedText: expected)
                }.value
            } else {
                typographyQA = nil
            }
            let gen = try await store.save(
                pngData: pngData,
                recipe: recipe,
                duration: seconds,
                provenance: provenance,
                performance: memory.persisted,
                typographyQA: typographyQA,
                completionID: completionID)
            let savedURL = try await store.imageURL(for: gen)
            if isLast, displayedResultID == resultID {
                resultSaveState = .saved(savedURL)
                displayedGeneration = gen
            }
            savedImageCount += 1
            SystemLog.shared.log(
                "Saved \(recipe.canvas.width)×\(recipe.canvas.height) image, "
                + "\(recipe.sampler.steps) steps, seed \(seed), "
                + String(format: "%.1f s.", seconds))
            return true
        } catch {
            let message = error.localizedDescription
            if isLast, displayedResultID == resultID {
                resultSaveState = .failed
                displayedGeneration = nil
            }
            let displayedMessage = "Rendered, but couldn't write it to the gallery: \(message)"
            errorMessage = displayedMessage
            if isQueueRunning { queueRunFailureMessage = displayedMessage }
            SystemLog.shared.log("Gallery save failed: \(message)")
            return false
        }
    }

    /// All `batch` images are done — `lastSeconds` was already set to the last image's own render
    /// time in `saveAndMaybeShow`, matching the duration saved to its `Generation` in the gallery.
    private func finishBatch() {
        currentStep = totalSteps
        clearLatentPreview()
        renderETASequence = -1
        genTask = nil
    }

    private func finishCancelled() {
        clearLatentPreview()
        renderETASequence = -1
        genTask = nil
        currentStep = 0
    }

    private func clearLatentPreview() {
        latentPreviewImage = nil
        latentPreviewStep = 0
        latentPreviewTotalSteps = 0
    }

    private func receiveLatentPreview(
        _ data: Data,
        step: Int,
        totalSteps: Int
    ) {
        guard livePreviewMode != .off,
              step >= latentPreviewStep,
              let image = NSImage(data: data) else { return }
        latentPreviewImage = image
        latentPreviewStep = step
        latentPreviewTotalSteps = totalSteps
    }

    private nonisolated static func coordinatorPhase(
        for phase: Krea2Pipeline.Phase
    ) -> InferenceCoordinator.Phase {
        switch phase {
        case .encodingPrompt: return .encodingPrompt
        case .encodingImage: return .encodingImage
        case .loadingTransformer: return .loadingTransformer
        case .denoising: return .denoising(step: 0, total: 0)
        case .decoding: return .decoding
        }
    }

    private struct RenderMemoryMetrics: Sendable {
        let sessionItemCount: Int
        let processBaselineBytes: Int64
        let processPeakBytes: Int64
        let processFinalBytes: Int64
        let mlxPeakBytes: Int64
        let mlxActiveBytes: Int64
        let mlxCacheBytes: Int64
        let swapBaselineBytes: Int64
        let maxSwapUsedBytes: Int64
        let maxSwapIncreaseBytes: Int64
        let swapFinalBytes: Int64
        let worstPressure: MemoryGovernor.Pressure
        let thermalBaselineState: Int
        let worstThermalState: Int
        let thermalFinalState: Int
        let phaseDurations: [String: Duration]

        static let empty = RenderMemoryMetrics(
            sessionItemCount: 1,
            processBaselineBytes: 0,
            processPeakBytes: 0,
            processFinalBytes: 0,
            mlxPeakBytes: 0,
            mlxActiveBytes: 0,
            mlxCacheBytes: 0,
            swapBaselineBytes: 0,
            maxSwapUsedBytes: 0,
            maxSwapIncreaseBytes: 0,
            swapFinalBytes: 0,
            worstPressure: .normal,
            thermalBaselineState: 0,
            worstThermalState: 0,
            thermalFinalState: 0,
            phaseDurations: [:])

        var persisted: GenerationPerformanceMetrics {
            let pressure: GenerationPerformanceMetrics.MemoryPressure
            switch worstPressure {
            case .normal: pressure = .normal
            case .warning: pressure = .warning
            case .critical: pressure = .critical
            }
            return GenerationPerformanceMetrics(
                sessionItemCount: sessionItemCount,
                phaseDurations: phaseDurations,
                processBaselineBytes: processBaselineBytes,
                processPeakBytes: processPeakBytes,
                processFinalBytes: processFinalBytes,
                mlxPeakBytes: mlxPeakBytes,
                mlxActiveBytes: mlxActiveBytes,
                mlxCacheBytes: mlxCacheBytes,
                swapBaselineBytes: swapBaselineBytes,
                swapPeakBytes: maxSwapUsedBytes,
                swapFinalBytes: swapFinalBytes,
                worstMemoryPressure: pressure,
                thermalBaselineState: thermalBaselineState,
                worstThermalState: worstThermalState,
                thermalFinalState: thermalFinalState)
        }
    }

    private struct RenderedFrame: Sendable {
        let pngData: Data
        let seconds: Double
        let memory: RenderMemoryMetrics
    }

    private nonisolated static func makeMemoryMonitor(
        onHardStop: @escaping RenderMemoryMonitor.HardStopHandler
    ) -> RenderMemoryMonitor {
        RenderMemoryMonitor(
            sampleProvider: TelemetryService.renderMemorySample,
            onHardStop: onHardStop)
    }

    private nonisolated static func renderPlannedFrames(
        items: [RenderSessionPlanner.Item],
        weights: Krea2Pipeline.Weights,
        catalog: ModelCatalog,
        conditioningCache: Krea2ConditioningCache,
        inputImageStore: InputImageStore?,
        previewEverySteps: Int,
        onPhase: @escaping @Sendable (Int?, Krea2Pipeline.Phase) -> Void,
        onStep: @escaping @Sendable (Int, Int, Int) -> Void,
        onPreview: @escaping @Sendable (Int, Data, Int, Int) -> Void,
        onHardStop: @escaping RenderMemoryMonitor.HardStopHandler
    ) async throws -> [RenderedFrame] {
        let monitor = makeMemoryMonitor(onHardStop: onHardStop)
        // MLX's peak counter is process-global. This function is called only while the caller owns
        // the exclusive generate/queue lease, so reset it here to make Gallery evidence belong to
        // this planned render session rather than an earlier render or prompt enhancement.
        MLX.Memory.peakMemory = 0
        monitor.start()
        monitor.markPhase("preparing")
        let started = Date()
        do {
            var preparedInputs = [Krea2Pipeline.ImageInput?]()
            preparedInputs.reserveCapacity(items.count)
            for item in items {
                if let reference = item.recipe.inputImage {
                    guard let inputImageStore else {
                        throw InputImageStoreError.unavailable(
                            "The Remix source library is unavailable.")
                    }
                    let source = try await inputImageStore.prepare(
                        reference,
                        targetWidth: item.recipe.canvas.width,
                        targetHeight: item.recipe.canvas.height)
                    preparedInputs.append(try Krea2Pipeline.ImageInput(
                        width: source.width,
                        height: source.height,
                        planarRGB: source.values))
                } else {
                    preparedInputs.append(nil)
                }
            }
            let requests = try items.indices.map { index in
                try GenerationRecipeRuntime.plannedRequest(
                    for: items[index].recipe,
                    catalog: catalog,
                    inputImage: preparedInputs[index])
            }
            let outputs = try await Krea2Pipeline.generatePlanned(
                requests: requests,
                weights: weights,
                conditioningCache: conditioningCache,
                previewEverySteps: previewEverySteps,
                phaseCallback: { phase in
                    monitor.markPhase(memoryPhaseName(for: phase))
                    onPhase(nil, phase)
                },
                itemPhaseCallback: { index, phase in
                    onPhase(index, phase)
                },
                itemPreviewCallback: { index, frame in
                    guard let data = try? LatentPreviewImageEncoder.pngData(from: frame) else {
                        return
                    }
                    onPreview(index, data, frame.step, frame.totalSteps)
                },
                itemStepCallback: onStep)

            monitor.markPhase("encodingPNG")
            let pngByIndex = try Dictionary(uniqueKeysWithValues: outputs.map { output in
                (output.requestIndex, try pngData(from: output.pixels))
            })
            let mlx = MLX.Memory.snapshot()
            let os = await monitor.stop()
            let elapsedPerFrame = Date().timeIntervalSince(started) / Double(items.count)
            let memory = RenderMemoryMetrics(
                sessionItemCount: items.count,
                processBaselineBytes: os.processBaselineBytes,
                processPeakBytes: os.processPeakBytes,
                processFinalBytes: os.processFinalBytes,
                mlxPeakBytes: Int64(mlx.peakMemory),
                mlxActiveBytes: Int64(mlx.activeMemory),
                mlxCacheBytes: Int64(mlx.cacheMemory),
                swapBaselineBytes: os.swapBaselineBytes,
                maxSwapUsedBytes: os.maxSwapUsedBytes,
                maxSwapIncreaseBytes: os.maxSwapIncreaseBytes,
                swapFinalBytes: os.swapFinalBytes,
                worstPressure: os.worstPressure,
                thermalBaselineState: os.thermalBaselineState,
                worstThermalState: os.worstThermalState,
                thermalFinalState: os.thermalFinalState,
                phaseDurations: os.phaseDurations)
            return try items.indices.map { index in
                guard let pngData = pngByIndex[index] else {
                    throw Krea2Pipeline.PlannedGenerationError.missingImage(index)
                }
                return RenderedFrame(
                    pngData: pngData,
                    seconds: elapsedPerFrame,
                    memory: memory)
            }
        } catch {
            _ = await monitor.stop()
            throw error
        }
    }

    private nonisolated static func memoryPhaseName(for phase: Krea2Pipeline.Phase) -> String {
        switch phase {
        case .encodingPrompt: "encodingPrompt"
        case .encodingImage: "encodingImage"
        case .loadingTransformer: "loadingTransformer"
        case .denoising: "denoising"
        case .decoding: "decoding"
        }
    }

    private nonisolated static func cachePressurePolicy(
        for level: MemoryGovernor.Level
    ) -> Krea2ConditioningCache.PressurePolicy {
        switch level {
        case .green: .normal
        case .amber: .amber
        case .red: .red
        }
    }

    private nonisolated static func gibibytes(_ bytes: Int64) -> Double {
        Double(bytes) / Double(MemoryGovernor.bytesPerGiB)
    }

    // MARK: MLXArray → PNG (off-main; adapted from the engine CLI's writePNG)

    /// pixels (1,3,H,W) in [0,1] → PNG `Data` (RGBA, ImageIO). Runs off the main actor so the
    /// tensor materialization (`eval`) and the copy never block the UI.
    nonisolated static func pngData(from pixels: MLXArray) throws -> Data {
        let h = pixels.dim(2), w = pixels.dim(3)
        let hwc = pixels[0].transposed(1, 2, 0)                        // (H,W,3)
        let u8 = clip(hwc * 255, min: 0, max: 255).asType(.uint8)
        eval(u8)
        let rgb = u8.asArray(UInt8.self)                              // H*W*3
        var rgba = [UInt8](repeating: 255, count: h * w * 4)
        for i in 0 ..< (h * w) {
            rgba[i * 4] = rgb[i * 3]; rgba[i * 4 + 1] = rgb[i * 3 + 1]; rgba[i * 4 + 2] = rgb[i * 3 + 2]
        }
        let raw = Data(rgba)
        guard let provider = CGDataProvider(data: raw as CFData),
              let cg = CGImage(
                  width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw GenerateError.imageConversion }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw GenerateError.imageConversion }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw GenerateError.imageConversion }
        return out as Data
    }
}

enum GenerateError: LocalizedError {
    case imageConversion
    var errorDescription: String? {
        switch self {
        case .imageConversion: return "Couldn't convert the rendered pixels to a PNG image."
        }
    }
}

enum ModelWeightLoadVerificationError: LocalizedError, Equatable {
    case unknownModel(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownModel(let model):
            return "The selected model is not present in the pinned model manifest: \(model)."
        case .verificationFailed(let path):
            return "Model verification failed immediately before loading: \(path). Re-link or import the official weights in Models."
        }
    }
}

enum PortableRecipeTransferError: LocalizedError, Equatable {
    case busy

    var errorDescription: String? {
        "Wait for local inference or model-file changes to finish before applying a recipe."
    }
}

enum PresetQueueError: LocalizedError {
    case queueIsRunning
    case queueUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .queueIsRunning:
            return "Wait for the running queue to stop before adding another preset."
        case .queueUnavailable(let message):
            return message
        }
    }
}
