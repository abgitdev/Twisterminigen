import Darwin
import Foundation

enum DownloadError: LocalizedError {
    case httpStatus(Int, String)
    case incomplete(name: String, expected: Int64, got: Int64)
    case noResponse
    case unsafeSource
    case writeFailed(String)
    case checksumMismatch(name: String)
    case invalidManifest(name: String)
    case invalidContentRange(name: String)
    case invalidAttempts

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let name):
            return "Server returned HTTP \(code) for \(name)."
        case .incomplete(let name, let expected, let got):
            return "\(name) ended early - \(ByteFormat.string(got)) of \(ByteFormat.string(expected))."
        case .noResponse:
            return "No response from the server."
        case .unsafeSource:
            return "The pinned download source must use HTTPS without embedded credentials."
        case .writeFailed(let path):
            return "Couldn't write \(path)."
        case .checksumMismatch(let name):
            return "\(name) failed its manifest checksum after downloading."
        case .invalidManifest(let name):
            return "\(name) does not have a valid exact size and SHA256 in the model manifest."
        case .invalidContentRange(let name):
            return "Server returned an invalid Content-Range for \(name)."
        case .invalidAttempts:
            return "A download needs at least one attempt."
        }
    }
}

/// An isolated transport for immutable, checksum-pinned public artifacts.
///
/// Model payloads can be many gigabytes, so putting them through the process-wide URL cache can
/// duplicate bytes already written to the managed `.part` file. Downloads also never need browser
/// cookies or credentials. A fresh ephemeral configuration keeps those stores out of this path.
enum PinnedDownloadTransport {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = true
        return configuration
    }

    static func permitsHTTPS(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return true
    }

    /// Manifest sources are persisted in resume metadata, so unlike transient CDN redirects they
    /// must not contain query credentials or fragments.
    static func permitsPinnedSource(_ url: URL) -> Bool {
        guard permitsHTTPS(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.query == nil && components.fragment == nil
    }

    static func redirectedRequest(
        from responseURL: URL?,
        proposed request: URLRequest
    ) -> URLRequest? {
        guard let targetURL = request.url, permitsHTTPS(targetURL) else { return nil }
        guard let responseURL, origin(of: responseURL) != origin(of: targetURL) else {
            return request
        }

        var sanitized = request
        for header in ["Authorization", "Cookie", "If-Range", "Proxy-Authorization", "Referer"] {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        return sanitized
    }

    private static func origin(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }
        let port = components.port ?? (scheme == "https" ? 443 : -1)
        return "\(scheme)://\(host):\(port)"
    }
}

/// The proof that a `.part` belongs to the exact pinned manifest source being downloaded.
struct ResumableDownloadMetadata: Codable, Sendable, Equatable {
    let manifestSchema: String
    let manifestVersion: Int
    let sourceRevision: String
    let sourceURL: String
    let expectedSize: Int64
    let sha256: String
    let strongETag: String?

    func matches(
        manifest: ModelManifest,
        revision: String,
        sourceURL: URL,
        file: ModelFile
    ) -> Bool {
        manifestSchema == manifest.schema
            && manifestVersion == manifest.version
            && sourceRevision == revision
            && self.sourceURL == sourceURL.absoluteString
            && expectedSize == file.expectedBytes
            && sha256.caseInsensitiveCompare(file.sha256) == .orderedSame
            && (strongETag == nil || strongETagValue(strongETag) != nil)
    }
}

/// Sequential, resumable download of the exact files pinned by one model component.
enum ResumableDownloader {
    typealias RetrySleeper = @Sendable (_ completedAttempt: Int) async throws -> Void

    private static let productionAttempts = 5

    /// Production API consumed by `ModelStore`.
    static func download(
        component: ModelComponent,
        onProgress: @escaping ModelDownloadProgress
    ) async throws {
        try await download(
            component: component,
            manifest: .current,
            configuration: PinnedDownloadTransport.configuration(),
            attempts: productionAttempts,
            retrySleeper: { completedAttempt in
                let seconds = UInt64(min(8, completedAttempt * 2))
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            },
            onProgress: onProgress)
    }

    /// Injectable transport and retry policy keep protocol tests tiny and deterministic.
    static func download(
        component: ModelComponent,
        manifest: ModelManifest,
        configuration: URLSessionConfiguration,
        attempts: Int,
        retrySleeper: @escaping RetrySleeper,
        onProgress: @escaping ModelDownloadProgress
    ) async throws {
        guard attempts > 0 else { throw DownloadError.invalidAttempts }

        let verifier = ModelVerifier(manifest: manifest)
        let reporter = DownloadProgressReporter(callback: onProgress)
        let total = max(1, component.expectedBytes)
        var cumulative: Int64 = 0

        for file in component.files {
            try Task.checkCancellation()
            guard file.expectedBytes >= 0, isSHA256(file.sha256) else {
                throw DownloadError.invalidManifest(name: file.localURL.lastPathComponent)
            }

            let name = file.localURL.lastPathComponent
            switch verifier.verify(file) {
            case .verified:
                removePartialArtifacts(for: file)
                cumulative += file.expectedBytes
                reporter.required(
                    fraction: fraction(cumulative, total: total),
                    message: "\(name) · ready")
                continue
            case .corrupted:
                removeDownloadArtifact(at: file.localURL)
                removeDownloadArtifact(at: file.verificationURL)
            case .missing:
                break
            }

            let base = cumulative
            try await downloadFile(
                component: component,
                file: file,
                manifest: manifest,
                verifier: verifier,
                configuration: configuration,
                attempts: attempts,
                retrySleeper: retrySleeper,
                onBytes: { written in
                    reporter.bytes(
                        fraction: fraction(base + written, total: total),
                        message: "\(name) · \(ByteFormat.string(written))")
                })

            cumulative = base + file.expectedBytes
            reporter.required(
                fraction: fraction(cumulative, total: total),
                message: "\(name) · done")
        }

        reporter.required(fraction: 1, message: "Complete")
    }

    private static func downloadFile(
        component: ModelComponent,
        file: ModelFile,
        manifest: ModelManifest,
        verifier: ModelVerifier,
        configuration: URLSessionConfiguration,
        attempts: Int,
        retrySleeper: @escaping RetrySleeper,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: file.localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        var attempt = 0
        while attempt < attempts {
            attempt += 1
            try Task.checkCancellation()
            do {
                try await runTransfer(
                    sourceURL: component.url(for: file),
                    sourceRevision: component.revision,
                    file: file,
                    manifest: manifest,
                    verifier: verifier,
                    configuration: configuration,
                    onBytes: onBytes)
                try Task.checkCancellation()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < attempts else { throw error }
                try await retrySleeper(attempt)
            }
        }
    }

    private static func runTransfer(
        sourceURL: URL,
        sourceRevision: String,
        file: ModelFile,
        manifest: ModelManifest,
        verifier: ModelVerifier,
        configuration: URLSessionConfiguration,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard PinnedDownloadTransport.permitsPinnedSource(sourceURL) else {
            throw DownloadError.unsafeSource
        }
        let coordinator = TransferCoordinator(
            sourceURL: sourceURL,
            sourceRevision: sourceRevision,
            file: file,
            manifest: manifest,
            verifier: verifier,
            configuration: configuration,
            onBytes: onBytes)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.start(continuation: continuation)
            }
        } onCancel: {
            coordinator.cancel()
        }
    }

    private static func removePartialArtifacts(for file: ModelFile) {
        removeDownloadArtifact(at: file.partURL)
        removeDownloadArtifact(at: file.metadataURL)
    }

    private static func fraction(_ bytes: Int64, total: Int64) -> Double {
        min(1, max(0, Double(bytes) / Double(total)))
    }

    private static func isSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

private final class DownloadProgressReporter: @unchecked Sendable {
    private let callback: ModelDownloadProgress
    private let lock = NSLock()
    private var lastByteReport: TimeInterval?

    init(callback: @escaping ModelDownloadProgress) {
        self.callback = callback
    }

    func bytes(fraction: Double, message: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldReport = lastByteReport.map { now - $0 >= 0.1 } ?? true
        if shouldReport { lastByteReport = now }
        lock.unlock()

        if shouldReport { callback(fraction, message) }
    }

    func required(fraction: Double, message: String) {
        callback(fraction, message)
    }
}

/// One URLSession data task writing into a trusted `.part`/metadata pair.
private final class TransferCoordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum ResponseMode {
        case none
        case full(expectedBodyBytes: Int64)
        case partial(expectedBodyBytes: Int64)

        var expectedBodyBytes: Int64? {
            switch self {
            case .none: nil
            case .full(let count), .partial(let count): count
            }
        }
    }

    private struct SatisfiedContentRange {
        let start: Int64
        let end: Int64
        let total: Int64

        var count: Int64 { end - start + 1 }
    }

    private struct ResumeState {
        let offset: Int64
        let metadata: ResumableDownloadMetadata?
    }

    private let sourceURL: URL
    private let sourceRevision: String
    private let file: ModelFile
    private let manifest: ModelManifest
    private let verifier: ModelVerifier
    private let configuration: URLSessionConfiguration
    private let onBytes: @Sendable (Int64) -> Void

    private var session: URLSession?
    private var handle: FileHandle?
    private var startOffset: Int64 = 0
    private var written: Int64 = 0
    private var responseBytes: Int64 = 0
    private var responseMode: ResponseMode = .none
    private var resumeMetadata: ResumableDownloadMetadata?
    private var partIdentity: (device: dev_t, inode: ino_t)?

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var wantsCancel = false
    private var finished = false

    init(
        sourceURL: URL,
        sourceRevision: String,
        file: ModelFile,
        manifest: ModelManifest,
        verifier: ModelVerifier,
        configuration: URLSessionConfiguration,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) {
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.file = file
        self.manifest = manifest
        self.verifier = verifier
        self.configuration = configuration
        self.onBytes = onBytes
        super.init()
    }

    func start(continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if wantsCancel {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let resume = loadResumeState()
        startOffset = resume.offset
        written = resume.offset
        resumeMetadata = resume.metadata

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: queue)
        self.session = session

        var request = URLRequest(url: sourceURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if startOffset > 0 {
            request.setValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range")
            if let strongETag = resumeMetadata?.strongETag {
                request.setValue(strongETag, forHTTPHeaderField: "If-Range")
            }
        }

        let task = session.dataTask(with: request)
        lock.lock()
        self.task = task
        let cancelNow = wantsCancel
        lock.unlock()

        if cancelNow {
            task.cancel()
            finish(.failure(CancellationError()))
        } else {
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        wantsCancel = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            reject(DownloadError.noResponse, clean: false, completionHandler: completionHandler)
            return
        }

        responseBytes = 0
        switch http.statusCode {
        case 200:
            acceptFullResponse(http, completionHandler: completionHandler)
        case 206:
            acceptPartialResponse(http, completionHandler: completionHandler)
        case 416:
            acceptUnsatisfiedRange(http, completionHandler: completionHandler)
        default:
            reject(
                DownloadError.httpStatus(http.statusCode, file.localURL.lastPathComponent),
                clean: false,
                completionHandler: completionHandler)
        }
    }

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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let expectedBodyBytes = responseMode.expectedBodyBytes,
              let handle else { return }

        let count = Int64(data.count)
        guard count <= expectedBodyBytes - responseBytes,
              count <= file.expectedBytes - written else {
            let error: Error
            switch responseMode {
            case .partial:
                error = DownloadError.invalidContentRange(name: file.localURL.lastPathComponent)
            case .full, .none:
                error = DownloadError.incomplete(
                    name: file.localURL.lastPathComponent,
                    expected: file.expectedBytes,
                    got: written + count)
            }
            failDuringBody(error, clean: true)
            return
        }

        do {
            try handle.write(contentsOf: data)
            responseBytes += count
            written += count
            onBytes(written)
        } catch {
            failDuringBody(
                DownloadError.writeFailed(file.partURL.lastPathComponent),
                clean: true)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        closeHandle()
        if isFinished { return }

        if let error {
            sanitizeResumableArtifacts()
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled,
               cancellationRequested {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
            return
        }

        switch responseMode {
        case .none:
            finish(.failure(DownloadError.noResponse))
        case .full(let expectedBodyBytes):
            guard responseBytes == expectedBodyBytes else {
                finish(.failure(DownloadError.incomplete(
                    name: file.localURL.lastPathComponent,
                    expected: expectedBodyBytes,
                    got: responseBytes)))
                return
            }
            finishCompletedResponse()
        case .partial(let expectedBodyBytes):
            guard responseBytes == expectedBodyBytes else {
                discardPartialArtifacts()
                finish(.failure(DownloadError.invalidContentRange(
                    name: file.localURL.lastPathComponent)))
                return
            }
            finishCompletedResponse()
        }
    }

    // MARK: Response acceptance

    private func acceptFullResponse(
        _ response: HTTPURLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // A 200 response always replaces any prior range state, including its validator.
        discardPartialArtifacts()
        startOffset = 0
        written = 0
        resumeMetadata = nil

        let declaredLength = response.expectedContentLength
        guard declaredLength < 0 || declaredLength == file.expectedBytes else {
            reject(
                DownloadError.incomplete(
                    name: file.localURL.lastPathComponent,
                    expected: file.expectedBytes,
                    got: max(0, declaredLength)),
                clean: true,
                completionHandler: completionHandler)
            return
        }

        let metadata = makeMetadata(
            strongETag: strongETagValue(response.value(forHTTPHeaderField: "ETag")))
        guard preparePart(append: false, metadata: metadata) else {
            completionHandler(.cancel)
            return
        }

        responseMode = .full(expectedBodyBytes: file.expectedBytes)
        completionHandler(.allow)
    }

    private func acceptPartialResponse(
        _ response: HTTPURLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let rawRange = response.value(forHTTPHeaderField: "Content-Range"),
              let range = Self.parseSatisfiedContentRange(rawRange),
              range.start == startOffset,
              range.total == file.expectedBytes,
              range.end >= range.start,
              range.end < range.total,
              response.expectedContentLength < 0 || response.expectedContentLength == range.count else {
            reject(
                DownloadError.invalidContentRange(name: file.localURL.lastPathComponent),
                clean: true,
                completionHandler: completionHandler)
            return
        }

        let responseETag = strongETagValue(response.value(forHTTPHeaderField: "ETag"))
        if let priorETag = resumeMetadata?.strongETag,
           let responseETag,
           priorETag != responseETag {
            reject(
                DownloadError.invalidContentRange(name: file.localURL.lastPathComponent),
                clean: true,
                completionHandler: completionHandler)
            return
        }

        let metadata = makeMetadata(
            strongETag: resumeMetadata?.strongETag ?? responseETag)
        guard preparePart(append: startOffset > 0, metadata: metadata) else {
            completionHandler(.cancel)
            return
        }

        responseMode = .partial(expectedBodyBytes: range.count)
        completionHandler(.allow)
    }

    private func acceptUnsatisfiedRange(
        _ response: HTTPURLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let rawRange = response.value(forHTTPHeaderField: "Content-Range"),
              let total = Self.parseUnsatisfiedContentRange(rawRange),
              total == file.expectedBytes,
              FileProbe.size(file.partURL) == total else {
            reject(
                DownloadError.invalidContentRange(name: file.localURL.lastPathComponent),
                clean: true,
                completionHandler: completionHandler)
            return
        }

        do {
            try acceptCompletedPart()
            finish(.success(()))
        } catch {
            discardPartialArtifacts()
            finish(.failure(error))
        }
        completionHandler(.cancel)
    }

    private func finishCompletedResponse() {
        let size = FileProbe.size(file.partURL) ?? written
        guard size == file.expectedBytes, written == file.expectedBytes else {
            finish(.failure(DownloadError.incomplete(
                name: file.localURL.lastPathComponent,
                expected: file.expectedBytes,
                got: size)))
            return
        }

        do {
            try acceptCompletedPart()
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    /// The verifier performs the mandatory manifest SHA and writes the canonical verified stamp.
    private func acceptCompletedPart() throws {
        guard FileProbe.size(file.partURL) == file.expectedBytes else {
            throw DownloadError.incomplete(
                name: file.localURL.lastPathComponent,
                expected: file.expectedBytes,
                got: FileProbe.size(file.partURL) ?? 0)
        }
        guard partNameStillMatchesOpenedFile() else {
            throw DownloadError.writeFailed(file.partURL.lastPathComponent)
        }

        do {
            removeDownloadArtifact(at: file.localURL)
            removeDownloadArtifact(at: file.verificationURL)
            guard !FileManager.default.fileExists(atPath: file.localURL.path),
                  !FileManager.default.fileExists(atPath: file.verificationURL.path) else {
                throw DownloadError.writeFailed(file.localURL.lastPathComponent)
            }
            try FileManager.default.moveItem(at: file.partURL, to: file.localURL)
        } catch {
            throw DownloadError.writeFailed(file.localURL.lastPathComponent)
        }

        guard verifier.verify(file) == .verified else {
            removeDownloadArtifact(at: file.localURL)
            removeDownloadArtifact(at: file.verificationURL)
            removeDownloadArtifact(at: file.metadataURL)
            throw DownloadError.checksumMismatch(name: file.localURL.lastPathComponent)
        }

        removeDownloadArtifact(at: file.metadataURL)
    }

    // MARK: Part lifecycle

    private func loadResumeState() -> ResumeState {
        let namedPart = safeNamedPart()
        let metadata = readMetadata()

        guard let namedPart, namedPart.size > 0,
              namedPart.size <= file.expectedBytes,
              let metadata,
              metadata.matches(
                manifest: manifest,
                revision: sourceRevision,
                sourceURL: sourceURL,
                file: file) else {
            discardPartialArtifacts()
            return ResumeState(offset: 0, metadata: nil)
        }

        partIdentity = (namedPart.device, namedPart.inode)
        return ResumeState(offset: namedPart.size, metadata: metadata)
    }

    private func makeMetadata(strongETag: String?) -> ResumableDownloadMetadata {
        ResumableDownloadMetadata(
            manifestSchema: manifest.schema,
            manifestVersion: manifest.version,
            sourceRevision: sourceRevision,
            sourceURL: sourceURL.absoluteString,
            expectedSize: file.expectedBytes,
            sha256: file.sha256.lowercased(),
            strongETag: strongETag)
    }

    private func preparePart(append: Bool, metadata: ResumableDownloadMetadata) -> Bool {
        do {
            let descriptor = file.partURL.path.withCString {
                Darwin.open(
                    $0,
                    O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                throw DownloadError.writeFailed(file.partURL.lastPathComponent)
            }
            var opened = stat()
            var named = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  file.partURL.path.withCString({ Darwin.lstat($0, &named) }) == 0,
                  (opened.st_mode & S_IFMT) == S_IFREG,
                  opened.st_uid == geteuid(),
                  opened.st_nlink == 1,
                  opened.st_dev == named.st_dev,
                  opened.st_ino == named.st_ino,
                  Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                Darwin.close(descriptor)
                throw DownloadError.writeFailed(file.partURL.lastPathComponent)
            }
            if append {
                guard let expectedIdentity = partIdentity,
                      opened.st_dev == expectedIdentity.device,
                      opened.st_ino == expectedIdentity.inode else {
                    Darwin.close(descriptor)
                    // The name was replaced after the resume offset was selected. Leave the
                    // replacement untouched and fail this attempt instead of writing or unlinking.
                    finish(.failure(DownloadError.writeFailed(
                        file.partURL.lastPathComponent)))
                    return false
                }
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            if append {
                let end = try handle.seekToEnd()
                guard end == UInt64(startOffset) else {
                    try? handle.close()
                    discardPartialArtifacts()
                    finish(.failure(DownloadError.invalidContentRange(
                        name: file.localURL.lastPathComponent)))
                    return false
                }
            } else {
                try handle.truncate(atOffset: 0)
            }
            self.handle = handle
            partIdentity = (opened.st_dev, opened.st_ino)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(metadata).write(to: file.metadataURL, options: .atomic)
            resumeMetadata = metadata
            return true
        } catch {
            discardPartialArtifacts()
            finish(.failure(DownloadError.writeFailed(file.partURL.lastPathComponent)))
            return false
        }
    }

    private func readMetadata() -> ResumableDownloadMetadata? {
        let maximumBytes = 16_384
        let descriptor = file.metadataURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size > 0,
              status.st_size <= maximumBytes,
              let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes else {
            return nil
        }
        return try? JSONDecoder().decode(ResumableDownloadMetadata.self, from: data)
    }

    private func sanitizeResumableArtifacts() {
        guard let namedPart = safeNamedPart(),
              namedPart.size > 0,
              namedPart.size <= file.expectedBytes,
              partNameStillMatchesOpenedFile(),
              let metadata = readMetadata(),
              metadata.matches(
                manifest: manifest,
                revision: sourceRevision,
                sourceURL: sourceURL,
                file: file) else {
            discardPartialArtifacts()
            return
        }
    }

    private func discardPartialArtifacts() {
        closeHandle()
        removeDownloadArtifact(at: file.partURL)
        removeDownloadArtifact(at: file.metadataURL)
        partIdentity = nil
        resumeMetadata = nil
        startOffset = 0
        written = 0
        responseBytes = 0
        responseMode = .none
    }

    private func closeHandle() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    private func partNameStillMatchesOpenedFile() -> Bool {
        guard let partIdentity else { return false }
        var named = stat()
        return file.partURL.path.withCString({ Darwin.lstat($0, &named) }) == 0
            && (named.st_mode & S_IFMT) == S_IFREG
            && named.st_uid == geteuid()
            && named.st_nlink == 1
            && named.st_dev == partIdentity.device
            && named.st_ino == partIdentity.inode
    }

    private func safeNamedPart() -> (device: dev_t, inode: ino_t, size: Int64)? {
        var status = stat()
        guard file.partURL.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size >= 0 else {
            return nil
        }
        return (status.st_dev, status.st_ino, Int64(status.st_size))
    }

    // MARK: Header parsing

    private static func parseSatisfiedContentRange(_ value: String) -> SatisfiedContentRange? {
        let fields = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }

        let rangeAndTotal = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2,
              let total = Int64(rangeAndTotal[1]) else { return nil }

        let bounds = rangeAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              total >= 0 else { return nil }
        return SatisfiedContentRange(start: start, end: end, total: total)
    }

    private static func parseUnsatisfiedContentRange(_ value: String) -> Int64? {
        let fields = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }

        let rangeAndTotal = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2,
              rangeAndTotal[0] == "*",
              let total = Int64(rangeAndTotal[1]),
              total >= 0 else { return nil }
        return total
    }

    // MARK: Completion

    private func reject(
        _ error: Error,
        clean: Bool,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if clean { discardPartialArtifacts() }
        finish(.failure(error))
        completionHandler(.cancel)
        cancelDataTask()
    }

    private func failDuringBody(_ error: Error, clean: Bool) {
        if clean { discardPartialArtifacts() }
        finish(.failure(error))
        cancelDataTask()
    }

    private func cancelDataTask() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    private var cancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wantsCancel
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        // Each coordinator owns exactly one task. Once its checked result is known there is no
        // useful background work to retain, including in rejection/cancellation paths.
        session?.invalidateAndCancel()
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private func removeDownloadArtifact(at url: URL) {
    var status = stat()
    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
          (status.st_mode & S_IFMT) != S_IFDIR else {
        return
    }
    _ = url.path.withCString { Darwin.unlink($0) }
}

private func strongETagValue(_ rawValue: String?) -> String? {
    guard let rawValue else { return nil }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count >= 2,
          value.first == "\"",
          value.last == "\"",
          !value.hasPrefix("W/"),
          !value.hasPrefix("w/") else { return nil }

    let inner = value.dropFirst().dropLast()
    guard !inner.contains("\"") else { return nil }
    return value
}
