import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Explicit, offline image tools for one verified Gallery PNG.
///
/// Opening this sheet performs no analysis. Palette extraction and Apple Vision cut-out each start
/// only from their own button, and neither changes a prompt or writes a file without another click.
struct GalleryImageToolsSheet: View {
    let basePrompt: String
    let sourceSize: LocalUpscalePixelSize
    let sourceGeneration: Generation
    let loadProtectedExportRoots: @MainActor @Sendable () async -> [URL]
    @Bindable var localUpscaleVM: LocalUpscaleViewModel
    let loadPNGData: () async throws -> Data
    let onUsePrompt: (String) throws -> Void

    init(
        basePrompt: String,
        sourceSize: LocalUpscalePixelSize,
        sourceGeneration: Generation,
        loadProtectedExportRoots: @escaping @MainActor @Sendable () async -> [URL],
        localUpscaleVM: LocalUpscaleViewModel,
        loadPNGData: @escaping () async throws -> Data,
        onUsePrompt: @escaping (String) throws -> Void
    ) {
        self.basePrompt = basePrompt
        self.sourceSize = sourceSize
        self.sourceGeneration = sourceGeneration
        self.loadProtectedExportRoots = loadProtectedExportRoots
        self.localUpscaleVM = localUpscaleVM
        self.loadPNGData = loadPNGData
        self.onUsePrompt = onUsePrompt
    }

    init(
        basePrompt: String,
        sourceSize: LocalUpscalePixelSize,
        sourceGeneration: Generation,
        loadProtectedExportRoots: @escaping @MainActor @Sendable () async -> [URL],
        localUpscaleVM: LocalUpscaleViewModel,
        sourceData: Data,
        onUsePrompt: @escaping (String) throws -> Void
    ) {
        self.init(
            basePrompt: basePrompt,
            sourceSize: sourceSize,
            sourceGeneration: sourceGeneration,
            loadProtectedExportRoots: loadProtectedExportRoots,
            localUpscaleVM: localUpscaleVM,
            loadPNGData: { sourceData },
            onUsePrompt: onUsePrompt)
    }

    init(
        basePrompt: String,
        sourceSize: LocalUpscalePixelSize,
        sourceGeneration: Generation,
        loadProtectedExportRoots: @escaping @MainActor @Sendable () async -> [URL],
        localUpscaleVM: LocalUpscaleViewModel,
        sourceURL: URL,
        onUsePrompt: @escaping (String) throws -> Void
    ) {
        self.init(
            basePrompt: basePrompt,
            sourceSize: sourceSize,
            sourceGeneration: sourceGeneration,
            loadProtectedExportRoots: loadProtectedExportRoots,
            localUpscaleVM: localUpscaleVM,
            loadPNGData: { try await BoundedImageDecoder.dataAsync(at: sourceURL) },
            onUsePrompt: onUsePrompt)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fxTheme) private var theme
    @State private var sourceData: Data?
    @State private var palette: ImagePalette?
    @State private var selectedColors = Set<String>()
    @State private var paletteError: String?
    @State private var extractingPalette = false
    @State private var paletteTask: Task<Void, Never>?
    @State private var cutout: ForegroundCutoutService.Cutout?
    @State private var cutoutError: String?
    @State private var makingCutout = false
    @State private var cutoutTask: Task<Void, Never>?
    @State private var saveError: String?
    @State private var upscalePreparationError: String?
    @State private var preparingUpscale = false
    @State private var upscalePreparationTask: Task<Void, Never>?
    @State private var showsUpscaleLicense = false
    @State private var confirmsUpscaleModelRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.fxBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    paletteSection
                    cutoutSection
                    upscaleSection
                }
                .padding(20)
            }
        }
        .frame(width: 660, height: 760)
        .background(theme == .dark ? Color.fxSheet : Color.clear)
        .fxStandalonePageBackground()
        .accessibilityIdentifier("gallery.image-tools.sheet")
        .task {
            localUpscaleVM.prepareForImageTools()
            await localUpscaleVM.refresh()
        }
        .interactiveDismissDisabled(isWorking)
        .onDisappear {
            paletteTask?.cancel()
            cutoutTask?.cancel()
            upscalePreparationTask?.cancel()
            localUpscaleVM.cancel()
            localUpscaleVM.discardPreparedResult()
        }
        .sheet(isPresented: $showsUpscaleLicense) {
            LocalUpscaleLicenseSheet(
                evidence: localUpscaleVM.license,
                modelName: localUpscaleVM.model.displayName,
                onAccept: {
                    localUpscaleVM.acceptLicense()
                    showsUpscaleLicense = false
                },
                onCancel: { showsUpscaleLicense = false })
        }
        .confirmationDialog(
            "Remove the local 4× model?",
            isPresented: $confirmsUpscaleModelRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove model", role: .destructive) { localUpscaleVM.startRemove() }
                .accessibilityIdentifier("gallery.image-tools.upscale.remove-confirm")
                .help("Remove only the verified local 4× model weights from this Mac.")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("gallery.image-tools.upscale.remove-cancel")
                .help("Keep the local 4× model installed.")
        } message: {
            Text("This removes only the optional Real-ESRGAN weights. Gallery images and exported 4× PNGs remain untouched.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.rays")
                .foregroundStyle(Color.fxAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Image tools")
                    .fxFont(16, weight: .semibold)
                    .foregroundStyle(Color.fxText)
                Text("Local on this Mac · nothing runs until you choose an action")
                    .fxFont(10.5)
                    .foregroundStyle(Color.fxText3)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(FxSecondaryButtonStyle(height: 30))
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)
                .accessibilityIdentifier("gallery.image-tools.close")
                .help(isWorking
                      ? "Close is unavailable while \(activeWorkDescription)."
                      : "Close Image tools without changing the Gallery image.")
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                icon: "paintpalette",
                title: "Palette → prompt",
                detail: "Extract deterministic dominant colours from a bounded 160 px thumbnail. Review and select swatches before copying or using them.")

            HStack(spacing: 10) {
                Button {
                    extractPalette()
                } label: {
                    if extractingPalette {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(palette == nil ? "Extract palette" : "Extract again", systemImage: "eyedropper.halffull")
                    }
                }
                .buttonStyle(FxSecondaryButtonStyle(height: 32))
                .disabled(isWorking)
                .accessibilityIdentifier("gallery.image-tools.palette.extract")
                .help(isWorking
                      ? "Palette extraction is unavailable while \(activeWorkDescription)."
                      : "Read dominant colours locally. This does not change the current prompt.")

                if let palette, !palette.isEmpty {
                    Text("\(selectedColors.count) of \(palette.colors.count) selected")
                        .fxMonoFont(10.5, weight: .medium)
                        .foregroundStyle(Color.fxText3)
                }
                Spacer()
            }

            if let paletteError {
                errorRow(paletteError)
            }

            if let palette, !palette.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 58, maximum: 72), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(Array(palette.colors.enumerated()), id: \.offset) { index, hex in
                        paletteSwatch(hex, index: index)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Prompt modifier")
                        .fxFont(10.5, weight: .semibold)
                        .foregroundStyle(Color.fxText3)
                    Text(selectedPalette.promptModifier.isEmpty
                         ? "Select at least one colour."
                         : selectedPalette.promptModifier)
                        .fxMonoFont(11)
                        .foregroundStyle(selectedPalette.isEmpty ? Color.fxText3 : Color.fxText2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .fxThemedSurface(.inset, radius: 8)
                }

                HStack(spacing: 8) {
                    Button {
                        copyModifier()
                    } label: {
                        Label("Copy modifier", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .disabled(selectedPalette.isEmpty)
                    .accessibilityIdentifier("gallery.image-tools.palette.copy-modifier")
                    .help(selectedPalette.isEmpty
                          ? "Copy modifier is unavailable until at least one palette colour is selected."
                          : "Copy the selected palette colours as a prompt modifier.")

                    Button {
                        copyFullPrompt()
                    } label: {
                        Label("Copy full prompt", systemImage: "text.badge.plus")
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .disabled(selectedPalette.isEmpty)
                    .accessibilityIdentifier("gallery.image-tools.palette.copy-full-prompt")
                    .help(selectedPalette.isEmpty
                          ? "Copy full prompt is unavailable until at least one palette colour is selected."
                          : "Copy the current prompt with the selected palette modifier appended.")

                    Spacer()

                    Button {
                        usePrompt()
                    } label: {
                        Label("Use in Generate", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(FxPrimaryButtonStyle(height: 30))
                    .disabled(selectedPalette.isEmpty)
                    .accessibilityIdentifier("gallery.image-tools.palette.use-in-generate")
                    .help(selectedPalette.isEmpty
                          ? "Use in Generate is unavailable until at least one palette colour is selected."
                          : "Explicitly append the reviewed palette modifier and load that prompt in Generate.")
                }
            }
        }
        .fxCard(padding: 16)
    }

    private var cutoutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                icon: "person.crop.rectangle.badge.plus",
                title: "Foreground cut-out",
                detail: "Apple Vision separates all detected foreground instances locally. The transparent PNG stays in memory until you choose Save PNG.")

            HStack(spacing: 10) {
                Button {
                    makeCutout()
                } label: {
                    if makingCutout {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(cutout == nil ? "Cut out subject" : "Run again", systemImage: "person.crop.rectangle")
                    }
                }
                .buttonStyle(FxSecondaryButtonStyle(height: 32))
                .disabled(isWorking || !ForegroundCutoutService.isAvailable)
                .accessibilityIdentifier("gallery.image-tools.cutout.run")
                .help(!ForegroundCutoutService.isAvailable
                      ? "Foreground cut-outs are unavailable because they require macOS 14 or later."
                      : isWorking
                          ? "Foreground cut-out is unavailable while \(activeWorkDescription)."
                          : "Run Apple Vision now. This performs no render and writes no file.")
                Spacer()
                if let cutout {
                    Text("\(cutout.image.width) × \(cutout.image.height)")
                        .fxMonoFont(10.5, weight: .medium)
                        .foregroundStyle(Color.fxText3)
                }
            }

            if let cutoutError {
                errorRow(cutoutError)
            }

            if let cutout {
                ZStack {
                    ImageToolsCheckerboard()
                    Image(decorative: cutout.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.fxBorder, lineWidth: 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Transparent foreground cut-out preview")

                HStack {
                    if let saveError {
                        Text(saveError)
                            .fxFont(10.5)
                            .foregroundStyle(Color.fxDanger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        saveCutout(cutout)
                    } label: {
                        Label("Save PNG…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(FxPrimaryButtonStyle(height: 30))
                    .accessibilityIdentifier("gallery.image-tools.cutout.save")
                    .help("Review the visible cut-out, then save a PNG with AI provenance metadata.")
                }
            }
        }
        .fxCard(padding: 16)
    }

    private var upscaleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                icon: "arrow.up.left.and.arrow.down.right",
                title: "Experimental local AI 4×",
                detail: "A real tiled SRVGG/Real-ESRGAN pass using separately verified local weights. It exports a new PNG and never replaces the Gallery original. There is no interpolation fallback; AI reconstruction may invent or redraw fine texture and detail.")

            HStack(spacing: 8) {
                Label(upscaleStateTitle, systemImage: upscaleStateIcon)
                    .fxMonoFont(10.5, weight: .semibold)
                    .foregroundStyle(localUpscaleVM.modelIsReady ? Color.fxOk : Color.fxText3)
                Text("· \(ByteFormat.string(localUpscaleVM.expectedDownloadBytes)) · \(localUpscaleVM.license.identifier)")
                    .fxMonoFont(10)
                    .foregroundStyle(Color.fxText3)
                Spacer()
                Button("License") { showsUpscaleLicense = true }
                    .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
                    .disabled(localUpscaleVM.isBusy)
                    .accessibilityIdentifier("gallery.image-tools.upscale.license")
                    .help(localUpscaleVM.isBusy
                          ? "License details are unavailable while \(localUpscaleActivityDescription)."
                          : "Review the exact optional 4× model license and pinned source evidence.")
            }

            if preparingUpscale {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the verified Gallery PNG…")
                        .fxMonoFont(10.5)
                        .foregroundStyle(Color.fxText2)
                    Spacer()
                    Button("Cancel") { upscalePreparationTask?.cancel() }
                        .buttonStyle(FxSecondaryButtonStyle(height: 28))
                        .accessibilityIdentifier("gallery.image-tools.upscale.prepare-cancel")
                        .help("Cancel preparation before the local 4× model starts.")
                }
            } else if localUpscaleVM.isBusy {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        if let fraction = localUpscaleVM.progressFraction {
                            ProgressView(value: fraction).frame(width: 120)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(localUpscaleVM.statusMessage ?? "Working…")
                            .fxMonoFont(10.5)
                            .foregroundStyle(Color.fxText2)
                        Spacer()
                        Button("Cancel") { localUpscaleVM.cancel() }
                            .buttonStyle(FxSecondaryButtonStyle(height: 28))
                            .accessibilityIdentifier("gallery.image-tools.upscale.operation-cancel")
                            .help("Request cancellation of the active local 4× operation.")
                    }
                }
            } else {
                HStack(spacing: 8) {
                    switch localUpscaleVM.weightState {
                    case .licenseRequired:
                        Button("Review & accept license…") { showsUpscaleLicense = true }
                            .buttonStyle(FxPrimaryButtonStyle(height: 30))
                            .accessibilityIdentifier("gallery.image-tools.upscale.review-license")
                            .help("Review the exact license notice before enabling the optional model download.")
                    case .missing:
                        Button("Install 4× model") { localUpscaleVM.startInstall() }
                            .buttonStyle(FxSecondaryButtonStyle(height: 30))
                            .accessibilityIdentifier("gallery.image-tools.upscale.install")
                            .help("Download and verify the optional local 4× model from its pinned source.")
                    case .partial:
                        Button("Resume model download") { localUpscaleVM.startInstall() }
                            .buttonStyle(FxSecondaryButtonStyle(height: 30))
                            .accessibilityIdentifier("gallery.image-tools.upscale.resume")
                            .help("Resume the partial optional 4× model download and verify it when complete.")
                    case .corrupted:
                        Button("Repair model") { localUpscaleVM.startInstall() }
                            .buttonStyle(FxSecondaryButtonStyle(height: 30))
                            .accessibilityIdentifier("gallery.image-tools.upscale.repair")
                            .help("Replace the failed optional 4× model files and verify the pinned artifacts.")
                    case .ready:
                        Button {
                            chooseUpscaleDestination()
                        } label: {
                            Label("AI Upscale 4×…", systemImage: "sparkles.rectangle.stack")
                        }
                        .buttonStyle(FxPrimaryButtonStyle(height: 30))
                        .disabled(
                            !localUpscaleVM.canUpscale
                                || isWorking
                                || localUpscaleVM.preparedResult != nil)
                        .accessibilityIdentifier("gallery.image-tools.upscale.start")
                        .help(upscaleStartHelp)

                        Button {
                            confirmsUpscaleModelRemoval = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(FxSecondaryButtonStyle(height: 30))
                        .accessibilityLabel("Remove local 4× model")
                        .accessibilityIdentifier("gallery.image-tools.upscale.remove")
                        .help("Open a confirmation before removing the optional local 4× model weights.")
                    }
                    Spacer()
                }
            }

            if let message = localUpscaleVM.errorMessage ?? upscalePreparationError {
                errorRow(message)
            } else if let message = localUpscaleVM.statusMessage,
                      localUpscaleVM.activity == .idle {
                Text(message)
                    .fxFont(10.5)
                    .foregroundStyle(Color.fxText2)
            }

            if let prepared = localUpscaleVM.preparedResult {
                VStack(alignment: .leading, spacing: 9) {
                    if let image = NSImage(data: prepared.output.data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .background(Color.black.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.fxBorder, lineWidth: 1))
                            .accessibilityLabel("Local AI 4× result awaiting review")
                    }
                    HStack(spacing: 8) {
                        Text("\(prepared.pixelSize.width) × \(prepared.pixelSize.height) · not published")
                            .fxMonoFont(10.5, weight: .medium)
                            .foregroundStyle(Color.fxText2)
                        Spacer()
                        Button("Discard") { localUpscaleVM.discardPreparedResult() }
                            .buttonStyle(FxSecondaryButtonStyle(height: 30))
                            .accessibilityIdentifier("gallery.image-tools.upscale.discard")
                            .help("Discard the private reviewed 4× result without publishing it.")
                        Button {
                            reviewAndPublishUpscale()
                        } label: {
                            Label("Review & Save", systemImage: "checkmark.shield")
                        }
                        .buttonStyle(FxPrimaryButtonStyle(height: 30))
                        .accessibilityIdentifier("gallery.image-tools.upscale.review-save")
                        .help("Review the visible 4× pixels and confirm publication to the chosen destination.")
                    }
                }
            }

            if let result = localUpscaleVM.lastResult {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.fxOk)
                    Text("\(result.pixelSize.width) × \(result.pixelSize.height) · \(result.outputURL.lastPathComponent)")
                        .fxMonoFont(10.5)
                        .foregroundStyle(Color.fxText2)
                        .lineLimit(1)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                    }
                    .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
                    .accessibilityIdentifier("gallery.image-tools.upscale.reveal")
                    .help("Reveal the published 4× PNG in Finder.")
                }
            }

            Text("The 4× result is kept private until its rendered pixels are visible here and you confirm Review & Save. Publication is provenance-bound and never overwrites an existing file.")
                .fxFont(10)
                .foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fxCard(padding: 16)
    }

    private var upscaleStateTitle: String {
        switch localUpscaleVM.weightState {
        case .licenseRequired: "License review required"
        case .missing: "Model not installed"
        case .partial(let bytes): "Partial download · \(ByteFormat.string(bytes))"
        case .corrupted: "Model verification failed"
        case .ready: "Verified model ready"
        }
    }

    private var upscaleStateIcon: String {
        switch localUpscaleVM.weightState {
        case .ready: "checkmark.seal.fill"
        case .partial: "arrow.clockwise"
        case .corrupted: "exclamationmark.triangle.fill"
        case .licenseRequired: "doc.text"
        case .missing: "arrow.down.circle"
        }
    }

    private func sectionHeader(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.fxAccent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fxFont(13, weight: .semibold)
                    .foregroundStyle(Color.fxText)
                Text(detail)
                    .fxFont(10.5)
                    .foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func paletteSwatch(_ hex: String, index: Int) -> some View {
        let selected = selectedColors.contains(hex)
        return Button {
            if selected {
                selectedColors.remove(hex)
            } else {
                selectedColors.insert(hex)
            }
            paletteError = nil
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(color(hex))
                        .frame(height: 38)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(contrastingColor(hex), Color.black.opacity(0.5))
                    }
                }
                Text(hex)
                    .fxMonoFont(8.5, weight: .semibold)
                    .foregroundStyle(selected ? Color.fxText : Color.fxText3)
                    .lineLimit(1)
            }
            .padding(5)
            .modifier(GalleryPaletteSwatchSurfaceModifier(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("gallery.image-tools.palette.swatch.\(index + 1)")
        .accessibilityLabel("Palette colour \(hex)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .help(selected ? "Click to exclude \(hex) from the prompt modifier." : "Click to include \(hex) in the prompt modifier.")
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
        .fxFont(10.5)
        .foregroundStyle(Color.fxDanger)
        .accessibilityElement(children: .combine)
    }

    private var selectedPalette: ImagePalette {
        guard let palette else { return ImagePalette(colors: []) }
        return ImagePalette(colors: palette.colors.filter(selectedColors.contains))
    }

    private var isWorking: Bool {
        extractingPalette || makingCutout || preparingUpscale || localUpscaleVM.isBusy
    }

    /// Human-readable activity used by every disabled Image tools control. Keeping this separate
    /// from the button titles makes accessibility help explain the exact transient lock.
    private var activeWorkDescription: String {
        if extractingPalette { return "palette extraction is running" }
        if makingCutout { return "Apple Vision foreground cut-out is running" }
        if preparingUpscale { return "the verified Gallery PNG is being prepared for 4× processing" }
        return localUpscaleActivityDescription
    }

    private var localUpscaleActivityDescription: String {
        switch localUpscaleVM.activity {
        case .idle: "another image tool is running"
        case .installing: "the optional 4× model is downloading or being verified"
        case .removing: "the optional 4× model is being removed"
        case .upscaling: "local AI 4× processing is running"
        case .publishing: "the reviewed 4× PNG is being published"
        }
    }

    private var upscaleStartHelp: String {
        if localUpscaleVM.preparedResult != nil {
            return "AI Upscale 4× is unavailable until the prepared result is reviewed and saved or discarded."
        }
        if isWorking {
            return "AI Upscale 4× is unavailable while \(activeWorkDescription)."
        }
        if !localUpscaleVM.modelIsReady {
            return "AI Upscale 4× is unavailable until the optional model is installed and verified."
        }
        if !localUpscaleVM.canUpscale {
            return "AI Upscale 4× is unavailable while another model or inference operation is active, or while the app is preparing to quit."
        }
        return "Choose a new PNG destination, then start the verified local AI 4× operation."
    }

    private func source() async throws -> Data {
        if let sourceData { return sourceData }
        let data = try await loadPNGData()
        guard !data.isEmpty else { throw BoundedImageDecoder.Error.emptyPayload }
        sourceData = data
        return data
    }

    private func extractPalette() {
        guard !isWorking else { return }
        paletteError = nil
        extractingPalette = true
        paletteTask?.cancel()
        paletteTask = Task { @MainActor in
            defer { extractingPalette = false }
            do {
                let data = try await source()
                let result = try await ImagePaletteService.extractAsync(from: data)
                guard !Task.isCancelled else { return }
                guard !result.isEmpty else {
                    palette = nil
                    selectedColors.removeAll()
                    paletteError = "No visible colours were found in this image."
                    return
                }
                palette = result
                selectedColors = Set(result.colors)
            } catch is CancellationError {
                return
            } catch {
                paletteError = error.localizedDescription
            }
        }
    }

    private func makeCutout() {
        guard !isWorking else { return }
        cutoutError = nil
        saveError = nil
        makingCutout = true
        cutoutTask?.cancel()
        cutoutTask = Task { @MainActor in
            defer { makingCutout = false }
            do {
                let data = try await source()
                let result = try await ForegroundCutoutService.makeCutoutAsync(from: data)
                guard !Task.isCancelled else { return }
                cutout = result
            } catch is CancellationError {
                return
            } catch {
                cutoutError = error.localizedDescription
            }
        }
    }

    private func copyModifier() {
        guard !selectedPalette.isEmpty else { return }
        copy(selectedPalette.promptModifier)
    }

    private func chooseUpscaleDestination() {
        guard localUpscaleVM.canUpscale, !isWorking else { return }
        let panel = NSSavePanel()
        panel.title = "Export Local AI 4× PNG"
        panel.message = "The original Gallery image is never overwritten. Choose a new PNG destination."
        panel.prompt = "Upscale"
        panel.allowedContentTypes = [.png]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Twisterminigen-\(sourceSize.width)x\(sourceSize.height)-AI-4x.png"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        upscalePreparationError = nil
        preparingUpscale = true
        upscalePreparationTask?.cancel()
        upscalePreparationTask = Task { @MainActor in
            defer { preparingUpscale = false }
            do {
                // Keep the cancellation phase meaningfully operable instead of flashing for a
                // single frame when the source PNG is already cached. Longer real preparation is
                // never delayed; cancellation remains cooperative throughout this interval.
                let clock = ContinuousClock()
                let minimumCancellationDeadline = clock.now.advanced(by: .seconds(2))
                let protectedRoots = await loadProtectedExportRoots()
                try ValidatedExternalPublisher.preflightPNGDestination(
                    destination,
                    protectedRoots: protectedRoots)
                let data = try await source()
                try Task.checkCancellation()
                try await clock.sleep(until: minimumCancellationDeadline)
                try Task.checkCancellation()
                localUpscaleVM.startUpscale(
                    sourcePNGData: data,
                    sourceSize: sourceSize,
                    destinationURL: destination,
                    sourceGeneration: sourceGeneration)
            } catch is CancellationError {
                return
            } catch {
                upscalePreparationError = "Couldn't prepare the private 4× result: \(error.localizedDescription)"
            }
        }
    }

    private func copyFullPrompt() {
        do {
            copy(try selectedPalette.applying(to: basePrompt))
            paletteError = nil
        } catch {
            paletteError = error.localizedDescription
        }
    }

    private func usePrompt() {
        do {
            let prompt = try selectedPalette.applying(to: basePrompt)
            try onUsePrompt(prompt)
            paletteError = nil
            dismiss()
        } catch {
            paletteError = error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveCutout(_ cutout: ForegroundCutoutService.Cutout) {
        let output: ReviewablePNG
        do {
            output = try ReviewablePNGFactory.data(
                from: cutout.pngData,
                sourceGeneration: sourceGeneration,
                derivation: .foregroundCutout)
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Transparent Cut-out"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.png]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Twisterminigen-cutout.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let protectedRoots = await loadProtectedExportRoots()
                try ValidatedExternalPublisher.preflightPNGDestination(
                    url,
                    protectedRoots: protectedRoots)
                guard let receipt = OutputReviewGate.reviewBeforeExport(
                    outputs: [output],
                    kind: .foregroundCutout,
                    previewPNG: output.data) else { return }
                let outcome = try await ValidatedExternalPublisher.publishReviewedPNG(
                    output,
                    to: url,
                    receipt: receipt,
                    kind: .foregroundCutout,
                    protectedRoots: protectedRoots)
                _ = try outcome.requireVisibleURL()
                if let code = outcome.durabilityWarningCode {
                    saveError = "The cut-out is visible, but filesystem durability could not be confirmed (POSIX \(code))."
                } else {
                    saveError = nil
                }
            } catch {
                saveError = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    private func reviewAndPublishUpscale() {
        guard let prepared = localUpscaleVM.preparedResult else { return }
        Task { @MainActor in
            let protectedRoots = await loadProtectedExportRoots()
            do {
                try ValidatedExternalPublisher.preflightPNGDestination(
                    prepared.destinationURL,
                    protectedRoots: protectedRoots)
            } catch {
                upscalePreparationError = "Choose another 4× destination: \(error.localizedDescription)"
                return
            }
            guard let receipt = OutputReviewGate.reviewBeforeExport(
                outputs: [prepared.output],
                kind: .localAIUpscale,
                previewPNG: prepared.output.data) else { return }
            await localUpscaleVM.publishPreparedResult(
                receipt: receipt,
                protectedRoots: protectedRoots)
        }
    }

    private func color(_ hex: String) -> Color {
        guard let value = UInt64(hex.dropFirst(), radix: 16) else { return .clear }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1)
    }

    private func contrastingColor(_ hex: String) -> Color {
        guard let value = UInt64(hex.dropFirst(), radix: 16) else { return .white }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.58 ? .black : .white
    }
}

/// Selection remains a semantic accent in both appearances; only the neutral
/// swatch shell becomes glass.
private struct GalleryPaletteSwatchSurfaceModifier: ViewModifier {
    let selected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if selected {
            content
                .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.fxAccentLine, lineWidth: 1))
        } else {
            content.fxThemedSurface(.inset, radius: 8)
        }
    }
}

private struct ImageToolsCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 14
            for y in stride(from: 0 as CGFloat, to: size.height, by: tile) {
                for x in stride(from: 0 as CGFloat, to: size.width, by: tile) {
                    let alternate = (Int(x / tile) + Int(y / tile)).isMultiple(of: 2)
                    context.fill(
                        Path(CGRect(x: x, y: y, width: tile, height: tile)),
                        with: .color((alternate ? Color.white : Color.black).opacity(0.09)))
                }
            }
        }
        .fxThemedSurface(.inset, radius: 0, bordered: false)
    }
}

private struct LocalUpscaleLicenseSheet: View {
    let evidence: LocalUpscaleLicenseEvidence
    let modelName: String
    let onAccept: () -> Void
    let onCancel: () -> Void
    @Environment(\.fxTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(Color.fxAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Optional 4× model license")
                        .fxFont(16, weight: .semibold)
                        .foregroundStyle(Color.fxText)
                    Text(modelName)
                        .fxMonoFont(10.5)
                        .foregroundStyle(Color.fxText3)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 64)

            Divider().overlay(Color.fxBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("The weights are not bundled. Accepting this exact notice only enables a separate, explicit download; it does not download or run the model by itself.")
                        .fxFont(11)
                        .foregroundStyle(Color.fxText2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(evidence.notice)
                        .fxMonoFont(10.5)
                        .foregroundStyle(Color.fxText2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .fxThemedSurface(.inset, radius: 9)

                    HStack(spacing: 14) {
                        Link("License source", destination: evidence.sourceURL)
                            .accessibilityIdentifier("gallery.image-tools.upscale.license-source")
                            .help("Open the authoritative optional 4× model license source in the browser.")
                        Link("Pinned model card", destination: evidence.modelCardURL)
                            .accessibilityIdentifier("gallery.image-tools.upscale.model-card")
                            .help("Open the pinned optional 4× model card in the browser.")
                    }
                    .fxFont(10.5, weight: .semibold)
                    .foregroundStyle(Color.fxAccent)
                }
                .padding(20)
            }

            Divider().overlay(Color.fxBorder)
            HStack(spacing: 8) {
                Text(evidence.identifier)
                    .fxMonoFont(10.5, weight: .semibold)
                    .foregroundStyle(Color.fxText3)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(FxSecondaryButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("gallery.image-tools.upscale.license-cancel")
                    .help("Close the license notice without accepting or downloading anything.")
                Button("Accept & continue", action: onAccept)
                    .buttonStyle(FxPrimaryButtonStyle(height: 32))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("gallery.image-tools.upscale.license-accept")
                    .help("Record acceptance of this exact notice. This does not download or run the model.")
            }
            .padding(16)
        }
        .frame(width: 620, height: 620)
        .background(theme == .dark ? Color.fxSheet : Color.clear)
        .fxStandalonePageBackground()
        .accessibilityIdentifier("gallery.image-tools.upscale.license-sheet")
    }
}
