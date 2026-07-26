import CryptoKit
import Darwin
import Foundation

struct LocalUpscaleLicenseEvidence: Codable, Sendable, Hashable {
    let identifier: String
    let displayName: String
    let sourceURL: URL
    let modelCardURL: URL
    let copyrightNotice: String
    /// Full notice embedded for offline attribution and binary redistribution compliance.
    let notice: String

    var noticeSHA256: String {
        SHA256.hash(data: Data(notice.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct LocalUpscaleWeightArtifact: Codable, Sendable, Hashable {
    let remotePath: String
    let filename: String
    let expectedBytes: Int64
    let expectedSHA256: String

    init(remotePath: String, filename: String, expectedBytes: Int64, expectedSHA256: String) {
        self.remotePath = remotePath
        self.filename = filename
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256.lowercased()
    }
}

/// Immutable evidence for an optional, separately downloaded local upscaler. No weights are
/// bundled. The revision, byte count, and SHA-256 below were rechecked against the Hub API at the
/// pinned commit on 2026-07-15.
struct LocalUpscaleWeightManifest: Codable, Sendable, Hashable {
    let repositoryID: String
    let revision: String
    let model: LocalUpscaleModel
    let artifacts: [LocalUpscaleWeightArtifact]
    let license: LocalUpscaleLicenseEvidence

    var identity: String {
        var fields = [repositoryID, revision, model.id, model.revision, license.noticeSHA256]
        for artifact in artifacts.sorted(by: { $0.filename < $1.filename }) {
            fields.append(
                "\(artifact.remotePath):\(artifact.filename):\(artifact.expectedBytes):\(artifact.expectedSHA256)")
        }
        return SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static let realESRGANGeneralX4V3: Self = {
        let revision = "e9a382fa779f227abf65ad49d4e5b90c1202d683"
        return Self(
            repositoryID: "mlx-community/Real-ESRGAN-general-x4v3",
            revision: revision,
            model: LocalUpscaleModel(
                id: "mlx-community/Real-ESRGAN-general-x4v3",
                displayName: "Real-ESRGAN General ×4 (MLX)",
                nativeFactor: .fourX,
                revision: revision),
            artifacts: [
                LocalUpscaleWeightArtifact(
                    remotePath: "model.safetensors",
                    filename: "model.safetensors",
                    expectedBytes: 2_434_666,
                    expectedSHA256: "86f4714b7420203457f2b70a24ee52640098acb2b3fc4ceb5eab120de96b4265"),
            ],
            license: LocalUpscaleLicenseEvidence(
                identifier: "BSD-3-Clause",
                displayName: "BSD 3-Clause License",
                sourceURL: URL(string: "https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE")!,
                modelCardURL: URL(
                    string: "https://huggingface.co/mlx-community/Real-ESRGAN-general-x4v3/tree/\(revision)")!,
                copyrightNotice: "Copyright (c) 2021, Xintao Wang. All rights reserved.",
                notice: Self.realESRGANBSDNotice))
    }()

    private static let realESRGANBSDNotice = """
    BSD 3-Clause License

    Copyright (c) 2021, Xintao Wang
    All rights reserved.

    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
    3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """
}

/// Proof that the user was shown and accepted the exact offline notice for this immutable model.
/// A stale acceptance cannot authorize a different model revision or a changed notice.
struct LocalUpscaleLicenseAcceptance: Codable, Sendable, Hashable {
    let manifestIdentity: String
    let licenseIdentifier: String
    let noticeSHA256: String

    static func accepting(_ manifest: LocalUpscaleWeightManifest) -> Self {
        Self(
            manifestIdentity: manifest.identity,
            licenseIdentifier: manifest.license.identifier,
            noticeSHA256: manifest.license.noticeSHA256)
    }

    func validate(for manifest: LocalUpscaleWeightManifest) throws {
        guard manifestIdentity == manifest.identity,
              licenseIdentifier == manifest.license.identifier,
              noticeSHA256 == manifest.license.noticeSHA256 else {
            throw LocalUpscaleManifestError.licenseNotAccepted
        }
    }
}

enum LocalUpscaleManifestError: Error, LocalizedError, Equatable, Sendable {
    case unsafeRepositoryID(String)
    case invalidRevision(String)
    case inconsistentModelIdentity
    case inconsistentModelRevision
    case unsupportedFactor
    case missingArtifacts
    case unsupportedArtifacts
    case invalidLicenseEvidence
    case unsafeArtifactName(String)
    case duplicateArtifactName(String)
    case invalidArtifactSize(String)
    case invalidSHA256(String)
    case licenseNotAccepted
    case missingFile(String)
    case unsafeFile(String)
    case unexpectedByteCount(filename: String, expected: Int64, actual: Int64)
    case unexpectedSHA256(filename: String, expected: String, actual: String)
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .unsafeRepositoryID(let id): "The upscaler repository ID \(id) is invalid."
        case .invalidRevision(let revision): "The upscaler revision \(revision) is not an immutable commit SHA."
        case .inconsistentModelIdentity: "The upscaler model identity does not match its repository."
        case .inconsistentModelRevision: "The upscaler model and weight manifest revisions differ."
        case .unsupportedFactor: "This executor supports only the pinned native 4× architecture."
        case .missingArtifacts: "The upscaler manifest contains no weight artifact."
        case .unsupportedArtifacts: "The upscaler manifest is not the exact single-artifact SRVGG checkpoint."
        case .invalidLicenseEvidence: "The upscaler manifest is missing its BSD-3-Clause evidence."
        case .unsafeArtifactName(let name): "The upscaler artifact name \(name) is unsafe."
        case .duplicateArtifactName(let name): "The upscaler manifest repeats \(name)."
        case .invalidArtifactSize(let name): "The upscaler artifact \(name) has an invalid expected size."
        case .invalidSHA256(let hash): "The upscaler manifest contains an invalid SHA-256: \(hash)."
        case .licenseNotAccepted: "The exact upscaler license notice has not been accepted."
        case .missingFile(let name): "The local upscaler weight \(name) is missing."
        case .unsafeFile(let name): "The local upscaler weight \(name) is not a safe regular file."
        case .unexpectedByteCount(let name, let expected, let actual):
            "The local upscaler weight \(name) has \(actual) bytes; expected \(expected)."
        case .unexpectedSHA256(let name, let expected, let actual):
            "The local upscaler weight \(name) failed SHA-256 verification (expected \(expected), got \(actual))."
        case .unreadableFile(let name): "The local upscaler weight \(name) could not be read."
        }
    }
}

enum LocalUpscaleManifestVerifier {
    static func validate(_ manifest: LocalUpscaleWeightManifest) throws {
        let repoParts = manifest.repositoryID.split(separator: "/", omittingEmptySubsequences: false)
        guard repoParts.count == 2,
              repoParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LocalUpscaleManifestError.unsafeRepositoryID(manifest.repositoryID)
        }
        guard isLowercaseHex(manifest.revision, count: 40) else {
            throw LocalUpscaleManifestError.invalidRevision(manifest.revision)
        }
        guard manifest.model.id == manifest.repositoryID else {
            throw LocalUpscaleManifestError.inconsistentModelIdentity
        }
        guard manifest.model.revision == manifest.revision else {
            throw LocalUpscaleManifestError.inconsistentModelRevision
        }
        guard manifest.model.nativeFactor == .fourX else {
            throw LocalUpscaleManifestError.unsupportedFactor
        }
        guard !manifest.artifacts.isEmpty else {
            throw LocalUpscaleManifestError.missingArtifacts
        }
        guard manifest.license.identifier == "BSD-3-Clause",
              manifest.license.copyrightNotice.contains("Xintao Wang"),
              manifest.license.notice.contains("BSD 3-Clause License"),
              manifest.license.sourceURL.scheme == "https",
              manifest.license.modelCardURL.scheme == "https" else {
            throw LocalUpscaleManifestError.invalidLicenseEvidence
        }

        var names = Set<String>()
        for artifact in manifest.artifacts {
            try validatePathComponent(artifact.filename)
            try validatePathComponent(artifact.remotePath)
            guard names.insert(artifact.filename).inserted else {
                throw LocalUpscaleManifestError.duplicateArtifactName(artifact.filename)
            }
            guard artifact.expectedBytes > 0,
                  artifact.expectedBytes <= 8 * 1_073_741_824 else {
                throw LocalUpscaleManifestError.invalidArtifactSize(artifact.filename)
            }
            guard isLowercaseHex(artifact.expectedSHA256, count: 64) else {
                throw LocalUpscaleManifestError.invalidSHA256(artifact.expectedSHA256)
            }
        }
        guard manifest.artifacts.count == 1,
              manifest.artifacts.first?.filename == "model.safetensors",
              manifest.artifacts.first?.remotePath == "model.safetensors" else {
            throw LocalUpscaleManifestError.unsupportedArtifacts
        }
    }

    /// Streams every artifact after rejecting symlinks and non-regular files. The returned URLs are
    /// the only paths an executor may map as weights.
    static func verify(
        _ manifest: LocalUpscaleWeightManifest,
        in directory: URL,
        acceptance: LocalUpscaleLicenseAcceptance
    ) throws -> [String: URL] {
        try validate(manifest)
        try acceptance.validate(for: manifest)
        let root = directory.standardizedFileURL
        var verified: [String: URL] = [:]
        for artifact in manifest.artifacts {
            let url = root.appendingPathComponent(artifact.filename, isDirectory: false)
            guard url.deletingLastPathComponent().standardizedFileURL == root else {
                throw LocalUpscaleManifestError.unsafeFile(artifact.filename)
            }
            let inspection = try inspectRegularFile(url, name: artifact.filename)
            let actualBytes = inspection.bytes
            guard actualBytes == artifact.expectedBytes else {
                throw LocalUpscaleManifestError.unexpectedByteCount(
                    filename: artifact.filename,
                    expected: artifact.expectedBytes,
                    actual: actualBytes)
            }
            let actualHash = inspection.sha256
            guard actualHash == artifact.expectedSHA256 else {
                throw LocalUpscaleManifestError.unexpectedSHA256(
                    filename: artifact.filename,
                    expected: artifact.expectedSHA256,
                    actual: actualHash)
            }
            verified[artifact.filename] = url
        }
        return verified
    }

    static func sha256(of url: URL) throws -> String {
        try inspectRegularFile(url, name: url.lastPathComponent).sha256
    }

    /// Hashes the same O_NOFOLLOW descriptor whose regular-file type and size were checked, so a
    /// path swap cannot replace verified weights between metadata inspection and streaming.
    private static func inspectRegularFile(
        _ url: URL,
        name: String
    ) throws -> (bytes: Int64, sha256: String) {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw LocalUpscaleManifestError.missingFile(name) }
            throw LocalUpscaleManifestError.unsafeFile(name)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw LocalUpscaleManifestError.unsafeFile(name)
        }
        var digest = SHA256()
        do {
            while true {
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                guard !chunk.isEmpty else { break }
                digest.update(data: chunk)
            }
        } catch {
            throw LocalUpscaleManifestError.unreadableFile(name)
        }
        return (
            Int64(status.st_size),
            digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func validatePathComponent(_ value: String) throws {
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              value != ".",
              value != ".." else {
            throw LocalUpscaleManifestError.unsafeArtifactName(value)
        }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}
