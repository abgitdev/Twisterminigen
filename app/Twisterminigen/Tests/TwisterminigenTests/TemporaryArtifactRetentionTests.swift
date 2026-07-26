import Darwin
import Foundation
import Testing
@testable import Twisterminigen

@Suite("Temporary artifact retention")
struct TemporaryArtifactRetentionTests {
    @Test("Reviewed previews are private, age-limited, count-limited, and lifecycle-cleanable")
    func reviewedPreviewRetentionIsPrivateAndBounded() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let firstDestination = try ReviewedPreviewStore.prepareDestination(
            baseDirectory: base)
        let directory = firstDestination.deletingLastPathComponent()
        #expect(permissions(of: directory) == 0o700)

        let now = Date()
        for index in 0 ..< 10 {
            let preview = directory.appendingPathComponent(
                "\(ReviewedPreviewStore.filenamePrefix)\(index).png")
            try Data("preview-\(index)".utf8).write(to: preview)
            try FileManager.default.setAttributes(
                [
                    .modificationDate: now.addingTimeInterval(
                        index == 0 ? -(ReviewedPreviewStore.maximumFileAge + 60) : Double(index)),
                    .posixPermissions: 0o600,
                ],
                ofItemAtPath: preview.path)
        }
        let privateStage = directory.appendingPathComponent(
            ".twister-private-stage-abandoned.tmp")
        try Data().write(to: privateStage)
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)

        try ReviewedPreviewStore.cleanupAfterLaunchOrUse(
            baseDirectory: base,
            now: now)
        let retained = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(ReviewedPreviewStore.filenamePrefix) }
        #expect(retained.count == ReviewedPreviewStore.maximumRetainedFiles)
        #expect(!FileManager.default.fileExists(atPath: privateStage.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))

        let published = try ReviewedPreviewStore.prepareDestination(
            baseDirectory: base,
            now: now)
        try Data("reviewed bytes".utf8).write(to: published)
        try ReviewedPreviewStore.securePublishedPreview(
            at: published,
            baseDirectory: base,
            now: now)
        #expect(permissions(of: published) == 0o600)

        try ReviewedPreviewStore.removeAllManagedPreviews(baseDirectory: base)
        let afterTermination = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        #expect(afterTermination.map(\.lastPathComponent) == [unrelated.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("Verified snapshot cleanup removes only private all-zero tombstone trees")
    func verifiedSnapshotTombstoneCleanupIsConservative() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let emptyRoot = parent.appendingPathComponent(
            "twister-verified-model-empty",
            isDirectory: true)
        let emptyNested = emptyRoot.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: emptyNested,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: emptyRoot.path)
        let emptyFile = emptyNested.appendingPathComponent("weights.safetensors")
        try Data().write(to: emptyFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: emptyFile.path)

        let liveRoot = parent.appendingPathComponent(
            "twister-verified-model-live",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: liveRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let liveFile = liveRoot.appendingPathComponent("weights.safetensors")
        try Data("still in use".utf8).write(to: liveFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: liveFile.path)

        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let symlink = parent.appendingPathComponent(
            "twister-verified-model-symlink",
            isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        #expect(VerifiedModelSnapshot.cleanupAbandonedTombstones(in: parent) == 1)
        #expect(!FileManager.default.fileExists(atPath: emptyRoot.path))
        #expect(try Data(contentsOf: liveFile) == Data("still in use".utf8))
        #expect(FileManager.default.fileExists(atPath: symlink.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Twisterminigen-TemporaryArtifactTests-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return root
    }

    private func permissions(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
