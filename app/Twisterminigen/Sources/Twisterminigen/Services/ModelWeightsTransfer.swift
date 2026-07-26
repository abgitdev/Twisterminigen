import Foundation

enum ModelFileMismatch: Error, Equatable, Sendable {
    case fileType
    case size(expected: Int64, actual: Int64)
    case sha256(expected: String, actual: String)
}

enum ModelWeightsTransferError: Error, Equatable, LocalizedError, Sendable {
    case unsafeSource(URL)
    case missingFile(String)
    case incompatibleFile(path: String, mismatch: ModelFileMismatch)
    case destinationExists(URL)
    case capacityUnavailable(URL)
    case insufficientSpace(required: Int64, available: Int64)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsafeSource(let url):
            return "The selected model folder is not a readable regular directory: \(url.path)"
        case .missingFile(let path):
            return "The selected folder is missing the required model file \(path)."
        case .incompatibleFile(let path, let mismatch):
            switch mismatch {
            case .fileType:
                return "\(path) is not a regular non-symlink file. The pinned Krea 2 Turbo build requires an ordinary model file at this path."
            case .size(let expected, let actual):
                return "\(path) contains \(actual) bytes; the pinned Krea 2 Turbo build requires \(expected) bytes."
            case .sha256(let expected, let actual):
                return "\(path) has SHA-256 \(Self.shortHash(actual)); the pinned Krea 2 Turbo build requires \(Self.shortHash(expected))."
            }
        case .destinationExists(let url):
            return "The managed import destination already exists: \(url.path)"
        case .capacityUnavailable(let url):
            return "Available disk space could not be determined for \(url.path)."
        case let .insufficientSpace(required, available):
            return "The managed import needs \(ByteFormat.string(required)) free; \(ByteFormat.string(available)) is available."
        case .copyFailed(let path):
            return "The model import could not copy \(path)."
        }
    }

    private static func shortHash(_ value: String) -> String {
        value.count > 12 ? "\(value.prefix(12))…" : value
    }
}

/// Validates an existing Krea checkpoint without writing beside it, or copies a complete verified
/// checkpoint into a new app-owned root. Both operations require every byte of the pinned Default
/// tier. Optional q8 can then be downloaded independently; a similarly named model is never used.
enum ModelWeightsTransfer {
    static func validateLinkedRoot(_ root: URL) throws -> ModelCatalog {
        let root = root.standardizedFileURL
        try validateDirectory(root)
        let catalog = ModelCatalog(root: root)
        for file in catalog.defaultFiles {
            try validate(file: file, displayPath: relativePath(of: file.localURL, root: root))
        }
        return catalog
    }

    static func importRoot(
        _ sourceRoot: URL,
        to destinationRoot: URL,
        capacityLookup: (URL) -> Int64? = { ModelDiskCapacity.importantUsageCapacity(for: $0) },
        diskSafetyMarginBytes: Int64 = ModelStore.defaultDiskSafetyMarginBytes
    ) throws -> ModelCatalog {
        let sourceRoot = sourceRoot.standardizedFileURL
        let destinationRoot = destinationRoot.standardizedFileURL
        try validateDirectory(sourceRoot)
        guard !FileManager.default.fileExists(atPath: destinationRoot.path) else {
            throw ModelWeightsTransferError.destinationExists(destinationRoot)
        }

        let destinationCatalog = ModelCatalog(root: destinationRoot)
        let payloadBytes = destinationCatalog.defaultFiles.reduce(Int64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.expectedBytes)
            return overflow ? Int64.max : sum
        }
        let (requiredBytes, overflow) = payloadBytes.addingReportingOverflow(
            max(0, diskSafetyMarginBytes))
        let required = overflow ? Int64.max : requiredBytes
        guard let available = capacityLookup(destinationRoot) else {
            throw ModelWeightsTransferError.capacityUnavailable(destinationRoot)
        }
        guard available >= required else {
            throw ModelWeightsTransferError.insufficientSpace(
                required: required,
                available: available)
        }
        let stagingRoot = destinationRoot
            .deletingLastPathComponent()
            .appendingPathComponent(".model-import-\(UUID().uuidString.lowercased())", isDirectory: true)
        let stagingCatalog = ModelCatalog(root: stagingRoot)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        do {
            try FileManager.default.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: true)
            for (stagingFile, finalFile) in zip(
                stagingCatalog.defaultFiles,
                destinationCatalog.defaultFiles)
            {
                let relative = relativePath(of: finalFile.localURL, root: destinationRoot)
                let source = try resolvedSource(
                    for: finalFile,
                    sourceRoot: sourceRoot,
                    relativeDestinationPath: relative)
                try validate(fileAt: source, against: finalFile, displayPath: relative)
                try FileManager.default.createDirectory(
                    at: stagingFile.localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                do {
                    try FileManager.default.copyItem(at: source, to: stagingFile.localURL)
                } catch {
                    throw ModelWeightsTransferError.copyFailed(relative)
                }
                try validate(file: stagingFile, displayPath: relative)
            }
            try FileManager.default.moveItem(at: stagingRoot, to: destinationRoot)
        } catch {
            throw error
        }
        return destinationCatalog
    }

    private static func validateDirectory(_ root: URL) throws {
        let values = try? root.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .isReadableKey,
        ])
        guard values?.isDirectory == true,
              values?.isSymbolicLink != true,
              values?.isReadable != false else {
            throw ModelWeightsTransferError.unsafeSource(root)
        }
    }

    private static func resolvedSource(
        for destinationFile: ModelFile,
        sourceRoot: URL,
        relativeDestinationPath: String
    ) throws -> URL {
        let candidates = [
            sourceRoot.appendingPathComponent(relativeDestinationPath),
            sourceRoot.appendingPathComponent(destinationFile.remotePath),
            sourceRoot.appendingPathComponent(destinationFile.localURL.lastPathComponent),
        ]
        for candidate in candidates {
            if (try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
                .map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true {
                return candidate
            }
        }
        throw ModelWeightsTransferError.missingFile(relativeDestinationPath)
    }

    private static func validate(file: ModelFile, displayPath: String) throws {
        try validate(fileAt: file.localURL, against: file, displayPath: displayPath)
    }

    static func validate(
        fileAt url: URL,
        against manifestFile: ModelFile,
        displayPath: String
    ) throws {
        // URL resource values may be cached on a URL instance after an external file changes.
        // Reconstruct the file URL so a retry always inspects current on-disk metadata.
        let currentURL = URL(fileURLWithPath: url.path, isDirectory: false)
        let values = try? currentURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true else {
            throw ModelWeightsTransferError.incompatibleFile(
                path: displayPath,
                mismatch: .fileType)
        }
        let actualBytes = Int64(values?.fileSize ?? -1)
        guard actualBytes == manifestFile.expectedBytes else {
            throw ModelWeightsTransferError.incompatibleFile(
                path: displayPath,
                mismatch: .size(expected: manifestFile.expectedBytes, actual: actualBytes))
        }
        let sha = try ModelVerifier.sha256Hex(of: currentURL)
        guard sha.caseInsensitiveCompare(manifestFile.sha256) == .orderedSame else {
            throw ModelWeightsTransferError.incompatibleFile(
                path: displayPath,
                mismatch: .sha256(expected: manifestFile.sha256, actual: sha))
        }
    }

    private static func relativePath(of child: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let childPath = child.standardizedFileURL.path
        return childPath.hasPrefix(rootPath)
            ? String(childPath.dropFirst(rootPath.count))
            : child.lastPathComponent
    }
}
