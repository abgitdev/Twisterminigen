import Darwin
import Foundation

enum OfficialKreaStyleLoRADownloadError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse(Int)
    case unsafePayload
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let status):
            return "The official Krea adapter download returned HTTP \(status)."
        case .unsafePayload:
            return "The official Krea adapter download was not a regular file."
        case let .sizeMismatch(expected, actual):
            return "The official adapter size changed (expected \(expected), received \(actual) bytes)."
        case .hashMismatch:
            return "The official adapter failed its pinned SHA-256 check."
        }
    }
}

enum OfficialKreaStyleLoRADownload {
    private enum RetainedFileOwner {
        case process(pid_t)
        case legacy
    }

    private static let retainedPrefix = ".twister-krea-lora-"
    private static let retainedSuffix = ".safetensors"
    private static let legacyMinimumAge: TimeInterval = 24 * 60 * 60

    static func download(_ style: OfficialKreaStyleLoRA) async throws -> URL {
        guard PinnedDownloadTransport.permitsPinnedSource(style.downloadURL) else {
            throw DownloadError.unsafeSource
        }
        cleanupAbandonedArtifacts()

        let redirectDelegate = PinnedHTTPSRedirectDelegate()
        let session = URLSession(
            configuration: PinnedDownloadTransport.configuration(),
            delegate: redirectDelegate,
            delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (temporary, response) = try await session.download(from: style.downloadURL)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            throw OfficialKreaStyleLoRADownloadError.invalidResponse(
                (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let values = try? temporary.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true else {
            throw OfficialKreaStyleLoRADownloadError.unsafePayload
        }
        let actualBytes = Int64(values?.fileSize ?? -1)
        guard actualBytes == style.byteCount else {
            throw OfficialKreaStyleLoRADownloadError.sizeMismatch(
                expected: style.byteCount,
                actual: actualBytes)
        }
        let sha = try ModelVerifier.sha256Hex(of: temporary)
        guard sha.caseInsensitiveCompare(style.sha256) == .orderedSame else {
            throw OfficialKreaStyleLoRADownloadError.hashMismatch
        }
        // URLSession owns its download URL. Move a verified copy to an explicit temporary file so
        // it stays valid until the LoRA actor finishes its transactional managed-library import.
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(retainedPrefix)\(getpid())-\(UUID().uuidString.lowercased())\(retainedSuffix)")
        do {
            try FileManager.default.copyItem(at: temporary, to: retained)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: retained.path)
        } catch {
            try? FileManager.default.removeItem(at: retained)
            throw error
        }
        return retained
    }

    /// Removes only app-namespaced, owned regular files left behind by an interrupted import.
    /// Symlinks, directories, hard links, and unrelated temporary files are never followed/deleted.
    @discardableResult
    static func cleanupAbandonedArtifacts(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date()
    ) -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []) else {
            return 0
        }

        var removed = 0
        for item in contents {
            let name = item.lastPathComponent
            guard let owner = retainedFileOwner(name) else { continue }

            var status = stat()
            guard item.path.withCString({ Darwin.lstat($0, &status) }) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1 else {
                continue
            }
            switch owner {
            case .process(let pid):
                guard !processIsRunning(pid) else { continue }
            case .legacy:
                let modified = Date(
                    timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                        + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
                guard now.timeIntervalSince(modified) >= legacyMinimumAge else { continue }
            }
            if item.path.withCString({ Darwin.unlink($0) }) == 0 {
                removed += 1
            }
        }
        return removed
    }

    private static func retainedFileOwner(_ name: String) -> RetainedFileOwner? {
        guard name.hasPrefix(retainedPrefix), name.hasSuffix(retainedSuffix) else {
            return nil
        }
        let payload = name
            .dropFirst(retainedPrefix.count)
            .dropLast(retainedSuffix.count)
        if UUID(uuidString: String(payload)) != nil {
            return .legacy
        }
        guard let separator = payload.firstIndex(of: "-"),
              let pid = pid_t(payload[..<separator]),
              pid > 0,
              UUID(uuidString: String(payload[payload.index(after: separator)...])) != nil else {
            return nil
        }
        return .process(pid)
    }

    private static func processIsRunning(_ pid: pid_t) -> Bool {
        if pid == getpid() { return true }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}

private final class PinnedHTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(PinnedDownloadTransport.redirectedRequest(
            from: response.url,
            proposed: request))
    }
}
