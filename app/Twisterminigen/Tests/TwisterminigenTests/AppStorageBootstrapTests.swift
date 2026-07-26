import Foundation
import Testing
@testable import Twisterminigen

@Suite("Application storage bootstrap")
struct AppStorageBootstrapTests {
    @Test("Read-only storage becomes a recoverable permissions state")
    func readOnlyStorage() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.storageRoot,
            withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: fixture.storageRoot.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: fixture.storageRoot.path)
        }

        let failure = try #require(capturedFailure {
            try fixture.bootstrap()
        })
        #expect(failure.kind == .permissions)
        #expect(failure.location == fixture.storageRoot)
        #expect(StorageUnavailablePresentation(error: failure).recovery.contains("write access"))
    }

    @Test("Out-of-space storage is detected without filling a real volume")
    func noSpaceStorage() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }

        let failure = try #require(capturedFailure {
            try fixture.bootstrap(capacityProvider: { _ in 0 })
        })
        #expect(failure.kind == .noSpace)
        #expect(failure.operation == "check-capacity")
        #expect(failure.diagnosticMessage.contains("kind=noSpace"))
    }

    @Test("A damaged child permission is identified at the affected directory")
    func damagedChildPermissions() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }
        try fixture.bootstrap()
        let images = fixture.storageRoot.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: images.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: images.path)
        }

        let failure = try #require(capturedFailure {
            try fixture.bootstrap()
        })
        #expect(failure.kind == .permissions)
        #expect(failure.location == images)
    }

    @Test("Choosing another folder retargets app-owned models and permits retry")
    func chooseAlternativeFolder() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }
        let originalModels = fixture.storageRoot
            .appendingPathComponent("Models", isDirectory: true)
        fixture.defaults.set(originalModels.path, forKey: AppPaths.weightsRootDefaultsKey)
        fixture.defaults.set(
            ModelWeightsSource.managed.rawValue,
            forKey: AppPaths.weightsSourceDefaultsKey)

        let alternative = fixture.root
            .appendingPathComponent("Alternative", isDirectory: true)
        try FileManager.default.createDirectory(
            at: alternative,
            withIntermediateDirectories: false)
        try AppPaths.setStorageRoot(
            alternative,
            defaults: fixture.defaults,
            libraryDirectory: fixture.library)

        let alternativeSupport = alternative
            .appendingPathComponent(AppPaths.appName, isDirectory: true)
        #expect(
            fixture.defaults.string(forKey: AppPaths.weightsRootDefaultsKey)
                == alternativeSupport.appendingPathComponent("Models", isDirectory: true).path)
        let modelRoot = try AppPaths.bootstrap(
            defaults: fixture.defaults,
            libraryDirectory: fixture.library,
            capacityProvider: { _ in AppPaths.minimumBootstrapCapacity })
        #expect(modelRoot == alternativeSupport.appendingPathComponent("Models", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: modelRoot.path))
        #expect(FileManager.default.fileExists(
            atPath: alternativeSupport
                .appendingPathComponent(AppPaths.storageOwnershipMarkerName)
                .path))
        #expect(try writeProbeResidue(in: alternativeSupport).isEmpty)
    }

    @Test("Custom marker must exactly match a nonempty stored ownership UUID")
    func customMarkerRequiresExactIdentifier() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }
        try fixture.bootstrap()
        let expected = try #require(fixture.defaults.string(
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey))
        #expect(AppPaths.hasValidOwnershipMarker(
            at: fixture.storageRoot,
            identifier: expected))
        try AppPaths.setStorageRoot(
            fixture.storageContainer,
            defaults: fixture.defaults,
            libraryDirectory: fixture.library)
        #expect(fixture.defaults.string(
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey) == expected)

        fixture.defaults.set(
            UUID().uuidString,
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey)
        let mismatch = try #require(capturedFailure { try fixture.bootstrap() })
        #expect(mismatch.kind == .invalidLocation)
        #expect(mismatch.operation == "claim-storage-target")

        fixture.defaults.removeObject(
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey)
        let missing = try #require(capturedFailure { try fixture.bootstrap() })
        #expect(missing.kind == .invalidLocation)
        #expect(missing.operation == "validate-ownership-identifier")
    }

    @Test("Canonical Application Support can TOFU an existing valid marker")
    func canonicalStorageCanTrustOnFirstUse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenCanonical-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(AppPaths.appName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        try writeMarker(
            identifier: identifier,
            to: support.appendingPathComponent(AppPaths.storageOwnershipMarkerName))
        try Data("existing app data".utf8).write(
            to: support.appendingPathComponent("queue.json"))
        let defaults = VolatileUserDefaults()

        _ = try AppPaths.bootstrap(
            defaults: defaults,
            libraryDirectory: library,
            capacityProvider: { _ in AppPaths.minimumBootstrapCapacity })

        #expect(defaults.string(
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey) == identifier)
        #expect(FileManager.default.fileExists(
            atPath: support.appendingPathComponent("queue.json").path))
    }

    @Test("A hostile existing target is refused without changing defaults")
    func hostileExistingTargetLeavesDefaultsUnchanged() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }
        let hostileContainer = fixture.root
            .appendingPathComponent("Hostile", isDirectory: true)
        let hostileSupport = hostileContainer
            .appendingPathComponent(AppPaths.appName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: hostileSupport,
            withIntermediateDirectories: true)
        try Data("not this installation".utf8).write(
            to: hostileSupport.appendingPathComponent("private.txt"))
        try writeMarker(
            identifier: UUID().uuidString,
            to: hostileSupport.appendingPathComponent(
                AppPaths.storageOwnershipMarkerName))
        let oldContainer = fixture.defaults.string(
            forKey: AppPaths.storageContainerDefaultsKey)
        let oldIdentifier = fixture.defaults.string(
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey)
        let oldWeights = fixture.defaults.string(forKey: AppPaths.weightsRootDefaultsKey)

        let failure = try #require(capturedFailure {
            try AppPaths.setStorageRoot(
                hostileContainer,
                defaults: fixture.defaults,
                libraryDirectory: fixture.library)
        })

        #expect(failure.kind == .invalidLocation)
        #expect(failure.operation == "claim-storage-target")
        #expect(fixture.defaults.string(
            forKey: AppPaths.storageContainerDefaultsKey) == oldContainer)
        #expect(fixture.defaults.string(
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey) == oldIdentifier)
        #expect(fixture.defaults.string(
            forKey: AppPaths.weightsRootDefaultsKey) == oldWeights)
    }

    @Test("A missing custom container is never recreated")
    func missingContainerIsNotRecreated() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.storageContainer)

        let failure = try #require(capturedFailure { try fixture.bootstrap() })

        #expect(failure.kind == .unavailable)
        #expect(failure.operation == "validate-storage-container")
        #expect(!FileManager.default.fileExists(atPath: fixture.storageContainer.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.storageRoot.path))
    }

    @Test("POSIX storage root and marker retain private permission bits")
    func privatePermissionBitsAreVerified() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }
        try fixture.bootstrap()
        let marker = fixture.storageRoot.appendingPathComponent(
            AppPaths.storageOwnershipMarkerName)
        let rootPermissions = try #require(
            FileManager.default.attributesOfItem(
                atPath: fixture.storageRoot.path)[.posixPermissions] as? NSNumber)
        let markerPermissions = try #require(
            FileManager.default.attributesOfItem(
                atPath: marker.path)[.posixPermissions] as? NSNumber)

        #expect(rootPermissions.intValue & 0o777 == 0o700)
        #expect(markerPermissions.intValue & 0o777 == 0o600)
    }

    @Test("Oversized ownership marker is bounded and refused")
    func oversizedOwnershipMarkerIsRefused() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.storageRoot,
            withIntermediateDirectories: false)
        let marker = fixture.storageRoot.appendingPathComponent(
            AppPaths.storageOwnershipMarkerName)
        try Data(repeating: 0x41, count: 4_097).write(to: marker)

        let failure = try #require(capturedFailure { try fixture.bootstrap() })

        #expect(failure.kind == .invalidLocation)
        #expect(failure.operation == "claim-storage-target")
        #expect(
            (try FileManager.default.attributesOfItem(
                atPath: marker.path)[.size] as? NSNumber)?.intValue == 4_097)
    }

    @Test("Legacy custom root is refused without touching unrelated files")
    func legacyCustomRootFailsClosed() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }
        let legacy = fixture.root.appendingPathComponent("LegacyShared", isDirectory: true)
        let unrelated = legacy.appendingPathComponent("family-photo.txt")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelated)
        fixture.defaults.removeObject(forKey: AppPaths.storageContainerDefaultsKey)
        fixture.defaults.set(legacy.path, forKey: AppPaths.storageRootDefaultsKey)

        let failure = try #require(capturedFailure {
            try fixture.bootstrap()
        })

        #expect(failure.kind == .invalidLocation)
        #expect(failure.operation == "legacy-storage-root")
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(!FileManager.default.fileExists(
            atPath: legacy.appendingPathComponent(AppPaths.storageOwnershipMarkerName).path))
    }

    @Test("Managed directories cannot be redirected through a symbolic link")
    func rejectsManagedDirectorySymlink() throws {
        let fixture = try StorageBootstrapFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        try fixture.bootstrap()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(
            at: fixture.storageRoot.appendingPathComponent("Images", isDirectory: true))
        try FileManager.default.createSymbolicLink(
            at: fixture.storageRoot.appendingPathComponent("Images", isDirectory: true),
            withDestinationURL: outside)

        let failure = try #require(capturedFailure {
            try fixture.bootstrap()
        })
        #expect(failure.kind == .invalidLocation)
        #expect(failure.location.lastPathComponent == "Images")
    }

    private func capturedFailure(_ operation: () throws -> Void) -> AppStorageBootstrapError? {
        do {
            try operation()
            return nil
        } catch let failure as AppStorageBootstrapError {
            return failure
        } catch {
            Issue.record("Unexpected bootstrap error: \(error)")
            return nil
        }
    }

    private func writeProbeResidue(in root: URL) throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent.hasPrefix(".twisterminigen-write-probe-")
        }
    }

    private func writeMarker(identifier: String, to url: URL) throws {
        try Data(
            """
            {"identifier":"\(identifier)","schema":"twisterminigen.storage-owner","version":1}
            """.utf8
        ).write(to: url)
    }
}

private final class StorageBootstrapFixture {
    let root: URL
    let library: URL
    let storageContainer: URL
    let storageRoot: URL
    let defaults = VolatileUserDefaults()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenStorageTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        library = root.appendingPathComponent("Library", isDirectory: true)
        storageContainer = root.appendingPathComponent("Storage", isDirectory: true)
        storageRoot = storageContainer
            .appendingPathComponent(AppPaths.appName, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: storageContainer,
            withIntermediateDirectories: false)
        defaults.set(storageContainer.path, forKey: AppPaths.storageContainerDefaultsKey)
        defaults.set(
            UUID().uuidString,
            forKey: AppPaths.storageOwnershipIdentifierDefaultsKey)
        defaults.set(
            storageRoot.appendingPathComponent("Models", isDirectory: true).path,
            forKey: AppPaths.weightsRootDefaultsKey)
        defaults.set(
            ModelWeightsSource.managed.rawValue,
            forKey: AppPaths.weightsSourceDefaultsKey)
    }

    func bootstrap(
        capacityProvider: ((URL) throws -> Int64?)? = { _ in
            AppPaths.minimumBootstrapCapacity
        }
    ) throws {
        _ = try AppPaths.bootstrap(
            defaults: defaults,
            libraryDirectory: library,
            capacityProvider: capacityProvider)
    }

    func cleanup() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: storageRoot.path)
        let images = storageRoot.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: images.path)
        try? FileManager.default.removeItem(at: root)
    }
}
