import Foundation
import ImageIO
import Krea2Sampler
import Testing
@testable import Twisterminigen

@Suite struct LatentPreviewImageEncoderTests {
    @Test func encodesExactLowResolutionFrame() throws {
        let frame = Krea2LatentPreviewFrame(
            step: 1,
            totalSteps: 4,
            width: 2,
            height: 1,
            rgb: [255, 0, 0, 0, 0, 255])
        let data = try LatentPreviewImageEncoder.pngData(from: frame)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 2)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 1)
    }

    @Test func rejectsMalformedFrame() {
        #expect(throws: LatentPreviewImageError.invalidFrame) {
            _ = try LatentPreviewImageEncoder.pngData(from: .init(
                step: 1,
                totalSteps: 1,
                width: 2,
                height: 2,
                rgb: [0]))
        }
    }
}
