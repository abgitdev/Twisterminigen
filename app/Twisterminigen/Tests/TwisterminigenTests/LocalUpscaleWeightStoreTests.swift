import CryptoKit
import Foundation
import Testing
@testable import Twisterminigen

@Suite("Local upscale weight store")
struct LocalUpscaleWeightStoreTests {
    @Test("Download is gated by exact license acceptance before transport")
    func licenseGatePrecedesTransport() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("upscale fixture".utf8)
        let manifest = makeManifest(data: data)
        let probe = DownloadProbe()
        let store = LocalUpscaleWeightStore(
            directory: directory,
            manifest: manifest,
            downloader: { _, _ in await probe.markCalled() },
            capacityLookup: { _ in 1_000_000 },
            diskSafetyMarginBytes: 0)

        #expect(await store.state(acceptance: nil) == .licenseRequired)
        do {
            try await store.download(
                acceptance: LocalUpscaleLicenseAcceptance(
                    manifestIdentity: "stale",
                    licenseIdentifier: manifest.license.identifier,
                    noticeSHA256: manifest.license.noticeSHA256),
                onProgress: { _, _ in })
            Issue.record("Stale license acceptance authorized a download")
        } catch let error as LocalUpscaleManifestError {
            #expect(error == .licenseNotAccepted)
        }
        #expect(!(await probe.wasCalled()))
    }

    @Test("Injected resumable transport must produce exact verified bytes before ready")
    func verifiedDownload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("verified upscale fixture".utf8)
        let manifest = makeManifest(data: data)
        let acceptance = LocalUpscaleLicenseAcceptance.accepting(manifest)
        let store = LocalUpscaleWeightStore(
            directory: directory,
            manifest: manifest,
            downloader: { component, progress in
                let file = try #require(component.files.first)
                try FileManager.default.createDirectory(
                    at: file.localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: file.localURL, options: .atomic)
                progress(1, "fixture complete")
            },
            capacityLookup: { _ in 1_000_000 },
            diskSafetyMarginBytes: 0)

        #expect(await store.state(acceptance: acceptance) == .missing)
        try await store.download(acceptance: acceptance, onProgress: { _, _ in })
        #expect(await store.state(acceptance: acceptance) == .ready)
        let verified = try await store.verifiedArtifacts(acceptance: acceptance)
        #expect(try Data(contentsOf: #require(verified["model.safetensors"])) == data)
    }

    @Test("Corrupt transport result never becomes ready")
    func corruptDownloadFails() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = makeManifest(data: Data("expected".utf8))
        let acceptance = LocalUpscaleLicenseAcceptance.accepting(manifest)
        let store = LocalUpscaleWeightStore(
            directory: directory,
            manifest: manifest,
            downloader: { component, _ in
                let file = try #require(component.files.first)
                try Data("tampered".utf8).write(to: file.localURL, options: .atomic)
            },
            capacityLookup: { _ in 1_000_000 },
            diskSafetyMarginBytes: 0)

        do {
            try await store.download(acceptance: acceptance, onProgress: { _, _ in })
            Issue.record("Corrupt downloaded bytes were accepted")
        } catch let error as LocalUpscaleWeightStoreError {
            guard case .verificationFailed = error else {
                Issue.record("Unexpected store error: \(error)")
                return
            }
        }
        guard case .corrupted = await store.state(acceptance: acceptance) else {
            Issue.record("Corrupt weight did not remain visibly corrupt")
            return
        }
    }

    private func makeManifest(data: Data) -> LocalUpscaleWeightManifest {
        let revision = String(repeating: "b", count: 40)
        return LocalUpscaleWeightManifest(
            repositoryID: "test/upscaler",
            revision: revision,
            model: LocalUpscaleModel(
                id: "test/upscaler",
                displayName: "Test ×4",
                nativeFactor: .fourX,
                revision: revision),
            artifacts: [LocalUpscaleWeightArtifact(
                remotePath: "model.safetensors",
                filename: "model.safetensors",
                expectedBytes: Int64(data.count),
                expectedSHA256: SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined())],
            license: LocalUpscaleWeightManifest.realESRGANGeneralX4V3.license)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Twister-upscale-store-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor DownloadProbe {
    private var called = false
    func markCalled() { called = true }
    func wasCalled() -> Bool { called }
}
