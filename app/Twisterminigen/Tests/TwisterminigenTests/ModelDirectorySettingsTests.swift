import Foundation
import Testing
@testable import Twisterminigen

@Suite("Model directory settings")
struct ModelDirectorySettingsTests {
    @Test("Pure resolver honors stored, legacy, and fallback precedence")
    func pureResolverPrecedence() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-directory-resolver-\(UUID().uuidString)", isDirectory: true)
        let selected = base.appendingPathComponent("selected", isDirectory: true)
        let legacy = base.appendingPathComponent("legacy", isDirectory: true)
        let fallback = base.appendingPathComponent("fallback", isDirectory: true)

        let stored = ModelDirectoryResolver.resolve(
            storedPath: selected.path,
            legacyRoot: legacy,
            fallbackRoot: fallback,
            legacyContainsCurrentWeights: true)
        #expect(stored.root == selected.standardizedFileURL)
        #expect(!stored.shouldPersist)

        let migrated = ModelDirectoryResolver.resolve(
            storedPath: nil,
            legacyRoot: legacy,
            fallbackRoot: fallback,
            legacyContainsCurrentWeights: true)
        #expect(migrated.root == legacy.standardizedFileURL)
        #expect(migrated.shouldPersist)

        let fresh = ModelDirectoryResolver.resolve(
            storedPath: nil,
            legacyRoot: legacy,
            fallbackRoot: fallback,
            legacyContainsCurrentWeights: false)
        #expect(fresh.root == fallback.standardizedFileURL)
        #expect(fresh.shouldPersist)
    }

    @Test("Legacy weights migrate by selection without copying")
    func migrationDoesNotCopy() throws {
        let fixture = try DirectorySettingsFixture()
        defer { fixture.remove() }
        let legacy = fixture.home
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("krea2-weights", isDirectory: true)
        let marker = legacy.appendingPathComponent("existing-weight.marker")
        let markerData = Data("leave-in-place".utf8)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try markerData.write(to: marker)

        let resolved = AppPaths.resolveWeightsRoot(
            defaults: fixture.defaults,
            homeDirectory: fixture.home,
            applicationSupportDirectory: fixture.appSupport,
            legacyContainsCurrentWeights: { candidate in
                candidate.standardizedFileURL == legacy.standardizedFileURL
                    && FileManager.default.fileExists(atPath: marker.path)
            })

        #expect(resolved == legacy.standardizedFileURL)
        #expect(fixture.defaults.string(forKey: AppPaths.weightsRootDefaultsKey) == legacy.path)
        #expect(fixture.defaults.string(forKey: AppPaths.weightsSourceDefaultsKey)
                == ModelWeightsSource.linked.rawValue)
        #expect(try Data(contentsOf: marker) == markerData)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.appSupport.appendingPathComponent("Models").path))
    }

    @Test("Stored folder skips legacy probing")
    func storedFolderWins() throws {
        let fixture = try DirectorySettingsFixture()
        defer { fixture.remove() }
        let selected = fixture.root.appendingPathComponent("chosen", isDirectory: true)
        fixture.defaults.set(selected.path, forKey: AppPaths.weightsRootDefaultsKey)
        var didProbeLegacy = false

        let resolved = AppPaths.resolveWeightsRoot(
            defaults: fixture.defaults,
            homeDirectory: fixture.home,
            applicationSupportDirectory: fixture.appSupport,
            legacyContainsCurrentWeights: { _ in
                didProbeLegacy = true
                return true
            })

        #expect(resolved == selected.standardizedFileURL)
        #expect(!didProbeLegacy)
        #expect(fixture.defaults.string(forKey: AppPaths.weightsSourceDefaultsKey)
                == ModelWeightsSource.linked.rawValue)
    }

    @Test("App-owned model roots remain managed during source migration")
    func appOwnedStoredFolderIsManaged() throws {
        let fixture = try DirectorySettingsFixture()
        defer { fixture.remove() }
        let selected = fixture.appSupport
            .appendingPathComponent("ImportedModels/imported-one", isDirectory: true)
        fixture.defaults.set(selected.path, forKey: AppPaths.weightsRootDefaultsKey)

        _ = AppPaths.resolveWeightsRoot(
            defaults: fixture.defaults,
            homeDirectory: fixture.home,
            applicationSupportDirectory: fixture.appSupport,
            legacyContainsCurrentWeights: { _ in false })

        #expect(fixture.defaults.string(forKey: AppPaths.weightsSourceDefaultsKey)
                == ModelWeightsSource.managed.rawValue)
    }
}

private struct DirectorySettingsFixture {
    let root: URL
    let home: URL
    let appSupport: URL
    let defaults: UserDefaults

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.home = root.appendingPathComponent("home", isDirectory: true)
        self.appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        self.defaults = VolatileUserDefaults()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
