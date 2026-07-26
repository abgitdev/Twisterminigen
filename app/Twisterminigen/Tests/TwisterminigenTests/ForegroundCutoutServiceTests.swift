import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Twisterminigen

final class ForegroundCutoutServiceTests: XCTestCase {
    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func mark() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testPNGEncoderPreservesTransparentPixelsAndEnforcesOutputLimit() throws {
        let source = makeImage(width: 2, height: 1) { x, _ in
            x == 0 ? (255, 0, 0, 255) : (0, 0, 0, 0)
        }

        let png = try ForegroundCutoutService.pngData(for: source)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 1)
        XCTAssertEqual(rgbaBytes(of: decoded)[7], 0)

        XCTAssertThrowsError(
            try ForegroundCutoutService.pngData(for: source, maximumBytes: 1)
        ) { error in
            XCTAssertEqual(
                error as? ForegroundCutoutService.Error,
                .pngTooLarge(maximumBytes: 1))
        }
    }

    func testMalformedDataReturnsStableTypedSourceError() {
        XCTAssertThrowsError(
            try ForegroundCutoutService.makeCutout(from: Data("bad image".utf8))
        ) { error in
            XCTAssertEqual(
                error as? ForegroundCutoutService.Error,
                .invalidSource(.unreadableImage))
        }
    }

    func testURLAPIAcceptsRegularImageAndRejectsFinalSymlink() throws {
        let image = makeImage(width: 1, height: 1) { _, _ in (4, 8, 12, 255) }
        let png = try ForegroundCutoutService.pngData(for: image)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterImageTools-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("source.png")
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try png.write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        XCTAssertEqual(try ImagePaletteService.extract(from: file).colors, ["#04080C"])
        XCTAssertThrowsError(try ImagePaletteService.extract(from: link)) { error in
            XCTAssertEqual(error as? BoundedImageDecoder.Error, .unsafeFile)
        }
    }

    func testSyntheticImageHasOnlyDocumentedVisionOutcomes() throws {
        let synthetic = makeImage(width: 8, height: 8) { x, y in
            (2 ... 5).contains(x) && (2 ... 5).contains(y)
                ? (255, 255, 255, 255)
                : (0, 0, 0, 255)
        }

        do {
            let result = try ForegroundCutoutService.makeCutout(from: synthetic)
            XCTAssertGreaterThan(result.image.width, 0)
            XCTAssertGreaterThan(result.image.height, 0)
            XCTAssertFalse(result.pngData.isEmpty)
        } catch let error as ForegroundCutoutService.Error {
            switch error {
            case .noForegroundSubject, .visionFailed, .invalidMaskedImage:
                break
            case .unavailable, .invalidSource, .pngEncodingFailed, .pngTooLarge:
                XCTFail("Unexpected foreground result: \(error.localizedDescription)")
            }
        }
    }

    func testDetachedAnalysisBridgePropagatesCancellationWithoutVisionInference() async {
        let started = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        let probe = CancellationProbe()
        let task = Task {
            try await CancellableImageAnalysis.run {
                started.signal()
                releaseWorker.wait()
                try Task.checkCancellation()
                return 1
            } onCancel: {
                probe.mark()
                releaseWorker.signal()
            }
        }

        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled analysis worker must not return a value")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertTrue(probe.wasCancelled)
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
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)!
    }

    private func rgbaBytes(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
