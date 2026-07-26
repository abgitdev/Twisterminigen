import Foundation

enum LocalUpscaleWeightState: Sendable, Equatable {
    case licenseRequired
    case missing
    case partial(bytes: Int64)
    case corrupted(String)
    case ready
}

enum LocalUpscaleWeightStoreError: Error, LocalizedError, Equatable, Sendable {
    case busy
    case diskCapacityUnavailable
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy: "The local upscaler weights are already being changed."
        case .diskCapacityUnavailable: "Available disk space could not be checked for the upscaler download."
        case .insufficientDiskSpace(let required, let available):
            "The upscaler download needs \(ByteFormat.string(required)) including safety headroom, but only \(ByteFormat.string(available)) is available."
        case .verificationFailed(let reason): "The downloaded upscaler failed verification: \(reason)"
        }
    }
}

typealias LocalUpscaleDownloadOperation = @Sendable (
    ModelComponent,
    @escaping ModelDownloadProgress
) async throws -> Void

protocol LocalUpscaleWeightManaging: Sendable {
    func state(
        acceptance: LocalUpscaleLicenseAcceptance?
    ) async -> LocalUpscaleWeightState
    func download(
        acceptance: LocalUpscaleLicenseAcceptance,
        onProgress: @escaping ModelDownloadProgress
    ) async throws
    @discardableResult
    func delete() async throws -> Int64
}

/// Separate optional-weight store. It reuses the app's range-resumable transport, while the local
/// upscaler manifest independently gates license acceptance and verifies the exact artifact before
/// an executor can become ready.
actor LocalUpscaleWeightStore: LocalUpscaleWeightManaging {
    static let defaultDiskSafetyMarginBytes: Int64 = 256 * 1_048_576

    let directory: URL
    let manifest: LocalUpscaleWeightManifest

    private let downloader: LocalUpscaleDownloadOperation
    private let capacityLookup: @Sendable (URL) -> Int64?
    private let diskSafetyMarginBytes: Int64
    private var isMutating = false

    init(
        directory: URL,
        manifest: LocalUpscaleWeightManifest = .realESRGANGeneralX4V3,
        downloader: @escaping LocalUpscaleDownloadOperation = { component, progress in
            try await ResumableDownloader.download(component: component, onProgress: progress)
        },
        capacityLookup: @escaping @Sendable (URL) -> Int64? = {
            ModelDiskCapacity.importantUsageCapacity(for: $0)
        },
        diskSafetyMarginBytes: Int64 = LocalUpscaleWeightStore.defaultDiskSafetyMarginBytes
    ) {
        self.directory = directory.standardizedFileURL
        self.manifest = manifest
        self.downloader = downloader
        self.capacityLookup = capacityLookup
        self.diskSafetyMarginBytes = max(0, diskSafetyMarginBytes)
    }

    func state(
        acceptance: LocalUpscaleLicenseAcceptance?
    ) async -> LocalUpscaleWeightState {
        guard let acceptance else { return .licenseRequired }
        do {
            try acceptance.validate(for: manifest)
        } catch {
            return .licenseRequired
        }

        do {
            _ = try LocalUpscaleManifestVerifier.verify(
                manifest,
                in: directory,
                acceptance: acceptance)
            return .ready
        } catch LocalUpscaleManifestError.missingFile {
            let partial = partialByteCount()
            return partial > 0 ? .partial(bytes: partial) : .missing
        } catch LocalUpscaleManifestError.unexpectedByteCount {
            return .corrupted("Unexpected byte count")
        } catch LocalUpscaleManifestError.unexpectedSHA256 {
            return .corrupted("SHA-256 mismatch")
        } catch {
            return .corrupted(error.localizedDescription)
        }
    }

    func verifiedArtifacts(
        acceptance: LocalUpscaleLicenseAcceptance
    ) throws -> [String: URL] {
        try LocalUpscaleManifestVerifier.verify(
            manifest,
            in: directory,
            acceptance: acceptance)
    }

    func download(
        acceptance: LocalUpscaleLicenseAcceptance,
        onProgress: @escaping ModelDownloadProgress
    ) async throws {
        guard !isMutating else { throw LocalUpscaleWeightStoreError.busy }
        isMutating = true
        defer { isMutating = false }

        try LocalUpscaleManifestVerifier.validate(manifest)
        try acceptance.validate(for: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if (try? LocalUpscaleManifestVerifier.verify(
            manifest,
            in: directory,
            acceptance: acceptance)) != nil {
            onProgress(1, "Ready")
            return
        }

        guard let available = capacityLookup(directory) else {
            throw LocalUpscaleWeightStoreError.diskCapacityUnavailable
        }
        let remaining = manifest.artifacts.reduce(Int64(0)) { total, artifact in
            let url = directory.appendingPathComponent(artifact.filename)
            let present = min(artifact.expectedBytes, max(0, FileProbe.size(url) ?? 0))
            return total + artifact.expectedBytes - present
        }
        let required = remaining + diskSafetyMarginBytes
        guard available >= required else {
            throw LocalUpscaleWeightStoreError.insufficientDiskSpace(
                requiredBytes: required,
                availableBytes: available)
        }

        try await downloader(downloadComponent(), onProgress)
        do {
            _ = try LocalUpscaleManifestVerifier.verify(
                manifest,
                in: directory,
                acceptance: acceptance)
        } catch {
            throw LocalUpscaleWeightStoreError.verificationFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func delete() async throws -> Int64 {
        guard !isMutating else { throw LocalUpscaleWeightStoreError.busy }
        isMutating = true
        defer { isMutating = false }

        var removedBytes: Int64 = 0
        for file in downloadComponent().files {
            for url in [
                file.localURL,
                file.partURL,
                file.metadataURL,
                file.verificationURL,
            ] {
                let bytes = FileProbe.size(url) ?? 0
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    removedBytes += bytes
                }
            }
        }
        return removedBytes
    }

    private func downloadComponent() -> ModelComponent {
        ModelComponent(
            id: "experimental-upscaler-x4",
            title: manifest.model.displayName,
            subtitle: "Experimental local AI super-resolution · \(manifest.license.identifier)",
            icon: "arrow.up.left.and.arrow.down.right",
            repo: manifest.repositoryID,
            revision: manifest.revision,
            files: manifest.artifacts.map { artifact in
                ModelFile(
                    remotePath: artifact.remotePath,
                    localURL: directory.appendingPathComponent(artifact.filename),
                    isMain: artifact.filename == "model.safetensors",
                    expectedBytes: artifact.expectedBytes,
                    sha256: artifact.expectedSHA256)
            })
    }

    private func partialByteCount() -> Int64 {
        downloadComponent().files.reduce(Int64(0)) { total, file in
            total + max(0, FileProbe.size(file.localURL) ?? FileProbe.size(file.partURL) ?? 0)
        }
    }
}
