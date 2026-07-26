import CryptoKit
import Foundation
import Testing
@testable import Twisterminigen

@Suite("Model store")
struct ModelStoreTests {
    @Test("Downloaded requires every file and a missing small config is partial")
    func allFilesAreRequired() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = ModelStore(catalog: fixture.catalog)

        let missing = try #require(await store.status(id: fixture.component.id))
        #expect(missing.state == .missing)

        try fixture.writeWeight()
        let partial = try #require(await store.status(id: fixture.component.id))
        #expect(partial.state == .partial)

        try fixture.writeConfig()
        let downloaded = try #require(await store.status(id: fixture.component.id))
        #expect(downloaded.state == .downloaded)
        #expect(FileManager.default.fileExists(atPath: fixture.config.verificationURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.weight.verificationURL.path))
    }

    @Test("One changed byte marks an exact-size component corrupted")
    func oneByteCorruption() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.writeAll()
        let store = ModelStore(catalog: fixture.catalog)
        #expect(await store.status(id: fixture.component.id)?.state == .downloaded)

        var corrupted = fixture.weightPayload
        corrupted[corrupted.startIndex] ^= 0xff
        try writeStoreData(corrupted, to: fixture.weight.localURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.weight.localURL.path)
        let modificationDate = try #require(attributes[.modificationDate] as? Date)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate.addingTimeInterval(10)],
            ofItemAtPath: fixture.weight.localURL.path)

        let status = try #require(await store.status(id: fixture.component.id))
        #expect(status.state == .corrupted)
        #expect(status.state != .partial)
        #expect(status.state.rawValue == "corrupted")
        #expect(!FileManager.default.fileExists(atPath: fixture.weight.verificationURL.path))
    }

    @Test("Delete removes final, part, metadata, and verification artifacts")
    func deleteRemovesEveryArtifact() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let artifacts = [
            fixture.weight.localURL,
            fixture.weight.partURL,
            fixture.weight.metadataURL,
            fixture.weight.partURL.appendingPathExtension("meta"),
            fixture.weight.verificationURL,
        ]
        for (index, url) in artifacts.enumerated() {
            try writeStoreData(Data(repeating: UInt8(index), count: index + 1), to: url)
        }
        let store = ModelStore(catalog: fixture.catalog)

        let freed = await store.delete(id: fixture.component.id)

        #expect(freed == 15)
        #expect(artifacts.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("A suspended download lease gates reentrant delete and duplicate download")
    func concurrentDeleteIsGated() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.writeAll()
        let gate = DownloadGate()
        let store = ModelStore(
            catalog: fixture.catalog,
            downloader: { _, progress in
                progress(0.5, "held")
                await gate.hold()
            },
            capacityLookup: { _ in 1_000_000 },
            diskSafetyMarginBytes: 0)

        let download = Task {
            try await store.download(id: fixture.component.id) { _, _ in }
        }
        await gate.waitUntilStarted()

        let freedWhileBusy = await store.delete(id: fixture.component.id)
        #expect(freedWhileBusy == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.weight.localURL.path))
        do {
            try await store.download(id: fixture.component.id) { _, _ in }
            Issue.record("A duplicate download acquired the same component lease")
        } catch ModelStoreError.componentBusy(let id) {
            #expect(id == fixture.component.id)
        } catch {
            Issue.record("Unexpected duplicate-download error: \(error)")
        }

        await gate.release()
        try await download.value

        let freedAfterRelease = await store.delete(id: fixture.component.id)
        #expect(freedAfterRelease > 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.weight.localURL.path))
    }

    @Test("Capacity lookup climbs to the nearest existing parent")
    func missingParentCapacityLookup() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let missingDestination = fixture.root
            .appendingPathComponent("not-created", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        var lookupURL: URL?

        let capacity = ModelDiskCapacity.capacity(
            for: missingDestination,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            importantUsageCapacity: { existing in
                lookupURL = existing
                return 42
            })

        #expect(capacity == 42)
        #expect(lookupURL == fixture.root.standardizedFileURL)
    }

    @Test("Unknown disk capacity fails explicitly before download")
    func unknownCapacityIsAnError() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = ModelStore(
            catalog: fixture.catalog,
            downloader: { _, _ in },
            capacityLookup: { _ in nil },
            diskSafetyMarginBytes: 0)

        do {
            try await store.download(id: fixture.component.id) { _, _ in }
            Issue.record("Download started without a known disk capacity")
        } catch ModelStoreError.diskCapacityUnavailable(let root) {
            #expect(root == fixture.root)
        } catch {
            Issue.record("Unexpected capacity error: \(error)")
        }
    }

    @Test("Root switch is gated by an active component mutation")
    func rootSwitchBusyGate() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.writeAll()
        let gate = DownloadGate()
        let store = ModelStore(
            catalog: fixture.catalog,
            downloader: { _, _ in await gate.hold() },
            capacityLookup: { _ in 1_000_000 },
            diskSafetyMarginBytes: 0)
        let replacementRoot = fixture.root
            .appendingPathComponent("replacement", isDirectory: true)

        let download = Task {
            try await store.download(id: fixture.component.id) { _, _ in }
        }
        await gate.waitUntilStarted()

        do {
            _ = try await store.switchRoot(to: replacementRoot)
            Issue.record("Root switched while a component mutation was active")
        } catch ModelStoreError.catalogBusy {
            #expect(await store.catalogSnapshot().root == fixture.root)
        } catch {
            Issue.record("Unexpected root-switch error: \(error)")
        }

        await gate.release()
        try await download.value

        let replacement = try await store.switchRoot(to: replacementRoot)
        #expect(replacement.root == replacementRoot.standardizedFileURL)
        #expect(await store.catalogSnapshot().root == replacementRoot.standardizedFileURL)
    }
}

private struct StoreFixture: Sendable {
    let root: URL
    let configPayload = Data("{\"tiny\":true}".utf8)
    let weightPayload = Data([0x10, 0x20, 0x30, 0x40])
    let config: ModelFile
    let weight: ModelFile
    let component: ModelComponent
    let catalog: ModelCatalog

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configPayload = Data("{\"tiny\":true}".utf8)
        let weightPayload = Data([0x10, 0x20, 0x30, 0x40])
        let config = ModelFile(
            remotePath: "config.json",
            localURL: root.appendingPathComponent("component/config.json"),
            isMain: false,
            expectedBytes: Int64(configPayload.count),
            sha256: storeSHA256(configPayload))
        let weight = ModelFile(
            remotePath: "weight.bin",
            localURL: root.appendingPathComponent("component/weight.bin"),
            isMain: true,
            expectedBytes: Int64(weightPayload.count),
            sha256: storeSHA256(weightPayload))
        let component = ModelComponent(
            id: "tiny-component",
            title: "Tiny",
            subtitle: "Test fixture",
            icon: "shippingbox",
            repo: "test/tiny",
            revision: String(repeating: "a", count: 40),
            files: [config, weight])

        self.root = root
        self.config = config
        self.weight = weight
        self.component = component
        self.catalog = ModelCatalog(
            root: root,
            manifest: ModelManifest(schema: "test.model-manifest", version: 1),
            components: [component])
    }

    func writeConfig() throws {
        try writeStoreData(configPayload, to: config.localURL)
    }

    func writeWeight() throws {
        try writeStoreData(weightPayload, to: weight.localURL)
    }

    func writeAll() throws {
        try writeConfig()
        try writeWeight()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor DownloadGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func writeStoreData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try data.write(to: url)
}

private func storeSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
