import AppKit
import Krea2Pipeline
import Observation
import SwiftUI

enum ModelComponentStatusPresentation {
    static func title(for state: ComponentState, linkedReadOnly: Bool) -> String {
        if linkedReadOnly {
            return switch state {
            case .downloaded: "Linked · verified"
            case .partial: "Linked · incomplete"
            case .corrupted: "Linked · mismatch"
            case .missing: "Linked · missing"
            }
        }
        return switch state {
        case .downloaded: "Installed · verified"
        case .partial: "Download paused"
        case .corrupted: "Repair required"
        case .missing: "Not installed"
        }
    }

    static func ownershipDetail(for state: ComponentState, linkedReadOnly: Bool) -> String {
        if linkedReadOnly {
            return state == .downloaded
                ? "Verified external file · managed outside Twisterminigen"
                : "External read-only source · use Show source to inspect it"
        }
        return state == .downloaded
            ? "App-managed file · can be removed here"
            : "App-managed storage · download is available here"
    }
}

/// Drives the Models screen: component statuses, live download progress, delete confirmation.
///
/// The VM is @MainActor; the heavy work (downloads, disk scans) lives on the `ModelStore` actor
/// and is invoked from a `Task`. Progress hops back to the main actor to update the UI.
@MainActor
@Observable
final class ModelsViewModel {
    private enum LicensedAction {
        case download(String)
        case importWeights
        case linkWeights
    }

    // Displayed state
    var components: [ComponentStatus] = []
    var errorMessage: String? = nil
    var weightsRoot: URL
    var isLinkedReadOnly: Bool
    var isRefreshing = false
    var isSwitchingRoot = false

    // Live downloads — per-component, so every component can download at the same time
    // (ResumableDownloader/TransferCoordinator have no shared mutable state, so this is safe).
    var downloadingIDs: Set<String> = []
    var progress: [String: Double] = [:]
    var progressLabel: [String: String] = [:]

    // Delete confirmation (nil = no alert)
    var pendingDeleteID: String? = nil
    var showsKreaLicenseReview = false

    /// Bumped whenever the on-disk set changes — lets other screens (Generate) re-check readiness.
    var revision: Int = 0

    private let store: ModelStore
    private let coordinator: InferenceCoordinator
    private let conditioningCache: Krea2ConditioningCache?
    private let modelQuality: ModelQualitySelection
    private let licensePreferences: KreaLicensePreferences
    private var pendingLicensedAction: LicensedAction?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var modelMutationLeases: [String: InferenceCoordinator.ModelMutationLease] = [:]
    private var refreshTask: Task<Void, Never>? = nil
    private var refreshRequestID = 0
    private var progressTokens: [String: UUID] = [:]
    private var progressSequences: [String: UInt64] = [:]

    init(
        store: ModelStore,
        coordinator: InferenceCoordinator,
        conditioningCache: Krea2ConditioningCache? = nil,
        initialRoot: URL = AppPaths.weightsRoot,
        modelQuality: ModelQualitySelection = ModelQualitySelection(),
        licensePreferences: KreaLicensePreferences
    ) {
        self.store = store
        self.coordinator = coordinator
        self.conditioningCache = conditioningCache
        self.weightsRoot = initialRoot.standardizedFileURL
        self.isLinkedReadOnly = AppPaths.weightsSource.isReadOnly
        self.modelQuality = modelQuality
        self.licensePreferences = licensePreferences
    }

    // MARK: Derived summary

    var downloadedCount: Int { components.filter { $0.state == .downloaded }.count }
    var totalCount: Int { components.count }
    var totalOnDiskBytes: Int64 { components.reduce(0) { $0 + $1.onDiskBytes } }
    var allDownloaded: Bool { !components.isEmpty && downloadedCount == totalCount }
    var selectedQuantizationTier: GenerationRecipe.QuantizationTier {
        modelQuality.tier
    }
    var selectedDescriptor: ModelDescriptor {
        ModelCatalog(root: weightsRoot).descriptor(for: selectedQuantizationTier)
    }
    var selectedModelReady: Bool { isReady(selectedDescriptor) }
    var defaultModelReady: Bool { isReady(ModelCatalog.defaultModelDescriptor) }
    var canModifyModels: Bool {
        coordinator.canChangeModels && !isSwitchingRoot && !isLinkedReadOnly
    }
    var canSelectQuality: Bool {
        coordinator.canChangeModels && !isSwitchingRoot
    }
    var canChooseFolder: Bool {
        coordinator.canChangeModels
            && !coordinator.isChangingModels
            && downloadingIDs.isEmpty
            && !isSwitchingRoot
    }
    var chooseFolderUnavailableReason: String? {
        if isSwitchingRoot { return "Wait for the current model-folder switch to finish." }
        if !downloadingIDs.isEmpty { return "Wait for all model downloads to finish before changing the model folder." }
        if coordinator.isChangingModels { return "Wait for the current model-file operation to finish." }
        if !coordinator.canChangeModels { return "Wait for the active render or app shutdown to finish." }
        return nil
    }
    var selectQualityUnavailableReason: String? {
        if isSwitchingRoot { return "Wait for the current model-folder switch to finish." }
        if !coordinator.canChangeModels { return "Wait for the active render or app shutdown to finish." }
        return nil
    }
    var modifyModelsUnavailableReason: String? {
        if isLinkedReadOnly { return "Linked weights are read-only; switch to Official downloads to change app-managed files." }
        if isSwitchingRoot { return "Wait for the current model-folder switch to finish." }
        if !coordinator.canChangeModels { return "Wait for the active render or app shutdown to finish." }
        return nil
    }
    var weightsRootDisplayPath: String {
        (weightsRoot.path as NSString).abbreviatingWithTildeInPath
    }
    var componentSummary: String {
        let bytes = ByteFormat.string(totalOnDiskBytes)
        return isLinkedReadOnly
            ? "\(downloadedCount) of \(totalCount) verified · \(bytes) external read-only"
            : "\(downloadedCount) of \(totalCount) installed · \(bytes) app-managed"
    }
    var hasAcceptedKreaLicense: Bool {
        licensePreferences.isAccepted
    }

    func reviewKreaLicense() {
        pendingLicensedAction = nil
        showsKreaLicenseReview = true
    }

    func cancelKreaLicenseReview() {
        pendingLicensedAction = nil
        showsKreaLicenseReview = false
    }

    func acceptKreaLicenseAndContinue() {
        licensePreferences.acceptCurrentTerms()
        let action = pendingLicensedAction
        pendingLicensedAction = nil
        showsKreaLicenseReview = false
        switch action {
        case .download(let id): download(id: id)
        case .importWeights: chooseImportFolder()
        case .linkWeights: chooseLinkedFolder()
        case nil: break
        }
    }

    func requestDownload(id: String) {
        guard requireKreaLicense(for: .download(id)) else { return }
        download(id: id)
    }

    func requestImportFolder() {
        guard requireKreaLicense(for: .importWeights) else { return }
        chooseImportFolder()
    }

    func requestLinkedFolder() {
        guard requireKreaLicense(for: .linkWeights) else { return }
        chooseLinkedFolder()
    }

    private func requireKreaLicense(for action: LicensedAction? = nil) -> Bool {
        guard hasAcceptedKreaLicense else {
            pendingLicensedAction = action
            showsKreaLicenseReview = true
            errorMessage = "Review and accept the Krea 2 Community License before accessing model weights."
            return false
        }
        return true
    }

    func component(id: String?) -> ComponentStatus? {
        guard let id else { return nil }
        return components.first { $0.id == id }
    }

    func isReady(_ descriptor: ModelDescriptor) -> Bool {
        !descriptor.componentIDs.isEmpty && descriptor.componentIDs.allSatisfy { id in
            components.first(where: { $0.id == id })?.state == .downloaded
        }
    }

    func selectQuality(_ descriptor: ModelDescriptor) {
        guard descriptor.isRenderable else { return }
        guard coordinator.canChangeModels else {
            errorMessage = "Model quality can't change while Krea 2 is working."
            return
        }
        guard isReady(descriptor) else {
            errorMessage = "Download the required \(descriptor.displayName) weights before selecting it."
            return
        }
        modelQuality.select(descriptor.quantizationTier)
        errorMessage = nil
        revision += 1
    }

    // MARK: Refresh

    func refresh() {
        refreshTask?.cancel()
        refreshRequestID += 1
        let requestID = refreshRequestID
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.store.snapshot()
            guard !Task.isCancelled, requestID == self.refreshRequestID else { return }
            self.components = snapshot.components
            self.weightsRoot = snapshot.root
            self.isLinkedReadOnly = snapshot.isReadOnly
            self.isRefreshing = false
            self.revision += 1
        }
    }

    // MARK: Model folder

    func chooseLinkedFolder() {
        guard requireKreaLicense(for: .linkWeights) else { return }
        guard canChooseFolder else {
            errorMessage = "The model folder can't change while Krea 2 or a download is working."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Link Existing Krea 2 Weights"
        panel.message = "Choose a complete Twisterminigen-compatible Krea 2 Turbo folder. It will be verified and used read-only."
        panel.prompt = "Link Read-Only"
        panel.directoryURL = weightsRoot
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        linkFolder(to: selected)
    }

    func chooseImportFolder() {
        guard requireKreaLicense(for: .importWeights) else { return }
        guard canChooseFolder else {
            errorMessage = "Weights can't be imported while Krea 2 or a download is working."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Existing Krea 2 Weights"
        panel.message = "Choose a complete compatible folder. Twisterminigen will verify every pinned file, then copy it into app-managed storage."
        panel.prompt = "Import Copy"
        panel.directoryURL = weightsRoot
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        importFolder(from: selected)
    }

    func revealFolder() {
        guard FileManager.default.fileExists(atPath: weightsRoot.path) else {
            errorMessage = "The model folder no longer exists: \(weightsRootDisplayPath)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([weightsRoot])
    }

    func revealComponent(id: String) {
        let catalog = ModelCatalog(root: weightsRoot)
        guard let component = catalog.component(id: id) else {
            errorMessage = "The selected model component is no longer in the active catalog."
            return
        }
        let existingFile = component.files.first {
            FileManager.default.fileExists(atPath: $0.localURL.path)
        }
        let target = existingFile?.localURL ?? weightsRoot
        guard FileManager.default.fileExists(atPath: target.path) else {
            errorMessage = "The linked model source no longer exists: \(weightsRootDisplayPath)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func dismissError() {
        errorMessage = nil
    }

    func linkFolder(to root: URL) {
        guard requireKreaLicense() else { return }
        let root = root.standardizedFileURL
        guard root != weightsRoot || !isLinkedReadOnly else { return }
        guard canChooseFolder,
              let lease = coordinator.beginModelMutation(key: "model-directory")
        else {
            errorMessage = "The model folder can't change while Krea 2 or a download is working."
            return
        }

        refreshTask?.cancel()
        refreshRequestID += 1
        isRefreshing = false
        isSwitchingRoot = true
        errorMessage = nil
        Task {
            defer {
                coordinator.finishModelMutation(lease)
                isSwitchingRoot = false
            }
            do {
                let catalog = try await Task.detached(priority: .userInitiated) {
                    let accessed = root.startAccessingSecurityScopedResource()
                    defer { if accessed { root.stopAccessingSecurityScopedResource() } }
                    return try ModelWeightsTransfer.validateLinkedRoot(root)
                }.value
                _ = try await store.switchCatalog(to: catalog, readOnly: true)
                await conditioningCache?.invalidateAll()
                AppPaths.setWeightsRoot(catalog.root, source: .linked)
                let snapshot = await store.snapshot()
                components = snapshot.components
                weightsRoot = snapshot.root
                isLinkedReadOnly = snapshot.isReadOnly
                revision += 1
            } catch {
                errorMessage = Self.modelFolderFailureMessage(
                    action: "link",
                    selected: root,
                    current: weightsRoot,
                    error: error)
            }
        }
    }

    func importFolder(from source: URL) {
        guard requireKreaLicense() else { return }
        guard canChooseFolder,
              let lease = coordinator.beginModelMutation(key: "model-import") else {
            errorMessage = "Weights can't be imported while Krea 2 or a download is working."
            return
        }
        refreshTask?.cancel()
        refreshRequestID += 1
        isRefreshing = false
        isSwitchingRoot = true
        errorMessage = nil
        let source = source.standardizedFileURL
        let destination = AppPaths.importedModels.appendingPathComponent(
            "krea-2-turbo-\(UUID().uuidString.lowercased())",
            isDirectory: true)

        Task {
            defer {
                coordinator.finishModelMutation(lease)
                isSwitchingRoot = false
            }
            do {
                let catalog = try await Task.detached(priority: .userInitiated) {
                    let accessed = source.startAccessingSecurityScopedResource()
                    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                    return try ModelWeightsTransfer.importRoot(source, to: destination)
                }.value
                _ = try await store.switchCatalog(to: catalog, readOnly: false)
                await conditioningCache?.invalidateAll()
                AppPaths.setWeightsRoot(catalog.root, source: .managed)
                let snapshot = await store.snapshot()
                components = snapshot.components
                weightsRoot = snapshot.root
                isLinkedReadOnly = snapshot.isReadOnly
                revision += 1
            } catch {
                errorMessage = Self.modelFolderFailureMessage(
                    action: "import",
                    selected: source,
                    current: weightsRoot,
                    error: error)
            }
        }
    }

    static func modelFolderFailureMessage(
        action: String,
        selected: URL,
        current: URL,
        error: any Error
    ) -> String {
        let selectedPath = (selected.standardizedFileURL.path as NSString)
            .abbreviatingWithTildeInPath
        let currentPath = (current.standardizedFileURL.path as NSString)
            .abbreviatingWithTildeInPath
        return "Couldn't \(action) the selected folder \(selectedPath). \(error.localizedDescription) The active model folder was not changed and remains \(currentPath)."
    }

    func useManagedDownloads() {
        guard canChooseFolder else {
            errorMessage = "The model source can't change while Krea 2 or a download is working."
            return
        }
        let root = AppPaths.defaultWeightsRoot.standardizedFileURL
        guard root != weightsRoot || isLinkedReadOnly else { return }
        guard let lease = coordinator.beginModelMutation(key: "model-directory") else { return }
        isSwitchingRoot = true
        Task {
            defer {
                coordinator.finishModelMutation(lease)
                isSwitchingRoot = false
            }
            do {
                _ = try await store.switchRoot(to: root, readOnly: false)
                await conditioningCache?.invalidateAll()
                AppPaths.setWeightsRoot(root, source: .managed)
                let snapshot = await store.snapshot()
                components = snapshot.components
                weightsRoot = snapshot.root
                isLinkedReadOnly = snapshot.isReadOnly
                revision += 1
            } catch {
                errorMessage = "Couldn't switch to managed model storage: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Download

    func download(id: String) {
        guard requireKreaLicense(for: .download(id)) else { return }
        guard !isSwitchingRoot else {
            errorMessage = "Model files can't change while the model folder is switching."
            return
        }
        guard !downloadingIDs.contains(id) else { return }
        guard components.contains(where: { $0.id == id }) else { return }

        guard let mutationLease = coordinator.beginModelMutation(key: id) else {
            errorMessage = "Model files can't change while Krea 2 is working."
            return
        }
        modelMutationLeases[id] = mutationLease

        errorMessage = nil
        downloadingIDs.insert(id)
        progress[id] = 0
        progressLabel[id] = "Starting…"
        let progressToken = UUID()
        let sequencer = DownloadProgressSequencer()
        progressTokens[id] = progressToken
        progressSequences[id] = 0

        downloadTasks[id] = Task {
            do {
                try await store.download(id: id) { fraction, label in
                    let sequence = sequencer.next()
                    Task { @MainActor in
                        guard self.downloadingIDs.contains(id),
                              self.progressTokens[id] == progressToken,
                              sequence > (self.progressSequences[id] ?? 0)
                        else { return }
                        self.progressSequences[id] = sequence
                        self.progress[id] = min(1, max(0, fraction))
                        self.progressLabel[id] = label
                    }
                }
                await self.conditioningCache?.invalidateAll()
                self.endDownload(id: id, error: nil)
            } catch is CancellationError {
                self.endDownload(id: id, error: nil)
            } catch {
                self.endDownload(id: id, error: error)
            }
        }
    }

    func cancelDownload(id: String) {
        downloadTasks[id]?.cancel()
    }

    /// Requests cancellation of resumable downloads before app termination. Folder switches,
    /// deletes, and other short file transactions are deliberately allowed to finish; their
    /// coordinator mutation leases keep termination deferred until the filesystem is consistent.
    func requestStopForTermination() {
        for task in downloadTasks.values {
            task.cancel()
        }
    }

    private func endDownload(id: String, error: Error?) {
        downloadingIDs.remove(id)
        progress[id] = nil
        progressLabel[id] = nil
        downloadTasks[id] = nil
        progressTokens[id] = nil
        progressSequences[id] = nil
        if let lease = modelMutationLeases.removeValue(forKey: id) {
            coordinator.finishModelMutation(lease)
        }
        if let error {
            let message = error.localizedDescription
            errorMessage = "Download failed — \(message)"
            SystemLog.shared.log("Model download failed: \(message)")
        }
        refresh()
    }

    // MARK: Delete (with confirmation)

    func requestDelete(id: String) {
        guard canModifyModels else {
            errorMessage = "Can't remove model files while Krea 2 is working."
            return
        }
        pendingDeleteID = id
    }
    func cancelDelete() { pendingDeleteID = nil }

    func confirmDelete() {
        guard let id = pendingDeleteID else { return }
        pendingDeleteID = nil
        guard !isSwitchingRoot else {
            errorMessage = "Model files can't change while the model folder is switching."
            return
        }
        guard let lease = coordinator.beginModelMutation(key: id) else {
            errorMessage = "Can't remove model files while Krea 2 is working."
            return
        }
        Task {
            let deletedBytes = await store.delete(id: id)
            if deletedBytes > 0 {
                await conditioningCache?.invalidateAll()
                if id == "dit-transformer-q8", modelQuality.tier == .q8 {
                    modelQuality.resetToDefault()
                }
            }
            coordinator.finishModelMutation(lease)
            refresh()
        }
    }

}

private final class DownloadProgressSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}
