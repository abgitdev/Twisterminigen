import SwiftUI
import AppKit
import Krea2Pipeline

@main
struct TwisterminigenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var startup: AppStartupState

    init() {
        _startup = State(initialValue: Self.startApplication())
    }

    private static func startApplication() -> AppStartupState {
        let modelRoot: URL
        do {
            modelRoot = try AppPaths.bootstrap()
        } catch {
            return .storageUnavailable(StorageUnavailablePresentation(error: error))
        }
        // Purge any response bytes cached by builds that predate the isolated download transport.
        URLCache.shared.removeAllCachedResponses()
        OfficialKreaStyleLoRADownload.cleanupAbandonedArtifacts()
        let store = GenerationStore()        // shared: Generate saves into it, Gallery reads it
        let queueSetup = Self.openQueueStore()
        let loraSetup = Self.openLoRAStore()
        let inputImageSetup = Self.openInputImageStore()
        let presetSetup = Self.openPresetLibraryStore()
        let inference = InferenceCoordinator()
        let describeImageVM = DescribeImageViewModel(coordinator: inference)
        let localUpscaleVM = LocalUpscaleViewModel(coordinator: inference)
        let licensePreferences = KreaLicensePreferences()
        let loraVM = LoRAViewModel(
            store: loraSetup.store,
            coordinator: inference,
            licensePreferences: licensePreferences,
            startupWarning: loraSetup.warning)
        let modelStore = ModelStore(
            catalog: ModelCatalog(root: modelRoot),
            readOnly: AppPaths.weightsSource.isReadOnly) // shared model-directory snapshot
        let telemetry = TelemetryService()   // shared: status bar + rail + System screen
        let conditioningCache = Krea2ConditioningCache()
        let memoryGovernor = MemoryGovernor(
            snapshotProvider: TelemetryService.memoryGovernorSnapshot)
        let modelQuality = ModelQualitySelection()
        let generateVM = GenerateViewModel(
            store: store,
            coordinator: inference,
            memoryGovernor: memoryGovernor,
            conditioningCache: conditioningCache,
            loraLibrary: loraVM,
            inputImageStore: inputImageSetup.store,
            inputImageStartupWarning: inputImageSetup.warning,
            queueStore: queueSetup.store,
            queueStartupWarning: queueSetup.warning,
            modelQuality: modelQuality,
            licensePreferences: licensePreferences)
        loraVM.configureTriggerInsertionHandler { [weak generateVM] assetID, triggers in
            guard let generateVM else { return }
            for trigger in triggers {
                _ = generateVM.insertLoRATrigger(assetID: assetID, trigger: trigger)
            }
        }
        let galleryVM = GalleryViewModel(
            store: store,
            annotations: GalleryAnnotationStore())
        let modelsVM = ModelsViewModel(
            store: modelStore,
            coordinator: inference,
            conditioningCache: conditioningCache,
            initialRoot: modelRoot,
            modelQuality: modelQuality,
            licensePreferences: licensePreferences)
        ShortcutRenderRuntime.configure(generate: generateVM)
        TerminationGuard.configure(
            coordinator: inference,
            generate: generateVM,
            models: modelsVM,
            describeImage: describeImageVM,
            localUpscale: localUpscaleVM)
        SystemLog.shared.log(
            "Application started — version \(AppVersion.current), build \(AppVersion.build).")
        return .ready(AppRuntime(
            generateVM: generateVM,
            galleryVM: galleryVM,
            modelsVM: modelsVM,
            loraVM: loraVM,
            describeImageVM: describeImageVM,
            localUpscaleVM: localUpscaleVM,
            presetStore: presetSetup.store,
            telemetry: telemetry,
            inference: inference,
            accessibilityPreferences: AppAccessibilityPreferences(),
            themePreferences: AppThemePreferences()))
    }

    private static func openLoRAStore() -> (store: LoRAStore?, warning: String?) {
        do {
            return (try LoRAStore(), nil)
        } catch {
            let message = error.localizedDescription
            SystemLog.shared.log("LoRA library startup failed: \(message)")
            return (nil, "LoRA library is unavailable: \(message)")
        }
    }

    private static func openInputImageStore() -> (store: InputImageStore?, warning: String?) {
        do {
            return (try InputImageStore(), nil)
        } catch {
            let message = error.localizedDescription
            SystemLog.shared.log("Input image library startup failed: \(message)")
            return (nil, "Remix source storage is unavailable: \(message)")
        }
    }

    private static func openQueueStore() -> (store: QueueStore?, warning: String?) {
        do {
            return (try QueueStore(), nil)
        } catch let error as QueueStoreError {
            let warning = error.localizedDescription
            SystemLog.shared.log("Queue startup recovery: \(warning)")
            if case .corruptFiles = error {
                do {
                    return (
                        try QueueStore(),
                        "Invalid queue data was isolated. The queue restarted empty; the original file was preserved for recovery.")
                } catch {
                    let retry = error.localizedDescription
                    SystemLog.shared.log("Queue startup retry failed: \(retry)")
                    return (nil, "Queue storage is unavailable: \(retry)")
                }
            }
            return (nil, "Queue storage is unavailable: \(warning)")
        } catch {
            let message = error.localizedDescription
            SystemLog.shared.log("Queue startup failed: \(message)")
            return (nil, "Queue storage is unavailable: \(message)")
        }
    }

    private static func openPresetLibraryStore() -> (store: PresetLibraryStore?, warning: String?) {
        do {
            return (try PresetLibraryStore(), nil)
        } catch {
            let message = error.localizedDescription
            SystemLog.shared.log("Preset library startup failed: \(message)")
            return (nil, "Preset storage is unavailable: \(message)")
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .ready(let runtime):
                AppAccessibilityRoot(preferences: runtime.accessibilityPreferences) {
                    ContentView(
                        generateVM: runtime.generateVM,
                        galleryVM: runtime.galleryVM,
                        modelsVM: runtime.modelsVM,
                        loraVM: runtime.loraVM,
                        describeImageVM: runtime.describeImageVM,
                        localUpscaleVM: runtime.localUpscaleVM,
                        presetStore: runtime.presetStore,
                        telemetry: runtime.telemetry,
                        inference: runtime.inference)
                    .environment(runtime.accessibilityPreferences)
                    .environment(runtime.themePreferences)
                    // Light reuses the opaque surface family while adaptive tokens resolve
                    // through the light color scheme. Only Glass enables material/backdrop paths.
                    .environment(
                        \.fxTheme,
                        runtime.themePreferences.selection == .glass
                            ? AppTheme.glass : AppTheme.dark)
                    // 1200 keeps the main workspace usable at the default text scale. Screens
                    // provide their own scrolling when an accessibility text size needs more room.
                    .frame(minWidth: 1200, minHeight: 720)
                    .preferredColorScheme(
                        runtime.themePreferences.selection.preferredColorScheme)
                    .background(
                        runtime.themePreferences.selection == .glass
                            ? Color.fxOpaqueBg : Color.fxBg)
                    .background(MainWindowTracker())
                }
            case .storageUnavailable(let presentation):
                StorageUnavailableRecoveryView(
                    presentation: presentation,
                    onRetry: retryStorage,
                    onChooseFolder: chooseAlternativeStorageFolder)
                    .frame(minWidth: 720, minHeight: 520)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Twisterminigen") {
                    Self.showAboutPanel()
                }
            }
            CommandGroup(replacing: .newItem) {}   // single-window app
            AppNavigationCommands()
            if case .ready(let runtime) = startup {
                PortableRecipeCommands(generate: runtime.generateVM)
            }
        }
    }

    private static func showAboutPanel() {
        let credits = NSMutableAttributedString(
            string: "Support Twisterminigen development on Ko-fi")
        credits.addAttribute(
            .link,
            value: ProjectLinks.donationURL,
            range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func retryStorage() {
        startup = Self.startApplication()
    }

    private func chooseAlternativeStorageFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Twisterminigen Storage"
        panel.message =
            "A private Twisterminigen subfolder will be created inside the selected folder. "
            + "Existing data is not moved or deleted."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            try AppPaths.setStorageRoot(selected)
            startup = Self.startApplication()
        } catch {
            startup = .storageUnavailable(StorageUnavailablePresentation(error: error))
        }
    }
}

private enum AppStartupState {
    case ready(AppRuntime)
    case storageUnavailable(StorageUnavailablePresentation)
}

@MainActor
private final class AppRuntime {
    let generateVM: GenerateViewModel
    let galleryVM: GalleryViewModel
    let modelsVM: ModelsViewModel
    let loraVM: LoRAViewModel
    let describeImageVM: DescribeImageViewModel
    let localUpscaleVM: LocalUpscaleViewModel
    let presetStore: PresetLibraryStore?
    let telemetry: TelemetryService
    let inference: InferenceCoordinator
    let accessibilityPreferences: AppAccessibilityPreferences
    let themePreferences: AppThemePreferences

    init(
        generateVM: GenerateViewModel,
        galleryVM: GalleryViewModel,
        modelsVM: ModelsViewModel,
        loraVM: LoRAViewModel,
        describeImageVM: DescribeImageViewModel,
        localUpscaleVM: LocalUpscaleViewModel,
        presetStore: PresetLibraryStore?,
        telemetry: TelemetryService,
        inference: InferenceCoordinator,
        accessibilityPreferences: AppAccessibilityPreferences,
        themePreferences: AppThemePreferences
    ) {
        self.generateVM = generateVM
        self.galleryVM = galleryVM
        self.modelsVM = modelsVM
        self.loraVM = loraVM
        self.describeImageVM = describeImageVM
        self.localUpscaleVM = localUpscaleVM
        self.presetStore = presetStore
        self.telemetry = telemetry
        self.inference = inference
        self.accessibilityPreferences = accessibilityPreferences
        self.themePreferences = themePreferences
    }
}

struct StorageUnavailablePresentation: Sendable, Equatable {
    let message: String
    let recovery: String
    let path: String
    let diagnostic: String

    init(error: Error, attemptedLocation: URL = AppPaths.appSupport) {
        let failure = AppStorageBootstrapError.wrap(
            error,
            operation: "startup",
            location: attemptedLocation)
        message = failure.localizedDescription
        recovery = failure.recoverySuggestion
            ?? "Check the storage volume or choose another folder, then retry."
        path = failure.location.path
        diagnostic = failure.diagnosticMessage
    }
}

private struct StorageUnavailableRecoveryView: View {
    let presentation: StorageUnavailablePresentation
    let onRetry: () -> Void
    let onChooseFolder: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.orange)

                VStack(spacing: 9) {
                    Text("Storage unavailable")
                        .font(.system(size: 24, weight: .bold))
                    Text(presentation.message)
                        .font(.system(size: 14, weight: .medium))
                        .accessibilityIdentifier("storage-unavailable.message")
                    Text(presentation.recovery)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 580)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Attempted location")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(presentation.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("storage-unavailable.path")
                    Divider()
                    Text("Diagnostic")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(presentation.diagnostic)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("storage-unavailable.diagnostic")
                }
                .padding(16)
                .frame(maxWidth: 620, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 12) {
                    Button("Retry", action: onRetry)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("storage-unavailable.retry")
                    Button("Choose Another Folder…", action: onChooseFolder)
                        .accessibilityIdentifier("storage-unavailable.choose-folder")
                }
                .controlSize(.large)
            }
            .padding(36)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage-unavailable.view")
    }
}

private struct AppNavigationCommands: Commands {
    @FocusedValue(\.appNavigationActions) private var navigation

    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(AppSection.allCases) { destination in
                Button("\(destination.shortcutNumber). \(destination.title)") {
                    navigation?.select(destination)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(destination.shortcutNumber))),
                    modifiers: .command)
                .disabled(navigation == nil)
            }
        }
    }
}

/// Handles launch-time setup that needs AppKit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationWaitTask: Task<Void, Never>?
    private var schedulesBusyWindowClose = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App Intents with openAppWhenRun=false may start the process without a UI scene. Do not
        // foreground merely because the process launched; MainWindowTracker requests activation
        // only after AppKit reports a genuinely visible main window.
        AppForegroundActivation.applicationDidFinishLaunching()
        QueueNotifier.installDelegate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard terminationWaitTask == nil else { return .terminateLater }
            guard let activity = TerminationGuard.activity() else { return .terminateNow }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Twisterminigen is still working"
            alert.informativeText = activity.explanation
                + " Stopping is cooperative: the current Metal or file operation may need time "
                + "to reach a safe boundary before the app can close."
            alert.addButton(withTitle: "Keep Working")
            alert.addButton(withTitle: "Stop and Quit When Safe")

            guard alert.runModal() == .alertSecondButtonReturn else {
                DispatchQueue.main.async { TerminationGuard.restoreMainWindow() }
                return .terminateCancel
            }

            TerminationGuard.requestStop()
            terminationWaitTask = Task { @MainActor [weak self, weak sender] in
                while TerminationGuard.activity() != nil, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled, let sender else { return }
                self?.terminationWaitTask = nil
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            if !flag { TerminationGuard.restoreMainWindow() }
            return true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            guard TerminationGuard.activity() == nil else {
                // Last-window close has the same explicit choice as Cmd-Q. Restore the SwiftUI
                // window first, then enter the normal termination delegate on the next run loop.
                if !schedulesBusyWindowClose {
                    schedulesBusyWindowClose = true
                    DispatchQueue.main.async { [weak self, weak sender] in
                        self?.schedulesBusyWindowClose = false
                        TerminationGuard.restoreMainWindow()
                        sender?.terminate(nil)
                    }
                }
                return false
            }
            return true
        }
    }
}

/// Public-state launch policy: an invisible/background scene never requests foreground, while the
/// first visible UI window does. This avoids guessing undocumented App Intent process arguments.
struct AppLaunchActivationPolicy: Equatable {
    private(set) var hasRequestedForeground = false

    mutating func shouldRequestForeground(windowIsVisible: Bool) -> Bool {
        guard windowIsVisible, !hasRequestedForeground else { return false }
        hasRequestedForeground = true
        return true
    }
}

/// Thin AppKit client with a dependency-injection seam. Production only reaches the live client
/// after a visible window event; tests can prove background launches make no activation calls.
@MainActor
enum AppForegroundActivation {
    struct Client {
        let setRegularPolicy: @MainActor () -> Void
        let activate: @MainActor () -> Void

        static var live: Self {
            Self(
                setRegularPolicy: {
                    _ = NSApplication.shared.setActivationPolicy(.regular)
                },
                activate: {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                })
        }
    }

    private static var policy = AppLaunchActivationPolicy()
    private static var client = Client.live

    static func applicationDidFinishLaunching() {
        // Deliberately no foreground work. A process has one launch lifecycle, and resetting the
        // policy here could duplicate a request if SwiftUI attached its visible scene first.
    }

    static func windowVisibilityDidChange(isVisible: Bool) {
        guard policy.shouldRequestForeground(windowIsVisible: isVisible) else { return }
        client.setRegularPolicy()
        client.activate()
    }

    static func installForTesting(_ client: Client) {
        self.client = client
        policy = AppLaunchActivationPolicy()
    }

    static func resetAfterTesting() {
        client = .live
        policy = AppLaunchActivationPolicy()
    }
}

/// Bridges the live coordinator into AppKit without transferring MLX ownership to the delegate.
@MainActor
private enum TerminationGuard {
    struct Activity {
        let explanation: String
    }

    private static var activityProvider: (() -> Activity?)?
    private static var stopRequest: (() -> Void)?
    static var mainWindow: NSWindow?

    static func configure(
        coordinator: InferenceCoordinator,
        generate: GenerateViewModel,
        models: ModelsViewModel,
        describeImage: DescribeImageViewModel,
        localUpscale: LocalUpscaleViewModel
    ) {
        activityProvider = { [weak coordinator] in
            guard let coordinator, coordinator.blocksApplicationTermination else { return nil }
            if let operation = coordinator.activeOperation {
                return Activity(explanation: "A \(operation.title) operation is still active.")
            }
            if coordinator.isChangingModels {
                return Activity(explanation: "Local model files are still being changed.")
            }
            return nil
        }
        stopRequest = {
            [weak coordinator, weak generate, weak models, weak describeImage, weak localUpscale] in
            coordinator?.requestApplicationTermination()
            generate?.cancel()
            models?.requestStopForTermination()
            describeImage?.cancel()
            localUpscale?.cancel()
        }
    }

    static func activity() -> Activity? { activityProvider?() }
    static func requestStop() { stopRequest?() }

    static func restoreMainWindow() {
        guard let mainWindow else { return }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// SwiftUI keeps its window after ordering it out, while AppKit may no longer expose it as key/main.
/// Retaining this non-owning handle lets a cancelled close restore the same WindowGroup window.
private struct MainWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ nsView: TrackingView, context: Context) {}

    @MainActor
    final class TrackingView: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didUpdateNotification,
                    object: window)
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didBecomeMainNotification,
                    object: window)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            TerminationGuard.mainWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityMayHaveChanged(_:)),
                name: NSWindow.didUpdateNotification,
                object: window)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityMayHaveChanged(_:)),
                name: NSWindow.didBecomeMainNotification,
                object: window)
            reportVisibility(of: window)
            // SwiftUI commonly attaches this tracking view immediately before orderFront. The
            // notification covers that transition; the next-turn check covers an already-visible
            // window whose notification preceded attachment.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.reportVisibility(of: window)
            }
        }

        @objc private func windowVisibilityMayHaveChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  self.window === window else { return }
            reportVisibility(of: window)
        }

        private func reportVisibility(of window: NSWindow) {
            AppForegroundActivation.windowVisibilityDidChange(isVisible: window.isVisible)
        }
    }
}
