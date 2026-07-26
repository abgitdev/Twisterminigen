import Foundation
import Observation

enum LoRAViewModelError: Error, Equatable, Sendable {
    case libraryUnavailable
    case missingAsset(UUID)
    case recipeHashMismatch(UUID)
}

extension LoRAViewModelError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .libraryUnavailable: return "The LoRA library is unavailable."
        case .missingAsset: return "This recipe references a LoRA that is not in the local library."
        case .recipeHashMismatch: return "This recipe references a different revision of a local LoRA."
        }
    }
}

@MainActor
@Observable
final class LoRAViewModel {
    private(set) var assets: [LoRAAsset] = []
    private(set) var active: [LoRASelection] = []
    private(set) var pendingRemovalIDs: Set<UUID> = []
    var isWorking = false
    var errorMessage: String?
    var operationMessage: String?

    private let store: LoRAStore?
    private let coordinator: InferenceCoordinator?
    private let licensePreferences: KreaLicensePreferences?
    private var stackPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var triggerInsertionHandler: (@MainActor (UUID, [String]) -> Void)?

    init(
        store: LoRAStore?,
        coordinator: InferenceCoordinator? = nil,
        licensePreferences: KreaLicensePreferences? = nil,
        startupWarning: String? = nil
    ) {
        self.store = store
        self.coordinator = coordinator
        self.licensePreferences = licensePreferences
        self.errorMessage = startupWarning
    }

    var isAvailable: Bool { store != nil }
    var hasAcceptedKreaLicense: Bool { licensePreferences?.isAccepted == true }
    var canMutateFiles: Bool { coordinator?.canChangeModels ?? true }
    var fileMutationUnavailableReason: String? {
        if !isAvailable { return "The local LoRA library is unavailable." }
        if isWorking { return "Wait for the current LoRA operation to finish." }
        if !canMutateFiles { return "Wait for the active render or app shutdown to finish before changing LoRA files." }
        return nil
    }
    var removalWillWaitForInference: Bool {
        coordinator?.isBusy == true && coordinator?.isTerminationRequested == false
    }

    func isRemovalPending(_ id: UUID) -> Bool {
        pendingRemovalIDs.contains(id)
    }

    func removalRequestUnavailableReason(for id: UUID) -> String? {
        if !isAvailable { return "The local LoRA library is unavailable." }
        if pendingRemovalIDs.contains(id) {
            return "Removal is already scheduled for the end of the active render or Queue run."
        }
        if isWorking { return "Wait for the current LoRA operation to finish." }
        if coordinator?.isTerminationRequested == true {
            return "Twisterminigen is preparing to quit, so a new file change cannot be scheduled."
        }
        return nil
    }
    var activeReferences: [GenerationRecipe.LoRAReference] {
        active.compactMap { selection in
            assets.first(where: { $0.id == selection.assetID }).map { asset in
                GenerationRecipe.LoRAReference(
                    managedID: asset.id,
                    sha256: asset.sha256,
                    scale: selection.scale)
            }
        }
    }

    func hasOfficialStyle(_ style: OfficialKreaStyleLoRA) -> Bool {
        assets.contains {
            $0.sha256.caseInsensitiveCompare(style.sha256) == .orderedSame
                && $0.origin.kind == .officialKreaStyle
        }
    }

    func refresh() async {
        guard let store else { return }
        apply(await store.snapshot())
    }

    func reloadAfterStorageManagerChange() async {
        guard let store else { return }
        do {
            apply(try await store.reloadAfterExternalStorageChange())
        } catch {
            assets = []
            active = []
            errorMessage = "LoRA storage reload failed: \(error.localizedDescription)"
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard let store, !urls.isEmpty else {
            if store == nil { errorMessage = LoRAViewModelError.libraryUnavailable.localizedDescription }
            return
        }
        let lease: InferenceCoordinator.ModelMutationLease?
        if let coordinator {
            guard let acquired = coordinator.beginModelMutation(key: "lora-import") else {
                errorMessage = "Wait for the current render or model operation to finish."
                return
            }
            lease = acquired
        } else {
            lease = nil
        }
        isWorking = true
        errorMessage = nil
        defer {
            if let lease { coordinator?.finishModelMutation(lease) }
            isWorking = false
        }
        do {
            for url in urls {
                apply(try await store.importAdapter(from: url))
            }
        } catch {
            errorMessage = "LoRA import failed: \(error.localizedDescription)"
        }
    }

    func importOfficialStyle(_ style: OfficialKreaStyleLoRA) async {
        guard hasAcceptedKreaLicense else {
            errorMessage = "Review and accept the Krea 2 Community License in Models before downloading an official style."
            return
        }
        guard let store else {
            errorMessage = LoRAViewModelError.libraryUnavailable.localizedDescription
            return
        }
        guard !hasOfficialStyle(style) else { return }
        let lease: InferenceCoordinator.ModelMutationLease?
        if let coordinator {
            guard let acquired = coordinator.beginModelMutation(key: "lora-official-import") else {
                errorMessage = "Wait for the current render or model operation to finish."
                return
            }
            lease = acquired
        } else {
            lease = nil
        }
        isWorking = true
        errorMessage = nil
        defer {
            if let lease { coordinator?.finishModelMutation(lease) }
            isWorking = false
        }
        do {
            let downloaded = try await OfficialKreaStyleLoRADownload.download(style)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            apply(try await store.importAdapter(
                from: downloaded,
                displayName: "Krea · \(style.title)",
                triggers: [style.trigger],
                origin: style.origin,
                expectedSHA256: style.sha256))
        } catch {
            errorMessage = "Official Krea style import failed: \(error.localizedDescription)"
        }
    }

    func remove(_ id: UUID) async {
        guard let store else {
            errorMessage = LoRAViewModelError.libraryUnavailable.localizedDescription
            return
        }
        guard let asset = assets.first(where: { $0.id == id }) else {
            errorMessage = "This LoRA adapter is no longer in the local library."
            return
        }
        if let unavailableReason = removalRequestUnavailableReason(for: id) {
            errorMessage = unavailableReason
            return
        }
        pendingRemovalIDs.insert(id)
        defer { pendingRemovalIDs.remove(id) }
        errorMessage = nil

        if removalWillWaitForInference {
            operationMessage = "\(asset.name) will be removed automatically after the active render or Queue run finishes."
        } else {
            operationMessage = nil
        }

        if let coordinator,
           !(await coordinator.waitUntilModelChangesAreAllowed()) {
            operationMessage = nil
            errorMessage = "Removal was cancelled because Twisterminigen is preparing to quit."
            return
        }

        let lease: InferenceCoordinator.ModelMutationLease?
        if let coordinator {
            guard let acquired = coordinator.beginModelMutation(key: "lora-remove-\(id)") else {
                operationMessage = nil
                errorMessage = "Wait for the current render or model operation to finish."
                return
            }
            lease = acquired
        } else {
            lease = nil
        }
        isWorking = true
        defer {
            if let lease { coordinator?.finishModelMutation(lease) }
            isWorking = false
        }
        do {
            apply(try await store.remove(id: id))
            operationMessage = "Removed \(asset.name) from the local LoRA library."
        } catch {
            operationMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func setActive(_ id: UUID, enabled: Bool) async {
        let wasActive = isActive(id)
        let optedAsset = assets.first(where: { $0.id == id })
        let succeeded = await mutate { store in try await store.setActive(id: id, enabled: enabled) }
        if succeeded,
           enabled,
           !wasActive,
           let optedAsset,
           optedAsset.automaticallyInsertTriggers,
           !optedAsset.triggers.isEmpty {
            triggerInsertionHandler?(id, optedAsset.triggers)
        }
    }

    /// The app wires this to Generate after both view models exist. Keeping the callback local and
    /// MainActor-isolated avoids notifications, globals, or a second source of prompt state.
    func configureTriggerInsertionHandler(
        _ handler: @escaping @MainActor (UUID, [String]) -> Void
    ) {
        triggerInsertionHandler = handler
    }

    func setScaleLocally(_ id: UUID, scale: Double) {
        guard let index = active.firstIndex(where: { $0.assetID == id }) else { return }
        active[index].scale = min(
            GenerationRecipe.maximumLoRAScale,
            max(0.01, scale))
    }

    func persistScale(_ id: UUID) async {
        guard let scale = active.first(where: { $0.assetID == id })?.scale else { return }
        await mutate { store in try await store.setScale(id: id, scale: scale) }
    }

    func move(_ id: UUID, offset: Int) async {
        await mutate { store in try await store.moveActive(id: id, offset: offset) }
    }

    /// Returns true only after the validated metadata transaction commits. The editor keeps its
    /// draft open on failure so an invalid phrase is never discarded behind an error banner.
    @discardableResult
    func updateTriggers(_ id: UUID, text: String) async -> Bool {
        let triggers = text
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return await mutate { store in
            try await store.updateTriggers(id: id, triggers: triggers)
        }
    }

    @discardableResult
    func setAutomaticallyInsertTriggers(_ id: UUID, enabled: Bool) async -> Bool {
        await mutate { store in
            try await store.setAutomaticallyInsertTriggers(id: id, enabled: enabled)
        }
    }

    func isActive(_ id: UUID) -> Bool {
        active.contains { $0.assetID == id }
    }

    func scale(for id: UUID) -> Double {
        active.first(where: { $0.assetID == id })?.scale ?? 1
    }

    func activeIndex(_ id: UUID) -> Int? {
        active.firstIndex { $0.assetID == id }
    }

    func validateReferences(_ references: [GenerationRecipe.LoRAReference]) throws {
        for reference in references {
            guard let asset = assets.first(where: { $0.id == reference.managedID }) else {
                throw LoRAViewModelError.missingAsset(reference.managedID)
            }
            guard asset.sha256.caseInsensitiveCompare(reference.sha256) == .orderedSame else {
                throw LoRAViewModelError.recipeHashMismatch(reference.managedID)
            }
        }
    }

    func applyReferences(_ references: [GenerationRecipe.LoRAReference]) throws {
        try validateReferences(references)
        active = references.map { .init(assetID: $0.managedID, scale: $0.scale) }
        guard let store else {
            if !references.isEmpty { throw LoRAViewModelError.libraryUnavailable }
            return
        }
        let previous = stackPersistenceTask
        stackPersistenceTask = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let snapshot = try await store.replaceActive(with: references)
                if self?.activeReferences == references {
                    self?.apply(snapshot)
                }
            } catch {
                self?.errorMessage = "Couldn't save the LoRA stack: \(error.localizedDescription)"
            }
        }
    }

    #if DEBUG
    /// Deterministic durability boundary for tests that apply several recipes back-to-back.
    /// Production callers remain non-blocking while the serialized persistence task completes.
    func waitForPendingStackPersistenceForTesting() async {
        await stackPersistenceTask?.value
    }
    #endif

    func resolve(
        _ references: [GenerationRecipe.LoRAReference]
    ) async throws -> [LoRAStore.ResolvedAdapter] {
        guard let store else {
            if references.isEmpty { return [] }
            throw LoRAViewModelError.libraryUnavailable
        }
        return try await store.resolve(references)
    }

    func estimatedResidentBytes(
        for references: [GenerationRecipe.LoRAReference]
    ) throws -> Int64 {
        try validateReferences(references)
        return references.reduce(0) { total, reference in
            guard let asset = assets.first(where: { $0.id == reference.managedID }) else { return total }
            let expandedTensorBytes = asset.tensorBytes > Int64.max / 3
                ? Int64.max
                : asset.tensorBytes * 3
            let estimate = max(asset.byteCount, expandedTensorBytes)
            let (sum, overflow) = total.addingReportingOverflow(estimate)
            return overflow ? Int64.max : sum
        }
    }

    @discardableResult
    private func mutate(
        _ operation: (LoRAStore) async throws -> LoRALibrarySnapshot
    ) async -> Bool {
        guard let store else {
            errorMessage = LoRAViewModelError.libraryUnavailable.localizedDescription
            return false
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            apply(try await operation(store))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func apply(_ snapshot: LoRALibrarySnapshot) {
        assets = snapshot.assets
        active = snapshot.active
    }
}
