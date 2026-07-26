import Foundation
import Testing
@testable import Twisterminigen

@Suite("Gallery annotations")
struct GalleryAnnotationStoreTests {
    @Test("Favorites persist independently and stale identifiers reconcile")
    func persistenceAndReconciliation() async throws {
        let fixture = try AnnotationFixture()
        defer { fixture.remove() }
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let store = GalleryAnnotationStore(fileURL: fixture.fileURL)

        #expect(try await store.setFavorite(true, for: first))
        #expect(try await store.setFavorite(true, for: second))
        #expect(try await store.favorites() == [first, second])

        let reopened = GalleryAnnotationStore(fileURL: fixture.fileURL)
        #expect(try await reopened.favorites() == [first, second])
        #expect(try await reopened.reconcile(validGenerationIDs: [second]) == [second])

        let reconciled = GalleryAnnotationStore(fileURL: fixture.fileURL)
        #expect(try await reconciled.favorites() == [second])
    }

    @Test("A corrupt annotation file is preserved and blocks mutation")
    func corruptionIsNonDestructive() async throws {
        let fixture = try AnnotationFixture()
        defer { fixture.remove() }
        let original = Data("not-json".utf8)
        try original.write(to: fixture.fileURL)
        let store = GalleryAnnotationStore(fileURL: fixture.fileURL)

        await #expect(throws: GalleryAnnotationStoreError.self) {
            try await store.favorites()
        }
        await #expect(throws: GalleryAnnotationStoreError.self) {
            try await store.setFavorite(true, for: UUID())
        }
        #expect(try Data(contentsOf: fixture.fileURL) == original)
    }
}

private struct AnnotationFixture {
    let root: URL
    let fileURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalleryAnnotationStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("annotations.json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
