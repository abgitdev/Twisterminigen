import CoreGraphics
import Foundation

/// Offline, deterministic dominant-colour extraction for a prompt reference.
///
/// The service never loads a model. It analyzes at most a 160-pixel sRGB thumbnail, builds a fixed
/// RGB histogram, and uses stable tie-breaks so identical input bytes produce identical swatches.
enum ImagePaletteService {
    static let maximumPaletteSize = ImagePalette.maximumColorCount
    static let defaultPaletteSize = 8

    enum Error: Swift.Error, Equatable, Sendable {
        case bitmapCreationFailed
    }

    static func extract(
        from data: Data,
        maximumColors: Int = defaultPaletteSize,
        limits: BoundedImageDecoder.Limits = .imageTools
    ) throws -> ImagePalette {
        guard maximumColors > 0 else { return ImagePalette(colors: []) }
        let thumbnail = try BoundedImageDecoder.decode(
            data,
            maximumOutputDimension: analysisMaximumDimension,
            limits: limits)
        return try extract(from: thumbnail, maximumColors: maximumColors)
    }

    static func extractAsync(
        from data: Data,
        maximumColors: Int = defaultPaletteSize,
        limits: BoundedImageDecoder.Limits = .imageTools
    ) async throws -> ImagePalette {
        try await CancellableImageAnalysis.run {
            try extract(
                from: data,
                maximumColors: maximumColors,
                limits: limits)
        }
    }

    /// Reference-photo convenience API. The file is opened with the same no-symlink, bounded read
    /// used by Gallery image tools; EXIF orientation is applied by the Data overload.
    static func extract(
        from url: URL,
        maximumColors: Int = defaultPaletteSize,
        limits: BoundedImageDecoder.Limits = .imageTools
    ) throws -> ImagePalette {
        try extract(
            from: BoundedImageDecoder.data(at: url, limits: limits),
            maximumColors: maximumColors,
            limits: limits)
    }

    static func extractAsync(
        from url: URL,
        maximumColors: Int = defaultPaletteSize,
        limits: BoundedImageDecoder.Limits = .imageTools
    ) async throws -> ImagePalette {
        let data = try await BoundedImageDecoder.dataAsync(at: url, limits: limits)
        return try await extractAsync(
            from: data,
            maximumColors: maximumColors,
            limits: limits)
    }

    static func extract(
        from image: CGImage,
        maximumColors: Int = defaultPaletteSize
    ) throws -> ImagePalette {
        guard maximumColors > 0 else { return ImagePalette(colors: []) }
        guard let bitmap = normalizedBitmap(from: image) else {
            throw Error.bitmapCreationFailed
        }
        return ImagePalette(colors: try dominantColors(
            in: bitmap,
            limit: min(maximumColors, maximumPaletteSize)))
    }

    private static let analysisMaximumDimension = 160
    private static let transparentAlphaCutoff = 16

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixels: [UInt8]
    }

    private static func normalizedBitmap(from image: CGImage) -> Bitmap? {
        guard image.width > 0, image.height > 0 else { return nil }
        let size = analysisSize(for: image)
        let bytesPerRow = size.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return Bitmap(
            width: size.width,
            height: size.height,
            bytesPerRow: bytesPerRow,
            pixels: pixels)
    }

    private static func analysisSize(for image: CGImage) -> (width: Int, height: Int) {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > analysisMaximumDimension else {
            return (max(image.width, 1), max(image.height, 1))
        }
        let scale = Double(analysisMaximumDimension) / Double(longestEdge)
        return (
            max(1, Int((Double(image.width) * scale).rounded(.down))),
            max(1, Int((Double(image.height) * scale).rounded(.down))))
    }

    private struct HistogramBin {
        var alphaWeight = 0
        var redWeight = 0
        var greenWeight = 0
        var blueWeight = 0

        mutating func add(red: Int, green: Int, blue: Int, alpha: Int) {
            alphaWeight += alpha
            redWeight += red * alpha
            greenWeight += green * alpha
            blueWeight += blue * alpha
        }

        var color: RGB {
            guard alphaWeight > 0 else { return RGB(red: 0, green: 0, blue: 0) }
            return RGB(
                red: redWeight / alphaWeight,
                green: greenWeight / alphaWeight,
                blue: blueWeight / alphaWeight)
        }
    }

    private struct RGB: Comparable {
        let red: Int
        let green: Int
        let blue: Int

        static func < (lhs: RGB, rhs: RGB) -> Bool {
            if lhs.red != rhs.red { return lhs.red < rhs.red }
            if lhs.green != rhs.green { return lhs.green < rhs.green }
            return lhs.blue < rhs.blue
        }

        var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

        func squaredDistance(to other: RGB) -> Int {
            let redDelta = red - other.red
            let greenDelta = green - other.green
            let blueDelta = blue - other.blue
            return redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta
        }
    }

    private struct Candidate {
        let color: RGB
        let alphaWeight: Int
    }

    private static func dominantColors(in bitmap: Bitmap, limit: Int) throws -> [String] {
        var bins: [Int: HistogramBin] = [:]
        bins.reserveCapacity(512)

        for y in 0 ..< bitmap.height {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            let rowStart = y * bitmap.bytesPerRow
            for x in 0 ..< bitmap.width {
                let offset = rowStart + x * 4
                let alpha = Int(bitmap.pixels[offset + 3])
                guard alpha >= transparentAlphaCutoff else { continue }

                // The normalized buffer is premultiplied RGBA. Recover visible RGB before binning,
                // then keep alpha as a weight so translucent antialiasing cannot dominate a subject.
                let red = min(255, (Int(bitmap.pixels[offset]) * 255 + alpha / 2) / alpha)
                let green = min(255, (Int(bitmap.pixels[offset + 1]) * 255 + alpha / 2) / alpha)
                let blue = min(255, (Int(bitmap.pixels[offset + 2]) * 255 + alpha / 2) / alpha)
                let key = quantizedKey(red: red, green: green, blue: blue)
                bins[key, default: HistogramBin()].add(
                    red: red,
                    green: green,
                    blue: blue,
                    alpha: alpha)
            }
        }

        var candidates = bins.values.map {
            Candidate(color: $0.color, alphaWeight: $0.alphaWeight)
        }
        candidates.sort { left, right in
            left.alphaWeight == right.alphaWeight
                ? left.color < right.color
                : left.alphaWeight > right.alphaWeight
        }

        let minimumSquaredDistance = 28 * 28
        var selected: [Candidate] = []
        for candidate in candidates where selected.count < limit {
            guard selected.allSatisfy({
                candidate.color.squaredDistance(to: $0.color) >= minimumSquaredDistance
            }) else { continue }
            selected.append(candidate)
        }
        return selected.map(\.color.hex)
    }

    private static func quantizedKey(red: Int, green: Int, blue: Int) -> Int {
        ((red >> 3) << 10) | ((green >> 3) << 5) | (blue >> 3)
    }
}

extension ImagePaletteService.Error: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bitmapCreationFailed:
            return "The image could not be converted to a safe sRGB analysis bitmap."
        }
    }
}
