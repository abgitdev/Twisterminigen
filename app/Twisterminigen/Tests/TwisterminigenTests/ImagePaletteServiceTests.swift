import CoreGraphics
import Foundation
import XCTest
@testable import Twisterminigen

final class ImagePaletteServiceTests: XCTestCase {
    func testDominantColorsAreStableAndPopulationOrdered() throws {
        let image = makeImage(width: 10, height: 10) { _, y in
            if y < 7 { return (255, 0, 0, 255) }
            if y < 9 { return (0, 0, 255, 255) }
            return (0, 255, 0, 255)
        }

        let first = try ImagePaletteService.extract(from: image)
        XCTAssertEqual(first.colors, ["#FF0000", "#0000FF", "#00FF00"])
        XCTAssertEqual(try ImagePaletteService.extract(from: image), first)
    }

    func testTransparentPixelsAreIgnoredAndRequestedCountIsBounded() throws {
        let transparency = makeImage(width: 2, height: 1) { x, _ in
            x == 0 ? (0, 0, 0, 0) : (18, 52, 86, 255)
        }
        XCTAssertEqual(
            try ImagePaletteService.extract(from: transparency).colors,
            ["#123456"])

        let many = makeImage(width: 32, height: 1) { x, _ in
            ((x % 4) * 80, ((x / 4) % 4) * 80, (x / 16) * 80, 255)
        }
        XCTAssertEqual(
            try ImagePaletteService.extract(from: many, maximumColors: 3).colors.count,
            3)
        XCTAssertLessThanOrEqual(
            try ImagePaletteService.extract(from: many, maximumColors: 99).colors.count,
            ImagePalette.maximumColorCount)
        XCTAssertTrue(
            try ImagePaletteService.extract(from: many, maximumColors: 0).isEmpty)
    }

    func testEncodedInputIsBoundedAndMalformedDataHasTypedFailure() throws {
        let image = makeImage(width: 1, height: 1) { _, _ in (25, 50, 75, 255) }
        let png = try ForegroundCutoutService.pngData(for: image)
        XCTAssertEqual(
            try ImagePaletteService.extract(from: png).colors,
            ["#19324B"])

        XCTAssertThrowsError(try ImagePaletteService.extract(from: Data("bad".utf8))) { error in
            XCTAssertEqual(error as? BoundedImageDecoder.Error, .unreadableImage)
        }

        let tinyLimit = BoundedImageDecoder.Limits(
            maximumEncodedBytes: 2,
            maximumPixelCount: 10,
            maximumDimension: 10)
        XCTAssertThrowsError(
            try ImagePaletteService.extract(from: png, limits: tinyLimit)
        ) { error in
            XCTAssertEqual(
                error as? BoundedImageDecoder.Error,
                .payloadTooLarge(maximumBytes: 2))
        }
    }

    func testPaletteSanitizesColorsAndPromptApplicationIsExplicitAndIdempotent() throws {
        let palette = ImagePalette(colors: [
            " #aa11ff ", "#AA11FF", "bad", "#001122", "#GGGGGG",
        ])
        XCTAssertEqual(palette.colors, ["#AA11FF", "#001122"])
        XCTAssertEqual(
            palette.promptModifier,
            "Use this color palette: #AA11FF, #001122.")

        let result = try palette.applying(to: "A glass sculpture")
        XCTAssertEqual(
            result,
            "A glass sculpture\nUse this color palette: #AA11FF, #001122.")
        XCTAssertEqual(try palette.applying(to: result), result)
        XCTAssertEqual(
            try palette.applying(to: "A glass sculpture\n"),
            "A glass sculpture\nUse this color palette: #AA11FF, #001122.")
    }

    func testPromptLimitAndTransientGenerationCopyPreserveOriginal() throws {
        let palette = ImagePalette(colors: ["#010203"])
        XCTAssertThrowsError(try palette.applying(to: "abcd", maximumUTF8Bytes: 4)) { error in
            XCTAssertEqual(
                error as? ImagePalettePromptError,
                .promptTooLong(maximumUTF8Bytes: 4))
        }

        let original = Generation(
            prompt: "Original",
            width: 512,
            height: 768,
            steps: 8,
            seed: 42,
            durationSeconds: 1.5,
            imageFileName: "test.png")
        let replacement = try original.replacingPositivePrompt("Updated")
        XCTAssertEqual(original.prompt, "Original")
        XCTAssertEqual(replacement.prompt, "Updated")
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.recipe.canvas, original.recipe.canvas)
        XCTAssertEqual(replacement.recipe.sampler, original.recipe.sampler)
        XCTAssertEqual(replacement.imageFileName, original.imageFileName)
    }

    private func makeImage(
        width: Int,
        height: Int,
        color: (Int, Int) -> (Int, Int, Int, Int)
    ) -> CGImage {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (red, green, blue, alpha) = color(x, y)
                pixels += [UInt8(red), UInt8(green), UInt8(blue), UInt8(alpha)]
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)!
    }
}
