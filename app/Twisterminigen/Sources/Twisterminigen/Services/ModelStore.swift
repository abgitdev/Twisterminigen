import Foundation

/// Download state of one component.
enum ComponentState: String, Sendable, Hashable {
    case downloaded
    case partial
    case corrupted
    case missing
}

/// Immutable snapshot of a component's on-disk status, handed to the UI.
struct ComponentStatus: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let expectedBytes: Int64
    let onDiskBytes: Int64
    let state: ComponentState
}

struct ModelStoreSnapshot: Sendable, Hashable {
    let root: URL
    let components: [ComponentStatus]
    let isReadOnly: Bool
}

enum ModelStoreError: LocalizedError {
    case unknownComponent(String)
    case componentBusy(String)
    case catalogBusy
    case diskCapacityUnavailable(URL)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case verificationFailed(String)
    case readOnlyCatalog

    var errorDescription: String? {
        switch self {
        case .unknownComponent(let id):
            "Unknown model component: \(id)."
        case .componentBusy(let id):
            "Model component \(id) is already being changed."
        case .catalogBusy:
            "The model folder can't change while model files are being changed."
        case .diskCapacityUnavailable(let root):
            "Couldn't determine available disk space for \(root.path). The download wasn't started."
        case .insufficientDiskSpace(let required, let available):
            "Not enough free disk space: need \(ByteFormat.string(required)) including safety headroom, but only \(ByteFormat.string(available)) is available."
        case .verificationFailed(let id):
            "Model component \(id) failed its manifest verification."
        case .readOnlyCatalog:
            "Linked model folders are read-only. Import the weights or switch to managed storage first."
        }
    }
}

typealias ModelDownloadProgress = @Sendable (Double, String) -> Void
typealias ModelDownloadOperation = @Sendable (
    ModelComponent,
    @escaping ModelDownloadProgress
) async throws -> Void
typealias ModelDiskCapacityLookup = @Sendable (URL) -> Int64?

enum ModelDiskCapacity {
    static func nearestExistingParent(
        of destination: URL,
        fileExists: (URL) -> Bool
    ) -> URL? {
        var candidate = destination.standardizedFileURL
        while true {
            if fileExists(candidate) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    static func capacity(
        for destination: URL,
        fileExists: (URL) -> Bool,
        importantUsageCapacity: (URL) -> Int64?
    ) -> Int64? {
        guard let existing = nearestExistingParent(
            of: destination,
            fileExists: fileExists)
        else { return nil }
        return importantUsageCapacity(existing)
    }

    static func importantUsageCapacity(for destination: URL) -> Int64? {
        capacity(
            for: destination,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            importantUsageCapacity: { existing in
                guard let values = try? existing.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
                      let available = values.volumeAvailableCapacityForImportantUsage
                else { return nil }
                return available
            })
    }
}

/// Owns one immutable catalog snapshot and serializes mutations per component.
actor ModelStore {
    static let defaultDiskSafetyMarginBytes: Int64 = 2 * 1_073_741_824

    private var catalog: ModelCatalog
    private var verifier: ModelVerifier
    private var isReadOnly: Bool
    private let linkedStampDirectory: URL
    private let downloader: ModelDownloadOperation
    private let capacityLookup: ModelDiskCapacityLookup
    private let diskSafetyMarginBytes: Int64
    private var mutationLeases: [String: UUID] = [:]
    private var activeDownloadIDs: Set<String> = []

    init(
        catalog: ModelCatalog = ModelCatalog(root: AppPaths.weightsRoot),
        readOnly: Bool = false,
        downloader: @escaping ModelDownloadOperation = { component, onProgress in
            try await ResumableDownloader.download(
                component: component,
                onProgress: onProgress)
        },
        capacityLookup: @escaping ModelDiskCapacityLookup = {
            ModelDiskCapacity.importantUsageCapacity(for: $0)
        },
        diskSafetyMarginBytes: Int64 = ModelStore.defaultDiskSafetyMarginBytes,
        linkedStampDirectory: URL = AppPaths.linkedModelVerification
    ) {
        self.catalog = catalog
        self.isReadOnly = readOnly
        self.linkedStampDirectory = linkedStampDirectory
        self.verifier = ModelVerifier(
            manifest: catalog.manifest,
            stampDirectory: readOnly ? linkedStampDirectory : nil)
        self.downloader = downloader
        self.capacityLookup = capacityLookup
        self.diskSafetyMarginBytes = max(0, diskSafetyMarginBytes)
    }

    func snapshot() -> ModelStoreSnapshot {
        ModelStoreSnapshot(
            root: catalog.root,
            components: components(),
            isReadOnly: isReadOnly)
    }

    func catalogSnapshot() -> ModelCatalog {
        catalog
    }

    @discardableResult
    func switchRoot(to root: URL, readOnly: Bool = false) throws -> ModelCatalog {
        try switchCatalog(to: ModelCatalog(root: root), readOnly: readOnly)
    }

    @discardableResult
    func switchCatalog(
        to replacement: ModelCatalog,
        readOnly: Bool = false
    ) throws -> ModelCatalog {
        guard mutationLeases.isEmpty else {
            throw ModelStoreError.catalogBusy
        }
        catalog = replacement
        isReadOnly = readOnly
        verifier = ModelVerifier(
            manifest: replacement.manifest,
            stampDirectory: readOnly ? linkedStampDirectory : nil)
        return replacement
    }

    func components() -> [ComponentStatus] {
        catalog.components.map(status(for:))
    }

    func status(id: String) -> ComponentStatus? {
        catalog.component(id: id).map(status(for:))
    }

    func download(
        id: String,
        onProgress: @escaping ModelDownloadProgress
    ) async throws {
        guard !isReadOnly else { throw ModelStoreError.readOnlyCatalog }
        guard let component = catalog.component(id: id) else {
            throw ModelStoreError.unknownComponent(id)
        }
        guard let lease = acquireLease(for: id) else {
            throw ModelStoreError.componentBusy(id)
        }
        defer {
            activeDownloadIDs.remove(id)
            releaseLease(lease)
        }

        let corruptedFiles = try preflightDownload(component)
        activeDownloadIDs.insert(id)
        removeCorruptedFinals(corruptedFiles)
        try await downloader(component, onProgress)

        guard component.files.allSatisfy({ verifier.verify($0) == .verified }) else {
            throw ModelStoreError.verificationFailed(id)
        }
    }

    /// Deletes final, part, transfer metadata, and verification stamps. Busy components are gated.
    @discardableResult
    func delete(id: String) -> Int64 {
        guard !isReadOnly else { return 0 }
        guard let component = catalog.component(id: id),
              let lease = acquireLease(for: id) else { return 0 }
        defer { releaseLease(lease) }

        let fileManager = FileManager.default
        var freed: Int64 = 0
        for file in component.files {
            let artifacts = [
                file.localURL,
                file.partURL,
                file.metadataURL,
                file.partURL.appendingPathExtension("meta"),
                file.verificationURL,
            ]
            for url in artifacts {
                if let size = FileProbe.size(url),
                   (try? fileManager.removeItem(at: url)) != nil {
                    freed += size
                }
            }
        }
        return freed
    }

    // MARK: Status resolution

    private func status(for component: ModelComponent) -> ComponentStatus {
        let verification = component.files.map { verifier.verify($0) }
        let onDisk = component.files.reduce(Int64(0)) { total, file in
            total + (FileProbe.size(file.localURL) ?? FileProbe.size(file.partURL) ?? 0)
        }

        let state: ComponentState
        if verification.allSatisfy({ $0 == .verified }) {
            state = .downloaded
        } else if verification.contains(.corrupted) {
            state = .corrupted
        } else if component.files.contains(where: hasPayload(for:)) {
            state = .partial
        } else {
            state = .missing
        }

        return ComponentStatus(
            id: component.id,
            title: component.title,
            subtitle: component.subtitle,
            icon: component.icon,
            expectedBytes: component.expectedBytes,
            onDiskBytes: onDisk,
            state: state)
    }

    private func hasPayload(for file: ModelFile) -> Bool {
        FileProbe.exists(file.localURL) || FileProbe.exists(file.partURL)
    }

    private func removeCorruptedFinals(_ corruptedFiles: [ModelFile]) {
        let fileManager = FileManager.default
        for file in corruptedFiles {
            try? fileManager.removeItem(at: file.localURL)
            try? fileManager.removeItem(at: file.metadataURL)
            try? fileManager.removeItem(at: file.verificationURL)
        }
    }

    // MARK: Disk preflight

    private struct DownloadFootprint {
        let remainingBytes: Int64
        let reclaimableBytes: Int64
        let corruptedFiles: [ModelFile]
    }

    private func preflightDownload(_ requested: ModelComponent) throws -> [ModelFile] {
        guard let available = capacityLookup(catalog.root) else {
            throw ModelStoreError.diskCapacityUnavailable(catalog.root)
        }

        let requestedFootprint = downloadFootprint(for: requested)
        let activeRemaining = activeDownloadIDs.compactMap { catalog.component(id: $0) }
            .reduce(Int64(0)) { total, component in
                total + activeDownloadRemainingBytes(for: component)
            }
        let remaining = requestedFootprint.remainingBytes + activeRemaining
        let netDownloadBytes = max(0, remaining - requestedFootprint.reclaimableBytes)
        let required = netDownloadBytes + diskSafetyMarginBytes

        guard available >= required else {
            throw ModelStoreError.insufficientDiskSpace(
                requiredBytes: required,
                availableBytes: available)
        }
        return requestedFootprint.corruptedFiles
    }

    private func downloadFootprint(for component: ModelComponent) -> DownloadFootprint {
        component.files.reduce(DownloadFootprint(
            remainingBytes: 0,
            reclaimableBytes: 0,
            corruptedFiles: [])) {
            total, file in
            let verification = verifier.verify(file)
            guard verification != .verified else { return total }

            let partialBytes = min(file.expectedBytes, max(0, FileProbe.size(file.partURL) ?? 0))
            let remaining = max(0, file.expectedBytes - partialBytes)
            let reclaimable = verification == .corrupted
                ? max(0, FileProbe.size(file.localURL) ?? 0)
                : 0
            return DownloadFootprint(
                remainingBytes: total.remainingBytes + remaining,
                reclaimableBytes: total.reclaimableBytes + reclaimable,
                corruptedFiles: verification == .corrupted
                    ? total.corruptedFiles + [file]
                    : total.corruptedFiles)
        }
    }

    private func activeDownloadRemainingBytes(for component: ModelComponent) -> Int64 {
        component.files.reduce(Int64(0)) { total, file in
            if let finalBytes = FileProbe.size(file.localURL), finalBytes >= file.expectedBytes {
                return total
            }
            let partialBytes = min(file.expectedBytes, max(0, FileProbe.size(file.partURL) ?? 0))
            return total + max(0, file.expectedBytes - partialBytes)
        }
    }

    // MARK: Reentrancy leases

    private struct MutationLease: Sendable {
        let componentID: String
        let token: UUID
    }

    private func acquireLease(for componentID: String) -> MutationLease? {
        guard mutationLeases[componentID] == nil else { return nil }
        let lease = MutationLease(componentID: componentID, token: UUID())
        mutationLeases[componentID] = lease.token
        return lease
    }

    private func releaseLease(_ lease: MutationLease) {
        guard mutationLeases[lease.componentID] == lease.token else { return }
        mutationLeases[lease.componentID] = nil
    }
}
