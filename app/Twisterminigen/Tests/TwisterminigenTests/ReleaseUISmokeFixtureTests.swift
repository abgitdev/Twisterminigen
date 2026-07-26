import Foundation
import Testing
@testable import Twisterminigen

/// Writes the bounded, non-user Gallery state required by the release UI-smoke matrix.
///
/// The test is inert during normal test runs. The operator must supply both an exact opt-in token
/// and a new `/private/tmp` storage root. Production code has no fixture mode, and this helper
/// refuses existing Gallery state rather than merging with or overwriting it.
@Suite("Release UI smoke fixture writer")
struct ReleaseUISmokeFixtureTests {
    private static let optInToken = "write-four-image-release-ui-smoke-fixture-v1"

    @Test("Writes four isolated Gallery images only with an explicit temporary-root opt-in")
    func writeFixtureWhenExplicitlyRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TWISTERMINIGEN_UI_SMOKE_FIXTURE_OPT_IN"] == Self.optInToken else {
            return
        }
        let rootText = try #require(
            environment["TWISTERMINIGEN_UI_SMOKE_FIXTURE_ROOT"],
            "The opted-in fixture writer requires an explicit root.")
        let requestedRoot = URL(fileURLWithPath: rootText, isDirectory: false)
            .standardizedFileURL
        let root = requestedRoot.deletingLastPathComponent()
            .appendingPathComponent(requestedRoot.lastPathComponent, isDirectory: false)
            .standardizedFileURL
        _ = try #require(
            root.path.hasPrefix("/private/tmp/")
                || root.path.hasPrefix("/tmp/"),
            "The release UI fixture writer accepts only an isolated temporary root.")

        let paths = LibraryPaths(
            root: root,
            thumbnails: root
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("thumbnails", isDirectory: true))
        _ = try #require(
            !FileManager.default.fileExists(atPath: paths.generationsIndex.path),
            "The release UI fixture writer refuses existing Gallery state.")
        _ = try #require(
            !FileManager.default.fileExists(atPath: paths.journal.path),
            "The release UI fixture writer refuses an existing transaction journal.")

        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let store = GenerationStore(paths: paths)
        for index in 0 ..< 4 {
            _ = try await store.save(
                pngData: png,
                prompt: "Release UI smoke fixture \(index + 1)",
                width: 512,
                height: 512,
                steps: 8,
                seed: UInt64(9_001 + index),
                duration: 0.01)
        }
        #expect(await store.all().count == 4)
    }
}
