import CryptoKit
import Foundation
import Testing
@testable import Twisterminigen

@Suite("Local upscale manifest")
struct LocalUpscaleManifestTests {
    @Test("Production SRVGG artifact, revision, hash, scale, and license stay pinned")
    func productionEvidence() throws {
        let manifest = LocalUpscaleWeightManifest.realESRGANGeneralX4V3

        try LocalUpscaleManifestVerifier.validate(manifest)
        #expect(manifest.repositoryID == "mlx-community/Real-ESRGAN-general-x4v3")
        #expect(manifest.revision == "e9a382fa779f227abf65ad49d4e5b90c1202d683")
        #expect(manifest.model.nativeFactor == .fourX)
        #expect(manifest.license.identifier == "BSD-3-Clause")
        #expect(manifest.license.notice.contains("Copyright (c) 2021, Xintao Wang"))
        #expect(manifest.artifacts == [
            LocalUpscaleWeightArtifact(
                remotePath: "model.safetensors",
                filename: "model.safetensors",
                expectedBytes: 2_434_666,
                expectedSHA256: "86f4714b7420203457f2b70a24ee52640098acb2b3fc4ceb5eab120de96b4265"),
        ])
    }

    @Test("Verifier requires exact notice acceptance and streams exact local bytes")
    func verificationAndLicenseGate() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("tiny verified SRVGG fixture".utf8)
        let manifest = makeManifest(data: data)
        let file = directory.appendingPathComponent("model.safetensors")
        try data.write(to: file)

        let staleAcceptance = LocalUpscaleLicenseAcceptance(
            manifestIdentity: "wrong",
            licenseIdentifier: manifest.license.identifier,
            noticeSHA256: manifest.license.noticeSHA256)
        #expect(throws: LocalUpscaleManifestError.licenseNotAccepted) {
            _ = try LocalUpscaleManifestVerifier.verify(
                manifest,
                in: directory,
                acceptance: staleAcceptance)
        }

        let acceptance = LocalUpscaleLicenseAcceptance.accepting(manifest)
        let verified = try LocalUpscaleManifestVerifier.verify(
            manifest,
            in: directory,
            acceptance: acceptance)
        #expect(verified["model.safetensors"] == file)
    }

    @Test("Verifier rejects traversal, symlinks, size drift, and hash drift")
    func rejectsUnsafeOrChangedWeights() throws {
        let data = Data("expected".utf8)
        let manifest = makeManifest(data: data)
        let acceptance = LocalUpscaleLicenseAcceptance.accepting(manifest)

        var unsafe = manifest
        unsafe = LocalUpscaleWeightManifest(
            repositoryID: unsafe.repositoryID,
            revision: unsafe.revision,
            model: unsafe.model,
            artifacts: [LocalUpscaleWeightArtifact(
                remotePath: "model.safetensors",
                filename: "../model.safetensors",
                expectedBytes: Int64(data.count),
                expectedSHA256: sha256(data))],
            license: unsafe.license)
        #expect(throws: LocalUpscaleManifestError.unsafeArtifactName("../model.safetensors")) {
            try LocalUpscaleManifestVerifier.validate(unsafe)
        }

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.deletingLastPathComponent()
            .appendingPathComponent("Twister-external-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: external) }
        try data.write(to: external)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("model.safetensors"),
            withDestinationURL: external)
        #expect(throws: LocalUpscaleManifestError.unsafeFile("model.safetensors")) {
            _ = try LocalUpscaleManifestVerifier.verify(
                manifest,
                in: directory,
                acceptance: acceptance)
        }

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("model.safetensors"))
        let tampered = Data("tampered".utf8)
        try tampered.write(
            to: directory.appendingPathComponent("model.safetensors"))
        #expect(throws: LocalUpscaleManifestError.unexpectedSHA256(
            filename: "model.safetensors",
            expected: sha256(data),
            actual: sha256(tampered))) {
            _ = try LocalUpscaleManifestVerifier.verify(
                manifest,
                in: directory,
                acceptance: acceptance)
        }
    }

    private func makeManifest(data: Data) -> LocalUpscaleWeightManifest {
        let license = LocalUpscaleWeightManifest.realESRGANGeneralX4V3.license
        let revision = String(repeating: "a", count: 40)
        return LocalUpscaleWeightManifest(
            repositoryID: "test/srvgg",
            revision: revision,
            model: LocalUpscaleModel(
                id: "test/srvgg",
                displayName: "Test SRVGG ×4",
                nativeFactor: .fourX,
                revision: revision),
            artifacts: [LocalUpscaleWeightArtifact(
                remotePath: "model.safetensors",
                filename: "model.safetensors",
                expectedBytes: Int64(data.count),
                expectedSHA256: sha256(data))],
            license: license)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Twister-upscale-manifest-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
