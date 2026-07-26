import SwiftUI
import AppKit
import Darwin
import UniformTypeIdentifiers

enum ReviewedPreviewStoreError: Error, LocalizedError {
    case unsafeDirectory(String)
    case unsafePreview(String)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory(let path):
            "The reviewed-preview directory is not a private app-owned directory: \(path)"
        case .unsafePreview(let path):
            "The reviewed-preview file is not a private regular file: \(path)"
        case let .posix(operation, code):
            "Reviewed-preview maintenance failed during \(operation) (POSIX \(code))."
        }
    }
}

/// Short-lived copies opened in an external image viewer. The viewer receives a pathname, so a
/// successful open cannot be followed by an immediate unlink. Instead, the app keeps a small,
/// private working set and removes it on termination; startup/use cleanup covers an unclean exit.
enum ReviewedPreviewStore {
    static let directoryName = "Twisterminigen-Reviewed-Previews"
    static let filenamePrefix = "Twisterminigen-reviewed-"
    static let maximumRetainedFiles = 8
    static let maximumFileAge: TimeInterval = 6 * 60 * 60

    static func directoryURL(
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        baseDirectory.standardizedFileURL.appendingPathComponent(
            directoryName,
            isDirectory: true)
    }

    static func prepareDestination(
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> URL {
        let directory = try ensurePrivateDirectory(
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        try cleanup(
            in: directory,
            fileManager: fileManager,
            now: now,
            maximumAge: maximumFileAge,
            maximumCount: maximumRetainedFiles)
        return directory.appendingPathComponent(
            "\(filenamePrefix)\(UUID().uuidString.lowercased()).png",
            isDirectory: false)
    }

    static func securePublishedPreview(
        at preview: URL,
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws {
        let directory = try ensurePrivateDirectory(
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        let standardized = preview.standardizedFileURL
        guard standardized.deletingLastPathComponent() == directory,
              isManagedPreviewName(standardized.lastPathComponent) else {
            throw ReviewedPreviewStoreError.unsafePreview(preview.path)
        }
        let descriptor = standardized.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ReviewedPreviewStoreError.posix(operation: "open(preview)", code: errno)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1 else {
            throw ReviewedPreviewStoreError.unsafePreview(preview.path)
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw ReviewedPreviewStoreError.posix(operation: "chmod(preview)", code: errno)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameFile(before, after),
              (after.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else {
            throw ReviewedPreviewStoreError.unsafePreview(preview.path)
        }
        try cleanup(
            in: directory,
            fileManager: fileManager,
            now: now,
            maximumAge: maximumFileAge,
            maximumCount: maximumRetainedFiles,
            protecting: standardized)
    }

    static func cleanupAfterLaunchOrUse(
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws {
        let directory = try ensurePrivateDirectory(
            baseDirectory: baseDirectory,
            fileManager: fileManager)
        try cleanup(
            in: directory,
            fileManager: fileManager,
            now: now,
            maximumAge: maximumFileAge,
            maximumCount: maximumRetainedFiles)
    }

    static func removeAllManagedPreviews(
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws {
        let directory = directoryURL(baseDirectory: baseDirectory)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try validatePrivateDirectory(directory)
        try cleanup(
            in: directory,
            fileManager: fileManager,
            now: Date(),
            maximumAge: 0,
            maximumCount: 0)
        _ = directory.path.withCString { Darwin.rmdir($0) }
    }

    static func discard(
        _ preview: URL,
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        let directory = directoryURL(baseDirectory: baseDirectory)
        let standardized = preview.standardizedFileURL
        guard standardized.deletingLastPathComponent() == directory,
              isManagedPreviewName(standardized.lastPathComponent) else { return }
        var status = stat()
        guard standardized.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid() else { return }
        _ = standardized.path.withCString { Darwin.unlink($0) }
    }

    private struct Candidate {
        let url: URL
        let modified: Date
    }

    private static func ensurePrivateDirectory(
        baseDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        let base = baseDirectory.standardizedFileURL
        let parentDescriptor = base.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parentDescriptor >= 0 else {
            throw ReviewedPreviewStoreError.posix(operation: "open(preview parent)", code: errno)
        }
        defer { Darwin.close(parentDescriptor) }

        let createResult = directoryName.withCString {
            Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        guard createResult == 0 || errno == EEXIST else {
            throw ReviewedPreviewStoreError.posix(operation: "mkdirat(preview)", code: errno)
        }
        let descriptor = directoryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ReviewedPreviewStoreError.posix(operation: "openat(preview)", code: errno)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            throw ReviewedPreviewStoreError.unsafeDirectory(
                directoryURL(baseDirectory: base).path)
        }
        guard Darwin.fchmod(descriptor, S_IRWXU) == 0 else {
            throw ReviewedPreviewStoreError.posix(operation: "fchmod(preview directory)", code: errno)
        }
        var namedStatus = stat()
        guard directoryName.withCString({
            Darwin.fstatat(parentDescriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              sameFile(status, namedStatus),
              (namedStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw ReviewedPreviewStoreError.unsafeDirectory(
                directoryURL(baseDirectory: base).path)
        }
        let directory = directoryURL(baseDirectory: base)
        try validatePrivateDirectory(directory)
        return directory
    }

    private static func validatePrivateDirectory(_ directory: URL) throws {
        var status = stat()
        guard directory.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & 0o777) == S_IRWXU else {
            throw ReviewedPreviewStoreError.unsafeDirectory(directory.path)
        }
    }

    private static func cleanup(
        in directory: URL,
        fileManager: FileManager,
        now: Date,
        maximumAge: TimeInterval,
        maximumCount: Int,
        protecting protectedURL: URL? = nil
    ) throws {
        let protectedURL = protectedURL?.standardizedFileURL
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        var previews: [Candidate] = []
        for item in contents {
            let standardized = item.standardizedFileURL
            let values = try standardized.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if isPrivateStageTombstoneName(standardized.lastPathComponent),
               values.fileSize == 0 {
                try fileManager.removeItem(at: standardized)
                continue
            }
            guard isManagedPreviewName(standardized.lastPathComponent) else { continue }
            previews.append(Candidate(
                url: standardized,
                modified: values.contentModificationDate ?? .distantPast))
        }

        var retained: [Candidate] = []
        for candidate in previews {
            let expired = now.timeIntervalSince(candidate.modified) >= maximumAge
            if expired, candidate.url != protectedURL {
                try fileManager.removeItem(at: candidate.url)
            } else {
                retained.append(candidate)
            }
        }

        let newestFirst = retained.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }
        let boundedCount = max(0, maximumCount)
        var keep = Set<URL>()
        if let protectedURL, boundedCount > 0 {
            keep.insert(protectedURL)
            let remaining = newestFirst.lazy
                .filter { $0.url != protectedURL }
                .prefix(boundedCount - 1)
            keep.formUnion(remaining.map(\.url))
        } else {
            keep.formUnion(newestFirst.prefix(boundedCount).map(\.url))
        }
        for candidate in newestFirst where !keep.contains(candidate.url) {
            try fileManager.removeItem(at: candidate.url)
        }
    }

    private static func isManagedPreviewName(_ name: String) -> Bool {
        name.hasPrefix(filenamePrefix) && name.hasSuffix(".png")
    }

    private static func isPrivateStageTombstoneName(_ name: String) -> Bool {
        name.hasPrefix(".twister-private-stage-") && name.hasSuffix(".tmp")
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
    }
}

/// Canvas-first generation workspace. The prompt has one authoritative editor in the bottom
/// composer; focused settings live in compact cards that rise from the corresponding studio chip.
struct GenerateView: View {
    @Bindable var vm: GenerateViewModel
    let onSavePreset: (Generation) -> Void
    let onDescribeImage: () -> Void
    let onOpenModels: () -> Void
    let onManageLoRA: () -> Void
    @State private var showInputImageImporter = false
    @State private var showRemixCropEditor = false
    @State private var showsRegionalPrompts = false
    @State private var showDeleteResultConfirmation = false
    @State private var showsExpert = false
    @State private var customStepsEnabled = false
    @State private var openSettingsPanel: GenerateSettingsPanel?
    @State private var queueConfirmation: QueueConfirmation?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fxTheme) private var theme

    // The normal workspace uses a one-line command surface. Keep the roomier
    // layout when the user explicitly selects an accessibility text size.
    private var isGlass: Bool { theme == .glass }
    // These began as literal dark-only values from the design reference. Resolve them through
    // the app theme so Light keeps readable contrast while Dark preserves the original palette.
    private var cLabel: Color { isGlass ? FxGlassPalette.textLabel : .fxTextLabel }
    private var cSub: Color { isGlass ? FxGlassPalette.text3 : .fxText3 }
    private var cText: Color { isGlass ? FxGlassPalette.text : .fxText }
    private var cEmber: Color { isGlass ? FxGlassPalette.ember : .fxEmberHi }
    private var cMuted: Color { isGlass ? FxGlassPalette.headerMuted : .fxHdrMuted }
    private var cIcon: Color { isGlass ? FxGlassPalette.text2 : .fxText2 }
    private var fill03: Color { isGlass ? FxGlassPalette.inset : .fxInset }
    private var fill04: Color { isGlass ? FxGlassPalette.inset : .fxInset }
    private var line07: Color { isGlass ? FxGlassPalette.border : .fxBorder }

    private var composerFieldHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 54 : 28
    }
    private var composerHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 76 : 42
    }
    private var composerVerticalPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 10 : 4
    }
    private var composerControlHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 38 : 34
    }
    private var composerTopSpacing: CGFloat { dynamicTypeSize.isAccessibilitySize ? 10 : 6 }
    private var studioControlHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 40 : 34
    }
    private var quickActionHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 44 : 38
    }
    private var canvasBottomReserve: CGFloat { 164 }
    private struct QueueConfirmation: Equatable {
        let id = UUID()
        let count: Int
    }

    var body: some View {
        GeometryReader { viewport in
            // Keep the prompt comfortably wide on the owner's large workspace. Settings retain
            // their established anchor so widening the composer does not move Fine-tuning.
            let controlDeckWidth = max(0, viewport.size.width - 48)
            let promptComposerWidth = GenerateWorkspaceLayout.composerWidth(
                availableWidth: controlDeckWidth)
            let settingsDeckWidth = GenerateWorkspaceLayout.settingsDeckWidth(
                availableWidth: controlDeckWidth)
            ZStack {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    .padding(.bottom, canvasBottomReserve)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if vm.isBusy {
                        busyCard
                            .frame(maxWidth: 520)
                            .padding(.bottom, 10)
                    } else if let error = vm.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .fxFont(11.5)
                            .foregroundStyle(Color.fxDanger)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 720, alignment: .leading)
                            .background(
                                (isGlass ? FxGlassPalette.sheet : Color.fxSheet).opacity(0.96),
                                in: Capsule())
                            .accessibilityElement(children: .combine)
                            .padding(.bottom, 10)
                    }
                    if let openSettingsPanel {
                        let settingsPanelWidth = GenerateSettingsPanelLayout.width(
                            panel: openSettingsPanel,
                            availableWidth: settingsDeckWidth,
                            usesAccessibilityLayout: dynamicTypeSize.isAccessibilitySize)
                        let settingsPanelHeight = GenerateSettingsPanelLayout.height(
                            panel: openSettingsPanel,
                            availableHeight: viewport.size.height,
                            usesAccessibilityLayout: dynamicTypeSize.isAccessibilitySize)
                        floatingSettingsPanel(
                            openSettingsPanel,
                            width: settingsPanelWidth,
                            maxHeight: settingsPanelHeight)
                            .frame(
                                width: settingsDeckWidth,
                                alignment: settingsPanelAlignment(openSettingsPanel))
                            .offset(
                                x: openSettingsPanel == .more
                                    ? -GenerateSettingsPanelLayout.moreTrailingCrop
                                    : 0)
                            .padding(.bottom, 10)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity))
                            .zIndex(3)
                    }
                    quickActionBar(width: controlDeckWidth)
                    promptComposer(width: promptComposerWidth)
                        .padding(.top, composerTopSpacing)
                }
                .frame(width: controlDeckWidth)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 20)

            }
            .animation(.easeOut(duration: 0.16), value: openSettingsPanel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fxPageBackground()
        .onExitCommand {
            if openSettingsPanel != nil { openSettingsPanel = nil }
        }
        .onAppear {
            try? ReviewedPreviewStore.cleanupAfterLaunchOrUse()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)
        ) { _ in
            try? ReviewedPreviewStore.removeAllManagedPreviews()
        }
        .onChange(of: openSettingsPanel) { _, panel in
            guard panel == .more else { return }
            customStepsEnabled = vm.steps != GenerateViewModel.officialTurboSteps
        }
        .onChange(of: vm.steps) { _, steps in
            guard openSettingsPanel == .more else { return }
            customStepsEnabled = steps != GenerateViewModel.officialTurboSteps
        }
        .alert("High memory render", isPresented: $vm.showHighMemoryConfirmation) {
            Button("Cancel", role: .cancel) { vm.cancelHighMemoryGenerate() }
                .accessibilityIdentifier("generate.high-memory.cancel")
                .help("Cancel this high-memory render before inference starts.")
            Button("Render once") { vm.confirmHighMemoryGenerate() }
                .accessibilityIdentifier("generate.high-memory.confirm")
                .help("Start this one high-memory render with the reviewed recipe.")
        } message: {
            Text(vm.highMemoryConfirmationText)
        }
        .alert("Delete this image?", isPresented: $showDeleteResultConfirmation) {
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("generate.result.delete-cancel")
                .help("Keep the managed Gallery image and leave it on the canvas.")
            Button("Delete", role: .destructive) {
                Task { await vm.deleteDisplayedResult() }
            }
            .accessibilityIdentifier("generate.result.delete-confirm")
            .help("Permanently remove this managed image from Gallery and clear the canvas.")
        } message: {
            Text("This removes the managed image from Gallery and clears this canvas. Copies you already saved elsewhere stay untouched.")
        }
        .sheet(isPresented: $showRemixCropEditor) {
            if let image = vm.inputImagePreview, vm.hasInputImage {
                RemixCropEditor(
                    image: image,
                    crop: Binding(
                        get: { vm.remixCrop },
                        set: { vm.remixCrop = $0 }),
                    resizeMode: vm.remixResizeMode)
            } else {
                Text("The Remix source is no longer available.")
                    .padding(32)
            }
        }
        .sheet(isPresented: $showsRegionalPrompts) {
            RegionalPromptsSheet(vm: vm)
        }
        .fileImporter(
            isPresented: $showInputImageImporter,
            allowedContentTypes: [.png, .jpeg, .heic],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let source = urls.first else { return }
                Task {
                    await vm.importInputImage(from: source)
                    if vm.hasInputImage {
                        withAnimation(.easeOut(duration: 0.16)) {
                            openSettingsPanel = .remix
                        }
                    }
                }
            case .failure(let error):
                vm.errorMessage = "Couldn't open the input image: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Studio controls

    private func quickActionBar(width: CGFloat) -> some View {
        ScrollView(.horizontal) {
            studioGlassGroup(width: width)
        }
        .scrollIndicators(.hidden)
        .frame(width: width, height: quickActionHeight, alignment: .center)
    }

    @ViewBuilder
    private func studioGlassGroup(width: CGFloat) -> some View {
        if !isGlass {
            studioButtonRow(width: width)
        } else if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                studioButtonRow(width: width)
            }
        } else {
            studioButtonRow(width: width)
        }
    }

    private func studioButtonRow(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            studioButton(
                "textformat", "Lettering",
                accessibilityID: "generate.quick.lettering",
                help: "Open Lettering controls for visible text in the generated scene.",
                tone: Color(hex: 0x7EDDC2),
                active: vm.letteringIsActive || openSettingsPanel == .text) {
                toggleSettingsPanel(.text)
            }
            studioButton(
                "photo", "Remix",
                accessibilityID: "generate.quick.remix",
                help: vm.hasInputImage
                    ? "Open Remix controls for the current source image."
                    : vm.importInputImageUnavailableReason
                        ?? "Choose a local source image for the Twister Remix extension.",
                tone: Color(hex: 0x9E95FF),
                active: vm.hasInputImage || openSettingsPanel == .remix) {
                if vm.hasInputImage {
                    toggleSettingsPanel(.remix)
                } else if vm.canImportInputImage {
                    showInputImageImporter = true
                } else {
                    // Keep the unavailable reason visible instead of opening an importer that
                    // cannot commit the selected source.
                    toggleSettingsPanel(.remix)
                }
            }
            studioButton(
                "rectangle.3.group", "Regions",
                accessibilityID: "generate.quick.regions",
                help: vm.regions.isEmpty
                    ? "Open Regional prompts and place up to eight experimental CFG 0 regions."
                    : "Edit the \(vm.regions.count) active Regional prompt region\(vm.regions.count == 1 ? "" : "s").",
                tone: Color(hex: 0xF3B64A),
                active: showsRegionalPrompts || !vm.regions.isEmpty) {
                withAnimation(.easeOut(duration: 0.16)) {
                    openSettingsPanel = nil
                }
                showsRegionalPrompts = true
            }
            studioButton(
                "slider.horizontal.3", "More",
                accessibilityID: "generate.quick.more",
                help: "Open compact canvas, render, variation, and expert controls.",
                tone: Color(hex: 0xE879D7),
                active: openSettingsPanel == .more) {
                toggleSettingsPanel(.more)
            }
        }
        .padding(.horizontal, 2)
        // Centre the complete chip group on wide windows. If accessibility
        // text makes it wider than the viewport, the ScrollView remains scrollable.
        .frame(minWidth: max(0, width - 4), alignment: .center)
    }

    private func toggleSettingsPanel(_ panel: GenerateSettingsPanel) {
        withAnimation(.easeOut(duration: 0.16)) {
            openSettingsPanel = GenerateSettingsPanel.toggled(
                current: openSettingsPanel,
                requested: panel)
        }
    }

    private func settingsPanelAlignment(_ panel: GenerateSettingsPanel) -> Alignment {
        switch panel {
        case .text, .remix: .leading
        case .more: .trailing
        }
    }

    private func promptComposer(width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isGlass ? FxGlassPalette.text2 : Color.fxAccent)
                .frame(width: 20)
                .accessibilityHidden(true)

            TextField(
                "",
                text: $vm.prompt,
                prompt: Text("Describe what to generate…").foregroundColor(cSub),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .fxFont(13.5)
            .foregroundStyle(cEmber)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1...3 : 1...1)
            .frame(maxWidth: .infinity)
            .frame(height: composerFieldHeight, alignment: .center)
            .disabled(vm.isEnhancing)
            .help(vm.isEnhancing
                  ? "The prompt is locked while Enhance is rewriting it. Stop Enhance to edit."
                  : "Describe the scene you want to generate.")
            .accessibilityLabel("Prompt")
            .accessibilityIdentifier("generate.prompt")

            // Keep commands at their natural width.  The prompt field is the
            // only flexible element and must yield space before a button clips.
            HStack(spacing: 10) {
                composerButton(
                    "text.viewfinder",
                    "Describe",
                    help: vm.isBusy
                        ? "Describe is unavailable while generation or Queue is running."
                        : "Turn a reference image into a prompt with the optional local vision model.",
                    action: onDescribeImage)
                    .disabled(vm.isBusy)
                    .accessibilityIdentifier("action.describe")
                composerButton(
                    vm.isEnhancing ? "stop.fill" : "sparkles",
                    vm.isEnhancing ? "Stop" : "Enhance",
                    help: vm.isEnhanceStopping
                        ? "Enhancement cancellation is already in progress."
                        : vm.isEnhancing
                        ? "Stop prompt enhancement."
                        : vm.enhanceUnavailableReason ?? "Enhance the prompt locally.") {
                        vm.isEnhancing ? vm.cancel() : vm.enhance()
                    }
                    .disabled(vm.isEnhanceStopping || (!vm.isEnhancing && !vm.canEnhance))
                    .accessibilityIdentifier("action.enhance")

                Divider().frame(height: 28)
                addToQueueButton
                composerPrimaryAction
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, composerVerticalPadding)
        .frame(width: width, height: composerHeight)
        .modifier(GenerateComposerSurfaceModifier())
    }

    private func studioButton(
        _ icon: String,
        _ title: String,
        accessibilityID: String,
        help: String,
        tone: Color,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            studioButtonLabel(icon, title, tone: tone, active: active)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(help)
    }

    @ViewBuilder
    private func studioButtonLabel(
        _ icon: String,
        _ title: String,
        tone: Color,
        active: Bool
    ) -> some View {
        let label = Label(title, systemImage: icon)
        if isGlass {
            label
                .fxFont(11.5, weight: .semibold)
                .foregroundStyle(active ? Color.white : FxGlassPalette.text2)
                .padding(.horizontal, 11)
                .frame(height: studioControlHeight)
                .fxGlassSurface(
                    radius: studioControlHeight / 2,
                    tint: tone.opacity(active ? 0.22 : 0.10),
                    stroke: tone.opacity(active ? 0.58 : 0.30),
                    interactive: true,
                    shadow: 7)
                .shadow(color: tone.opacity(active ? 0.30 : 0.18), radius: 9)
        } else {
            label
                .fxFont(11.5, weight: .semibold)
                .foregroundStyle(active ? Color.fxAccentHi : cIcon)
                .padding(.horizontal, 11)
                .frame(height: studioControlHeight)
                .background(
                    active ? Color.fxAccent.opacity(0.14) : fill04,
                    in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(
                    active ? Color.fxAccentLine : line07,
                    lineWidth: 1))
        }
    }

    private func composerButton(
        _ icon: String,
        _ title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            let label = Label(title, systemImage: icon)
            if isGlass {
                label
                    .fxFont(11.5, weight: .semibold)
                    .foregroundStyle(FxGlassPalette.text2)
                    .padding(.horizontal, 9)
                    .frame(height: composerControlHeight)
                    .fxGlassSurface(
                        radius: 9,
                        tint: FxGlassPalette.control,
                        stroke: Color.white.opacity(0.15),
                        interactive: true)
            } else {
                label
                    .fxFont(11.5, weight: .semibold)
                    .foregroundStyle(cIcon)
                    .padding(.horizontal, 9)
                    .frame(height: composerControlHeight)
                    .background(
                        fill04,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(line07, lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var addToQueueButton: some View {
        let confirmed = queueConfirmation != nil
        let count = vm.queue.count
        let title = confirmed
            ? "Queued · \(count)"
            : count == 0 ? "Queue" : "Queue · \(count)"
        return composerButton(
            confirmed ? "checkmark" : "plus",
            title,
            help: vm.addToQueueUnavailableReason
                ?? (vm.isBusy
                    ? "Append the current recipe after every image already in the active render queue."
                    : count == 0
                    ? "Add the current recipe to Queue."
                    : "Add the current recipe to Queue. \(count) already queued."),
            action: addCurrentRecipeToQueue)
        .disabled(!vm.canAddToQueue)
        .accessibilityIdentifier("action.queue")
        .accessibilityLabel(confirmed ? "Added to Queue, \(count) queued" : "Add to Queue")
        .accessibilityHint(vm.addToQueueUnavailableReason
                           ?? (vm.isBusy
                               ? "Snapshots this recipe at the durable tail of the active work."
                               : "Adds an immutable snapshot of this recipe."))
    }

    private func addCurrentRecipeToQueue() {
        Task { @MainActor in
            guard let count = await vm.addCurrentToQueue() else { return }
            let confirmation = QueueConfirmation(count: count)
            withAnimation(.easeOut(duration: 0.14)) {
                queueConfirmation = confirmation
            }
            try? await Task.sleep(for: .seconds(2))
            guard queueConfirmation == confirmation else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                queueConfirmation = nil
            }
        }
    }

    @ViewBuilder private var composerPrimaryAction: some View {
        if vm.isBusy {
            HStack(spacing: 8) {
                let actionEnabled = vm.canSubmitCurrentRecipe
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        openSettingsPanel = nil
                    }
                    addCurrentRecipeToQueue()
                } label: {
                    Label(
                        queueConfirmation == nil ? "Generate next" : "Queued next",
                        systemImage: queueConfirmation == nil ? "bolt.fill" : "checkmark")
                        .fxFont(11.5, weight: .semibold)
                        .foregroundStyle(actionEnabled ? Color.white : Color.white.opacity(0.62))
                        .padding(.horizontal, 14)
                        .frame(height: composerControlHeight)
                        .modifier(GeneratePrimaryActionSurfaceModifier(isEnabled: actionEnabled))
                }
                .buttonStyle(.plain)
                .disabled(!actionEnabled)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("action.generate")
                .help(vm.submitCurrentRecipeUnavailableReason
                      ?? "Append this recipe after every image already in the active render queue.")
                .accessibilityHint(vm.submitCurrentRecipeUnavailableReason
                                   ?? "Snapshots this recipe and renders it after the active work.")

                Button {
                    vm.cancel()
                } label: {
                    Label(vm.isStopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                        .fxFont(12.5, weight: .semibold)
                        .padding(.horizontal, 12)
                        .frame(height: composerControlHeight)
                }
                .buttonStyle(.bordered)
                .tint(Color.fxDanger)
                .disabled(vm.isStopping)
                .help(vm.isStopping
                      ? "Cancellation was requested; the current Metal operation must finish first."
                      : "Stop the current render after the active Metal operation.")
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("action.stop.composer")
            }
        } else {
            let actionEnabled = vm.canSubmitCurrentRecipe
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    openSettingsPanel = nil
                }
                vm.generate()
            } label: {
                Label(vm.resultImage == nil ? "Generate" : "Generate again", systemImage: "bolt.fill")
                    // Match Describe/Enhance typography; hierarchy comes from colour, not type size.
                    .fxFont(11.5, weight: .semibold)
                    .foregroundStyle(actionEnabled ? Color.white : Color.white.opacity(0.62))
                    .padding(.horizontal, 16)
                    .frame(height: composerControlHeight)
                    .modifier(GeneratePrimaryActionSurfaceModifier(isEnabled: actionEnabled))
            }
            .buttonStyle(.plain)
            .disabled(!actionEnabled)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("action.generate")
            .help(vm.submitCurrentRecipeUnavailableReason ?? "Generate with the current recipe.")
            .accessibilityHint(vm.submitCurrentRecipeUnavailableReason ?? "Starts a local Krea 2 render.")
        }
    }

    private func floatingSettingsPanel(
        _ panel: GenerateSettingsPanel,
        width: CGFloat,
        maxHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: panel.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isGlass ? FxGlassPalette.text2 : Color.fxAccentHi)
                    .accessibilityHidden(true)
                Text(panel.title)
                    .fxFont(panel == .more ? 12.5 : 13, weight: .bold)
                    .foregroundStyle(cText)
                Spacer()
                Button { openSettingsPanel = nil } label: {
                    Image(systemName: "xmark").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(cIcon)
                .accessibilityLabel("Close \(panel.title)")
                .accessibilityIdentifier("generate.settings.close")
                .help("Close \(panel.title) without changing its current settings.")
            }
            .padding(.horizontal, panel == .more ? 12 : 16)
            .frame(minHeight: panel == .more
                ? GenerateSettingsPanelLayout.moreHeaderHeight
                : 48)
            Divider().overlay(Color.fxBorder)
            ScrollView(.vertical) {
                VStack(
                    alignment: .leading,
                    spacing: panel == .more
                        ? GenerateSettingsPanelLayout.moreContentSpacing
                        : 20
                ) {
                    if vm.isBusy {
                        Label(
                            "Settings are locked while generation or Queue is running. Stop the active render to edit them.",
                            systemImage: "lock.fill")
                            .fxFont(10.5, weight: .medium)
                            .foregroundStyle(cSub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(panel.sections, id: \.self) { section in
                        floatingPanelSection(section)
                    }
                }
                .frame(
                    width: GenerateSettingsPanelLayout.contentWidth(
                        panel: panel,
                        panelWidth: width),
                    alignment: .leading)
                .padding(panel == .more
                    ? GenerateSettingsPanelLayout.moreContentPadding
                    : 18)
                // Fine-tuning receives an explicit 256 pt inner proposal, so its padding is part
                // of the 284 pt column instead of widening or merely clipping the controls.
                .frame(
                    maxWidth: panel == .more ? nil : .infinity,
                    alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .contentMargins(
                .trailing,
                panel == .more
                    ? GenerateSettingsPanelLayout.moreScrollIndicatorTrailingInset
                    : 0,
                for: .scrollIndicators)
            .contentMargins(
                .bottom,
                panel == .more
                    ? GenerateSettingsPanelLayout.moreScrollIndicatorBottomInset
                    : 0,
                for: .scrollIndicators)
            .clipped()
            .frame(maxHeight: max(
                170,
                maxHeight - (panel == .more
                    ? GenerateSettingsPanelLayout.moreHeaderHeight + 1
                    : 49)))
        }
        .frame(
            width: width,
            height: panel == .more || panel == .text ? maxHeight : nil)
        .modifier(GenerateSettingsSurfaceModifier())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("generate.settings.\(panel.accessibilityID)")
    }

    @ViewBuilder
    private func floatingPanelSection(_ section: GenerateSettingsPanel.Section) -> some View {
        switch section {
        case .exactText:
            textModePanelSection
        case .remixSource:
            inputImageSection
        case .canvas:
            canvasSettingsSection
        case .render:
            renderSettingsSection
        case .variations:
            variationsSettingsSection
        case .expert:
            expertSettingsSection
        }
    }

    private var textModePanelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Text to appear")
                    .fxFont(11.5, weight: .semibold)
                    .foregroundStyle(cLabel)
                Spacer()
                Text("\(vm.exactText.utf8.count) / \(GenerationRecipe.maximumExactTextUTF8Bytes)")
                    .fxMonoFont(9.5)
                    .foregroundStyle(cSub)
                if !vm.exactText.isEmpty {
                    Button("Clear") {
                        vm.exactText = ""
                    }
                    .buttonStyle(.plain)
                    .fxFont(10.5, weight: .semibold)
                    .foregroundStyle(cEmber)
                    .accessibilityIdentifier("generate.lettering.clear")
                    .help("Remove the visible-text instruction from this recipe.")
                }
            }
            ZStack(alignment: .topLeading) {
                if vm.exactText.isEmpty {
                    Text("Text to appear…")
                        .fxFont(12.5)
                        .foregroundStyle(cSub)
                        .padding(.horizontal, 11)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.exactText)
                    .fxFont(12.5)
                    .foregroundStyle(cEmber)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .accessibilityLabel("Text to appear")
                    .accessibilityIdentifier("generate.lettering.text")
                    .help(vm.isBusy
                          ? "Lettering is locked while generation or Queue is running."
                          : "Enter the text you want the image to show; exact spelling is not guaranteed.")
            }
            .frame(height: 92)
            .background(fill03, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(line07, lineWidth: 1))
            Label(
                "Exact spelling is not guaranteed. Lettering turns on automatically when this field contains text. Results are saved only after local Vision OCR QA succeeds; Gallery shows the score.",
                systemImage: "info.circle")
                .fxFont(10.5)
                .foregroundStyle(cSub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(vm.isBusy)
        .opacity(vm.isBusy ? 0.6 : 1)
        .help(vm.isBusy
              ? "Lettering is locked while generation or Queue is running."
              : "Ask for visible text. Krea 2 can still misspell or alter the requested lettering.")
    }

    // MARK: - Floating panel controls
    private var inputImageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Remix source")
                    .fxFont(12, weight: .semibold)
                    .foregroundStyle(cLabel)
                Spacer()
                if vm.isImportingInputImage {
                    ProgressView().controlSize(.mini)
                }
            }
            Label(
                "Twister extension — not an official Krea editing pipeline. Strength and crop can materially change the result.",
                systemImage: "wand.and.stars")
                .fxFont(10.5)
                .foregroundStyle(cSub)
                .fixedSize(horizontal: false, vertical: true)
            if let image = vm.inputImagePreview, vm.hasInputImage {
                HStack(spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipped()
                        .overlay(Rectangle().strokeBorder(line07, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.inputImageDimensions ?? "Managed source")
                            .fxMonoFont(11.5, weight: .semibold)
                            .foregroundStyle(cText)
                        Button("Replace") { showInputImageImporter = true }
                            .buttonStyle(.plain)
                            .fxFont(11.5, weight: .medium)
                            .foregroundStyle(cIcon)
                            .accessibilityIdentifier("generate.remix.replace")
                            .help(vm.isBusy
                                  ? "Remix controls are locked while generation or Queue is running."
                                  : "Choose a different managed Remix source image.")
                    }
                    Spacer()
                    Button { vm.clearInputImage() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("generate.remix.remove")
                    .help(vm.isBusy
                          ? "Remix controls are locked while generation or Queue is running."
                          : "Remove the current Remix source image.")
                }
                VStack(spacing: 8) {
                    HStack {
                        Text("Strength")
                            .fxFont(11.5, weight: .medium)
                            .foregroundStyle(cMuted)
                        Spacer()
                        Text(vm.remixStrength.formatted(.number.precision(.fractionLength(2))))
                            .fxMonoFont(11.5, weight: .semibold)
                            .foregroundStyle(cText)
                    }
                    FxSlider(
                        value: Binding(
                            get: { vm.remixStrength },
                            set: { vm.remixStrength = $0 }),
                        range: 0.05...1,
                        step: 0.05,
                        knob: 16,
                        track: 4,
                        accessibilityLabel: "Remix strength",
                        accessibilityValue: "\(Int((vm.remixStrength * 100).rounded())) percent",
                        accessibilityID: "generate.remix.strength")
                    .accessibilityIdentifier("generate.remix.strength")
                    .help(vm.isBusy
                          ? "Remix controls are locked while generation or Queue is running."
                          : "Set how strongly the prompt may depart from the Remix source image.")
                    Picker("Resize", selection: Binding(
                        get: { vm.remixResizeMode },
                        set: { vm.remixResizeMode = $0 })) {
                        Text("Fit").tag(GenerationRecipe.ResizeMode.fit)
                        Text("Fill").tag(GenerationRecipe.ResizeMode.fill)
                        Text("Stretch").tag(GenerationRecipe.ResizeMode.stretch)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("generate.remix.resize")
                    .help(vm.isBusy
                          ? "Remix controls are locked while generation or Queue is running."
                          : "Choose how the source image is fitted to the output canvas.")
                    HStack(spacing: 8) {
                        Button {
                            showRemixCropEditor = true
                        } label: {
                            Label(vm.remixCrop == nil ? "Crop source" : "Edit crop", systemImage: "crop")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("generate.remix.crop")
                        .help(vm.isBusy
                              ? "Remix controls are locked while generation or Queue is running."
                              : "Open the visual source crop editor.")
                        Spacer()
                        if vm.remixCrop != nil {
                            Button("Reset") { vm.remixCrop = nil }
                                .buttonStyle(.plain)
                                .foregroundStyle(cIcon)
                                .help(vm.isBusy
                                      ? "Remix controls are locked while generation or Queue is running."
                                      : "Clear the crop and use the complete source image.")
                                .accessibilityIdentifier("generate.remix.crop-reset")
                        }
                    }
                    if let crop = vm.remixCrop {
                        Text(remixCropSummary(crop))
                            .fxMonoFont(10.5, weight: .medium)
                            .foregroundStyle(cMuted)
                            .accessibilityLabel("Current Remix crop")
                            .accessibilityValue(remixCropAccessibilityValue(crop))
                    }
                }
            } else {
                if let reason = vm.importInputImageUnavailableReason {
                    Label(reason, systemImage: "info.circle")
                        .fxFont(10.5, weight: .medium)
                        .foregroundStyle(cSub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { showInputImageImporter = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                        Text("Choose image")
                        Spacer()
                    }
                    .fxFont(12.5, weight: .medium)
                    .foregroundStyle(cIcon)
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .background(fill04)
                    .overlay(Rectangle().strokeBorder(line07, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("generate.remix.choose")
                .disabled(!vm.canImportInputImage)
                .help(vm.importInputImageUnavailableReason
                      ?? "Import a managed PNG, JPEG, or HEIC source")
            }
        }
        .disabled(vm.isBusy)
        .opacity(vm.isBusy ? 0.6 : 1)
        .help(vm.isBusy
              ? "Remix controls are locked while generation or Queue is running."
              : vm.importInputImageUnavailableReason
                  ?? "Import or adjust the managed Remix source image.")
        .dropDestination(for: URL.self) { urls, _ in
            guard let source = urls.first, vm.canImportInputImage else { return false }
            Task { await vm.importInputImage(from: source) }
            return true
        }
        .accessibilityIdentifier("generate.remix.drop-zone")
    }

    private func remixCropSummary(_ crop: GenerationRecipe.NormalizedRect) -> String {
        String(
            format: "x %.2f%% · y %.2f%% · w %.2f%% · h %.2f%%",
            crop.x * 100,
            crop.y * 100,
            crop.width * 100,
            crop.height * 100)
    }

    private func remixCropAccessibilityValue(_ crop: GenerationRecipe.NormalizedRect) -> String {
        String(
            format: "X %.2f percent, Y %.2f percent, width %.2f percent, height %.2f percent",
            crop.x * 100,
            crop.y * 100,
            crop.width * 100,
            crop.height * 100)
    }

    // MARK: - More · Canvas

    private var canvasSettingsSection: some View {
        VStack(alignment: .leading, spacing: GenerateSettingsPanelLayout.moreContentSpacing) {
            aspectQualitySection
            verifiedSizeSection
            sizeRow
            renderSummaryRow
        }
    }

    private var verifiedSizeSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SIZE")
                .fxFont(9.5, weight: .semibold)
                .foregroundStyle(cSub)
            HStack(spacing: 7) {
                ForEach(GenerateViewModel.VerifiedCanvasTier.allCases) { tier in
                    let active = vm.isCanvasTierActive(tier)
                    Button {
                        if !active { vm.applyCanvasTier(tier) }
                    } label: {
                        Text("1 MP · 1024")
                            .fxMonoFont(10.5, weight: .semibold)
                        .foregroundStyle(active ? Color.white : cMuted)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(
                            active
                                ? AnyShapeStyle(Color.fxAccent.opacity(0.9))
                                : AnyShapeStyle(fill04),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(active ? Color.clear : line07, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("generate.settings.canvas.tier.1024")
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .disabled(vm.isBusy)
                    .help(vm.isBusy
                          ? "Canvas size is locked while generation or Queue is running."
                          : active
                              ? "The current dimensions use the verified 1024-class canvas."
                              : "Return to the verified 1024-class size while keeping the nearest aspect ratio.")
                }
            }
        }
    }

    private var renderSummaryRow: some View {
        HStack(spacing: 4) {
            Text(vm.compactRenderSummary)
                .fxMonoFont(9.5, weight: .medium)
                .foregroundStyle(cSub)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .help(vm.renderEstimate.basis)
        .accessibilityElement(children: .combine)
    }

    // ── Aspect ratio ──────────────────────────────────────────────────────
    private var aspectQualitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ASPECT").fxFont(9.5, weight: .semibold).foregroundStyle(cSub)
            VStack(spacing: 5) {
                HStack(spacing: GenerateSettingsPanelLayout.moreAspectSpacing) {
                    ForEach(
                        Array(GenerateViewModel.aspectPresets.prefix(
                            GenerateSettingsPanelLayout.moreAspectColumns))
                    ) { preset in
                        aspectChip(preset)
                    }
                }
                HStack(spacing: GenerateSettingsPanelLayout.moreAspectSpacing) {
                    ForEach(
                        Array(GenerateViewModel.aspectPresets.dropFirst(
                            GenerateSettingsPanelLayout.moreAspectColumns))
                    ) { preset in
                        aspectChip(preset)
                    }
                    swapButton
                }
            }
        }
    }

    // ── Width / Height (custom exact size, /16-aligned) ──────────────────
    private var sizeRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("EXACT SIZE")
                .fxFont(9.5, weight: .semibold)
                .foregroundStyle(cSub)
            HStack(
                alignment: .bottom,
                spacing: GenerateSettingsPanelLayout.moreExactSizeSpacing
            ) {
                FxStepper(label: "Width", value: $vm.width,
                          range: GenerateViewModel.minSide...GenerateViewModel.maxSide, step: 16,
                          compactControls: true,
                          unavailableReason: vm.isBusy
                              ? "Exact canvas size is locked while generation or Queue is running."
                              : nil,
                          accessibilityIDBase: "generate.settings.canvas.width")
                    .frame(width: GenerateSettingsPanelLayout.moreExactSizeFieldWidth)
                FxStepper(label: "Height", value: $vm.height,
                          range: GenerateViewModel.minSide...GenerateViewModel.maxSide, step: 16,
                          compactControls: true,
                          unavailableReason: vm.isBusy
                              ? "Exact canvas size is locked while generation or Queue is running."
                              : nil,
                          accessibilityIDBase: "generate.settings.canvas.height")
                    .frame(width: GenerateSettingsPanelLayout.moreExactSizeFieldWidth)
            }
        }
        .opacity(vm.isBusy ? 0.6 : 1)
    }

    private var swapButton: some View {
        Button { vm.swapOrientation() } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(cIcon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(fill04, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(line07, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("generate.settings.canvas.swap")
        .disabled(vm.isBusy || vm.width == vm.height)
        .help(vm.isBusy
              ? "Canvas controls are locked while generation or Queue is running."
              : vm.width == vm.height
                  ? "Width and height are already equal."
                  : "Swap width and height.")
    }

    private func aspectChip(
        _ p: GenerateViewModel.AspectPreset,
        label: String? = nil
    ) -> some View {
        let active = vm.isAspectActive(p)
        return Button {
            if !active { vm.applyAspect(p) }
        } label: {
            Text(label ?? p.id)
                .fxMonoFont(10.5, weight: .semibold)
                .foregroundStyle(active ? Color.white : cMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    active
                        ? AnyShapeStyle(Color.fxAccent.opacity(0.9))
                        : AnyShapeStyle(fill04),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? Color.clear : line07, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            "generate.settings.canvas.aspect.\(p.id.replacingOccurrences(of: ":", with: "x"))")
        .accessibilityAddTraits(active ? .isSelected : [])
        .disabled(vm.isBusy)
        .help(vm.isBusy
              ? "Aspect controls are locked while generation or Queue is running."
              : active
                  ? "Aspect \(p.id) is already selected."
                  : "Use aspect \(p.id) — \(String(p.w))×\(String(p.h)).")
    }

    // MARK: - More · Render

    private var renderSettingsSection: some View {
        VStack(alignment: .leading, spacing: GenerateSettingsPanelLayout.moreContentSpacing) {
            activeModelRow
            stepsRow
            livePreviewSection
        }
    }

    private var activeModelRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(vm.modelsReady ? Color.fxOk : Color.fxDanger)
                .frame(width: 6, height: 6)
            Text(vm.activeModelDisplayName)
                .fxMonoFont(10, weight: .medium)
                .foregroundStyle(cText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Models", action: onOpenModels)
                .buttonStyle(.plain)
                .fxFont(10, weight: .semibold)
                .foregroundStyle(Color.fxAccentHi)
                .accessibilityIdentifier("generate.settings.open-models")
                .disabled(vm.isBusy)
                .help(vm.isBusy
                      ? "Models cannot be opened from this panel during an active render."
                      : "Open the Models section. The active model is read-only here.")
        }
        .accessibilityLabel("Active model \(vm.activeModelDisplayName)")
    }

    // ── Steps ─────────────────────────────────────────────────────────────
    private var stepsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("STEPS")
                    .fxFont(9.5, weight: .semibold)
                    .foregroundStyle(cSub)
                Spacer()
                Text(customStepsEnabled ? "\(vm.steps)" : "Turbo · 8")
                    .fxMonoFont(10.5, weight: .semibold)
                    .foregroundStyle(customStepsEnabled ? cText : cSub)
                Toggle("", isOn: Binding(
                    get: { customStepsEnabled },
                    set: { enabled in
                        customStepsEnabled = enabled
                        if !enabled { vm.steps = GenerateViewModel.officialTurboSteps }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(vm.isBusy)
                    .accessibilityLabel("Custom steps")
                    .accessibilityIdentifier("generate.settings.custom-steps.toggle")
                    .help(vm.isBusy
                          ? "Steps are locked while generation or Queue is running."
                          : "Enable a custom 4–12 step count. Off restores the recommended 8 steps.")
            }
            if customStepsEnabled {
                FxSlider(value: Binding(
                    get: { Double(vm.steps) },
                    set: { vm.steps = Int($0.rounded()) }),
                    range: 4...12, step: 1, knob: 18, track: 5,
                    accessibilityLabel: "Denoising steps",
                    accessibilityValue: "\(vm.steps) steps",
                    accessibilityID: "generate.settings.custom-steps.slider")
                    .disabled(vm.isBusy)
                    .accessibilityIdentifier("generate.settings.custom-steps.slider")
                    .help(vm.isBusy
                          ? "Steps are locked while generation or Queue is running."
                          : "Choose 4–12 denoising steps; Krea 2 Turbo is recommended at 8.")
            }
        }
        .help(vm.isBusy
              ? "Steps are locked while generation or Queue is running."
              : customStepsEnabled
                  ? "Custom denoising steps. Krea 2 Turbo is recommended at 8."
                  : "Krea 2 Turbo Recommended uses 8 denoising steps.")
    }

    // MARK: - More · Expert

    private var expertSettingsSection: some View {
        DisclosureGroup(isExpanded: $showsExpert) {
            VStack(
                alignment: .leading,
                spacing: GenerateSettingsPanelLayout.moreExpertSpacing
            ) {
                guidanceEditor
                if vm.guidanceValue.map({ $0 > 0 }) == true {
                    negativePromptEditor
                }
                if !vm.noncanonicalTurboSettings.isEmpty {
                    noncanonicalTurboWarning
                }
                activeLoRAStackRow
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.fxAccent)
                Text("Expert")
                    .fxFont(12, weight: .bold)
                    .foregroundStyle(cLabel)
                Spacer()
                Text(!vm.advancedInputsAreValid
                     ? "Needs attention"
                     : vm.noncanonicalTurboSettings.isEmpty ? "Turbo defaults" : "Noncanonical")
                    .fxMonoFont(9.5, weight: .medium)
                    .foregroundStyle(!vm.advancedInputsAreValid
                                     ? Color.red
                                     : vm.noncanonicalTurboSettings.isEmpty ? cSub : Color.orange)
            }
        }
        .tint(cIcon)
        .accessibilityIdentifier("generate.settings.expert")
        .disabled(vm.isBusy)
        .opacity(vm.isBusy ? 0.6 : 1)
        .help(vm.isBusy
              ? "Expert settings are locked while generation or Queue is running."
              : "Expert Turbo overrides. Negative prompt appears only when CFG is greater than 0.")
    }

    private var guidanceEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guidance (CFG)")
                        .fxFont(11.5, weight: .semibold)
                        .foregroundStyle(cLabel)
                    Text("Turbo default is 0")
                        .fxFont(10.5)
                        .foregroundStyle(cSub)
                }
                Spacer()
                TextField("0", text: $vm.guidanceText)
                    .textFieldStyle(.plain)
                    .fxMonoFont(12.5, weight: .semibold)
                    .foregroundStyle(vm.guidanceIsInvalid ? Color.red : cText)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 8)
                    .frame(
                        width: GenerateSettingsPanelLayout.moreGuidanceFieldWidth,
                        height: GenerateSettingsPanelLayout.moreGuidanceFieldHeight)
                    .background(fill03, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                        vm.guidanceIsInvalid ? Color.red.opacity(0.8) : line07,
                        lineWidth: 1))
                    .onSubmit { vm.normalizeGuidanceText() }
                    .accessibilityLabel("Guidance")
                    .accessibilityValue(vm.guidanceText)
                    .accessibilityIdentifier("generate.settings.cfg")
                    .disabled(!vm.regions.isEmpty)
                    .help(vm.isBusy
                          ? "Expert settings are locked while generation or Queue is running."
                          : vm.regions.isEmpty
                              ? "Set classifier-free guidance."
                              : "Regional prompts use the experimental CFG 0 path only.")
            }
            if vm.guidanceIsInvalid {
                advancedWarning("Enter a decimal from 0 to \(Int(GenerationRecipe.maximumGuidance)) using a period.")
            } else if vm.guidanceConflictsWithRegionalPrompts {
                advancedWarning("Regional prompts require Turbo CFG 0.")
            } else if vm.guidanceValue != 0 {
                Text("Non-zero CFG leaves the recommended distilled Turbo path.")
                    .fxFont(10.5)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var negativePromptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Negative prompt")
                    .fxFont(11.5, weight: .semibold)
                    .foregroundStyle(cLabel)
                Spacer()
                Text("\(vm.negativePrompt.utf8.count) / \(GenerationRecipe.maximumPromptUTF8Bytes)")
                    .fxMonoFont(9.5)
                    .foregroundStyle(vm.negativePromptIsInvalid ? Color.red : cSub)
            }
            ZStack(alignment: .topLeading) {
                if vm.negativePrompt.isEmpty {
                    Text("Optional exclusions…")
                        .fxFont(12.5)
                        .foregroundStyle(cSub)
                        .padding(.horizontal, 11)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.negativePrompt)
                    .fxFont(12.5)
                    .foregroundStyle(cEmber)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .accessibilityLabel("Negative prompt")
                    .accessibilityIdentifier("generate.settings.negative-prompt")
                    .help(vm.isBusy
                          ? "Expert settings are locked while generation or Queue is running."
                          : "Enter optional exclusions used by the non-zero CFG path.")
            }
            .frame(height: 68)
            .background(fill03, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                vm.negativePromptIsInvalid ? Color.red.opacity(0.8) : line07,
                lineWidth: 1))
            if vm.negativePromptIsInvalid {
                advancedWarning("The negative prompt exceeds the recipe size limit.")
            }
        }
    }

    private var noncanonicalTurboWarning: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "Noncanonical Turbo: \(vm.noncanonicalTurboSettings.joined(separator: ", "))",
                systemImage: "exclamationmark.triangle.fill")
                .fxFont(10.5, weight: .semibold)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Restore Turbo Recommended") {
                vm.restoreTurboRecommendedSettings()
                customStepsEnabled = false
            }
            .buttonStyle(.plain)
            .fxFont(10.5, weight: .semibold)
            .foregroundStyle(Color.fxAccentHi)
            .accessibilityIdentifier("generate.settings.restore-turbo")
            .help(vm.isBusy
                  ? "Expert settings are locked while generation or Queue is running."
                  : "Restore CFG 0 and the recommended 8-step Turbo path.")
        }
        .padding(10)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
    }

    private var activeLoRAStackRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.fxAccent)
                Text("ACTIVE LoRA STACK")
                    .fxFont(9.5, weight: .semibold)
                    .foregroundStyle(cSub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 4)
                Button("Manage", action: onManageLoRA)
                    .buttonStyle(.plain)
                    .fxFont(10.5, weight: .semibold)
                    .foregroundStyle(Color.fxAccentHi)
                    .accessibilityLabel("Manage in LoRA")
                    .accessibilityIdentifier("generate.settings.manage-lora")
                    .help(vm.isBusy
                          ? "Expert settings are locked while generation or Queue is running."
                          : "Open LoRA to enable, disable, reorder, or scale adapters.")
            }
            Text(vm.activeLoRASummary ?? "None")
                .fxMonoFont(10.5, weight: .medium)
                .foregroundStyle(cText)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(GenerateSettingsPanelLayout.moreLoRAPadding)
        .background(fill03, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(line07, lineWidth: 1))
    }

    private func advancedWarning(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .fxFont(10.5, weight: .medium)
            .foregroundStyle(Color.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var livePreviewSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("LIVE PREVIEW")
                    .fxFont(9.5, weight: .semibold)
                    .foregroundStyle(cSub)
                    .help(vm.isBusy
                          ? "Off hides the current diagnostic frame immediately. Other cadence changes apply to the next rendered image."
                          : "Choose how often to copy the diagnostic latent preview.")
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.fxAccent.opacity(0.8))
            }
            HStack(spacing: 7) {
                ForEach(GenerateViewModel.LivePreviewMode.allCases, id: \.self) { mode in
                    previewModeButton(mode)
                }
            }
        }
        .help(vm.isBusy
              ? "Diagnostic latent view — not the final decoded image. Off applies immediately."
              : "Diagnostic latent view — not the final decoded image.")
    }

    private func previewModeButton(_ mode: GenerateViewModel.LivePreviewMode) -> some View {
        let isSelected = vm.livePreviewMode == mode
        return Button {
            if !isSelected { vm.setLivePreviewMode(mode) }
        } label: {
            Text(mode.displayName)
                .fxFont(10, weight: .semibold)
                .foregroundStyle(isSelected ? Color.white : cMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    isSelected
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color.fxAccent, Color.fxAccentDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                        : AnyShapeStyle(fill04),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? Color.fxAccent.opacity(0.9) : line07, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(previewModeAccessibilityID(mode))
        .accessibilityLabel("Live preview \(mode.displayName)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(isSelected
                  ? "Live preview \(mode.displayName.lowercased()) is already selected."
                  : vm.isBusy && mode == .off
                      ? "Hide the current latent preview immediately and disable it for following images."
                  : vm.isBusy
                      ? "Use \(mode.displayName.lowercased()) beginning with the next rendered image."
                  : mode == .everyStep
                      ? "Update after each denoise step. This adds a small diagnostic copy each step."
                      : "Use live preview \(mode.displayName.lowercased()).")
    }

    private func previewModeAccessibilityID(
        _ mode: GenerateViewModel.LivePreviewMode
    ) -> String {
        switch mode {
        case .off: "generate.settings.preview.off"
        case .everyFourSteps: "generate.settings.preview.every-4-steps"
        case .everyStep: "generate.settings.preview.every-step"
        }
    }

    // MARK: - More · Variations

    private var variationsSettingsSection: some View {
        VStack(alignment: .leading, spacing: GenerateSettingsPanelLayout.moreContentSpacing) {
            seedStrategySection
            batchSection
        }
    }

    private var seedStrategySection: some View {
        let randomActive = vm.seedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 5) {
            Text("SEED")
                .fxFont(9.5, weight: .semibold)
                .foregroundStyle(cSub)
            HStack(spacing: 6) {
                Image(systemName: randomActive ? "dice" : "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(cIcon)
                TextField("random every render", text: $vm.seedText)
                    .textFieldStyle(.plain)
                    .fxMonoFont(10.5, weight: .medium)
                    .foregroundStyle(vm.seedIsInvalid ? Color.red : cText)
                    .disabled(vm.isBusy)
                    .accessibilityLabel(randomActive ? "Random seed" : "Fixed seed")
                    .accessibilityIdentifier("generate.settings.seed.value")
                Button {
                    randomActive ? vm.useFixedSeed() : vm.randomizeSeed()
                } label: {
                    Text(randomActive ? "Fix" : "Random")
                        .fxFont(9.5, weight: .semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.fxAccentHi)
                .disabled(vm.isBusy)
                .accessibilityIdentifier(randomActive
                    ? "generate.settings.seed.fixed"
                    : "generate.settings.seed.random")
                .help(randomActive
                    ? "Freeze one visible seed for deterministic renders."
                    : "Resolve a new random seed when each render starts.")
                Button { vm.useLastSeed() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(cIcon)
                .disabled(vm.isBusy || vm.lastSeed == nil)
                .accessibilityLabel("Use last seed")
                .accessibilityIdentifier("generate.settings.seed.last")
                .help(vm.lastSeed == nil
                    ? "Complete a render before reusing its resolved seed."
                    : "Copy the last resolved result seed into this field.")
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(fill03, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                vm.seedIsInvalid ? Color.red.opacity(0.8) : line07,
                lineWidth: 1))
            if vm.seedIsInvalid {
                advancedWarning("Enter an unsigned 64-bit integer.")
            }
        }
        .opacity(vm.isBusy ? 0.6 : 1)
    }

    private var batchSection: some View {
        HStack(spacing: 8) {
            Text("BATCH")
                .fxFont(9.5, weight: .semibold)
                .foregroundStyle(cSub)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                pmButton(
                    "minus",
                    accessibilityID: "generate.settings.batch.decrement",
                    enabled: !vm.isBusy && vm.batch > 1,
                    help: vm.isBusy
                        ? "Batch is locked while generation or Queue is running."
                        : vm.batch == 1
                            ? "Batch is already at the minimum of 1."
                            : "Decrease batch size.") {
                        vm.batch -= 1
                    }
                Spacer(minLength: 0)
                Text("\(vm.batch)")
                    .fxMonoFont(13, weight: .semibold)
                    .foregroundStyle(cText)
                Text(vm.batch == 1 ? " image" : " images")
                    .fxFont(10.5)
                    .foregroundStyle(cSub)
                Spacer(minLength: 0)
                pmButton(
                    "plus",
                    accessibilityID: "generate.settings.batch.increment",
                    enabled: !vm.isBusy && vm.batch < 8,
                    help: vm.isBusy
                        ? "Batch is locked while generation or Queue is running."
                        : vm.batch == 8
                            ? "Batch is already at the maximum of 8."
                            : "Increase batch size.") {
                        vm.batch += 1
                    }
            }
            .frame(width: 118, height: 30)
            .background(fill03, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(line07, lineWidth: 1))
        }
        .opacity(vm.isBusy ? 0.6 : 1)
        .help("Images render sequentially. Fixed seeds advance seed, seed+1, seed+2.")
    }

    private func pmButton(
        _ symbol: String,
        accessibilityID: String,
        enabled: Bool,
        help: String,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(cIcon)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .disabled(!enabled)
        .help(help)
    }


    // ── Busy card (frame a) ───────────────────────────────────────────────
    private var busyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FxDot(tone: .amber, live: true, size: 8)
                Text(vm.activityText)
                    .fxFont(12.5, weight: .semibold).foregroundStyle(cText)
                Spacer(minLength: 8)
                if let eta = vm.etaText {
                    Text(eta).fxMonoFont(12, weight: .semibold).foregroundStyle(Color.fxAccentHi)
                }
            }
            if let progress = vm.denoisingProgress {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.3))
                        RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(colors: [.fxAccentDeep, .fxAccent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, min(1, progress)) * g.size.width)
                    }
                }
                .frame(height: 6)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
            HStack(spacing: 8) {
                Text(vm.busySubline).fxMonoFont(11, weight: .medium).foregroundStyle(cSub)
                Spacer(minLength: 8)
                Button { vm.cancel() } label: {
                    HStack(spacing: 5) {
                        if vm.isStopping {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "square").font(.system(size: 10))
                        }
                        Text(vm.isStopping ? "Stopping..." : "Stop")
                    }.fxFont(11.5, weight: .semibold).foregroundStyle(cIcon)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .disabled(vm.isStopping)
                .help(vm.isStopping
                      ? "Cancellation was requested; the current Metal operation must finish first."
                      : "Stop after the active Metal operation finishes.")
                .accessibilityIdentifier("generate.busy.stop")
            }
        }
        .padding(16)
        .modifier(GenerateBusySurfaceModifier())
    }

    // ════════════════════════ COLUMN 2 — CANVAS ════════════════════════
    private var canvas: some View {
        ZStack {
            if isGlass {
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.12), location: 0),
                        .init(color: Color.white.opacity(0.025), location: 0.48),
                        .init(color: Color(hex: 0x081124, alpha: 0.15), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom)
            } else {
                RadialGradient(
                    colors: [Color.fxCanvasTop, Color.fxCanvas, Color.fxBg],
                    center: .top,
                    startRadius: 0,
                    endRadius: 900)
            }
            canvasContent
        }
        .clipShape(RoundedRectangle(
            cornerRadius: isGlass ? 14 : 18,
            style: .continuous))
        .overlay(alignment: .topTrailing) {
            if vm.resultImage != nil, !vm.isBusy { canvasButtons }
        }
        .modifier(GenerateCanvasSurfaceModifier())
        .frame(minWidth: 300, minHeight: 360)
        .accessibilityIdentifier("generate.canvas")
    }

    private var canvasButtons: some View {
        HStack(spacing: 8) {
            if vm.resultHasPersistedFile {
                if let generation = vm.displayedGeneration {
                    canvasButton(
                        "rectangle.stack.badge.plus",
                        accessibilityID: "generate.result.save-preset",
                        label: "Save as Preset",
                        help: "Save this result's complete generation recipe as a reusable Preset.") {
                        onSavePreset(generation)
                    }
                }
                canvasButton(
                    "arrow.down.to.line",
                    accessibilityID: "generate.result.save-copy",
                    label: "Save a copy",
                    help: "Review this result, then choose a destination for a PNG copy.") { saveCopy() }
                canvasButton(
                    "arrow.up.right.and.arrow.down.left",
                    accessibilityID: "generate.result.view-full-size",
                    label: "View full size",
                    help: "Review a provenance-bound copy, then open it at full size.") { viewFullSize() }
                canvasButton(
                    "trash",
                    accessibilityID: "generate.result.delete",
                    label: "Delete from Gallery",
                    help: "Open a confirmation before permanently deleting this managed Gallery image.",
                    tint: Color.fxDanger) {
                    showDeleteResultConfirmation = true
                }
            }
            canvasButton(
                "xmark",
                accessibilityID: "generate.result.clear-canvas",
                label: "Clear canvas",
                help: "Hide this result from Generate without deleting its saved Gallery image.") {
                vm.clearDisplayedResult()
            }
        }.padding(18)
    }

    private func canvasButton(
        _ icon: String,
        accessibilityID: String,
        label: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(tint ?? cText)
                .frame(width: 34, height: 34)
                .modifier(GenerateCanvasButtonSurfaceModifier())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(label)
        .help(help)
    }

    /// Copies the already-saved gallery PNG to a user-chosen location.
    private func saveCopy() {
        guard let source = vm.persistedResultURL else {
            vm.errorMessage = "This result wasn't saved to Gallery, so there is no PNG to copy."
            return
        }
        Task { @MainActor in
            do {
                let output = try await vm.reviewableDisplayedResult()
                let panel = NSSavePanel()
                panel.nameFieldStringValue = source.lastPathComponent
                panel.allowedContentTypes = [.png]
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                guard let receipt = OutputReviewGate.reviewBeforeExport(
                    outputs: [output],
                    kind: .saveCopy) else { return }
                _ = await vm.exportDisplayedResult(
                    output,
                    to: destination,
                    receipt: receipt,
                    kind: .saveCopy)
            } catch {
                vm.errorMessage = "Couldn't prepare the PNG export: \(error.localizedDescription)"
            }
        }
    }

    /// Opens only a reviewed provenance copy in the default viewer. The private managed PNG is
    /// never handed to Preview, where Save As would otherwise bypass the export boundary.
    private func viewFullSize() {
        guard vm.persistedResultURL != nil else {
            vm.errorMessage = "This result wasn't saved to Gallery, so there is no PNG to open."
            return
        }
        Task { @MainActor in
            do {
                let output = try await vm.reviewableDisplayedResult(
                    derivation: .reviewedGalleryCopy)
                guard let receipt = OutputReviewGate.reviewBeforeExport(
                    outputs: [output],
                    kind: .finderCopy,
                    previewPNG: output.data) else { return }
                let destination = try ReviewedPreviewStore.prepareDestination()
                if await vm.exportDisplayedResult(
                    output,
                    to: destination,
                    receipt: receipt,
                    kind: .finderCopy) {
                    try ReviewedPreviewStore.securePublishedPreview(at: destination)
                    guard NSWorkspace.shared.open(destination) else {
                        ReviewedPreviewStore.discard(destination)
                        vm.errorMessage = "The reviewed PNG was created, but no image viewer could open it."
                        return
                    }
                }
            } catch {
                vm.errorMessage = "Couldn't prepare the reviewed preview: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder private var canvasContent: some View {
        if let image = vm.resultImage, !vm.isBusy {
            if vm.resultHasPersistedFile {
                resultImageView(image).onDrag { resultDragProvider() }
            } else {
                resultImageView(image)
            }
        } else if vm.isBusy {
            Group {
                if vm.livePreviewMode != .off, let preview = vm.latentPreviewImage {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(16)
                        .overlay(alignment: .bottom) {
                            Text("LATENT PREVIEW · \(vm.latentPreviewStep) / \(vm.latentPreviewTotalSteps)")
                                .fxMonoFont(10.5, weight: .semibold)
                                .foregroundStyle(Color.fxText2)
                                .padding(.vertical, 7)
                                .padding(.horizontal, 11)
                                .background(Color.black.opacity(0.58), in: Capsule())
                                .padding(20)
                        }
                        .overlay(alignment: .topTrailing) {
                            Button {
                                vm.setLivePreviewMode(.off)
                            } label: {
                                Label("Hide preview", systemImage: "xmark")
                                    .fxFont(11.5, weight: .semibold)
                                    .foregroundStyle(Color.white)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(Color.black.opacity(0.72), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(20)
                            .accessibilityIdentifier("generate.live-preview.dismiss")
                            .help("Hide the current latent preview immediately and keep live preview off.")
                        }
                        .accessibilityLabel("Latent preview")
                        .accessibilityValue("Step \(vm.latentPreviewStep) of \(vm.latentPreviewTotalSteps)")
                } else {
                    VStack(spacing: 16) {
                        if let progress = vm.denoisingProgress {
                            ZStack {
                                Ring(pct: progress, size: 104, lineWidth: 6)
                                Text("\(Int(progress * 100))%")
                                    .fxFont(22, weight: .bold)
                                    .foregroundStyle(cText)
                            }
                        } else {
                            ProgressView().controlSize(.large)
                        }
                        VStack(spacing: 4) {
                            Text(vm.activityText)
                                .fxMonoFont(13).foregroundStyle(cText)
                            if let eta = vm.etaText {
                                Text(eta).fxMonoFont(12).foregroundStyle(cSub)
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("generate.state.busy")
        } else {
            emptyCanvasPlaceholder
        }
    }

    @ViewBuilder
    private var emptyCanvasPlaceholder: some View {
        if isGlass {
            ZStack {
                // The rear pane is deliberately borderless. A complete border
                // remains visible through translucent glass and would cut across
                // the copy on the front pane.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: 0x9BB6E9, alpha: 0.055))
                    .frame(width: 232, height: 150)
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                    .offset(x: 12, y: 4)
                    .opacity(0.42)

                // Keep the icon and both one-line labels inside the same pane.
                // At the standard text size the subtitle is ~200 pt wide, so
                // 232 pt leaves a real 16 pt inset instead of overflowing.
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(FxGlassPalette.text2.opacity(0.82))
                        .shadow(color: Color.white.opacity(0.13), radius: 5)
                    Text("Your image will appear here")
                        .fxFont(13, weight: .semibold)
                        .foregroundStyle(FxGlassPalette.text2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    Text("Type a prompt and press Generate.")
                        .fxFont(12)
                        .foregroundStyle(cSub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                .padding(.horizontal, 16)
                .frame(width: 232, height: 150)
                .modifier(GeneratePlaceholderSurfaceModifier(
                    tint: Color(hex: 0xC1D2F7, alpha: 0.10),
                    stroke: Color.white.opacity(0.20),
                    shadow: 10))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("generate.state.empty")
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.fxText3.opacity(0.6))
                Text("Your image will appear here")
                    .fxFont(13, weight: .semibold)
                    .foregroundStyle(Color.fxText2)
                Text("Type a prompt and press Generate.")
                    .fxFont(12)
                    .foregroundStyle(cSub)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("generate.state.empty")
        }
    }

    private func resultImageView(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).padding(16)
            .overlay(alignment: .bottom) { canvasCaption }
            .accessibilityIdentifier("generate.state.result")
    }

    @ViewBuilder private var canvasCaption: some View {
        if let seed = vm.lastSeed,
           let width = vm.resultWidth,
           let height = vm.resultHeight,
           vm.resultImage != nil,
           !vm.isBusy {
            HStack(spacing: 8) {
                Text("\(String(width)) × \(String(height))")
                StatusSep()
                Text("seed \(String(seed))").lineLimit(1).truncationMode(.middle)
                if let t = vm.lastGenText { StatusSep(); Text(t) }
            }
            .fxMonoFont(10.5).foregroundStyle(Color.fxText2)
            .padding(.vertical, 7).padding(.horizontal, 12)
            .background(Color.black.opacity(0.5), in: Capsule())
            .padding(20)
        }
    }

    private func resultDragProvider() -> NSItemProvider {
        vm.displayedResultDragProvider()
    }
}

enum GenerateWorkspaceLayout {
    /// Matches the wider owner-marked command surface while remaining bounded on large displays.
    static let preferredComposerWidth: CGFloat = 1_320
    /// Preserve the accepted Fine-tuning/Text/Remix panel anchor from builds 123–139.
    static let preferredSettingsDeckWidth: CGFloat = 860

    static func composerWidth(availableWidth: CGFloat) -> CGFloat {
        min(max(0, availableWidth), preferredComposerWidth)
    }

    static func settingsDeckWidth(availableWidth: CGFloat) -> CGFloat {
        min(max(0, availableWidth), preferredSettingsDeckWidth)
    }
}

private struct GenerateComposerSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            content.fxGlassSurface(
                radius: 13,
                tint: Color(hex: 0x868890, alpha: 0.27),
                stroke: Color.white.opacity(0.22),
                shadow: 18)
        } else {
            content
                .background(
                    Color.fxSheet.opacity(0.98),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.fxBorderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        }
    }
}

private struct GeneratePrimaryActionSurfaceModifier: ViewModifier {
    let isEnabled: Bool
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            content.fxGlassSurface(
                radius: 9,
                tint: Color(hex: 0x7168EE, alpha: isEnabled ? 0.68 : 0.30),
                stroke: Color(hex: 0xC9C5FF, alpha: isEnabled ? 0.82 : 0.40),
                interactive: isEnabled,
                shadow: isEnabled ? 9 : 3)
                .shadow(
                    color: Color(hex: 0x7168EE, alpha: isEnabled ? 0.38 : 0.10),
                    radius: isEnabled ? 11 : 4)
        } else {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            content
                .background(
                    LinearGradient(
                        colors: [
                            Color(hex: 0x8179F4, alpha: isEnabled ? 1 : 0.42),
                            Color(hex: 0x5B52D2, alpha: isEnabled ? 1 : 0.36),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    in: shape)
                .overlay(shape.strokeBorder(
                    Color(hex: 0xB8B3FF, alpha: isEnabled ? 0.42 : 0.24),
                    lineWidth: 1))
                .shadow(
                    color: Color(hex: 0x6259DE, alpha: isEnabled ? 0.28 : 0.06),
                    radius: isEnabled ? 8 : 2,
                    y: 2)
        }
    }
}

private struct GenerateSettingsSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            content.fxGlassSurface(
                radius: 16,
                tint: Color(hex: 0x11172C, alpha: 0.76),
                stroke: Color.white.opacity(0.20),
                shadow: 24)
        } else {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            content
                .background(Color.fxSheet.opacity(0.98), in: shape)
                .overlay(shape.strokeBorder(Color.fxBorderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 28, y: 14)
        }
    }
}

private struct GenerateBusySurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            content.fxGlassSurface(
                radius: 14,
                tint: Color(hex: 0x93A7B5, alpha: 0.10),
                stroke: Color(hex: 0xAFC5DB, alpha: 0.26),
                shadow: 12)
        } else {
            content
                .background(
                    Color(hex: 0x93A7B5, alpha: 0.08),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(hex: 0x93A7B5, alpha: 0.24), lineWidth: 1))
        }
    }
}

private struct GenerateCanvasSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme
    @Environment(\.fxReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            content
                .background(reduceTransparency ? FxGlassPalette.panel : Color.clear, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.17), lineWidth: 1))
        } else {
            content.overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.035), lineWidth: 1))
        }
    }
}

private struct GeneratePlaceholderSurfaceModifier: ViewModifier {
    let tint: Color
    let stroke: Color
    let shadow: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .background(tint, in: shape)
            .overlay(shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.11), location: 0),
                        .init(color: Color.white.opacity(0.045), location: 0.38),
                        .init(color: Color.clear, location: 0.44),
                        .init(color: Color.clear, location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .overlay(shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.13), Color.clear, Color.white.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing),
                lineWidth: 0.65))
            .shadow(color: .black.opacity(shadow > 0 ? 0.16 : 0), radius: shadow, y: shadow * 0.35)
    }
}

private struct GenerateCanvasButtonSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            content.fxGlassSurface(
                radius: 9,
                tint: Color.black.opacity(0.24),
                stroke: Color.white.opacity(0.15),
                interactive: true,
                shadow: 5)
        } else {
            content
                .background(
                    Color.black.opacity(0.38),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}
