import CoreGraphics
import Foundation
import ImageIO
import Krea2Sampler
import UniformTypeIdentifiers

enum LatentPreviewImageError: Error, Equatable, Sendable {
    case invalidFrame
    case imageCreationFailed
    case encodingFailed
}

enum LatentPreviewImageEncoder {
    static func pngData(from frame: Krea2LatentPreviewFrame) throws -> Data {
        guard frame.width > 0,
              frame.height > 0,
              frame.rgb.count == frame.width * frame.height * 3 else {
            throw LatentPreviewImageError.invalidFrame
        }
        var rgba = [UInt8](repeating: 255, count: frame.width * frame.height * 4)
        for index in 0 ..< (frame.width * frame.height) {
            rgba[index * 4] = frame.rgb[index * 3]
            rgba[index * 4 + 1] = frame.rgb[index * 3 + 1]
            rgba[index * 4 + 2] = frame.rgb[index * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: frame.width,
                height: frame.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: frame.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent) else {
            throw LatentPreviewImageError.imageCreationFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil) else {
            throw LatentPreviewImageError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LatentPreviewImageError.encodingFailed
        }
        return output as Data
    }
}
