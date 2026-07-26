import CryptoKit
import Dispatch
import Foundation
import Testing
@testable import Twisterminigen

@Suite("Resumable downloader")
struct ResumableDownloaderTests {
    @Test("Production transport has no cache, cookie, or credential store")
    func isolatedProductionTransport() {
        let configuration = PinnedDownloadTransport.configuration()

        #expect(configuration.identifier == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.waitsForConnectivity)
        #expect(configuration.timeoutIntervalForRequest == 120)
    }

    @Test("Pinned transport permits only credential-free HTTPS")
    func pinnedHTTPSPolicy() throws {
        #expect(PinnedDownloadTransport.permitsPinnedSource(
            try #require(URL(string: "https://huggingface.co/org/repo/resolve/revision/file"))))
        #expect(!PinnedDownloadTransport.permitsPinnedSource(
            try #require(URL(string: "http://huggingface.co/org/repo/file"))))
        #expect(!PinnedDownloadTransport.permitsPinnedSource(
            try #require(URL(string: "https://embedded-user@huggingface.co/org/repo/file"))))
        #expect(!PinnedDownloadTransport.permitsPinnedSource(
            FileManager.default.temporaryDirectory.appendingPathComponent("model.safetensors")))
        #expect(!PinnedDownloadTransport.permitsPinnedSource(
            try #require(URL(string: "https://huggingface.co/org/repo/file?download=true"))))
        #expect(PinnedDownloadTransport.permitsHTTPS(
            try #require(URL(string: "https://cdn.example/file?signature=transient"))))

        var crossOrigin = URLRequest(
            url: try #require(URL(string: "https://cdn.example/file?signature=transient")))
        crossOrigin.setValue("unit-test-value", forHTTPHeaderField: "Authorization")
        crossOrigin.setValue("\"source-etag\"", forHTTPHeaderField: "If-Range")
        crossOrigin.setValue("bytes=42-", forHTTPHeaderField: "Range")
        let source = URL(string: "https://huggingface.co/source")!
        let sanitized = try #require(PinnedDownloadTransport.redirectedRequest(
            from: source,
            proposed: crossOrigin))
        #expect(sanitized.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sanitized.value(forHTTPHeaderField: "If-Range") == nil)
        #expect(sanitized.value(forHTTPHeaderField: "Range") == "bytes=42-")
    }

    @Test("Abandoned official LoRA cleanup is exact and never follows special files")
    func officialLoRACleanupIsConservative() throws {
        let root = try makeDownloadDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent(
            ".twister-krea-lora-99999999-\(UUID().uuidString.lowercased()).safetensors")
        let active = root.appendingPathComponent(
            ".twister-krea-lora-\(getpid())-\(UUID().uuidString.lowercased()).safetensors")
        let oldLegacy = root.appendingPathComponent(
            ".twister-krea-lora-\(UUID().uuidString.lowercased()).safetensors")
        let freshLegacy = root.appendingPathComponent(
            ".twister-krea-lora-\(UUID().uuidString.lowercased()).safetensors")
        let unrelated = root.appendingPathComponent("keep.safetensors")
        let outside = root.appendingPathComponent("outside.safetensors")
        let symlink = root.appendingPathComponent(
            ".twister-krea-lora-\(UUID().uuidString.lowercased()).safetensors")
        try Data("managed".utf8).write(to: managed)
        try Data("active".utf8).write(to: active)
        try Data("old legacy".utf8).write(to: oldLegacy)
        try Data("fresh legacy".utf8).write(to: freshLegacy)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-25 * 60 * 60)],
            ofItemAtPath: oldLegacy.path)
        try Data("keep".utf8).write(to: unrelated)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        #expect(OfficialKreaStyleLoRADownload.cleanupAbandonedArtifacts(in: root) == 2)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
        #expect(!FileManager.default.fileExists(atPath: oldLegacy.path))
        #expect(try Data(contentsOf: active) == Data("active".utf8))
        #expect(try Data(contentsOf: freshLegacy) == Data("fresh legacy".utf8))
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)) != nil)
    }

    @Test("Symlinked and hard-linked partials never redirect model writes")
    func hostilePartialFilesAreReplacedSafely() async throws {
        enum LinkKind: CaseIterable {
            case symbolic
            case hard
        }

        for kind in LinkKind.allCases {
            let fixture = try DownloadFixture()
            defer { fixture.remove() }
            let outside = fixture.root.appendingPathComponent("outside-private.txt")
            let original = Data("must not change".utf8)
            try original.write(to: outside)
            switch kind {
            case .symbolic:
                try FileManager.default.createSymbolicLink(
                    at: fixture.file.partURL,
                    withDestinationURL: outside)
            case .hard:
                try FileManager.default.linkItem(at: outside, to: fixture.file.partURL)
            }
            let server = StubServer(responses: [
                .init(
                    statusCode: 200,
                    headers: fixture.fullHeaders(),
                    chunks: [fixture.payload]),
            ])

            try await fixture.download(using: server)

            #expect(try Data(contentsOf: outside) == original)
            #expect(try Data(contentsOf: fixture.file.localURL) == fixture.payload)
        }
    }

    @Test("A same-size partial inode swap before append fails without touching the replacement")
    func partialInodeSwapFailsClosed() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let prefixCount = 7
        let prefix = Data(fixture.payload.prefix(prefixCount))
        try fixture.writePart(prefix, etag: "\"model-v1\"")
        let displaced = fixture.root.appendingPathComponent("displaced-original.part")
        let replacement = fixture.root.appendingPathComponent("replacement.bin")
        let replacementBytes = Data(repeating: 0xa7, count: prefixCount)
        try replacementBytes.write(to: replacement)
        let suffix = Data(fixture.payload.dropFirst(prefixCount))
        let server = StubServer(responses: [
            .init(
                statusCode: 206,
                headers: [
                    "Content-Length": "\(suffix.count)",
                    "Content-Range":
                        "bytes \(prefixCount)-\(fixture.payload.count - 1)/\(fixture.payload.count)",
                    "ETag": "\"model-v1\"",
                ],
                chunks: [suffix],
                beforeResponse: {
                    try? FileManager.default.moveItem(
                        at: fixture.file.partURL,
                        to: displaced)
                    try? FileManager.default.moveItem(
                        at: replacement,
                        to: fixture.file.partURL)
                }),
        ])

        await expectDownloadFailure {
            try await fixture.download(using: server)
        }

        #expect(try Data(contentsOf: fixture.file.partURL) == replacementBytes)
        #expect(try Data(contentsOf: displaced) == prefix)
        #expect(!FileProbe.exists(fixture.file.localURL))
    }

    @Test("A directory planted at the partial path is never recursively removed")
    func directoryPartialFailsClosed() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.file.partURL,
            withIntermediateDirectories: false)
        let sentinel = fixture.file.partURL.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)
        let server = StubServer(responses: [
            .init(
                statusCode: 200,
                headers: fixture.fullHeaders(),
                chunks: [fixture.payload]),
        ])

        await expectDownloadFailure {
            try await fixture.download(using: server)
        }

        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(!FileProbe.exists(fixture.file.localURL))
    }

    @Test("A 200 response is rewritten, verified, and stamped")
    func fullResponse() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let server = StubServer(responses: [
            .init(
                statusCode: 200,
                headers: fixture.fullHeaders(etag: "\"model-v1\""),
                chunks: [fixture.payload]),
        ])

        try await fixture.download(using: server)

        #expect(try Data(contentsOf: fixture.file.localURL) == fixture.payload)
        #expect(!FileProbe.exists(fixture.file.partURL))
        #expect(!FileProbe.exists(fixture.file.metadataURL))
        #expect(ModelVerifier(manifest: fixture.manifest).isVerifiedFromCache(fixture.file))
        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Range") == nil)
    }

    @Test("A correct 206 appends at the exact offset and sends If-Range")
    func correctPartialResponse() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let prefixCount = 7
        let prefix = fixture.payload.prefix(prefixCount)
        let suffix = fixture.payload.dropFirst(prefixCount)
        try fixture.writePart(Data(prefix), etag: "\"model-v1\"")
        let server = StubServer(responses: [
            .init(
                statusCode: 206,
                headers: [
                    "Content-Length": "\(suffix.count)",
                    "Content-Range": "bytes \(prefixCount)-\(fixture.payload.count - 1)/\(fixture.payload.count)",
                    "ETag": "\"model-v1\"",
                ],
                chunks: [Data(suffix)]),
        ])

        try await fixture.download(using: server)

        #expect(try Data(contentsOf: fixture.file.localURL) == fixture.payload)
        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=\(prefixCount)-")
        #expect(request.value(forHTTPHeaderField: "If-Range") == "\"model-v1\"")
    }

    @Test("A server ignoring Range with 200 cleanly rewrites the part")
    func ignoredRangeRewrites() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let prefixCount = 9
        try fixture.writePart(Data(fixture.payload.prefix(prefixCount)), etag: "\"old-v1\"")
        let server = StubServer(responses: [
            .init(
                statusCode: 200,
                headers: fixture.fullHeaders(etag: "\"new-v2\""),
                chunks: [fixture.payload]),
        ])

        try await fixture.download(using: server)

        #expect(try Data(contentsOf: fixture.file.localURL) == fixture.payload)
        #expect(FileProbe.size(fixture.file.localURL) == Int64(fixture.payload.count))
        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=\(prefixCount)-")
    }

    @Test("Missing or wrong 206 ranges discard all prior bytes before retry")
    func invalidPartialResponsesRestartCleanly() async throws {
        enum InvalidRangeCase: CaseIterable {
            case missing
            case wrongStart
            case bodyLengthDisagreesWithEnd
        }

        for invalidCase in InvalidRangeCase.allCases {
            let fixture = try DownloadFixture()
            defer { fixture.remove() }
            let prefixCount = 6
            let suffix = Data(fixture.payload.dropFirst(prefixCount))
            try fixture.writePart(Data(fixture.payload.prefix(prefixCount)), etag: "\"model-v1\"")

            var invalidHeaders = [
                "Content-Length": "\(suffix.count)",
                "ETag": "\"model-v1\"",
            ]
            switch invalidCase {
            case .missing:
                break
            case .wrongStart:
                invalidHeaders["Content-Range"] =
                    "bytes 0-\(suffix.count - 1)/\(fixture.payload.count)"
            case .bodyLengthDisagreesWithEnd:
                invalidHeaders["Content-Range"] =
                    "bytes \(prefixCount)-\(fixture.payload.count - 2)/\(fixture.payload.count)"
            }

            let server = StubServer(responses: [
                .init(statusCode: 206, headers: invalidHeaders, chunks: [suffix]),
                .init(
                    statusCode: 200,
                    headers: fixture.fullHeaders(),
                    chunks: [fixture.payload]),
            ])

            try await fixture.download(using: server, attempts: 2)

            #expect(try Data(contentsOf: fixture.file.localURL) == fixture.payload)
            #expect(server.requests.count == 2)
            #expect(server.requests[0].value(forHTTPHeaderField: "Range") == "bytes=\(prefixCount)-")
            #expect(server.requests[1].value(forHTTPHeaderField: "Range") == nil)
        }
    }

    @Test("A valid 416 accepts only an exact, SHA-valid completed part")
    func validUnsatisfiedRange() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        try fixture.writePart(fixture.payload, etag: "\"model-v1\"")
        let server = StubServer(responses: [
            .init(
                statusCode: 416,
                headers: ["Content-Range": "bytes */\(fixture.payload.count)"],
                chunks: []),
        ])

        try await fixture.download(using: server)

        #expect(try Data(contentsOf: fixture.file.localURL) == fixture.payload)
        #expect(ModelVerifier(manifest: fixture.manifest).isVerifiedFromCache(fixture.file))
        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=\(fixture.payload.count)-")
    }

    @Test("Invalid 416 variants discard the part and retry from zero")
    func invalidUnsatisfiedRangesRestartCleanly() async throws {
        enum Invalid416Case: CaseIterable {
            case wrongTotal
            case incompletePart
            case wrongSHA
        }

        for invalidCase in Invalid416Case.allCases {
            let fixture = try DownloadFixture()
            defer { fixture.remove() }

            let part: Data
            let contentRange: String
            switch invalidCase {
            case .wrongTotal:
                part = fixture.payload
                contentRange = "bytes */\(fixture.payload.count + 1)"
            case .incompletePart:
                part = Data(fixture.payload.dropLast())
                contentRange = "bytes */\(fixture.payload.count)"
            case .wrongSHA:
                part = Data(repeating: 0xa5, count: fixture.payload.count)
                contentRange = "bytes */\(fixture.payload.count)"
            }
            try fixture.writePart(part, etag: "\"model-v1\"")

            let server = StubServer(responses: [
                .init(
                    statusCode: 416,
                    headers: ["Content-Range": contentRange],
                    chunks: []),
                .init(
                    statusCode: 200,
                    headers: fixture.fullHeaders(),
                    chunks: [fixture.payload]),
            ])

            try await fixture.download(using: server, attempts: 2)

            #expect(try Data(contentsOf: fixture.file.localURL) == fixture.payload)
            #expect(server.requests.count == 2)
            #expect(server.requests[1].value(forHTTPHeaderField: "Range") == nil)
        }
    }

    @Test("Unknown 200 length is accepted only after exact bytes and SHA")
    func unknownContentLength() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let server = StubServer(responses: [
            .init(
                statusCode: 200,
                headers: ["ETag": "\"model-v1\""],
                chunks: [fixture.payload]),
        ])

        try await fixture.download(using: server)

        #expect(try Data(contentsOf: fixture.file.localURL) == fixture.payload)
        #expect(ModelVerifier(manifest: fixture.manifest).isVerifiedFromCache(fixture.file))
    }

    @Test("Declared N-1 and N+1 bodies are never accepted")
    func offByOneLengthsAreRejected() async throws {
        for body in [Data(DownloadFixture.defaultPayload.dropLast()),
                     DownloadFixture.defaultPayload + Data([0xff])] {
            let fixture = try DownloadFixture()
            defer { fixture.remove() }
            let server = StubServer(responses: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Length": "\(body.count)"],
                    chunks: [body]),
            ])

            await expectDownloadFailure {
                try await fixture.download(using: server)
            }

            #expect(!FileProbe.exists(fixture.file.localURL))
            #expect(!FileProbe.exists(fixture.file.partURL))
            #expect(!FileProbe.exists(fixture.file.metadataURL))
        }
    }

    @Test("Exact-size bytes with the wrong SHA are removed")
    func checksumMismatch() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let wrongBody = Data(repeating: 0x5a, count: fixture.payload.count)
        let server = StubServer(responses: [
            .init(
                statusCode: 200,
                headers: ["Content-Length": "\(wrongBody.count)"],
                chunks: [wrongBody]),
        ])

        await expectDownloadFailure {
            try await fixture.download(using: server)
        }

        #expect(!FileProbe.exists(fixture.file.localURL))
        #expect(!FileProbe.exists(fixture.file.partURL))
        #expect(!FileProbe.exists(fixture.file.metadataURL))
        #expect(!FileProbe.exists(fixture.file.verificationURL))
    }

    @Test("Cancellation preserves a valid pair and the next request resumes it")
    func cancellationAndResume() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let prefixCount = 7
        let prefix = Data(fixture.payload.prefix(prefixCount))
        let suffix = Data(fixture.payload.dropFirst(prefixCount))
        try fixture.writePart(prefix, etag: "\"model-v1\"")

        let releaseFirstResponse = DispatchSemaphore(value: 0)
        defer { releaseFirstResponse.signal() }
        let partialHeaders = [
            "Content-Length": "\(suffix.count)",
            "Content-Range": "bytes \(prefixCount)-\(fixture.payload.count - 1)/\(fixture.payload.count)",
            "ETag": "\"model-v1\"",
        ]
        let server = StubServer(responses: [
            .init(
                statusCode: 206,
                headers: partialHeaders,
                chunks: [suffix],
                beforeResponse: {
                    _ = releaseFirstResponse.wait(timeout: .now() + 60)
                }),
            .init(
                statusCode: 206,
                headers: partialHeaders,
                chunks: [suffix]),
        ])

        let firstDownload = Task {
            try await fixture.download(using: server)
        }
        try await waitUntil {
            server.requests.count == 1
        }
        firstDownload.cancel()
        releaseFirstResponse.signal()
        do {
            try await firstDownload.value
            Issue.record("Cancelled download unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Cancelled download returned \(error)")
        }

        #expect(try Data(contentsOf: fixture.file.partURL) == prefix)
        let metadata = try JSONDecoder().decode(
            ResumableDownloadMetadata.self,
            from: Data(contentsOf: fixture.file.metadataURL))
        #expect(metadata.manifestSchema == fixture.manifest.schema)
        #expect(metadata.manifestVersion == fixture.manifest.version)
        #expect(metadata.sourceRevision == fixture.component.revision)
        #expect(metadata.expectedSize == Int64(fixture.payload.count))
        #expect(metadata.sha256 == fixture.file.sha256)
        #expect(metadata.strongETag == "\"model-v1\"")

        try await fixture.download(using: server)

        #expect(try Data(contentsOf: fixture.file.localURL) == fixture.payload)
        #expect(server.requests.count == 2)
        #expect(server.requests[1].value(forHTTPHeaderField: "Range") == "bytes=\(prefixCount)-")
        #expect(server.requests[1].value(forHTTPHeaderField: "If-Range") == "\"model-v1\"")
    }

    @Test("Byte progress is bounded while ready, done, and complete are mandatory")
    func boundedAndFinalProgress() async throws {
        let root = try makeDownloadDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = ModelManifest(schema: "test.download-manifest", version: 11)
        let readyPayload = Data("already verified".utf8)
        let downloadPayload = Data((0..<128).map(UInt8.init))
        let readyFile = makeFile(name: "ready.bin", payload: readyPayload, root: root)
        let downloadFile = makeFile(name: "download.bin", payload: downloadPayload, root: root)
        let component = makeComponent(files: [readyFile, downloadFile])
        try writeDownloadData(readyPayload, to: readyFile.localURL)
        #expect(ModelVerifier(manifest: manifest).verify(readyFile) == .verified)

        let server = StubServer(responses: [
            .init(
                statusCode: 200,
                headers: ["Content-Length": "\(downloadPayload.count)"],
                chunks: downloadPayload.map { Data([$0]) }),
        ])
        let recorder = ProgressRecorder()

        try await runDownload(
            component: component,
            manifest: manifest,
            server: server,
            progress: { fraction, message in
                recorder.append(fraction: fraction, message: message)
            })

        let events = recorder.events
        #expect(events.contains { $0.message == "ready.bin · ready" })
        #expect(events.contains { $0.message == "download.bin · done" })
        #expect(events.last?.fraction == 1)
        #expect(events.last?.message == "Complete")

        let byteEvents = events.filter {
            !$0.message.hasSuffix(" · ready")
                && !$0.message.hasSuffix(" · done")
                && $0.message != "Complete"
        }
        for (earlier, later) in zip(byteEvents, byteEvents.dropFirst()) {
            #expect(later.time - earlier.time >= 0.095)
        }
        #expect(byteEvents.count <= 2)
    }
}

private struct DownloadFixture: Sendable {
    static let defaultPayload = Data("manifest-exact-model-payload".utf8)

    let root: URL
    let manifest: ModelManifest
    let payload: Data
    let file: ModelFile
    let component: ModelComponent

    init(payload: Data = defaultPayload) throws {
        let root = try makeDownloadDirectory()
        let file = makeFile(name: "model.bin", payload: payload, root: root)
        self.root = root
        self.manifest = ModelManifest(schema: "test.download-manifest", version: 7)
        self.payload = payload
        self.file = file
        self.component = makeComponent(files: [file])
    }

    func fullHeaders(etag: String? = nil) -> [String: String] {
        var headers = ["Content-Length": "\(payload.count)"]
        if let etag { headers["ETag"] = etag }
        return headers
    }

    func writePart(_ data: Data, etag: String?) throws {
        try writeDownloadData(data, to: file.partURL)
        let metadata = ResumableDownloadMetadata(
            manifestSchema: manifest.schema,
            manifestVersion: manifest.version,
            sourceRevision: component.revision,
            sourceURL: component.url(for: file).absoluteString,
            expectedSize: file.expectedBytes,
            sha256: file.sha256,
            strongETag: etag)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: file.metadataURL, options: .atomic)
    }

    func download(using server: StubServer, attempts: Int = 1) async throws {
        try await runDownload(
            component: component,
            manifest: manifest,
            server: server,
            attempts: attempts)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func runDownload(
    component: ModelComponent,
    manifest: ModelManifest,
    server: StubServer,
    attempts: Int = 1,
    progress: @escaping ModelDownloadProgress = { _, _ in }
) async throws {
    try await ResumableDownloader.download(
        component: component,
        manifest: manifest,
        configuration: server.configuration,
        attempts: attempts,
        retrySleeper: { _ in },
        onProgress: progress)
}

private func makeComponent(files: [ModelFile]) -> ModelComponent {
    ModelComponent(
        id: "tiny-download",
        title: "Tiny download",
        subtitle: "Test fixture",
        icon: "shippingbox",
        repo: "test/tiny-download",
        revision: String(repeating: "b", count: 40),
        files: files)
}

private func makeFile(name: String, payload: Data, root: URL) -> ModelFile {
    ModelFile(
        remotePath: name,
        localURL: root.appendingPathComponent(name),
        isMain: true,
        expectedBytes: Int64(payload.count),
        sha256: downloadSHA256(payload))
}

private func makeDownloadDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ResumableDownloaderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeDownloadData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try data.write(to: url)
}

private func downloadSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func expectDownloadFailure(
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Download unexpectedly succeeded")
    } catch {
        // Expected.
    }
}

private enum WaitError: Error {
    case timedOut
}

private func waitUntil(_ condition: () -> Bool) async throws {
    // Hosted runners can take several seconds to schedule the URLProtocol data delegate.
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw WaitError.timedOut
}

private final class ProgressRecorder: @unchecked Sendable {
    struct Event: Sendable {
        let time: TimeInterval
        let fraction: Double
        let message: String
    }

    private let lock = NSLock()
    private var storage: [Event] = []

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(fraction: Double, message: String) {
        lock.lock()
        storage.append(Event(
            time: ProcessInfo.processInfo.systemUptime,
            fraction: fraction,
            message: message))
        lock.unlock()
    }
}

private struct StubResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let chunks: [Data]
    let chunkDelayNanoseconds: UInt64
    let beforeResponse: (@Sendable () -> Void)?

    init(
        statusCode: Int,
        headers: [String: String],
        chunks: [Data],
        chunkDelayNanoseconds: UInt64 = 0,
        beforeResponse: (@Sendable () -> Void)? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.chunks = chunks
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
        self.beforeResponse = beforeResponse
    }
}

private final class StubServer: @unchecked Sendable {
    private let id = UUID().uuidString
    private let lock = NSLock()
    private var queuedResponses: [StubResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [StubResponse]) {
        self.queuedResponses = responses
        DownloaderURLProtocol.register(self, id: id)
    }

    deinit {
        DownloaderURLProtocol.unregister(id: id)
    }

    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloaderURLProtocol.self]
        configuration.httpAdditionalHeaders = [DownloaderURLProtocol.serverHeader: id]
        return configuration
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func response(for request: URLRequest) -> StubResponse? {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        guard !queuedResponses.isEmpty else { return nil }
        return queuedResponses.removeFirst()
    }
}

private final class DownloaderURLProtocol: URLProtocol, @unchecked Sendable {
    static let serverHeader = "X-Twisterminigen-Test-Server"

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var servers: [String: WeakStubServer] = [:]

    private let stateLock = NSLock()
    private var stopped = false
    private var deliveryWorkItem: DispatchWorkItem?

    static func register(_ server: StubServer, id: String) {
        registryLock.lock()
        servers[id] = WeakStubServer(server)
        registryLock.unlock()
    }

    static func unregister(id: String) {
        registryLock.lock()
        servers[id] = nil
        registryLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: serverHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let serverID = request.value(forHTTPHeaderField: Self.serverHeader),
              let server = Self.server(id: serverID),
              let responsePlan = server.response(for: request),
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: responsePlan.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: responsePlan.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            responsePlan.beforeResponse?()
            guard !self.isStopped else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            for (index, chunk) in responsePlan.chunks.enumerated() {
                if index > 0, responsePlan.chunkDelayNanoseconds > 0 {
                    Thread.sleep(
                        forTimeInterval: Double(responsePlan.chunkDelayNanoseconds) / 1_000_000_000)
                }
                guard !self.isStopped else { return }
                self.client?.urlProtocol(self, didLoad: chunk)
            }

            guard !self.isStopped else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }

        stateLock.lock()
        deliveryWorkItem = workItem
        let stopNow = stopped
        stateLock.unlock()
        if stopNow {
            workItem.cancel()
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        let workItem = deliveryWorkItem
        stateLock.unlock()
        workItem?.cancel()
    }

    private static func server(id: String) -> StubServer? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return servers[id]?.value
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }
}

private final class WeakStubServer: @unchecked Sendable {
    weak var value: StubServer?

    init(_ value: StubServer) {
        self.value = value
    }
}
