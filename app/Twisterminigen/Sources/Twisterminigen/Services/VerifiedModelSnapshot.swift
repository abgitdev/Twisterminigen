import Darwin
import Foundation
import Krea2Pipeline

struct VerifiedModelSnapshotInput: Sendable, Hashable {
    let sourceURL: URL
    let relativePath: String
    let expectedBytes: Int64
    let expectedSHA256: String

    init(
        sourceURL: URL,
        relativePath: String,
        expectedBytes: Int64,
        expectedSHA256: String
    ) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.relativePath = relativePath
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256.lowercased()
    }

    init(_ file: ModelFile) {
        self.init(
            sourceURL: file.localURL,
            relativePath: file.remotePath,
            expectedBytes: file.expectedBytes,
            expectedSHA256: file.sha256)
    }
}

enum VerifiedModelSnapshotError: Error, LocalizedError, Sendable, Equatable {
    case noInputs
    case unsafeRelativePath(String)
    case duplicateRelativePath(String)
    case invalidExpectedFile(String)
    case sourceUnavailable(String)
    case sourceNotRegular(String)
    case unexpectedByteCount(path: String, expected: Int64, actual: Int64)
    case unexpectedSHA256(path: String, expected: String, actual: String)
    case snapshotChanged(String)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .noInputs:
            "The verified model snapshot has no inputs."
        case .unsafeRelativePath(let path):
            "The verified model snapshot path is unsafe: \(path)"
        case .duplicateRelativePath(let path):
            "The verified model snapshot repeats a path: \(path)"
        case .invalidExpectedFile(let path):
            "The verified model snapshot has an invalid manifest entry: \(path)"
        case .sourceUnavailable(let path):
            "The model file is unavailable: \(path)"
        case .sourceNotRegular(let path):
            "The model file is not a non-symlink regular file: \(path)"
        case let .unexpectedByteCount(path, expected, actual):
            "The model file \(path) has \(actual) bytes; expected \(expected)."
        case let .unexpectedSHA256(path, expected, actual):
            "The staged model file \(path) failed SHA-256 (expected \(expected), got \(actual))."
        case .snapshotChanged(let path):
            "The staged model file changed while it was being verified: \(path)"
        case let .posix(operation, code):
            "Verified model staging failed during \(operation) (POSIX \(code))."
        }
    }
}

/// Private, stage-bound copies of exact manifest files. APFS clones are created from an already
/// opened `O_NOFOLLOW` source descriptor. Cross-volume/non-cloneable sources use a streaming copy
/// from that same descriptor. Only the staged descriptor is hashed, and loaders receive only the
/// staged URL. The directory remains alive until the resident engine stage releases its lease.
final class VerifiedModelSnapshot: @unchecked Sendable {
    typealias SourceOpenedHook = @Sendable (VerifiedModelSnapshotInput) throws -> Void

    let root: URL
    let fileReplacements: [URL: URL]
    private let cleanupDescriptors: [Int32]
    private let cleanupParentDescriptor: Int32
    private let cleanupRootDescriptor: Int32
    private let cleanupRootName: String

    private init(
        root: URL,
        fileReplacements: [URL: URL],
        cleanupDescriptors: [Int32],
        cleanupParentDescriptor: Int32,
        cleanupRootDescriptor: Int32,
        cleanupRootName: String
    ) {
        self.root = root
        self.fileReplacements = fileReplacements
        self.cleanupDescriptors = cleanupDescriptors
        self.cleanupParentDescriptor = cleanupParentDescriptor
        self.cleanupRootDescriptor = cleanupRootDescriptor
        self.cleanupRootName = cleanupRootName
    }

    deinit {
        // Reclaim cloned/copied extents through the exact descriptors retained by this lease.
        // Removal is then relative to retained parent/root directory descriptors and proceeds only
        // when the entire private tree contains app-owned zero-byte regular files.
        Self.reclaimAndClose(cleanupDescriptors)
        _ = Self.removeEmptySnapshotTree(
            parentDescriptor: cleanupParentDescriptor,
            rootDescriptor: cleanupRootDescriptor,
            rootName: cleanupRootName)
        Darwin.close(cleanupRootDescriptor)
        Darwin.close(cleanupParentDescriptor)
    }

    static func create(
        inputs: [VerifiedModelSnapshotInput],
        stagingParent: URL? = nil,
        sourceOpenedHook: SourceOpenedHook? = nil
    ) throws -> VerifiedModelSnapshot {
        guard !inputs.isEmpty else { throw VerifiedModelSnapshotError.noInputs }

        var seen = Set<String>()
        for input in inputs {
            try validate(input)
            guard seen.insert(input.relativePath).inserted else {
                throw VerifiedModelSnapshotError.duplicateRelativePath(input.relativePath)
            }
        }

        let parent = (stagingParent ?? FileManager.default.temporaryDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let parentDescriptor = try openDirectory(parent)
        defer { Darwin.close(parentDescriptor) }
        cleanupAbandonedTombstones(parentDescriptor: parentDescriptor)

        let rootName = "twister-verified-model-\(UUID().uuidString.lowercased())"
        let mkdirResult = rootName.withCString { name in
            mkdirat(parentDescriptor, name, S_IRWXU)
        }
        guard mkdirResult == 0 else {
            throw VerifiedModelSnapshotError.posix(operation: "mkdirat", code: errno)
        }

        let root = parent.appendingPathComponent(rootName, isDirectory: true)
        let rootDescriptor = try openDirectory(at: parentDescriptor, name: rootName)
        defer { Darwin.close(rootDescriptor) }

        var replacements: [URL: URL] = [:]
        var cleanupDescriptors: [Int32] = []
        var completed = false
        defer {
            if !completed {
                reclaimAndClose(cleanupDescriptors)
                _ = removeEmptySnapshotTree(
                    parentDescriptor: parentDescriptor,
                    rootDescriptor: rootDescriptor,
                    rootName: rootName)
            }
        }
        replacements.reserveCapacity(inputs.count)
        for input in inputs {
            let components = input.relativePath.split(
                separator: "/", omittingEmptySubsequences: false).map(String.init)
            let filename = components.last!
            let directoryComponents = Array(components.dropLast())
            let destinationParent = try createDirectoryChain(
                rootDescriptor: rootDescriptor,
                components: directoryComponents)
            defer { Darwin.close(destinationParent) }

            let sourceDescriptor = input.sourceURL.withUnsafeFileSystemRepresentation {
                path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard sourceDescriptor >= 0 else {
                if errno == ENOENT {
                    throw VerifiedModelSnapshotError.sourceUnavailable(input.sourceURL.path)
                }
                throw VerifiedModelSnapshotError.sourceNotRegular(input.sourceURL.path)
            }
            defer { Darwin.close(sourceDescriptor) }

            let sourceStatus = try regularFileStatus(
                descriptor: sourceDescriptor,
                path: input.sourceURL.path,
                source: true)
            guard Int64(sourceStatus.st_size) == input.expectedBytes else {
                throw VerifiedModelSnapshotError.unexpectedByteCount(
                    path: input.relativePath,
                    expected: input.expectedBytes,
                    actual: Int64(sourceStatus.st_size))
            }
            try sourceOpenedHook?(input)

            try cloneOrCopy(
                sourceDescriptor: sourceDescriptor,
                destinationDirectory: destinationParent,
                filename: filename)

            var snapshotDescriptor = filename.withCString { name in
                openat(destinationParent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard snapshotDescriptor >= 0 else {
                throw VerifiedModelSnapshotError.posix(operation: "openat(snapshot)", code: errno)
            }
            guard fchmod(snapshotDescriptor, S_IRUSR | S_IWUSR) == 0 else {
                let code = errno
                Darwin.close(snapshotDescriptor)
                throw VerifiedModelSnapshotError.posix(operation: "fchmod(snapshot writable)", code: code)
            }
            Darwin.close(snapshotDescriptor)
            snapshotDescriptor = filename.withCString { name in
                openat(destinationParent, name, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
            guard snapshotDescriptor >= 0 else {
                throw VerifiedModelSnapshotError.posix(
                    operation: "openat(snapshot cleanup lease)", code: errno)
            }
            var descriptorRetained = false
            defer {
                if !descriptorRetained { Darwin.close(snapshotDescriptor) }
            }
            cleanupDescriptors.append(snapshotDescriptor)
            descriptorRetained = true

            let before = try regularFileStatus(
                descriptor: snapshotDescriptor,
                path: input.relativePath,
                source: false)
            guard Int64(before.st_size) == input.expectedBytes else {
                throw VerifiedModelSnapshotError.unexpectedByteCount(
                    path: input.relativePath,
                    expected: input.expectedBytes,
                    actual: Int64(before.st_size))
            }
            let actualSHA = try ModelVerifier.sha256Hex(
                ofFileDescriptor: snapshotDescriptor).lowercased()
            let after = try regularFileStatus(
                descriptor: snapshotDescriptor,
                path: input.relativePath,
                source: false)
            var pathStatus = stat()
            let pathResult = filename.withCString { name in
                fstatat(destinationParent, name, &pathStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard pathResult == 0,
                  sameFile(before, after),
                  sameFile(after, pathStatus) else {
                throw VerifiedModelSnapshotError.snapshotChanged(input.relativePath)
            }
            guard actualSHA == input.expectedSHA256 else {
                throw VerifiedModelSnapshotError.unexpectedSHA256(
                    path: input.relativePath,
                    expected: input.expectedSHA256,
                    actual: actualSHA)
            }
            guard fchmod(snapshotDescriptor, S_IRUSR) == 0 else {
                throw VerifiedModelSnapshotError.posix(operation: "fchmod(snapshot)", code: errno)
            }

            let destination = root.appendingPathComponent(input.relativePath)
            replacements[input.sourceURL] = destination
        }

        let retainedParent = fcntl(parentDescriptor, F_DUPFD_CLOEXEC, 0)
        guard retainedParent >= 0 else {
            throw VerifiedModelSnapshotError.posix(
                operation: "fcntl(snapshot parent cleanup lease)",
                code: errno)
        }
        let retainedRoot = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard retainedRoot >= 0 else {
            let code = errno
            Darwin.close(retainedParent)
            throw VerifiedModelSnapshotError.posix(
                operation: "fcntl(snapshot root cleanup lease)",
                code: code)
        }

        completed = true
        return VerifiedModelSnapshot(
            root: root,
            fileReplacements: replacements,
            cleanupDescriptors: cleanupDescriptors,
            cleanupParentDescriptor: retainedParent,
            cleanupRootDescriptor: retainedRoot,
            cleanupRootName: rootName)
    }

    func replacementFile(for source: URL) throws -> URL {
        let key = source.standardizedFileURL
        guard let replacement = fileReplacements[key] else {
            throw Krea2Pipeline.ModelLoadLeaseError.missingFileReplacement(source.path)
        }
        return replacement
    }

    func engineLease(directoryReplacements: [URL: URL] = [:]) -> Krea2Pipeline.ModelLoadLease {
        Krea2Pipeline.ModelLoadLease(
            fileReplacements: fileReplacements,
            directoryReplacements: directoryReplacements,
            onRelease: { withExtendedLifetime(self) {} })
    }

    private static func validate(_ input: VerifiedModelSnapshotInput) throws {
        let pieces = input.relativePath.split(
            separator: "/", omittingEmptySubsequences: false)
        guard !input.relativePath.isEmpty,
              !input.relativePath.hasPrefix("/"),
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !input.relativePath.utf8.contains(0) else {
            throw VerifiedModelSnapshotError.unsafeRelativePath(input.relativePath)
        }
        let digest = input.expectedSHA256
        guard input.expectedBytes > 0,
              digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }),
              digest == digest.lowercased() else {
            throw VerifiedModelSnapshotError.invalidExpectedFile(input.relativePath)
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw VerifiedModelSnapshotError.posix(operation: "open(directory)", code: errno)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
            let code = errno
            Darwin.close(descriptor)
            throw VerifiedModelSnapshotError.posix(operation: "fstat(directory)", code: code)
        }
        return descriptor
    }

    private static func openDirectory(at parent: Int32, name: String) throws -> Int32 {
        let descriptor = name.withCString { component in
            openat(parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw VerifiedModelSnapshotError.posix(operation: "openat(directory)", code: errno)
        }
        return descriptor
    }

    private static func createDirectoryChain(
        rootDescriptor: Int32,
        components: [String]
    ) throws -> Int32 {
        var current = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else {
            throw VerifiedModelSnapshotError.posix(operation: "fcntl(F_DUPFD_CLOEXEC)", code: errno)
        }
        do {
            for component in components {
                let result = component.withCString { name in
                    mkdirat(current, name, S_IRWXU)
                }
                guard result == 0 || errno == EEXIST else {
                    throw VerifiedModelSnapshotError.posix(operation: "mkdirat(component)", code: errno)
                }
                let next = try openDirectory(at: current, name: component)
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func cloneOrCopy(
        sourceDescriptor: Int32,
        destinationDirectory: Int32,
        filename: String
    ) throws {
        let cloned = filename.withCString { name in
            fclonefileat(sourceDescriptor, destinationDirectory, name, 0)
        }
        if cloned == 0 { return }

        let cloneError = errno
        guard cloneError == EXDEV || cloneError == ENOTSUP || cloneError == ENOSYS
                || cloneError == EINVAL else {
            throw VerifiedModelSnapshotError.posix(operation: "fclonefileat", code: cloneError)
        }

        let destinationDescriptor = filename.withCString { name in
            openat(
                destinationDirectory,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
        }
        guard destinationDescriptor >= 0 else {
            throw VerifiedModelSnapshotError.posix(operation: "openat(copy)", code: errno)
        }
        defer { Darwin.close(destinationDescriptor) }

        guard lseek(sourceDescriptor, 0, SEEK_SET) >= 0 else {
            throw VerifiedModelSnapshotError.posix(operation: "lseek(source)", code: errno)
        }
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                while true {
                    let result = Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else {
                throw VerifiedModelSnapshotError.posix(operation: "read(source)", code: errno)
            }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes -> Int in
                    while true {
                        let result = Darwin.write(
                            destinationDescriptor,
                            bytes.baseAddress!.advanced(by: offset),
                            count - offset)
                        if result < 0, errno == EINTR { continue }
                        return result
                    }
                }
                guard written > 0 else {
                    throw VerifiedModelSnapshotError.posix(operation: "write(snapshot)", code: errno)
                }
                offset += written
            }
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw VerifiedModelSnapshotError.posix(operation: "fsync(snapshot)", code: errno)
        }
    }

    private static func regularFileStatus(
        descriptor: Int32,
        path: String,
        source: Bool
    ) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw VerifiedModelSnapshotError.posix(operation: "fstat(file)", code: errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else {
            if source { throw VerifiedModelSnapshotError.sourceNotRegular(path) }
            throw VerifiedModelSnapshotError.snapshotChanged(path)
        }
        return status
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func reclaimAndClose(_ descriptors: [Int32]) {
        for descriptor in descriptors {
            _ = ftruncate(descriptor, 0)
            _ = fsync(descriptor)
            Darwin.close(descriptor)
        }
    }

    /// Removes abandoned snapshots from an earlier crash only when their complete descriptor-bound
    /// tree is private and contains zero-byte regular files. Live snapshots contain non-empty
    /// weights and are therefore never modified.
    @discardableResult
    static func cleanupAbandonedTombstones(
        in parent: URL = FileManager.default.temporaryDirectory
    ) -> Int {
        guard let descriptor = try? openDirectory(
            parent.resolvingSymlinksInPath().standardizedFileURL) else { return 0 }
        defer { Darwin.close(descriptor) }
        return cleanupAbandonedTombstones(parentDescriptor: descriptor)
    }

    @discardableResult
    private static func cleanupAbandonedTombstones(
        parentDescriptor: Int32
    ) -> Int {
        guard let names = directoryEntryNames(parentDescriptor) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix("twister-verified-model-") {
            let rootDescriptor = name.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard rootDescriptor >= 0 else { continue }
            let didRemove = removeEmptySnapshotTree(
                parentDescriptor: parentDescriptor,
                rootDescriptor: rootDescriptor,
                rootName: name)
            Darwin.close(rootDescriptor)
            if didRemove { removed += 1 }
        }
        return removed
    }

    private static func removeEmptySnapshotTree(
        parentDescriptor: Int32,
        rootDescriptor: Int32,
        rootName: String
    ) -> Bool {
        var openedRoot = stat()
        var namedRoot = stat()
        guard Darwin.fstat(rootDescriptor, &openedRoot) == 0,
              rootName.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &namedRoot,
                      AT_SYMLINK_NOFOLLOW)
              }) == 0,
              sameIdentity(openedRoot, namedRoot),
              isPrivateDirectory(openedRoot),
              treeContainsOnlyPrivateEmptyEntries(rootDescriptor) else {
            return false
        }
        guard removePrivateEmptyContents(rootDescriptor) else { return false }

        var finalOpenedRoot = stat()
        var finalNamedRoot = stat()
        guard Darwin.fstat(rootDescriptor, &finalOpenedRoot) == 0,
              rootName.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &finalNamedRoot,
                      AT_SYMLINK_NOFOLLOW)
              }) == 0,
              sameIdentity(openedRoot, finalOpenedRoot),
              sameIdentity(finalOpenedRoot, finalNamedRoot) else {
            return false
        }
        return rootName.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        } == 0
    }

    /// Validation is deliberately a separate pass: cleanup must never start deleting zero-byte
    /// siblings before discovering that another file still belongs to a live snapshot.
    private static func treeContainsOnlyPrivateEmptyEntries(
        _ directoryDescriptor: Int32
    ) -> Bool {
        guard let names = directoryEntryNames(directoryDescriptor) else { return false }
        for name in names {
            var namedStatus = stat()
            guard name.withCString({
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &namedStatus,
                    AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  namedStatus.st_uid == geteuid(),
                  (namedStatus.st_mode & 0o077) == 0 else {
                return false
            }
            switch namedStatus.st_mode & S_IFMT {
            case S_IFREG:
                guard namedStatus.st_size == 0 else { return false }
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard childDescriptor >= 0 else { return false }
                var openedStatus = stat()
                let valid = Darwin.fstat(childDescriptor, &openedStatus) == 0
                    && sameIdentity(namedStatus, openedStatus)
                    && isPrivateDirectory(openedStatus)
                    && treeContainsOnlyPrivateEmptyEntries(childDescriptor)
                Darwin.close(childDescriptor)
                guard valid else { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func removePrivateEmptyContents(
        _ directoryDescriptor: Int32
    ) -> Bool {
        guard let names = directoryEntryNames(directoryDescriptor) else { return false }
        for name in names {
            var namedStatus = stat()
            guard name.withCString({
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &namedStatus,
                    AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  namedStatus.st_uid == geteuid(),
                  (namedStatus.st_mode & 0o077) == 0 else {
                return false
            }
            switch namedStatus.st_mode & S_IFMT {
            case S_IFREG:
                guard namedStatus.st_size == 0,
                      name.withCString({
                          Darwin.unlinkat(directoryDescriptor, $0, 0)
                      }) == 0 else {
                    return false
                }
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard childDescriptor >= 0 else { return false }
                var openedStatus = stat()
                let valid = Darwin.fstat(childDescriptor, &openedStatus) == 0
                    && sameIdentity(namedStatus, openedStatus)
                    && isPrivateDirectory(openedStatus)
                    && treeContainsOnlyPrivateEmptyEntries(childDescriptor)
                    && removePrivateEmptyContents(childDescriptor)
                Darwin.close(childDescriptor)
                guard valid,
                      name.withCString({
                          Darwin.unlinkat(directoryDescriptor, $0, AT_REMOVEDIR)
                      }) == 0 else {
                    return false
                }
            default:
                return false
            }
        }
        return true
    }

    private static func directoryEntryNames(_ descriptor: Int32) -> [String]? {
        // `dup` shares the directory stream offset with the retained descriptor. Open "." through
        // the descriptor instead so validation and deletion each receive an independent stream.
        let independent = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard independent >= 0 else { return nil }
        guard let stream = Darwin.fdopendir(independent) else {
            Darwin.close(independent)
            return nil
        }
        defer { Darwin.closedir(stream) }

        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { return nil }
        return names.sorted()
    }

    private static func isPrivateDirectory(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == geteuid()
            && (status.st_mode & 0o077) == 0
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}
