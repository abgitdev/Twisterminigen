import CryptoKit
import Darwin
import Foundation

enum ModelFileVerification: Sendable, Equatable {
    case missing
    case corrupted
    case verified
}

/// A verification stamp is deliberately bound to the file-system object, not only to attributes
/// that an unprivileged writer can restore after replacing bytes. `ctime`, device and inode make a
/// same-size/restored-mtime replacement invalidate the cache; mode prevents a permission change
/// from silently retaining the proof.
struct ModelVerificationStamp: Codable, Sendable, Equatable {
    let manifestSchema: String
    let manifestVersion: Int
    let size: Int64
    let sha256: String
    let fileDevice: UInt64
    let fileInode: UInt64
    let fileMode: UInt32
    let fileChangeTimeSeconds: Int64
    let fileChangeTimeNanoseconds: Int64
    let fileModificationTimeSeconds: Int64
    let fileModificationTimeNanoseconds: Int64
}

/// Verifies exact manifest bytes and persists a stat-checkable proof. Linked, read-only catalogs
/// place that proof in app-owned storage instead of beside the model file. Every probe opens the
/// final path component with `O_NOFOLLOW`, requires a regular file, and obtains metadata with
/// `fstat` from that exact descriptor.
struct ModelVerifier: Sendable {
    typealias HashFileDescriptor = @Sendable (Int32) throws -> String

    let manifest: ModelManifest
    private let hashFileDescriptor: HashFileDescriptor
    private let allowsStampMutation: Bool
    private let stampDirectory: URL?

    init(
        manifest: ModelManifest,
        allowsStampMutation: Bool = true,
        stampDirectory: URL? = nil,
        hashFileDescriptor: @escaping HashFileDescriptor = {
            try ModelVerifier.sha256Hex(ofFileDescriptor: $0)
        }
    ) {
        self.manifest = manifest
        self.allowsStampMutation = allowsStampMutation
        self.stampDirectory = stampDirectory
        self.hashFileDescriptor = hashFileDescriptor
    }

    /// Fast UI/status probe. The cache is valid only for the same non-symlink regular-file object
    /// and the complete security-relevant stat tuple captured after the successful SHA-256 pass.
    func isVerifiedFromCache(_ file: ModelFile) -> Bool {
        guard let metadata = try? Self.metadataForPath(file.localURL),
              metadata.size == file.expectedBytes,
              let stamp = readStamp(for: file) else { return false }
        return stampMatches(stamp, file: file, metadata: metadata)
    }

    /// Normal catalog verification may consume a valid stat-bound stamp. Generation must instead
    /// call `verifyForLoad`, which always hashes immediately before the model loader opens the path.
    func verify(_ file: ModelFile) -> ModelFileVerification {
        verify(file, alwaysHash: false)
    }

    /// Full load-bound verification. This never trusts a cached SHA and is intentionally allowed
    /// to read every byte before each new resident model load.
    func verifyForLoad(_ file: ModelFile) -> ModelFileVerification {
        verify(file, alwaysHash: true)
    }

    static func sha256Hex(of url: URL) throws -> String {
        let opened = try openRegularFile(url)
        defer { Darwin.close(opened.descriptor) }
        let digest = try sha256Hex(ofFileDescriptor: opened.descriptor)
        let after = try metadata(of: opened.descriptor)
        guard after == opened.metadata,
              try metadataForPath(url) == after else {
            throw ModelVerifierError.fileChangedDuringVerification(url)
        }
        return digest
    }

    static func sha256Hex(ofFileDescriptor descriptor: Int32) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw ModelVerifierError.posix("lseek", errno)
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                while true {
                    let result = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else {
                throw ModelVerifierError.posix("read", errno)
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0 ..< count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func verify(
        _ file: ModelFile,
        alwaysHash: Bool
    ) -> ModelFileVerification {
        let opened: OpenedRegularFile
        do {
            opened = try Self.openRegularFile(file.localURL)
        } catch ModelVerifierError.posix(_, let code) where code == ENOENT {
            if allowsStampMutation { invalidateStamp(for: file) }
            return .missing
        } catch {
            if allowsStampMutation { invalidateStamp(for: file) }
            return .corrupted
        }
        defer { Darwin.close(opened.descriptor) }

        guard opened.metadata.size == file.expectedBytes else {
            if allowsStampMutation { invalidateStamp(for: file) }
            return .corrupted
        }
        if !alwaysHash, let stamp = readStamp(for: file),
           stampMatches(stamp, file: file, metadata: opened.metadata) {
            return .verified
        }

        do {
            let actualSHA = try hashFileDescriptor(opened.descriptor).lowercased()
            let after = try Self.metadata(of: opened.descriptor)
            // Re-open the path with O_NOFOLLOW too. This catches an atomic path replacement that
            // occurred while the original descriptor was being hashed.
            let currentPathMetadata = try Self.metadataForPath(file.localURL)
            guard after == opened.metadata,
                  currentPathMetadata == after,
                  actualSHA == file.sha256.lowercased() else {
                if allowsStampMutation { invalidateStamp(for: file) }
                return .corrupted
            }

            let stamp = ModelVerificationStamp(
                manifestSchema: manifest.schema,
                manifestVersion: manifest.version,
                size: after.size,
                sha256: actualSHA,
                fileDevice: after.device,
                fileInode: after.inode,
                fileMode: after.mode,
                fileChangeTimeSeconds: after.changeTimeSeconds,
                fileChangeTimeNanoseconds: after.changeTimeNanoseconds,
                fileModificationTimeSeconds: after.modificationTimeSeconds,
                fileModificationTimeNanoseconds: after.modificationTimeNanoseconds)
            if allowsStampMutation { try writeStamp(stamp, for: file) }
            return .verified
        } catch {
            if allowsStampMutation { invalidateStamp(for: file) }
            return .corrupted
        }
    }

    private struct FileMetadata: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let changeTimeSeconds: Int64
        let changeTimeNanoseconds: Int64
        let modificationTimeSeconds: Int64
        let modificationTimeNanoseconds: Int64
    }

    private struct OpenedRegularFile {
        let descriptor: Int32
        let metadata: FileMetadata
    }

    private static func openRegularFile(_ url: URL) throws -> OpenedRegularFile {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ModelVerifierError.posix("open", errno)
        }
        do {
            return OpenedRegularFile(
                descriptor: descriptor,
                metadata: try metadata(of: descriptor))
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func metadataForPath(_ url: URL) throws -> FileMetadata {
        let opened = try openRegularFile(url)
        defer { Darwin.close(opened.descriptor) }
        return opened.metadata
    }

    private static func metadata(of descriptor: Int32) throws -> FileMetadata {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw ModelVerifierError.posix("fstat", errno)
        }
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            throw ModelVerifierError.notRegularFile
        }
        return FileMetadata(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt32(value.st_mode),
            size: Int64(value.st_size),
            changeTimeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeTimeNanoseconds: Int64(value.st_ctimespec.tv_nsec),
            modificationTimeSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationTimeNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }

    private func stampMatches(
        _ stamp: ModelVerificationStamp,
        file: ModelFile,
        metadata: FileMetadata
    ) -> Bool {
        stamp.manifestSchema == manifest.schema
            && stamp.manifestVersion == manifest.version
            && stamp.size == file.expectedBytes
            && stamp.size == metadata.size
            && stamp.sha256.caseInsensitiveCompare(file.sha256) == .orderedSame
            && stamp.fileDevice == metadata.device
            && stamp.fileInode == metadata.inode
            && stamp.fileMode == metadata.mode
            && stamp.fileChangeTimeSeconds == metadata.changeTimeSeconds
            && stamp.fileChangeTimeNanoseconds == metadata.changeTimeNanoseconds
            && stamp.fileModificationTimeSeconds == metadata.modificationTimeSeconds
            && stamp.fileModificationTimeNanoseconds == metadata.modificationTimeNanoseconds
    }

    private func readStamp(for file: ModelFile) -> ModelVerificationStamp? {
        guard let data = try? Data(contentsOf: stampURL(for: file)) else { return nil }
        return try? JSONDecoder().decode(ModelVerificationStamp.self, from: data)
    }

    private func writeStamp(_ stamp: ModelVerificationStamp, for file: ModelFile) throws {
        if let stampDirectory {
            try FileManager.default.createDirectory(
                at: stampDirectory,
                withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stamp)
        try data.write(to: stampURL(for: file), options: .atomic)
    }

    private func invalidateStamp(for file: ModelFile) {
        try? FileManager.default.removeItem(at: stampURL(for: file))
    }

    private func stampURL(for file: ModelFile) -> URL {
        guard let stampDirectory else { return file.verificationURL }
        let identity = [
            manifest.schema,
            String(manifest.version),
            file.localURL.standardizedFileURL.path,
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return stampDirectory.appendingPathComponent("\(digest).json")
    }
}

private enum ModelVerifierError: Error {
    case posix(String, Int32)
    case notRegularFile
    case fileChangedDuringVerification(URL)
}
