import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Shared, bounded ImageIO decoding for local image-analysis features.
///
/// Reading metadata before allocating a raster keeps malformed or unexpectedly large images from
/// turning a small helper action into an unbounded memory request. ImageIO also applies EXIF
/// orientation here, so Vision and palette analysis see the same upright pixels shown to the user.
enum BoundedImageDecoder {
    struct Limits: Sendable, Equatable {
        static let imageTools = Limits()

        let maximumEncodedBytes: Int
        let maximumPixelCount: Int
        let maximumDimension: Int

        init(
            maximumEncodedBytes: Int = 256 * 1_024 * 1_024,
            maximumPixelCount: Int = 40_000_000,
            maximumDimension: Int = 16_384
        ) {
            self.maximumEncodedBytes = maximumEncodedBytes
            self.maximumPixelCount = maximumPixelCount
            self.maximumDimension = maximumDimension
        }
    }

    enum Error: Swift.Error, Equatable, Sendable {
        case emptyPayload
        case payloadTooLarge(maximumBytes: Int)
        case unsafeFile
        case unreadableImage
        case imageTooLarge(width: Int, height: Int, maximumPixels: Int)
        case invalidAnalysisDimension(Int)
    }

    /// Opens a local file without following a final symlink and reads at most the configured byte
    /// limit. The descriptor is checked with `fstat`, so a path swap cannot bypass the regular-file
    /// and size checks performed for reference-photo imports.
    static func data(
        at url: URL,
        limits: Limits = .imageTools
    ) throws -> Data {
        guard limits.maximumEncodedBytes > 0 else { throw Error.unsafeFile }
        let sourceURL = url.standardizedFileURL
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let descriptor: Int32 = sourceURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw Error.unsafeFile }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw Error.unsafeFile
        }
        guard status.st_size <= off_t(limits.maximumEncodedBytes) else {
            throw Error.payloadTooLarge(maximumBytes: limits.maximumEncodedBytes)
        }

        var result = Data()
        result.reserveCapacity(min(Int(status.st_size), limits.maximumEncodedBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                while true {
                    let value = Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
                    if value < 0, errno == EINTR { continue }
                    return value
                }
            }
            guard count >= 0 else { throw Error.unsafeFile }
            guard count > 0 else { break }
            guard result.count <= limits.maximumEncodedBytes - count else {
                throw Error.payloadTooLarge(maximumBytes: limits.maximumEncodedBytes)
            }
            buffer.withUnsafeBytes { bytes in
                result.append(
                    bytes.bindMemory(to: UInt8.self).baseAddress!,
                    count: count)
            }
        }
        guard !result.isEmpty else { throw Error.emptyPayload }
        return result
    }

    static func dataAsync(
        at url: URL,
        limits: Limits = .imageTools
    ) async throws -> Data {
        try await CancellableImageAnalysis.run(priority: .utility) {
            try data(at: url, limits: limits)
        }
    }

    /// Decodes the first frame into an upright CGImage. Supplying `maximumOutputDimension` asks
    /// ImageIO to downsample while decoding instead of allocating a full-size intermediate.
    static func decode(
        _ data: Data,
        maximumOutputDimension: Int? = nil,
        limits: Limits = .imageTools
    ) throws -> CGImage {
        guard !data.isEmpty else { throw Error.emptyPayload }
        guard data.count <= limits.maximumEncodedBytes else {
            throw Error.payloadTooLarge(maximumBytes: limits.maximumEncodedBytes)
        }
        guard limits.maximumEncodedBytes > 0,
              limits.maximumPixelCount > 0,
              limits.maximumDimension > 0 else {
            throw Error.unreadableImage
        }
        if let maximumOutputDimension, maximumOutputDimension <= 0 {
            throw Error.invalidAnalysisDimension(maximumOutputDimension)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw Error.unreadableImage
        }

        let width = widthNumber.intValue
        let height = heightNumber.intValue
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0,
              height > 0,
              !overflow,
              width <= limits.maximumDimension,
              height <= limits.maximumDimension,
              pixelCount <= limits.maximumPixelCount else {
            throw Error.imageTooLarge(
                width: width,
                height: height,
                maximumPixels: limits.maximumPixelCount)
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maximumOutputDimension {
            options[kCGImageSourceThumbnailMaxPixelSize] = min(
                maximumOutputDimension,
                max(width, height))
        } else {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(width, height)
        }

        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary),
              image.width > 0,
              image.height > 0 else {
            throw Error.unreadableImage
        }
        return image
    }

    static func validate(
        _ image: CGImage,
        limits: Limits = .imageTools
    ) throws {
        let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard image.width > 0,
              image.height > 0,
              !overflow,
              image.width <= limits.maximumDimension,
              image.height <= limits.maximumDimension,
              pixelCount <= limits.maximumPixelCount else {
            throw Error.imageTooLarge(
                width: image.width,
                height: image.height,
                maximumPixels: limits.maximumPixelCount)
        }
    }
}

extension BoundedImageDecoder.Error: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyPayload, .unreadableImage:
            return "The image could not be decoded safely."
        case .unsafeFile:
            return "The selected image is not a readable regular file."
        case .payloadTooLarge(let maximumBytes):
            return "The image exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)) analysis limit."
        case .imageTooLarge(let width, let height, let maximumPixels):
            return "The \(width)x\(height) image exceeds the \(maximumPixels)-pixel analysis limit."
        case .invalidAnalysisDimension:
            return "The requested image-analysis size is invalid."
        }
    }
}
