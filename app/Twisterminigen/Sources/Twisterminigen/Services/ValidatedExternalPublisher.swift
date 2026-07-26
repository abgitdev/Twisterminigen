import Darwin
import CryptoKit
import Foundation

enum ExternalPublishError: Error, Equatable, LocalizedError, Sendable {
    case wrongExtension(expected: String)
    case invalidDestination(URL)
    case managedDestination(URL)
    case destinationExists(URL)
    case duplicateDestination(URL)
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .wrongExtension(let expected):
            "Choose a .\(expected) destination."
        case .invalidDestination(let url):
            "The selected destination is not a safe writable file location: \(url.path)."
        case .managedDestination:
            "Choose a destination outside Twisterminigen's private app, cache, model, and Gallery storage."
        case .destinationExists(let url):
            "A file already exists at \(url.lastPathComponent); nothing was replaced."
        case .duplicateDestination(let url):
            "More than one output resolves to \(url.path)."
        case .writeFailed(let code):
            "The file could not be published safely (POSIX \(code))."
        }
    }
}

struct ReviewedPNGPublication: Sendable, Hashable {
    let output: ReviewablePNG
    let destination: URL
}

enum ExternalPublicationOutcome: Sendable, Equatable {
    case publishedDurable(URL)
    case publishedDurabilityWarning(URL, code: Int32)
    case failedBeforeVisibility(URL, error: ExternalPublishError)
    case stateUnknown(URL, error: ExternalPublishError)

    var destination: URL {
        switch self {
        case .publishedDurable(let url),
             .publishedDurabilityWarning(let url, _),
             .failedBeforeVisibility(let url, _),
             .stateUnknown(let url, _):
            url
        }
    }

    /// Non-nil only when this process confirmed that its complete file became visible. An unknown
    /// state deliberately remains distinct from a confirmed absence.
    var confirmedVisibleURL: URL? {
        switch self {
        case .publishedDurable(let url), .publishedDurabilityWarning(let url, _): url
        case .failedBeforeVisibility, .stateUnknown: nil
        }
    }

    var isConfirmedVisible: Bool { confirmedVisibleURL != nil }
    var isDurable: Bool {
        guard case .publishedDurable = self else { return false }
        return true
    }

    var durabilityWarningCode: Int32? {
        guard case .publishedDurabilityWarning(_, let code) = self else { return nil }
        return code
    }

    var failure: ExternalPublishError? {
        switch self {
        case .failedBeforeVisibility(_, let error), .stateUnknown(_, let error): error
        case .publishedDurable, .publishedDurabilityWarning: nil
        }
    }

    func requireVisibleURL() throws -> URL {
        switch self {
        case .publishedDurable(let url), .publishedDurabilityWarning(let url, _):
            return url
        case .failedBeforeVisibility(_, let error):
            throw error
        case .stateUnknown(let url, let error):
            throw ExternalPublicationStateError.stateUnknown(url, underlying: error)
        }
    }
}

enum ExternalPublicationStateError: Error, Equatable, LocalizedError, Sendable {
    case stateUnknown(URL, underlying: ExternalPublishError)

    var errorDescription: String? {
        switch self {
        case .stateUnknown(let url, let error):
            "Publication state is unknown for \(url.lastPathComponent). Inspect the destination before retrying. \(error.localizedDescription)"
        }
    }
}

struct ReviewedPNGPublishResult: Sendable, Equatable {
    struct Failure: Sendable, Equatable {
        let destination: URL
        let error: ExternalPublishError
        let stateUnknown: Bool
    }

    let outcomes: [ExternalPublicationOutcome]
    let unattempted: [URL]

    var published: [URL] { outcomes.compactMap(\.confirmedVisibleURL) }
    var durabilityWarnings: [ExternalPublicationOutcome] {
        outcomes.filter { $0.durabilityWarningCode != nil }
    }
    var failure: Failure? {
        guard let outcome = outcomes.first(where: { $0.failure != nil }),
              let error = outcome.failure else { return nil }
        if case .stateUnknown = outcome {
            return Failure(destination: outcome.destination, error: error, stateUnknown: true)
        }
        return Failure(destination: outcome.destination, error: error, stateUnknown: false)
    }

    var isComplete: Bool { failure == nil && unattempted.isEmpty }
}

/// The only boundary that publishes user-selected files outside private app storage. PNG paths
/// require a single-use, digest-bound review receipt; non-image documents use explicit document
/// entry points. All paths share the same symlink resolution and collision-safe filesystem code.
enum ValidatedExternalPublisher {
    enum PublicationFault: Sendable, Equatable {
        case exclusiveRenameUnsupported
        case directorySyncFailure(Int32)
        /// Replaces the staged pathname while leaving the original descriptor open. This models
        /// the exact pathname/descriptor race that production must detect after `RENAME_EXCL`.
        case replaceStagingBeforeRename(Data)
        /// Rebinds the destination's parent pathname while its original directory FD stays open.
        case rebindParentBeforeRename
    }

    enum DocumentKind: Sendable {
        case portableRecipe
        case queueRecipeMetadata

        var pathExtension: String {
            switch self {
            case .portableRecipe: "twisterrecipe"
            case .queueRecipeMetadata: "json"
            }
        }
    }

    static func preflightPNGDestination(
        _ destination: URL,
        protectedRoots: [URL] = []
    ) throws {
        _ = try validateWithSecurityScope(
            destination,
            expectedExtension: "png",
            protectedRoots: protectedRoots)
    }

    static func preflightDocumentDestination(
        _ destination: URL,
        kind: DocumentKind,
        protectedRoots: [URL] = []
    ) throws {
        _ = try validateWithSecurityScope(
            destination,
            expectedExtension: kind.pathExtension,
            protectedRoots: protectedRoots)
    }

    @MainActor
    static func publishReviewedPNG(
        _ output: ReviewablePNG,
        to destination: URL,
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind,
        protectedRoots: [URL] = []
    ) async throws -> ExternalPublicationOutcome {
        let publications = [ReviewedPNGPublication(output: output, destination: destination)]
        let result = try await publishReviewedPNGs(
            publications,
            receipt: receipt,
            kind: kind,
            protectedRoots: protectedRoots)
        guard let outcome = result.outcomes.first else {
            throw ExternalPublishError.invalidDestination(destination)
        }
        return outcome
    }

    @MainActor
    static func publishReviewedPNGs(
        _ publications: [ReviewedPNGPublication],
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind,
        protectedRoots: [URL] = []
    ) async throws -> ReviewedPNGPublishResult {
        try await publishReviewedPNGs(
            publications,
            receipt: receipt,
            kind: kind,
            protectedRoots: protectedRoots,
            beforeEachPublication: nil,
            faultForPublication: nil)
    }

    #if DEBUG
    @MainActor
    static func publishReviewedPNGForTesting(
        _ output: ReviewablePNG,
        to destination: URL,
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind,
        protectedRoots: [URL] = [],
        fault: PublicationFault
    ) async throws -> ExternalPublicationOutcome {
        let result = try await publishReviewedPNGs(
            [.init(output: output, destination: destination)],
            receipt: receipt,
            kind: kind,
            protectedRoots: protectedRoots,
            beforeEachPublication: nil,
            faultForPublication: { _, _ in fault })
        guard let outcome = result.outcomes.first else {
            throw ExternalPublishError.invalidDestination(destination)
        }
        return outcome
    }

    /// Deterministic race/failure seam for publication-result tests. Production has no hook.
    @MainActor
    static func publishReviewedPNGsForTesting(
        _ publications: [ReviewedPNGPublication],
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind,
        protectedRoots: [URL] = [],
        beforeEachPublication: @escaping @Sendable (Int, URL) throws -> Void,
        faultForPublication: @escaping @Sendable (Int, URL) -> PublicationFault? = { _, _ in nil }
    ) async throws -> ReviewedPNGPublishResult {
        try await publishReviewedPNGs(
            publications,
            receipt: receipt,
            kind: kind,
            protectedRoots: protectedRoots,
            beforeEachPublication: beforeEachPublication,
            faultForPublication: faultForPublication)
    }
    #endif

    @MainActor
    private static func publishReviewedPNGs(
        _ publications: [ReviewedPNGPublication],
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind,
        protectedRoots: [URL],
        beforeEachPublication: (@Sendable (Int, URL) throws -> Void)?,
        faultForPublication: (@Sendable (Int, URL) -> PublicationFault?)?
    ) async throws -> ReviewedPNGPublishResult {
        guard !publications.isEmpty else {
            OutputReviewGate.revoke(receipt)
            throw ExternalPublishError.invalidDestination(URL(fileURLWithPath: ""))
        }
        var resolvedDestinations = Set<String>()
        do {
            for publication in publications {
                let validated = try validateWithSecurityScope(
                    publication.destination,
                    expectedExtension: "png",
                    protectedRoots: protectedRoots)
                guard resolvedDestinations.insert(validated.resolved.path.lowercased()).inserted else {
                    throw ExternalPublishError.duplicateDestination(publication.destination)
                }
            }
        } catch {
            OutputReviewGate.revoke(receipt)
            throw error
        }

        try OutputReviewGate.consume(
            receipt,
            outputs: publications.map(\.output),
            kind: kind)

        return await Task.detached(priority: .userInitiated) {
            var outcomes: [ExternalPublicationOutcome] = []
            outcomes.reserveCapacity(publications.count)
            for (index, publication) in publications.enumerated() {
                do {
                    try beforeEachPublication?(index, publication.destination)
                    let outcome = publishBytes(
                        publication.output.data,
                        to: publication.destination,
                        expectedExtension: "png",
                        protectedRoots: protectedRoots,
                        fault: faultForPublication?(index, publication.destination))
                    outcomes.append(outcome)
                    if outcome.failure != nil {
                        return ReviewedPNGPublishResult(
                            outcomes: outcomes,
                            unattempted: publications.dropFirst(index + 1)
                                .map { $0.destination.standardizedFileURL })
                    }
                } catch let error as ExternalPublishError {
                    let destination = publication.destination.standardizedFileURL
                    outcomes.append(.failedBeforeVisibility(destination, error: error))
                    return ReviewedPNGPublishResult(
                        outcomes: outcomes,
                        unattempted: publications.dropFirst(index + 1)
                            .map { $0.destination.standardizedFileURL })
                } catch {
                    let destination = publication.destination.standardizedFileURL
                    outcomes.append(.failedBeforeVisibility(
                        destination,
                        error: .writeFailed(EIO)))
                    return ReviewedPNGPublishResult(
                        outcomes: outcomes,
                        unattempted: publications.dropFirst(index + 1)
                            .map { $0.destination.standardizedFileURL })
                }
            }
            return ReviewedPNGPublishResult(outcomes: outcomes, unattempted: [])
        }.value
    }

    static func publishDocument(
        _ data: Data,
        to destination: URL,
        kind: DocumentKind,
        protectedRoots: [URL] = []
    ) -> ExternalPublicationOutcome {
        publishBytes(
            data,
            to: destination,
            expectedExtension: kind.pathExtension,
            protectedRoots: protectedRoots,
            fault: nil)
    }

    #if DEBUG
    static func publishDocumentForTesting(
        _ data: Data,
        to destination: URL,
        kind: DocumentKind,
        protectedRoots: [URL] = [],
        fault: PublicationFault
    ) -> ExternalPublicationOutcome {
        publishBytes(
            data,
            to: destination,
            expectedExtension: kind.pathExtension,
            protectedRoots: protectedRoots,
            fault: fault)
    }
    #endif

    private struct ValidatedDestination: Sendable {
        let standardized: URL
        let resolved: URL
        let parentDevice: UInt64
        let parentInode: UInt64
    }

    private static func publishBytes(
        _ data: Data,
        to destination: URL,
        expectedExtension: String,
        protectedRoots: [URL],
        fault: PublicationFault?
    ) -> ExternalPublicationOutcome {
        let accessed = destination.startAccessingSecurityScopedResource()
        defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
        do {
            let validated = try validate(
                destination,
                expectedExtension: expectedExtension,
                protectedRoots: protectedRoots)
            return try collisionSafePublish(
                data,
                to: validated.standardized,
                expectedParentIdentity: (validated.parentDevice, validated.parentInode),
                fault: fault)
        } catch let error as ExternalPublishError {
            return .failedBeforeVisibility(destination.standardizedFileURL, error: error)
        } catch {
            return .failedBeforeVisibility(
                destination.standardizedFileURL,
                error: .writeFailed(EIO))
        }
    }

    private static func validateWithSecurityScope(
        _ destination: URL,
        expectedExtension: String,
        protectedRoots: [URL]
    ) throws -> ValidatedDestination {
        let accessed = destination.startAccessingSecurityScopedResource()
        defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
        return try validate(
            destination,
            expectedExtension: expectedExtension,
            protectedRoots: protectedRoots)
    }

    private static func validate(
        _ destination: URL,
        expectedExtension: String,
        protectedRoots: [URL]
    ) throws -> ValidatedDestination {
        let standardized = destination.standardizedFileURL
        guard standardized.pathExtension.lowercased() == expectedExtension.lowercased() else {
            throw ExternalPublishError.wrongExtension(expected: expectedExtension)
        }
        let parent = standardized.deletingLastPathComponent()
        let values: URLResourceValues
        do {
            values = try parent.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isWritableKey,
            ])
        } catch {
            throw ExternalPublishError.invalidDestination(destination)
        }
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isWritable != false else {
            throw ExternalPublishError.invalidDestination(destination)
        }

        let resolvedParent = parent.resolvingSymlinksInPath()
        let resolved = resolvedParent.appendingPathComponent(
            standardized.lastPathComponent,
            isDirectory: false)
        let roots = [AppPaths.appSupport, AppPaths.caches, AppPaths.weightsRoot] + protectedRoots
        guard !roots.contains(where: { root in
            let standardizedRoot = root.standardizedFileURL
            return isWithin(standardized, parent: standardizedRoot)
                || isWithin(resolved, parent: standardizedRoot.resolvingSymlinksInPath())
        }) else {
            throw ExternalPublishError.managedDestination(destination)
        }

        var status = stat()
        let lstatStatus = standardized.path.withCString { Darwin.lstat($0, &status) }
        let lstatError = errno
        if lstatStatus == 0 { throw ExternalPublishError.destinationExists(destination) }
        guard lstatError == ENOENT else {
            throw ExternalPublishError.invalidDestination(destination)
        }
        var parentStatus = stat()
        guard resolvedParent.path.withCString({ Darwin.lstat($0, &parentStatus) }) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw ExternalPublishError.invalidDestination(destination)
        }
        return ValidatedDestination(
            standardized: standardized,
            resolved: resolved,
            parentDevice: deviceValue(parentStatus),
            parentInode: UInt64(parentStatus.st_ino))
    }

    /// Writes and fsyncs a private sibling, then makes the destination visible in one exclusive
    /// rename. There is deliberately no direct-write fallback: a filesystem without RENAME_EXCL
    /// fails before the destination exists. Once rename succeeds, this function never unlinks or
    /// rolls back the destination pathname; a later directory-fsync failure is a visible-file
    /// durability warning. Failed private staging files are scrubbed to zero bytes through their
    /// still-open descriptor and left as hidden tombstones, avoiding every pathname-delete race.
    private static func collisionSafePublish(
        _ data: Data,
        to destination: URL,
        expectedParentIdentity: (device: UInt64, inode: UInt64),
        fault: PublicationFault?
    ) throws -> ExternalPublicationOutcome {
        let directory = destination.deletingLastPathComponent()
        let directoryDescriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else { throw ExternalPublishError.writeFailed(errno) }
        defer { Darwin.close(directoryDescriptor) }

        var openedDirectoryStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &openedDirectoryStatus) == 0,
              deviceValue(openedDirectoryStatus) == expectedParentIdentity.device,
              UInt64(openedDirectoryStatus.st_ino) == expectedParentIdentity.inode else {
            throw ExternalPublishError.invalidDestination(destination)
        }

        let temporaryName = ".twister-private-stage-\(UUID().uuidString).tmp"
        let destinationName = destination.lastPathComponent
        let temporaryDescriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600)
        }
        guard temporaryDescriptor >= 0 else {
            throw ExternalPublishError.writeFailed(errno)
        }

        func failBeforeVisibility(_ error: ExternalPublishError) -> ExternalPublicationOutcome {
            let scrubbed = scrubFailedStagingFile(descriptor: temporaryDescriptor)
            _ = Darwin.close(temporaryDescriptor)
            return scrubbed
                ? .failedBeforeVisibility(destination, error: error)
                : .stateUnknown(destination, error: error)
        }

        do {
            try write(data, descriptor: temporaryDescriptor)
        } catch let error as ExternalPublishError {
            return failBeforeVisibility(error)
        } catch {
            return failBeforeVisibility(.writeFailed(EIO))
        }
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            return failBeforeVisibility(.writeFailed(errno))
        }

        // The directory pathname may be renamed or rebound after validation. Refuse to make this
        // process's file visible unless the pathname still resolves to the exact open directory.
        guard parentPathStillIdentifies(
            directory,
            descriptor: directoryDescriptor,
            expected: openedDirectoryStatus) else {
            return failBeforeVisibility(.invalidDestination(destination))
        }

        #if DEBUG
        do {
            switch fault {
            case .replaceStagingBeforeRename(let replacement):
                try replaceStagingPathForTesting(
                    temporaryName: temporaryName,
                    replacement: replacement,
                    directoryDescriptor: directoryDescriptor)
            case .rebindParentBeforeRename:
                try rebindParentPathForTesting(directory)
            case .exclusiveRenameUnsupported, .directorySyncFailure, nil:
                break
            }
        } catch let error as ExternalPublishError {
            return failBeforeVisibility(error)
        } catch {
            return failBeforeVisibility(.writeFailed(EIO))
        }
        #endif

        let renameResult: Int32
        let renameError: Int32
        if fault == .exclusiveRenameUnsupported {
            renameResult = -1
            renameError = ENOTSUP
        } else {
            renameResult = temporaryName.withCString { source in
                destinationName.withCString { target in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        source,
                        directoryDescriptor,
                        target,
                        UInt32(RENAME_EXCL))
                }
            }
            renameError = errno
        }
        guard renameResult == 0 else {
            let error: ExternalPublishError = renameError == EEXIST
                ? .destinationExists(destination)
                : .writeFailed(renameError)
            return failBeforeVisibility(error)
        }


        // `renameatx_np` accepts a pathname, not the descriptor whose bytes were reviewed. Bind
        // success back to that still-open descriptor and to the exact bytes before reporting a
        // visible result. A mismatch is never rolled back through the mutable destination name.
        let destinationDescriptor = destinationName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard destinationDescriptor >= 0 else {
            let code = errno
            _ = Darwin.close(temporaryDescriptor)
            return .stateUnknown(destination, error: .writeFailed(code))
        }
        defer { Darwin.close(destinationDescriptor) }

        var stagedStatus = stat()
        var destinationStatus = stat()
        guard Darwin.fstat(temporaryDescriptor, &stagedStatus) == 0,
              Darwin.fstat(destinationDescriptor, &destinationStatus) == 0 else {
            let code = errno
            _ = Darwin.close(temporaryDescriptor)
            return .stateUnknown(destination, error: .writeFailed(code))
        }
        guard sameFileIdentity(stagedStatus, destinationStatus),
              (destinationStatus.st_mode & S_IFMT) == S_IFREG else {
            // The reviewed staging inode is not the inode moved to the destination. Scrubbing the
            // still-open staging descriptor is safe here because it cannot affect the destination.
            _ = scrubFailedStagingFile(descriptor: temporaryDescriptor)
            _ = Darwin.close(temporaryDescriptor)
            return .stateUnknown(destination, error: .writeFailed(ESTALE))
        }
        guard exactBytesAndSHA256Match(
            data,
            descriptor: destinationDescriptor,
            expectedStatus: destinationStatus) else {
            _ = Darwin.close(temporaryDescriptor)
            return .stateUnknown(destination, error: .writeFailed(EBADMSG))
        }
        guard parentPathStillIdentifies(
            directory,
            descriptor: directoryDescriptor,
            expected: openedDirectoryStatus) else {
            _ = Darwin.close(temporaryDescriptor)
            return .stateUnknown(destination, error: .invalidDestination(destination))
        }

        let closeResult = Darwin.close(temporaryDescriptor)
        let closeError = errno
        let directorySyncResult: Int32
        let directorySyncError: Int32
        if case .directorySyncFailure(let code) = fault {
            directorySyncResult = -1
            directorySyncError = code
        } else {
            directorySyncResult = Darwin.fsync(directoryDescriptor)
            directorySyncError = errno
        }
        if closeResult != 0 {
            return .publishedDurabilityWarning(destination, code: closeError)
        }
        if directorySyncResult != 0 {
            return .publishedDurabilityWarning(destination, code: directorySyncError)
        }
        return .publishedDurable(destination)
    }

    private static func scrubFailedStagingFile(descriptor: Int32) -> Bool {
        guard Darwin.ftruncate(descriptor, 0) == 0 else { return false }
        return Darwin.fsync(descriptor) == 0
    }

    private static func parentPathStillIdentifies(
        _ directory: URL,
        descriptor: Int32,
        expected: stat
    ) -> Bool {
        let reopened = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard reopened >= 0 else { return false }
        defer { Darwin.close(reopened) }
        var openStatus = stat()
        var reopenedStatus = stat()
        guard Darwin.fstat(descriptor, &openStatus) == 0,
              Darwin.fstat(reopened, &reopenedStatus) == 0 else { return false }
        return sameFileIdentity(openStatus, expected)
            && sameFileIdentity(reopenedStatus, expected)
            && (reopenedStatus.st_mode & S_IFMT) == S_IFDIR
    }

    private static func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        deviceValue(lhs) == deviceValue(rhs) && UInt64(lhs.st_ino) == UInt64(rhs.st_ino)
    }

    /// Performs one complete descriptor read, comparing every byte and a streaming SHA-256 to the
    /// reviewed payload. Status is sampled again after the read to reject concurrent mutation.
    private static func exactBytesAndSHA256Match(
        _ expected: Data,
        descriptor: Int32,
        expectedStatus: stat
    ) -> Bool {
        guard expectedStatus.st_size == off_t(expected.count) else { return false }
        let expectedDigest = Data(SHA256.hash(data: expected))
        var actualHasher = SHA256()
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < expected.count {
            let requested = min(buffer.count, expected.count - offset)
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                while true {
                    let result = Darwin.pread(
                        descriptor,
                        bytes.baseAddress,
                        requested,
                        off_t(offset))
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard count == requested else { return false }
            let bytesEqual = expected.withUnsafeBytes { expectedBytes in
                buffer.withUnsafeBytes { actualBytes in
                    Darwin.memcmp(
                        expectedBytes.baseAddress!.advanced(by: offset),
                        actualBytes.baseAddress!,
                        count) == 0
                }
            }
            guard bytesEqual else { return false }
            actualHasher.update(data: Data(buffer[0 ..< count]))
            offset += count
        }
        var trailingByte: UInt8 = 0
        let trailingCount = Darwin.pread(descriptor, &trailingByte, 1, off_t(offset))
        guard trailingCount == 0,
              Data(actualHasher.finalize()) == expectedDigest else { return false }
        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0 else { return false }
        return sameFileIdentity(finalStatus, expectedStatus)
            && finalStatus.st_size == expectedStatus.st_size
            && finalStatus.st_mtimespec.tv_sec == expectedStatus.st_mtimespec.tv_sec
            && finalStatus.st_mtimespec.tv_nsec == expectedStatus.st_mtimespec.tv_nsec
            && finalStatus.st_ctimespec.tv_sec == expectedStatus.st_ctimespec.tv_sec
            && finalStatus.st_ctimespec.tv_nsec == expectedStatus.st_ctimespec.tv_nsec
    }

    #if DEBUG
    private static func replaceStagingPathForTesting(
        temporaryName: String,
        replacement: Data,
        directoryDescriptor: Int32
    ) throws {
        let displacedName = ".twister-test-displaced-\(UUID().uuidString).tmp"
        let moveResult = temporaryName.withCString { source in
            displacedName.withCString { target in
                Darwin.renameat(directoryDescriptor, source, directoryDescriptor, target)
            }
        }
        guard moveResult == 0 else { throw ExternalPublishError.writeFailed(errno) }
        let replacementDescriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600)
        }
        guard replacementDescriptor >= 0 else {
            throw ExternalPublishError.writeFailed(errno)
        }
        defer { Darwin.close(replacementDescriptor) }
        try write(replacement, descriptor: replacementDescriptor)
        guard Darwin.fsync(replacementDescriptor) == 0 else {
            throw ExternalPublishError.writeFailed(errno)
        }
    }

    private static func rebindParentPathForTesting(_ directory: URL) throws {
        let displaced = directory.deletingLastPathComponent().appendingPathComponent(
            ".twister-test-displaced-parent-\(UUID().uuidString)",
            isDirectory: true)
        let moveResult = directory.path.withCString { source in
            displaced.path.withCString { target in Darwin.rename(source, target) }
        }
        guard moveResult == 0 else { throw ExternalPublishError.writeFailed(errno) }
        let createResult = directory.path.withCString { Darwin.mkdir($0, 0o700) }
        guard createResult == 0 else { throw ExternalPublishError.writeFailed(errno) }
    }
    #endif

    private static func write(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ExternalPublishError.writeFailed(count < 0 ? errno : EIO)
                }
                offset += count
            }
        }
    }

    private static func isWithin(_ child: URL, parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path.lowercased()
        let parentPath = parent.standardizedFileURL.path.lowercased()
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private static func deviceValue(_ status: stat) -> UInt64 {
        UInt64(bitPattern: Int64(status.st_dev))
    }
}
