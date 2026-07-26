import CryptoKit
import Foundation
import Testing
@testable import Twisterminigen

@Suite("Describe Image")
struct DescribeImageTests {
    @Test("Pinned assistant manifest is complete and revision-addressed")
    func manifestIsPinned() throws {
        let catalog = DescribeImageModel.catalog(root: URL(fileURLWithPath: "/tmp/describe-model"))
        let component = try #require(catalog.component(id: DescribeImageModel.componentID))

        #expect(component.repo == "mlx-community/Qwen3-VL-4B-Instruct-8bit")
        #expect(component.revision == "0943db6e15185b86be368d3cf0704aec740b142b")
        #expect(component.files.count == 12)
        #expect(component.expectedBytes == 5_116_417_767)
        #expect(component.mainFile.localURL.lastPathComponent == "model.safetensors")
        #expect(component.files.allSatisfy { file in
            component.url(for: file).absoluteString.contains(component.revision)
        })
    }

    @Test("Input policy rejects empty, oversized, and decompression-bomb dimensions")
    func inputPolicyBounds() throws {
        let policy = DescribeImageInputPolicy(
            maximumFileBytes: 100,
            maximumSourcePixels: 1_000,
            maximumSourceDimension: 100,
            thumbnailDimension: 64)

        #expect(throws: DescribeImageError.emptyFile) {
            try policy.validate(fileBytes: 0, width: 10, height: 10)
        }
        #expect(throws: DescribeImageError.fileTooLarge(maxBytes: 100)) {
            try policy.validate(fileBytes: 101, width: 10, height: 10)
        }
        #expect(throws: DescribeImageError.imageTooLarge(maxPixels: 1_000)) {
            try policy.validate(fileBytes: 10, width: 50, height: 50)
        }
        try policy.validate(fileBytes: 10, width: 25, height: 40)
    }

    @Test("Output removes hidden reasoning, trims, and rejects empty results")
    func outputCleaning() throws {
        let cleaned = try DescribeImageOutput.cleaned(
            "  <think>private chain of thought</think> A red bicycle beside a blue wall.  ")
        #expect(cleaned == "A red bicycle beside a blue wall.")
        #expect(throws: DescribeImageError.emptyDescription) {
            try DescribeImageOutput.cleaned("<think>nothing visible</think>")
        }
        #expect(try DescribeImageOutput.cleaned("usable prefix <think>unterminated") == "usable prefix")
        let oversized = try DescribeImageOutput.cleaned(
            String(repeating: "x", count: DescribeImageOutput.maximumCharacters + 100))
        #expect(oversized.count == DescribeImageOutput.maximumCharacters)
    }

    @Test("Service owns and releases a distinct Describe inference lease")
    @MainActor
    func serviceLeaseSuccess() async throws {
        let probe = DescribeBackendProbe(result: "a quiet harbor at dawn")
        let coordinator = InferenceCoordinator()
        let service = DescribeImageService(coordinator: coordinator, backend: probe)

        let task = Task {
            try await service.describe(imageURL: URL(fileURLWithPath: "/tmp/reference.png")) { _ in }
        }
        await probe.waitUntilStarted()
        #expect(coordinator.activeOperation == .describe)
        #expect(coordinator.phase == .describing)

        await probe.release()
        #expect(try await task.value == "a quiet harbor at dawn")
        #expect(coordinator.activeOperation == nil)
        #expect(coordinator.phase == .idle)
    }

    @Test("Describe refuses while another inference operation owns MLX")
    @MainActor
    func busyCoordinatorRejects() async throws {
        let coordinator = InferenceCoordinator()
        let generateLease = try #require(coordinator.begin(.generate))
        let probe = DescribeBackendProbe(result: "unused")
        let service = DescribeImageService(coordinator: coordinator, backend: probe)

        await #expect(throws: DescribeImageError.self) {
            _ = try await service.describe(
                imageURL: URL(fileURLWithPath: "/tmp/reference.png")) { _ in }
        }
        #expect(await probe.callCount == 0)
        #expect(coordinator.activeOperation == .generate)
        coordinator.finish(generateLease)
    }

    @Test("Cancellation marks stopping and keeps lease until backend actually exits")
    @MainActor
    func cancellationContract() async throws {
        let probe = DescribeBackendProbe(result: "unused", cancellationDelay: .milliseconds(60))
        let coordinator = InferenceCoordinator()
        let service = DescribeImageService(coordinator: coordinator, backend: probe)
        let task = Task {
            try await service.describe(imageURL: URL(fileURLWithPath: "/tmp/reference.png")) { _ in }
        }

        await probe.waitUntilStarted()
        service.cancel()
        #expect(coordinator.phase == .stopping)
        #expect(coordinator.activeOperation == .describe)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(coordinator.phase == .stopping)
        #expect(coordinator.activeOperation == .describe)

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(coordinator.phase == .idle)
        #expect(coordinator.activeOperation == nil)
    }

    @Test("Backend failure clears ownership and leaves an observable failed phase")
    @MainActor
    func failureContract() async {
        let backend = StubDescribeBackend { _, _ in throw DescribeImageError.unreadableImage }
        let coordinator = InferenceCoordinator()
        let service = DescribeImageService(coordinator: coordinator, backend: backend)

        await #expect(throws: DescribeImageError.unreadableImage) {
            _ = try await service.describe(
                imageURL: URL(fileURLWithPath: "/tmp/reference.png")) { _ in }
        }
        #expect(coordinator.activeOperation == nil)
        if case .failed = coordinator.phase {
            // expected
        } else {
            Issue.record("Expected failed coordinator phase")
        }
    }

    @Test("View model never starts inference before explicit Describe")
    @MainActor
    func viewModelRequiresExplicitAction() async {
        let coordinator = InferenceCoordinator()
        let backend = StubDescribeBackend { _, progress in
            progress(.analyzing)
            return "sunlit glass greenhouse"
        }
        let models = StubDescribeModelManager(state: .downloaded)
        let viewModel = DescribeImageViewModel(
            coordinator: coordinator,
            backend: backend,
            modelManager: models)

        await viewModel.refreshModelStatus()
        viewModel.selectImage(URL(fileURLWithPath: "/tmp/reference.png"))
        #expect(viewModel.descriptionText.isEmpty)
        #expect(coordinator.activeOperation == nil)

        await viewModel.describeAndWait()
        #expect(viewModel.descriptionText == "sunlit glass greenhouse")
        #expect(viewModel.activity == .idle)
        #expect(coordinator.activeOperation == nil)
    }

    @Test("Optional assistant store reuses verified resumable model infrastructure")
    func modelStoreRoundTrip() async throws {
        let fixture = try DescribeModelStoreFixture()
        defer { fixture.remove() }

        let store = DescribeImageModelStore(
            catalog: fixture.catalog,
            downloader: { component, progress in
                let file = component.mainFile
                try FileManager.default.createDirectory(
                    at: file.localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fixture.payload.write(to: file.localURL)
                progress(1, "done")
            },
            capacityLookup: { _ in Int64.max },
            diskSafetyMarginBytes: 0)

        #expect(await store.status().state == .missing)
        try await store.install { _, _ in }
        #expect(await store.status().state == .downloaded)
        #expect(await store.remove() >= Int64(fixture.payload.count))
        #expect(await store.status().state == .missing)
    }
}

private struct StubDescribeBackend: DescribeImageBackend {
    let handler: @Sendable (
        URL,
        @escaping @Sendable (DescribeImageProgress) -> Void
    ) async throws -> String

    init(handler: @escaping @Sendable (
        URL,
        @escaping @Sendable (DescribeImageProgress) -> Void
    ) async throws -> String) {
        self.handler = handler
    }

    func describe(
        imageURL: URL,
        onProgress: @escaping @Sendable (DescribeImageProgress) -> Void
    ) async throws -> String {
        try await handler(imageURL, onProgress)
    }
}

private actor DescribeBackendProbe: DescribeImageBackend {
    let result: String
    let cancellationDelay: Duration
    private(set) var callCount = 0
    private var started = false
    private var released = false

    init(result: String, cancellationDelay: Duration = .zero) {
        self.result = result
        self.cancellationDelay = cancellationDelay
    }

    func describe(
        imageURL _: URL,
        onProgress: @escaping @Sendable (DescribeImageProgress) -> Void
    ) async throws -> String {
        callCount += 1
        started = true
        onProgress(.loadingModel)
        do {
            while !released {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
            return result
        } catch is CancellationError {
            if cancellationDelay > .zero {
                let delay = cancellationDelay
                await Task.detached {
                    try? await Task.sleep(for: delay)
                }.value
            }
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() { released = true }
}

private actor StubDescribeModelManager: DescribeImageModelManaging {
    private var current: ComponentState

    init(state: ComponentState) { current = state }

    func status() -> ComponentStatus {
        ComponentStatus(
            id: DescribeImageModel.componentID,
            title: DescribeImageModel.title,
            subtitle: "test",
            icon: "photo",
            expectedBytes: 10,
            onDiskBytes: current == .downloaded ? 10 : 0,
            state: current)
    }

    func install(onProgress: @escaping ModelDownloadProgress) async throws {
        onProgress(1, "done")
        current = .downloaded
    }

    func remove() -> Int64 {
        current = .missing
        return 10
    }
}

private final class DescribeModelStoreFixture: @unchecked Sendable {
    let root: URL
    let payload = Data("tiny-assistant".utf8)
    let catalog: ModelCatalog

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("describe-model-store-\(UUID().uuidString)", isDirectory: true)
        let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let file = ModelFile(
            remotePath: "model.safetensors",
            localURL: root.appendingPathComponent("model.safetensors"),
            isMain: true,
            expectedBytes: Int64(payload.count),
            sha256: sha)
        let component = ModelComponent(
            id: DescribeImageModel.componentID,
            title: "test",
            subtitle: "test",
            icon: "photo",
            repo: "test/repo",
            revision: String(repeating: "a", count: 40),
            files: [file])
        catalog = ModelCatalog(root: root, manifest: .current, components: [component])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
