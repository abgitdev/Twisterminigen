import CryptoKit
import Darwin
import Foundation
import Krea2Pipeline
import Testing
@testable import Twisterminigen

@Suite("Model manifest")
struct ModelManifestTests {
    @Test("Component status distinguishes linked external files from app-managed installs")
    func componentStatusOwnershipIsExplicit() {
        #expect(ModelComponentStatusPresentation.title(
            for: .downloaded,
            linkedReadOnly: true) == "Linked · verified")
        #expect(ModelComponentStatusPresentation.title(
            for: .missing,
            linkedReadOnly: true) == "Linked · missing")
        #expect(ModelComponentStatusPresentation.title(
            for: .downloaded,
            linkedReadOnly: false) == "Installed · verified")
        #expect(ModelComponentStatusPresentation.title(
            for: .missing,
            linkedReadOnly: false) == "Not installed")
        #expect(ModelComponentStatusPresentation.ownershipDetail(
            for: .downloaded,
            linkedReadOnly: true).contains("managed outside Twisterminigen"))
        #expect(ModelComponentStatusPresentation.ownershipDetail(
            for: .downloaded,
            linkedReadOnly: false).contains("can be removed here"))
    }

    @Test("The production manifest pins Default and optional q8 files exactly")
    func productionManifestIsExact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCatalog-\(UUID().uuidString)", isDirectory: true)
        let catalog = ModelCatalog(root: root)
        let expected: [String: ExpectedFile] = [
            "text_encoder/config.json": .init(
                bytes: 1_559,
                sha256: "1a1006851200920f53ab7e17ca14a8b3d1b91075dfbbff493307ba894cab0abb",
                revision: ModelCatalog.officialRevision),
            "text_encoder/model.safetensors": .init(
                bytes: 8_875_715_136,
                sha256: "8434db05292f95e0041589a7c82abeb39385be59c85b54ae11caa7b45e9f4f13",
                revision: ModelCatalog.officialRevision),
            "tokenizer/tokenizer.json": .init(
                bytes: 11_422_650,
                sha256: "be75606093db2094d7cd20f3c2f385c212750648bd6ea4fb2bf507a6a4c55506",
                revision: ModelCatalog.officialRevision),
            "tokenizer/tokenizer_config.json": .init(
                bytes: 664,
                sha256: "c871ed314285a377eccf509b906aa5fe015d5e79a3ddab2c198467329127ead6",
                revision: ModelCatalog.officialRevision),
            "tokenizer/chat_template.jinja": .init(
                bytes: 5_292,
                sha256: "3636d0f0bd6bef02654cdffdc447b79cb2cef8ab02cc75267345946291a489e4",
                revision: ModelCatalog.officialRevision),
            "vae/config.json": .init(
                bytes: 791,
                sha256: "54949c79def0d1060353c3fbfd4d2d2c4815ae241da6d6d28c99634c4eac6e6e",
                revision: ModelCatalog.officialRevision),
            "vae/diffusion_pytorch_model.safetensors": .init(
                bytes: 507_591_892,
                sha256: "ab1b61103959913d6c7e628cf793dbb2ca4726a40a3b3ae206c52b8e75bf6f08",
                revision: ModelCatalog.officialRevision),
            "transformer_mixed_4_8.safetensors": .init(
                bytes: 9_840_816_670,
                sha256: "985d60722b339c3cd9df16a173f0cb504ae93d81ce9fbe2c3ab158cf5b60a5fb",
                revision: ModelCatalog.ditRevision),
            "transformer_8bit.safetensors": .init(
                bytes: 14_244_836_620,
                sha256: "b10f33f0dcd91772990e7cecfc8003ba4d3f1ba27f03010b6d17a1f490f80a6c",
                revision: ModelCatalog.q8Revision),
        ]

        #expect(catalog.manifest == .current)
        #expect(catalog.manifest.schema == "twisterminigen.model-catalog")
        #expect(catalog.manifest.version == 1)
        #expect(catalog.components.count == 4)
        #expect(catalog.allFiles.count == 9)
        #expect(catalog.defaultFiles.count == 8)

        for component in catalog.components {
            for file in component.files {
                let item = try #require(expected[file.remotePath])
                #expect(file.expectedBytes == item.bytes)
                #expect(file.sha256 == item.sha256)
                #expect(component.revision == item.revision)
                #expect(file.localURL.path.hasPrefix(root.path + "/"))
                #expect(component.url(for: file).absoluteString ==
                    "https://huggingface.co/\(component.repo)/resolve/\(item.revision)/\(file.remotePath)")
                #expect(!component.url(for: file).absoluteString.contains("/resolve/main/"))
            }
        }
    }

    @Test("Model-folder mismatches report the exact failing property")
    @MainActor
    func modelFolderMismatchIsActionable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let expectedPayload = Data("expected".utf8)
        let manifestFile = ModelFile(
            remotePath: "text_encoder/config.json",
            localURL: url,
            isMain: false,
            expectedBytes: Int64(expectedPayload.count),
            sha256: sha256(expectedPayload))

        try Data("short".utf8).write(to: url)
        let sizeError = ModelWeightsTransferError.incompatibleFile(
            path: manifestFile.remotePath,
            mismatch: .size(
                expected: Int64(expectedPayload.count),
                actual: Int64(Data("short".utf8).count)))
        do {
            try ModelWeightsTransfer.validate(
                fileAt: url,
                against: manifestFile,
                displayPath: manifestFile.remotePath)
            Issue.record("Expected an exact-size mismatch")
        } catch let error as ModelWeightsTransferError {
            #expect(error == sizeError)
            #expect(error.localizedDescription.contains("contains 5 bytes"))
            #expect(error.localizedDescription.contains("requires 8 bytes"))
        }

        let changedPayload = Data("changed!".utf8)
        #expect(changedPayload.count == expectedPayload.count)
        try changedPayload.write(to: url)
        let actualHash = sha256(changedPayload)
        let hashError = ModelWeightsTransferError.incompatibleFile(
            path: manifestFile.remotePath,
            mismatch: .sha256(expected: manifestFile.sha256, actual: actualHash))
        do {
            try ModelWeightsTransfer.validate(
                fileAt: url,
                against: manifestFile,
                displayPath: manifestFile.remotePath)
            Issue.record("Expected an exact SHA-256 mismatch")
        } catch let error as ModelWeightsTransferError {
            #expect(error == hashError)
            #expect(error.localizedDescription.contains(String(actualHash.prefix(12))))
            #expect(error.localizedDescription.contains(String(manifestFile.sha256.prefix(12))))
        }

        let message = ModelsViewModel.modelFolderFailureMessage(
            action: "link",
            selected: root.appendingPathComponent("selected"),
            current: root.appendingPathComponent("active"),
            error: hashError)
        #expect(message.contains("selected"))
        #expect(message.contains("active model folder was not changed"))
        #expect(message.contains("active"))
    }

    @Test("Turbo exposes only Default mixed-4/8 and downloadable Best Fidelity q8")
    func modelDescriptorsAreDeclarative() throws {
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/model-descriptors"))
        let descriptors = catalog.descriptors

        #expect(descriptors.count == 2)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(descriptors.allSatisfy { $0.isActive })
        #expect(descriptors.allSatisfy { $0.isRenderable })
        #expect(descriptors.allSatisfy { $0.isDownloadable })
        #expect(descriptors.allSatisfy { $0.checkpointFamily == .turbo })

        let defaultTier = ModelCatalog.defaultModelDescriptor
        #expect(defaultTier.isDefault)
        #expect(defaultTier.quantizationTier == .mixed4And8)
        #expect(Set(defaultTier.componentIDs) == ["text-encoder", "vae", "dit-transformer"])
        #expect(catalog.generationReference == catalog.generationReference(for: defaultTier))

        let q8 = try #require(descriptors.first {
            $0.quantizationTier == .q8
        })
        #expect(q8 == ModelCatalog.bestFidelityModelDescriptor)
        #expect(q8.displayName.contains("Best Fidelity"))
        #expect(Set(q8.componentIDs) == ["text-encoder", "vae", "dit-transformer-q8"])
        #expect(catalog.generationReference(for: .q8).variantID == "alis-q8")
        #expect(catalog.generationReference(for: .q8).manifestHash
                != catalog.generationReference.manifestHash)

        #expect(GenerationRecipe.QuantizationTier.allCases == [.mixed4And8, .q8])
        #expect(!descriptors.contains { $0.checkpointFamily == .raw })
    }

    @Test("Exact files are stamped once and cache invalidates on stat identity or manifest change")
    func verificationCacheLifecycle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("tiny legacy weight".utf8)
        let url = root.appendingPathComponent("weights/tiny.bin")
        try write(payload, to: url)
        let file = ModelFile(
            remotePath: "tiny.bin",
            localURL: url,
            isMain: true,
            expectedBytes: Int64(payload.count),
            sha256: sha256(payload))
        let manifest = ModelManifest(schema: "test.model-manifest", version: 7)
        let counter = HashCounter()
        let verifier = ModelVerifier(
            manifest: manifest,
            hashFileDescriptor: { try counter.hash($0) })

        #expect(!verifier.isVerifiedFromCache(file))
        #expect(verifier.verify(file) == .verified)
        #expect(counter.value == 1)
        #expect(verifier.isVerifiedFromCache(file))
        #expect(verifier.verify(file) == .verified)
        #expect(counter.value == 1)

        let stampData = try Data(contentsOf: file.verificationURL)
        let stamp = try JSONDecoder().decode(ModelVerificationStamp.self, from: stampData)
        #expect(stamp.manifestSchema == manifest.schema)
        #expect(stamp.manifestVersion == manifest.version)
        #expect(stamp.size == Int64(payload.count))
        #expect(stamp.sha256 == file.sha256)
        #expect(stamp.fileInode > 0)
        #expect(stamp.fileMode > 0)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = try #require(attributes[.modificationDate] as? Date)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate.addingTimeInterval(10)],
            ofItemAtPath: url.path)

        #expect(!verifier.isVerifiedFromCache(file))
        #expect(verifier.verify(file) == .verified)
        #expect(counter.value == 2)

        let nextVerifier = ModelVerifier(
            manifest: ModelManifest(schema: manifest.schema, version: manifest.version + 1),
            hashFileDescriptor: { try counter.hash($0) })
        #expect(!nextVerifier.isVerifiedFromCache(file))
        #expect(nextVerifier.verify(file) == .verified)
        #expect(counter.value == 3)
    }

    @Test("Load-bound verification always rehashes a cached model")
    func verificationForLoadNeverTrustsCachedDigest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("load-bound model".utf8)
        let url = root.appendingPathComponent("model.bin")
        try write(payload, to: url)
        let file = ModelFile(
            remotePath: "model.bin",
            localURL: url,
            isMain: true,
            expectedBytes: Int64(payload.count),
            sha256: sha256(payload))
        let counter = HashCounter()
        let verifier = ModelVerifier(
            manifest: .current,
            hashFileDescriptor: { try counter.hash($0) })

        #expect(verifier.verify(file) == .verified)
        #expect(verifier.verify(file) == .verified)
        #expect(counter.value == 1)
        #expect(verifier.verifyForLoad(file) == .verified)
        #expect(verifier.verifyForLoad(file) == .verified)
        #expect(counter.value == 3)
    }

    @Test("Same-size atomic replacement with restored mtime invalidates linked cache")
    func replacementCannotReuseVerificationStamp() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = Data("verified bytes".utf8)
        let replacement = Data("attacker bytes".utf8)
        #expect(original.count == replacement.count)
        let url = root.appendingPathComponent("linked.bin")
        try write(original, to: url)
        let file = ModelFile(
            remotePath: "linked.bin",
            localURL: url,
            isMain: true,
            expectedBytes: Int64(original.count),
            sha256: sha256(original))
        let stampRoot = root.appendingPathComponent("stamps", isDirectory: true)
        let verifier = ModelVerifier(manifest: .current, stampDirectory: stampRoot)
        #expect(verifier.verify(file) == .verified)
        #expect(verifier.isVerifiedFromCache(file))

        let originalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let originalModificationDate = try #require(
            originalAttributes[.modificationDate] as? Date)
        let temporary = root.appendingPathComponent("replacement.bin")
        try write(replacement, to: temporary)
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: temporary.path)
        #expect(rename(temporary.path, url.path) == 0)

        #expect(!verifier.isVerifiedFromCache(file))
        #expect(verifier.verifyForLoad(file) == .corrupted)
    }

    @Test("Final-component symlinks are rejected even when target bytes match")
    func symlinkCannotSatisfyVerification() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("verified bytes".utf8)
        let target = root.appendingPathComponent("target.bin")
        let linked = root.appendingPathComponent("linked.bin")
        try write(payload, to: target)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        let file = ModelFile(
            remotePath: "linked.bin",
            localURL: linked,
            isMain: true,
            expectedBytes: Int64(payload.count),
            sha256: sha256(payload))
        let verifier = ModelVerifier(manifest: .current)

        #expect(!verifier.isVerifiedFromCache(file))
        #expect(verifier.verify(file) == .corrupted)
        #expect(verifier.verifyForLoad(file) == .corrupted)
        #expect(throws: (any Error).self) {
            _ = try ModelVerifier.sha256Hex(of: linked)
        }
    }

    @Test("In-place same-size mutation with restored mtime invalidates ctime-bound cache")
    func inPlaceMutationCannotReuseVerificationStamp() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = Data("original-bytes".utf8)
        let changed = Data("mutated!-bytes".utf8)
        #expect(original.count == changed.count)
        let url = root.appendingPathComponent("linked.bin")
        try write(original, to: url)
        let file = ModelFile(
            remotePath: "linked.bin",
            localURL: url,
            isMain: true,
            expectedBytes: Int64(original.count),
            sha256: sha256(original))
        let verifier = ModelVerifier(manifest: .current)
        #expect(verifier.verify(file) == .verified)

        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = try #require(before[.modificationDate] as? Date)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: changed)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path)

        #expect(!verifier.isVerifiedFromCache(file))
        #expect(verifier.verifyForLoad(file) == .corrupted)
    }

    @Test("Snapshot clones the already-open file when its source path is atomically replaced")
    func snapshotUsesOpenedDescriptorAcrossPathReplacement() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stageParent = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stageParent, withIntermediateDirectories: true)

        let original = Data("verified snapshot bytes".utf8)
        let attacker = Data("replaced snapshot bytes".utf8)
        #expect(original.count == attacker.count)
        let source = root.appendingPathComponent("weights.safetensors")
        let replacement = root.appendingPathComponent("replacement.safetensors")
        try write(original, to: source)
        try write(attacker, to: replacement)
        let input = VerifiedModelSnapshotInput(
            sourceURL: source,
            relativePath: "model/weights.safetensors",
            expectedBytes: Int64(original.count),
            expectedSHA256: sha256(original))

        let snapshot = try VerifiedModelSnapshot.create(
            inputs: [input],
            stagingParent: stageParent,
            sourceOpenedHook: { _ in
                guard Darwin.rename(replacement.path, source.path) == 0 else {
                    throw SnapshotTestError.rename(errno)
                }
            })
        let staged = try snapshot.replacementFile(for: source)
        #expect(try Data(contentsOf: staged) == original)
        #expect(try Data(contentsOf: source) == attacker)

        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: staged) == original)
    }

    @Test("Stage lease isolates in-place source mutation and owns snapshot through materialization")
    func snapshotLeaseIsolatesMutationAndRemoval() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stageParent = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stageParent, withIntermediateDirectories: true)

        let original = Data("resident-stage-original".utf8)
        let changed = Data("resident-stage-mutated!".utf8)
        #expect(original.count == changed.count)
        let source = root.appendingPathComponent("model.safetensors")
        try write(original, to: source)
        let input = VerifiedModelSnapshotInput(
            sourceURL: source,
            relativePath: "model.safetensors",
            expectedBytes: Int64(original.count),
            expectedSHA256: sha256(original))

        func makeLease() throws -> (Krea2Pipeline.ModelLoadLease, URL) {
            let snapshot = try VerifiedModelSnapshot.create(
                inputs: [input], stagingParent: stageParent)
            let staged = try snapshot.replacementFile(for: source)
            return (snapshot.engineLease(), staged)
        }

        var (lease, staged): (Krea2Pipeline.ModelLoadLease?, URL) = try makeLease()
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: changed)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.removeItem(at: source)

        // This host Data stands in for a fully materialized stage result: it must come exclusively
        // from the pinned snapshot even though the source inode was changed and then removed.
        let materialized = try Data(contentsOf: staged)
        #expect(materialized == original)
        #expect(lease != nil)
        #expect(FileManager.default.fileExists(atPath: staged.path))

        lease = nil
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(!FileManager.default.fileExists(
            atPath: staged.deletingLastPathComponent().path))
    }

    @Test("Lease cleanup truncates its retained inode and never deletes a replacement pathname")
    func snapshotCleanupIsDescriptorBound() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stageParent = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stageParent, withIntermediateDirectories: true)

        let original = Data("original-cloned-extent".utf8)
        let replacement = Data("replacement-must-stay!".utf8)
        #expect(original.count == replacement.count)
        let source = root.appendingPathComponent("model.safetensors")
        let attacker = root.appendingPathComponent("attacker.safetensors")
        try write(original, to: source)
        try write(replacement, to: attacker)
        let input = VerifiedModelSnapshotInput(
            sourceURL: source,
            relativePath: "model.safetensors",
            expectedBytes: Int64(original.count),
            expectedSHA256: sha256(original))

        func makeLease() throws -> (Krea2Pipeline.ModelLoadLease, URL) {
            let snapshot = try VerifiedModelSnapshot.create(
                inputs: [input], stagingParent: stageParent)
            return (snapshot.engineLease(), try snapshot.replacementFile(for: source))
        }
        var (lease, staged): (Krea2Pipeline.ModelLoadLease?, URL) = try makeLease()
        guard Darwin.rename(attacker.path, staged.path) == 0 else {
            throw SnapshotTestError.rename(errno)
        }

        #expect(lease != nil)
        lease = nil
        #expect(try Data(contentsOf: staged) == replacement)
    }

    @Test("Every app render weight set carries a full load-bound verifier")
    func renderWeightsRehashAtEngineLoadBoundary() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        func component(_ id: String, _ filename: String, _ payload: Data) throws -> ModelComponent {
            let url = root.appendingPathComponent(filename)
            try write(payload, to: url)
            return ModelComponent(
                id: id,
                title: id,
                subtitle: "test",
                icon: "cube",
                repo: "test/\(id)",
                revision: "pinned-test-revision",
                files: [ModelFile(
                    remotePath: filename,
                    localURL: url,
                    isMain: true,
                    expectedBytes: Int64(payload.count),
                    sha256: sha256(payload))])
        }
        let text = Data("text-encoder".utf8)
        let vae = Data("vae-weights!".utf8)
        let transformer = Data("transformer!".utf8)
        let catalog = ModelCatalog(
            root: root,
            manifest: .current,
            components: [
                try component("text-encoder", "text.bin", text),
                try component("vae", "vae.bin", vae),
                try component("dit-transformer", "dit.bin", transformer),
            ])
        let weights = GenerateViewModel.makeWeights(
            catalog: catalog,
            model: catalog.generationReference)
        let verify = try #require(weights.loadVerification)
        let textLease = try verify(.textEncoder)
        _ = try textLease.replacementDirectory(for: catalog.officialDirectory)
        withExtendedLifetime(try verify(.transformer)) {}
        withExtendedLifetime(try verify(.vaeEncoder)) {}
        withExtendedLifetime(try verify(.vaeDecoder)) {}

        let transformerURL = root.appendingPathComponent("dit.bin")
        let changed = Data("TRANSFORMER!".utf8)
        #expect(changed.count == transformer.count)
        let modificationDate = try #require(
            (try FileManager.default.attributesOfItem(atPath: transformerURL.path))[
                .modificationDate
            ] as? Date)
        let handle = try FileHandle(forWritingTo: transformerURL)
        try handle.write(contentsOf: changed)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: transformerURL.path)

        #expect(throws: (any Error).self) {
            try verify(.transformer)
        }
    }

    @Test("Pinned identity is root-independent and changes with manifest content")
    func pinnedIdentityIsDeterministic() {
        let first = ModelCatalog(root: URL(fileURLWithPath: "/tmp/models-a"))
        let second = ModelCatalog(root: URL(fileURLWithPath: "/tmp/models-b"))
        #expect(first.pinnedIdentity == second.pinnedIdentity)
        #expect(first.pinnedIdentity.count == 64)

        let changedComponent = ModelComponent(
            id: "text-encoder",
            title: "Text Encoder",
            subtitle: "test",
            icon: "character.cursor.ibeam",
            repo: "example/model",
            revision: "changed-revision",
            files: [ModelFile(
                remotePath: "weights.bin",
                localURL: URL(fileURLWithPath: "/tmp/models-c/weights.bin"),
                isMain: true,
                expectedBytes: 1,
                sha256: String(repeating: "a", count: 64))])
        let changed = ModelCatalog(
            root: URL(fileURLWithPath: "/tmp/models-c"),
            manifest: first.manifest,
            components: [changedComponent])
        #expect(changed.pinnedIdentity != first.pinnedIdentity)
    }

    private struct ExpectedFile {
        let bytes: Int64
        let sha256: String
        let revision: String
    }
}

private final class HashCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func hash(_ descriptor: Int32) throws -> String {
        lock.withLock { count += 1 }
        return try ModelVerifier.sha256Hex(ofFileDescriptor: descriptor)
    }
}

private enum SnapshotTestError: Error {
    case rename(Int32)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TwisterminigenTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try data.write(to: url)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
