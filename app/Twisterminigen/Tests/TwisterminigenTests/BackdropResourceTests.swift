import AppKit
import Testing
@testable import Twisterminigen

@Suite("Tahoe glass backdrop")
struct BackdropResourceTests {
    @Test("The supplied full-resolution backdrop is packaged with the app")
    func bundledBackdropContract() throws {
        let url = try #require(FxBackdropAsset.resourceURL)
        let image = try #require(NSImage(contentsOf: url))
        let representation = try #require(image.representations.max {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        })

        #expect(url.isFileURL)
        #expect(!url.path.contains("/Downloads/"))
        #expect(representation.pixelsWide == 2_642)
        #expect(representation.pixelsHigh == 1_600)
    }
}
