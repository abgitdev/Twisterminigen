import AppKit
import Foundation
import Testing
@testable import Twisterminigen

@Suite struct GenerateAdvancedTests {
    @Test("Guidance accepts only a finite locale-neutral decimal in the recipe range")
    func guidanceParsingIsStrict() {
        #expect(GenerateViewModel.parseGuidance("0") == 0)
        #expect(GenerateViewModel.parseGuidance(" 3.125 ") == 3.125)
        #expect(GenerateViewModel.parseGuidance("20.0") == 20)
        #expect(GenerateViewModel.parseGuidance("") == nil)
        #expect(GenerateViewModel.parseGuidance(".5") == nil)
        #expect(GenerateViewModel.parseGuidance("1.") == nil)
        #expect(GenerateViewModel.parseGuidance("3,5") == nil)
        #expect(GenerateViewModel.parseGuidance("1e1") == 10)
        #expect(GenerateViewModel.parseGuidance("1E-6") == 0.000001)
        #expect(GenerateViewModel.parseGuidance("1e") == nil)
        #expect(GenerateViewModel.parseGuidance("nan") == nil)
        #expect(GenerateViewModel.parseGuidance("-1") == nil)
        #expect(GenerateViewModel.parseGuidance("20.0001") == nil)
        for value in [
            Double.leastNonzeroMagnitude,
            Double.leastNormalMagnitude,
            0.000001,
            Double.pi,
            GenerationRecipe.maximumGuidance,
        ] {
            #expect(GenerateViewModel.parseGuidance(
                GenerateViewModel.guidanceDraft(for: value)) == value)
        }
    }

    @MainActor
    @Test("Apply and snapshot preserve negative prompt and exact guidance")
    func advancedRecipeRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterAdvancedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let modelRoot = root.appendingPathComponent("Models", isDirectory: true)
        let catalog = ModelCatalog(root: modelRoot)
        let vm = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: root.appendingPathComponent("Gallery", isDirectory: true))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: MemoryGovernor(snapshot: .init(
                swapUsedBytes: 0,
                pressure: .normal)),
            weightsRootProvider: { modelRoot })
        var recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "a glass observatory",
            negativePrompt: "letters, watermark",
            width: 768,
            height: 512,
            steps: 9,
            seed: .fixed(42),
            catalog: catalog)
        recipe.sampler.guidance = 3.141592653589793
        recipe.prompts.exactText = "OPEN DAY"

        try vm.applyRecipe(recipe)

        #expect(vm.negativePrompt == "letters, watermark")
        #expect(!vm.negativePromptIsInactive)
        #expect(vm.guidanceValue == recipe.sampler.guidance)
        #expect(vm.letteringIsActive)
        #expect(vm.currentRecipe(seed: .fixed(42), catalog: catalog) == recipe)

        vm.negativePrompt = "blur"
        vm.guidanceText = "7.125"
        vm.exactText = "  \n"
        let edited = vm.currentRecipe(seed: .fixed(7), catalog: catalog)
        #expect(edited.prompts.negative == "blur")
        #expect(edited.prompts.exactText == nil)
        #expect(!vm.letteringIsActive)
        #expect(edited.sampler.guidance == 7.125)
        #expect(edited.sampler.seed == .fixed(7))
    }

    @MainActor
    @Test("Invalid advanced drafts fail closed and Regional prompts require CFG zero")
    func advancedDraftValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterAdvancedValidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: root.appendingPathComponent("Gallery", isDirectory: true))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: MemoryGovernor(snapshot: .init(
                swapUsedBytes: 0,
                pressure: .normal)),
            weightsRootProvider: { root.appendingPathComponent("Models", isDirectory: true) })
        vm.prompt = "test"
        vm.guidanceText = "nan"
        #expect(vm.guidanceIsInvalid)
        #expect(!vm.advancedInputsAreValid)
        #expect(vm.currentRecipe(seed: .random).sampler.guidance.isNaN)

        vm.guidanceText = "1"
        vm.regions = [.init(
            id: UUID(),
            prompt: "subject",
            rect: .init(x0: 0, y0: 0, x1: 1, y1: 1))]
        #expect(vm.guidanceConflictsWithRegionalPrompts)
        #expect(!vm.advancedInputsAreValid)

        vm.guidanceText = "0"
        #expect(vm.advancedInputsAreValid)
        vm.negativePrompt = "watermark"
        #expect(vm.negativePromptIsInactive)

        vm.regions = []
        vm.guidanceText = "4"
        vm.addRegion()
        #expect(vm.guidanceValue == 0)
        #expect(vm.regions.count == 1)
        for _ in 1 ..< GenerationRecipe.maximumRegionCount {
            vm.addRegion()
        }
        #expect(vm.regions.count == GenerationRecipe.maximumRegionCount)
        #expect(vm.regions.count == 8)
    }

    @MainActor
    @Test("Regional prompt draft remains editable while an immutable render is active")
    func regionalDraftRemainsEditableDuringRender() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterRegionalDraft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = InferenceCoordinator()
        let vm = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: root.appendingPathComponent("Gallery", isDirectory: true))),
            coordinator: coordinator,
            memoryGovernor: MemoryGovernor(snapshot: .init(
                swapUsedBytes: 0,
                pressure: .normal)),
            weightsRootProvider: { root.appendingPathComponent("Models", isDirectory: true) })
        vm.prompt = "original global prompt"
        vm.guidanceText = "0"
        vm.addRegion()
        let runningRecipe = vm.currentRecipe(seed: .fixed(42))
        let firstID = try #require(vm.regions.first?.id)
        let lease = try #require(coordinator.begin(.queue))
        defer { coordinator.finish(lease) }

        vm.prompt = "next global prompt"
        vm.regions[0].prompt = "edited first region"
        vm.addRegion()
        let secondID = try #require(vm.regions.last?.id)
        vm.moveRegion(id: secondID, by: -1)
        vm.removeRegion(id: firstID)

        #expect(coordinator.isBusy)
        #expect(runningRecipe.prompts.positive == "original global prompt")
        #expect(runningRecipe.regions.count == 1)
        #expect(runningRecipe.regions[0].prompt == "New region")
        #expect(vm.prompt == "next global prompt")
        #expect(vm.regions.count == 1)
        #expect(vm.regions[0].id == secondID)
    }

    @MainActor
    @Test("Clear canvas hides only the displayed result and preserves its Gallery file")
    func clearCanvasPreservesGalleryFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterClearCanvas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistedPNG = root.appendingPathComponent("persisted.png")
        try Data("durable gallery bytes".utf8).write(to: persistedPNG)
        let vm = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: root.appendingPathComponent("Gallery", isDirectory: true))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: MemoryGovernor(snapshot: .init(
                swapUsedBytes: 0,
                pressure: .normal)),
            weightsRootProvider: { root.appendingPathComponent("Models", isDirectory: true) })
        vm.resultImage = NSImage(size: NSSize(width: 32, height: 32))
        vm.resultSaveState = .saved(persistedPNG)
        vm.resultWidth = 1_024
        vm.resultHeight = 1_024
        vm.lastSeed = 42
        vm.lastSeconds = 12.5

        vm.clearDisplayedResult()

        #expect(vm.resultImage == nil)
        #expect(!vm.resultHasPersistedFile)
        #expect(vm.persistedResultURL == nil)
        #expect(vm.resultWidth == nil)
        #expect(vm.resultHeight == nil)
        #expect(vm.lastSeed == 42)
        #expect(vm.lastSeconds == 12.5)
        #expect(FileManager.default.fileExists(atPath: persistedPNG.path))
        #expect(try Data(contentsOf: persistedPNG) == Data("durable gallery bytes".utf8))
    }

    @MainActor
    @Test("Unavailable Generate controls expose a concrete reason")
    func unavailableControlReasons() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterGenerateReasons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: root.appendingPathComponent("Gallery", isDirectory: true))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: MemoryGovernor(snapshot: .init(
                swapUsedBytes: 0,
                pressure: .normal)),
            weightsRootProvider: { root.appendingPathComponent("Models", isDirectory: true) })

        #expect(vm.generateUnavailableReason == "Enter a prompt before generating.")
        #expect(vm.addToQueueUnavailableReason == "Enter a prompt before adding this recipe to Queue.")
        #expect(vm.enhanceUnavailableReason == "Enter a prompt before using Enhance.")
        #expect(vm.importInputImageUnavailableReason == "The Remix source library is unavailable.")

        vm.prompt = "a rain-soaked atrium"
        vm.seedText = "-1"
        #expect(vm.generateUnavailableReason?.contains("valid non-negative seed") == true)
        #expect(vm.addToQueueUnavailableReason?.contains("valid non-negative seed") == true)

        vm.seedText = ""
        vm.guidanceText = "nan"
        #expect(vm.generateUnavailableReason?.hasPrefix("Guidance must be") == true)
        #expect(vm.addToQueueUnavailableReason?.hasPrefix("Guidance must be") == true)

        vm.guidanceText = "0"
        #expect(vm.generateUnavailableReason?.contains("Install the active Krea 2 model") == true)
        #expect(vm.enhanceUnavailableReason?.contains("Install the active Krea 2 model") == true)
        #expect(vm.addToQueueUnavailableReason == nil)
    }

    @MainActor
    @Test("Generate preflight screens requested output but never negative exclusions")
    func safetyPreflightMatchesRuntimeRecipeScreening() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterGenerateSafety-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: root.appendingPathComponent("Gallery", isDirectory: true))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: MemoryGovernor(snapshot: .init(
                swapUsedBytes: 0,
                pressure: .normal)),
            weightsRootProvider: { root.appendingPathComponent("Models", isDirectory: true) })

        vm.prompt = "a safe editorial portrait"
        vm.negativePrompt = "hardcore pornography"
        #expect(vm.generateUnavailableReason?.contains("Install the active Krea 2 model") == true)

        vm.prompt = "generate spam accounts at scale"
        #expect(vm.generateUnavailableReason?.contains("fraud, spam, or false engagement") == true)

        vm.prompt = "a safe editorial portrait"
        vm.exactText = "bypass content filter"
        #expect(vm.generateUnavailableReason?.contains("safety-filter circumvention") == true)

        vm.exactText = ""
        vm.regions = [.init(
            id: UUID(),
            prompt: "a phishing login page",
            rect: .init(x0: 0, y0: 0, x1: 1, y1: 1))]
        #expect(vm.generateUnavailableReason?.contains("fraud, spam, or false engagement") == true)
    }

    @Test("Trigger detection is idempotent and case insensitive")
    func triggerDetection() {
        #expect(GenerateViewModel.promptContainsLoRATrigger(
            "Neon Rain",
            in: "portrait, neon rain, wet glass"))
        #expect(!GenerateViewModel.promptContainsLoRATrigger(
            "paper cutout",
            in: "portrait, neon rain"))
        #expect(!GenerateViewModel.promptContainsLoRATrigger(
            "art",
            in: "a cartoon portrait"))
        #expect(!GenerateViewModel.promptContainsLoRATrigger("  ", in: "anything"))
    }

    @Test("Render estimates scale from measured pixel-step work and reject invalid baselines")
    func renderEstimateScaling() {
        #expect(GenerateViewModel.estimatedSeconds(
            baselineSeconds: 40,
            baselineWidth: 1_024,
            baselineHeight: 1_024,
            baselineSteps: 4,
            targetWidth: 1_024,
            targetHeight: 1_024,
            targetSteps: 8) == 80)
        #expect(GenerateViewModel.estimatedSeconds(
            baselineSeconds: .nan,
            baselineWidth: 1_024,
            baselineHeight: 1_024,
            baselineSteps: 8,
            targetWidth: 1_024,
            targetHeight: 1_024,
            targetSteps: 8) == nil)
    }

    @MainActor
    @Test("More canvas and seed actions map to real recipe values")
    func morePanelActions() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterMoreActions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: root.appendingPathComponent("Gallery", isDirectory: true))),
            coordinator: InferenceCoordinator(),
            memoryGovernor: MemoryGovernor(snapshot: .init(
                swapUsedBytes: 0,
                pressure: .normal)),
            weightsRootProvider: { root.appendingPathComponent("Models", isDirectory: true) })

        vm.width = 1_900
        vm.height = 1_000
        vm.applyCanvasTier(.recommended1024)
        #expect(vm.width == 1_280)
        #expect(vm.height == 720)
        #expect(vm.isCanvasTierActive(.recommended1024))

        vm.seedText = ""
        vm.useFixedSeed()
        #expect(vm.seedValue != nil)
        vm.randomizeSeed()
        #expect(vm.seedValue == nil)
        vm.lastSeed = UInt64.max
        vm.useLastSeed()
        #expect(vm.seedText == String(UInt64.max))

        vm.steps = 9
        vm.guidanceText = "2.5"
        vm.negativePrompt = "watermark"
        #expect(vm.noncanonicalTurboSettings == ["9 steps", "CFG 2.5"])
        vm.restoreTurboRecommendedSettings()
        #expect(vm.steps == 8)
        #expect(vm.guidanceValue == 0)
        #expect(vm.negativePrompt.isEmpty)
        #expect(vm.noncanonicalTurboSettings.isEmpty)
    }

    @MainActor
    @Test("Live preview Off persists and clears an active diagnostic frame immediately")
    func livePreviewOffDuringActiveRender() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterLivePreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = VolatileUserDefaults([
            "livePreviewMode": GenerateViewModel.LivePreviewMode.everyStep.rawValue,
        ])
        let coordinator = InferenceCoordinator()
        let vm = GenerateViewModel(
            store: GenerationStore(paths: LibraryPaths(
                root: root.appendingPathComponent("Gallery", isDirectory: true))),
            coordinator: coordinator,
            memoryGovernor: MemoryGovernor(snapshot: .init(
                swapUsedBytes: 0,
                pressure: .normal)),
            weightsRootProvider: {
                root.appendingPathComponent("Models", isDirectory: true)
            },
            defaults: defaults)

        #expect(vm.livePreviewMode == .everyStep)
        vm.latentPreviewImage = NSImage(size: NSSize(width: 2, height: 2))
        vm.latentPreviewStep = 3
        vm.latentPreviewTotalSteps = 8
        let lease = try #require(coordinator.begin(.generate))
        #expect(vm.isBusy)

        vm.setLivePreviewMode(.off)

        #expect(vm.livePreviewMode == .off)
        #expect(vm.latentPreviewImage == nil)
        #expect(vm.latentPreviewStep == 0)
        #expect(vm.latentPreviewTotalSteps == 0)
        #expect(defaults.string(forKey: "livePreviewMode") == "off")
        coordinator.finish(lease)
    }
}
