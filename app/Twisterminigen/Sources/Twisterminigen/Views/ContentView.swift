import SwiftUI
import AppKit

/// Live app sections shown in the sidebar in the same order used by keyboard navigation.
enum AppSection: String, CaseIterable, Identifiable {
    case generate
    case queue
    case gallery
    case presets
    case models
    case lora
    case system
    case help

    var id: String { rawValue }

    /// Stable Command-key navigation order, matching the visible tab order.
    var shortcutNumber: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    var title: String {
        switch self {
        case .generate: return "Generate"
        case .queue:    return "Queue"
        case .gallery:  return "Gallery"
        case .presets:  return "Presets"
        case .models:   return "Models"
        case .lora:     return "LoRA"
        case .system:   return "System"
        case .help:     return "Help"
        }
    }

    var icon: String {
        switch self {
        case .generate: return "wand.and.stars"
        case .queue:    return "list.bullet.rectangle"
        case .gallery:  return "photo.on.rectangle.angled"
        case .presets:  return "slider.horizontal.3"
        case .models:   return "cube"
        case .lora:     return "point.3.connected.trianglepath.dotted"
        case .system:   return "gauge.with.dots.needle.bottom.50percent"
        case .help:     return "questionmark.circle"
        }
    }

    var help: String {
        switch self {
        case .generate: return "Create an image from a prompt with the Krea 2 engine"
        case .queue:    return "Line up prompts and run them one after another"
        case .gallery:  return "Browse and manage earlier renders"
        case .presets:  return "Reusable local visual recipes for Krea 2 Turbo"
        case .models:   return "Download and manage the Krea 2 weights"
        case .lora:     return "Import, order, and scale local LoRA adapters"
        case .system:   return "Live telemetry and maintenance"
        case .help:     return "Reference cheat sheet + a replayable welcome overview"
        }
    }

}

/// Root window: custom title bar + top tab bar + detail + bottom telemetry status bar.
struct ContentView: View {
    @Bindable var generateVM: GenerateViewModel
    @Bindable var galleryVM: GalleryViewModel
    @Bindable var modelsVM: ModelsViewModel
    @Bindable var loraVM: LoRAViewModel
    @Bindable var describeImageVM: DescribeImageViewModel
    @Bindable var localUpscaleVM: LocalUpscaleViewModel
    let presetStore: PresetLibraryStore?
    @Bindable var telemetry: TelemetryService
    @Bindable var inference: InferenceCoordinator

    @State private var section: AppSection = OnboardingLaunchPolicy.initialSection(
        modelsReady: GenerateViewModel.modelsReady(
            in: ModelCatalog(root: AppPaths.weightsRoot)),
        environmentOverride: ProcessInfo.processInfo.environment["TWISTERMINIGEN_SECTION"])
    @State private var presetCreationRequest: PresetCreationRequest?
    @State private var restoredExperiment: RestoredExperimentPresentation?
    @State private var showsDescribeImage = false
    @State private var showsOnboarding = false
    @State private var portableRecipeImportNotice: PortableRecipeImportNotice?
    @State private var queueNotificationRouter = QueueNotificationRouter.shared
    @Environment(\.fxTheme) private var theme

    var body: some View {
        ZStack {
            FxAppBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                FxTitleBar { titleBarTrailing }
                FxTabBar(section: $section, busy: inference.isBusy, tail: tabTail)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                FxStatusBar { statusTrailing }
            }
        }
        .background(theme == .glass ? Color.fxOpaqueBg : Color.fxBg)
        .task {
            await generateVM.restorePersistedQueue()
            telemetry.start()
            galleryVM.reload()
            modelsVM.refresh()
            await loraVM.refresh()
            generateVM.refreshModelsReady()
            if OnboardingLaunchPolicy.shouldPresent() {
                // A first launch with absent weights is intentionally useful: the Models screen
                // remains visible behind the tour and is the destination after Skip/Finish.
                if !generateVM.modelsReady { section = .models }
                showsOnboarding = true
            }
        }
        // Refresh the gallery whenever Generate saves a new image.
        .onChange(of: generateVM.savedImageCount) { _, _ in galleryVM.reload() }
        // Re-check model readiness when entering Generate or after the on-disk weights change.
        .onChange(of: section) { _, s in if s == .generate { generateVM.refreshModelsReady() } }
        .onChange(of: modelsVM.revision) { _, _ in generateVM.refreshModelsReady() }
        .onChange(of: queueNotificationRouter.pendingRoute?.id, initial: true) { _, _ in
            guard let route = queueNotificationRouter.takePendingRoute() else { return }
            handleQueueNotification(route)
        }
        .onOpenURL { url in
            Task { @MainActor in
                do {
                    let report = try await generateVM.importPortableRecipe(from: url)
                    applyPortableRecipeOpenResolution(.completed(report))
                } catch {
                    applyPortableRecipeOpenResolution(
                        .failed(errorDescription: error.localizedDescription))
                }
            }
        }
        .alert(item: $portableRecipeImportNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK")))
        }
        .sheet(item: $restoredExperiment) { presentation in
            QueueLabView(vm: generateVM, context: presentation.context)
        }
        .sheet(isPresented: $showsDescribeImage) {
            DescribeImageSheet(
                viewModel: describeImageVM,
                onUseDescription: { description in
                    generateVM.prompt = description
                    section = .generate
                    showsDescribeImage = false
                },
                onDismiss: { showsDescribeImage = false })
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView {
                OnboardingLaunchPolicy.markSeen()
                if !generateVM.modelsReady { section = .models }
                showsOnboarding = false
            }
        }
        .focusedSceneValue(
            \.appNavigationActions,
            AppNavigationActions { destination in section = destination })
    }

    // ── Header right group: live step/% + ETA pill + model chip + settings ──
    @ViewBuilder private var titleBarTrailing: some View {
        if inference.isBusy {
            Text(busyLine)
                .fxMonoFont(11.5)
                .foregroundStyle(theme == .glass ? FxGlassPalette.headerMuted : Color.fxHdrMuted)
                .help("Live render progress.")
            if let eta = generateVM.etaText {
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text(eta)
                }
                .fxMonoFont(11)
                .foregroundStyle(theme == .glass ? FxGlassPalette.headerText : Color.fxHdrText)
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(
                    theme == .glass ? FxGlassPalette.headerButton : Color.fxHdrBtnBg,
                    in: Capsule())
                .overlay(Capsule().strokeBorder(
                    theme == .glass
                        ? FxGlassPalette.headerButtonBorder
                        : Color.fxHdrBtnBorder,
                    lineWidth: 1))
                .help("Estimated time remaining.")
            }
        }
        FxModelChip(name: "Krea 2", state: modelStateName)
            .help(modelStateHelp)
    }

    private var busyLine: String {
        if case let .denoising(step, total) = inference.phase, total > 0 {
            let pct = Int((Double(step) / Double(total) * 100).rounded())
            return "step \(step)/\(total) · \(pct)%"
        }
        return inference.statusText
    }

    private var activityName: String {
        switch inference.activeOperation {
        case .enhance: return "enhancing"
        case .describe: return "describing"
        case .upscale: return "upscaling"
        case .generate, .queue: return "rendering"
        case nil: return "ready"
        }
    }

    private var modelStateName: String {
        if inference.isBusy { return activityName }
        if modelsVM.isSwitchingRoot { return "switching" }
        if modelsVM.isRefreshing { return "verifying" }
        return modelsVM.selectedModelReady ? "ready" : "not ready"
    }

    private var modelStateHelp: String {
        if modelsVM.isRefreshing {
            return "Checking the local model files against the pinned manifest."
        }
        if modelsVM.selectedModelReady {
            return "\(modelsVM.selectedDescriptor.displayName) is ready. Weights load from disk on each render."
        }
        return "\(modelsVM.selectedDescriptor.displayName) needs its required components on the Models screen."
    }

    @ViewBuilder private var detail: some View {
        Group {
            switch section {
            case .generate:
                GenerateView(
                    vm: generateVM,
                    onSavePreset: queuePresetCreation,
                    onDescribeImage: { showsDescribeImage = true },
                    onOpenModels: { section = .models },
                    onManageLoRA: { section = .lora })
            case .queue:    QueueView(vm: generateVM, section: $section)
            case .gallery:
                GalleryFaithfulView(
                    vm: galleryVM,
                    localUpscaleVM: localUpscaleVM,
                    onUseRecipe: { generation in
                        do {
                            try generateVM.applyRecipe(generation.recipe)
                            section = .generate
                        } catch {
                            galleryVM.reportUseSettingsError(error)
                        }
                    },
                    onRemix: { generation in
                        let prepared = await generateVM.beginRemix(from: generation)
                        if prepared { section = .generate }
                        return prepared
                    },
                    onSavePreset: queuePresetCreation,
                    onOpenExperiment: { context in
                        section = .queue
                        restoredExperiment = RestoredExperimentPresentation(context: context)
                    })
            case .presets:
                if let presetStore {
                    PresetsLibraryView(
                        store: presetStore,
                        gallery: galleryVM,
                        makeNewDraft: makeNewPresetDraft,
                        onApply: { recipe in
                            try await generateVM.applyPresetRecipe(recipe)
                            section = .generate
                        },
                        onAddToQueue: { recipe in
                            try await generateVM.enqueuePresetRecipe(recipe)
                            section = .queue
                        },
                        creationRequest: $presetCreationRequest)
                } else {
                    PresetStorageUnavailableView()
                }
            case .models:   ModelsFaithfulView(vm: modelsVM)
            case .lora:     LoRAView(vm: loraVM)
            case .system:   SystemFaithfulView(
                telemetry: telemetry,
                gallery: galleryVM,
                models: modelsVM,
                lora: loraVM,
                inference: inference,
                generate: generateVM)
            case .help:     HelpView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.\(section.rawValue)")
    }

    // ── Tabs are clean in the maket — no trailing accessories ─────────────────
    private func tabTail(_ s: AppSection) -> AnyView? { nil }

    // ── Bottom status bar telemetry (same on every view) ──────────────────────
    @ViewBuilder private var statusTrailing: some View {
        let s = telemetry.snapshot
        FxStat(label: "CPU", value: "\(Int(s.cpuPercent.rounded()))%").help("Live CPU load.")
        StatusSep(tint: Color(hex: 0xE0D271))
        FxStat(label: "GPU", value: "\(Int(s.gpuPercent.rounded()))%").help("Live GPU utilization.")
        StatusSep(tint: Color.fxOk)
        FxStat(label: "RAM", value: ramPair(s)).help("Memory in use across the whole Mac / total installed.")
        StatusSep(tint: Color.fxOk)
        FxStat(label: "MLX", value: ByteFormat.string(s.appFootprintBytes), accent: true)
            .help("MLX / app memory held right now — spikes during a render.")
        StatusSep(tint: Color(hex: 0x65CBB0))
        FxStat(label: "Disk", value: "\(ByteFormat.string(s.diskFreeBytes)) free")
            .help("Free space on the images volume.")
    }

    /// "9.3 / 32 GB" — drops the used-side unit when both sides share it.
    private func ramPair(_ s: TelemetrySnapshot) -> String {
        let used = ByteFormat.string(s.systemUsedBytes)
        let total = ByteFormat.string(s.systemTotalBytes)
        if let unit = total.split(separator: " ").last, used.hasSuffix(" \(unit)") {
            return "\(used.dropLast(unit.count + 1)) / \(total)"
        }
        return "\(used) / \(total)"
    }

    private func makeNewPresetDraft() -> PresetCardDraft {
        var recipe = generateVM.currentRecipe(seed: .random)
        if recipe.prompts.positive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recipe.prompts.positive = "A carefully composed original image with clear subject, light, material, and color."
        }
        return PresetCardDraft(
            categoryID: "moments",
            title: "",
            summary: "",
            recipe: recipe)
    }

    private func queuePresetCreation(_ generation: Generation) {
        Task {
            do {
                let coverData = try await galleryVM.pngDataForPreset(generation)
                presetCreationRequest = PresetCreationRequest(
                    id: generation.id,
                    draft: PresetCardDraft(
                        categoryID: "moments",
                        title: "",
                        summary: "",
                        recipe: generation.recipe),
                    coverData: coverData)
                section = .presets
            } catch {
                galleryVM.errorMessage = "Couldn’t prepare this image as a preset cover: \(error.localizedDescription)"
            }
        }
    }

    private func applyPortableRecipeOpenResolution(
        _ resolution: PortableRecipeOpenResolution
    ) {
        if let destination = resolution.destination { section = destination }
        portableRecipeImportNotice = resolution.notice
    }

    /// Notification actions always resolve against a fresh persisted Gallery snapshot. This avoids
    /// remixing a stale in-memory item when the Gallery tab has not been opened during the queue run.
    private func handleQueueNotification(_ route: QueueNotifier.Route) {
        switch route.action {
        case .openGallery:
            galleryVM.reload()
            section = .gallery
        case .remix:
            Task { @MainActor in
                let generations = await galleryVM.reloadAndWait()
                guard let generationID = route.generationID,
                      let generation = generations.first(where: { $0.id == generationID })
                else {
                    galleryVM.errorMessage = "This queue result is no longer available for Remix."
                    section = .gallery
                    return
                }
                if await generateVM.beginRemix(from: generation) {
                    section = .generate
                } else {
                    let reason = generateVM.errorMessage
                        ?? "The selected queue result could not be prepared for Remix."
                    generateVM.errorMessage = nil
                    galleryVM.errorMessage = "Remix failed: \(reason)"
                    section = .gallery
                }
            }
        }
    }
}

/// Root-level result for Finder/document-open recipe imports. The optional destination is nil on
/// failure, so a user already looking at Models or another section is not silently redirected.
struct PortableRecipeOpenResolution {
    let destination: AppSection?
    let notice: PortableRecipeImportNotice

    static func completed(_ report: PortableRecipeImportReport) -> Self {
        if report.canApply {
            return Self(
                destination: .generate,
                notice: PortableRecipeImportNotice(
                    kind: .loaded,
                    title: "Recipe loaded",
                    message: report.summary + "\n\nNo render was started."))
        }
        return Self(
            destination: nil,
            notice: PortableRecipeImportNotice(
                kind: .dependenciesMissing,
                title: "Recipe dependencies missing",
                message: report.summary
                    + "\n\nThe current section and Generate settings were not changed."))
    }

    static func failed(errorDescription: String) -> Self {
        Self(
            destination: nil,
            notice: PortableRecipeImportNotice(
                kind: .failed,
                title: "Recipe import failed",
                message: errorDescription))
    }
}

struct PortableRecipeImportNotice: Identifiable {
    enum Kind: Equatable {
        case loaded
        case dependenciesMissing
        case failed
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

struct AppNavigationActions {
    let select: (AppSection) -> Void
}

private struct AppNavigationActionsKey: FocusedValueKey {
    typealias Value = AppNavigationActions
}

extension FocusedValues {
    var appNavigationActions: AppNavigationActions? {
        get { self[AppNavigationActionsKey.self] }
        set { self[AppNavigationActionsKey.self] = newValue }
    }
}

private struct RestoredExperimentPresentation: Identifiable {
    let id = UUID()
    let context: ExperimentContext
}

private struct PresetStorageUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34)).foregroundStyle(Color.fxDanger)
            Text("Preset storage is unavailable")
                .fxFont(16, weight: .bold).foregroundStyle(Color.fxText2)
            Text("Check the Application Support folder permissions, then relaunch Twisterminigen.")
                .fxFont(12).foregroundStyle(Color.fxText3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fxPageBackground()
    }
}
