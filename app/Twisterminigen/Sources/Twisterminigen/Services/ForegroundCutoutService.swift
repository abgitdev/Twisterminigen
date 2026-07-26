import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A completely local Apple Vision foreground lift with an in-memory transparent PNG result.
enum ForegroundCutoutService {
    /// CGImage is an immutable Core Foundation image. Keeping it together with immutable Data makes
    /// the completed result safe to transfer from a detached analysis task back to the main actor.
    struct Cutout: @unchecked Sendable {
        let image: CGImage
        let pngData: Data
    }

    private final class VisionCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var request: VNRequest?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func install(_ request: VNRequest) {
            lock.lock()
            self.request = request
            let cancelNow = cancelled
            lock.unlock()
            if cancelNow { request.cancel() }
        }

        func clear(_ request: VNRequest) {
            lock.lock()
            if self.request === request { self.request = nil }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let request = request
            lock.unlock()
            request?.cancel()
        }
    }

    enum Error: Swift.Error, Equatable, Sendable {
        case unavailable
        case invalidSource(BoundedImageDecoder.Error)
        case noForegroundSubject
        case visionFailed(String)
        case invalidMaskedImage
        case pngEncodingFailed
        case pngTooLarge(maximumBytes: Int)
    }

    static let maximumPNGBytes = 256 * 1_024 * 1_024

    static var isAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Decodes an upright, bounded source and lifts all foreground instances. Nothing is written.
    static func makeCutout(
        from data: Data,
        cropToSubject: Bool = true,
        limits: BoundedImageDecoder.Limits = .imageTools
    ) throws -> Cutout {
        let image: CGImage
        do {
            image = try BoundedImageDecoder.decode(data, limits: limits)
        } catch let error as BoundedImageDecoder.Error {
            throw Error.invalidSource(error)
        }
        return try makeCutout(
            from: image,
            cropToSubject: cropToSubject,
            limits: limits,
            cancellation: nil)
    }

    /// Cancellable worker API used by SwiftUI. Closing the owner task cancels both the detached
    /// worker and its installed VNRequest, rather than only discarding a late Vision result.
    static func makeCutoutAsync(
        from data: Data,
        cropToSubject: Bool = true,
        limits: BoundedImageDecoder.Limits = .imageTools
    ) async throws -> Cutout {
        let cancellation = VisionCancellation()
        return try await CancellableImageAnalysis.run {
            let image: CGImage
            do {
                image = try BoundedImageDecoder.decode(data, limits: limits)
            } catch let error as BoundedImageDecoder.Error {
                throw Error.invalidSource(error)
            }
            return try makeCutout(
                from: image,
                cropToSubject: cropToSubject,
                limits: limits,
                cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Reference-photo convenience API with security-scope support and a bounded, no-symlink read.
    static func makeCutout(
        from url: URL,
        cropToSubject: Bool = true,
        limits: BoundedImageDecoder.Limits = .imageTools
    ) throws -> Cutout {
        let data: Data
        do {
            data = try BoundedImageDecoder.data(at: url, limits: limits)
        } catch let error as BoundedImageDecoder.Error {
            throw Error.invalidSource(error)
        }
        return try makeCutout(
            from: data,
            cropToSubject: cropToSubject,
            limits: limits)
    }

    static func makeCutoutAsync(
        from url: URL,
        cropToSubject: Bool = true,
        limits: BoundedImageDecoder.Limits = .imageTools
    ) async throws -> Cutout {
        let data: Data
        do {
            data = try await BoundedImageDecoder.dataAsync(at: url, limits: limits)
        } catch let error as BoundedImageDecoder.Error {
            throw Error.invalidSource(error)
        }
        return try await makeCutoutAsync(
            from: data,
            cropToSubject: cropToSubject,
            limits: limits)
    }

    static func makeCutout(
        from image: CGImage,
        cropToSubject: Bool = true,
        limits: BoundedImageDecoder.Limits = .imageTools
    ) throws -> Cutout {
        try makeCutout(
            from: image,
            cropToSubject: cropToSubject,
            limits: limits,
            cancellation: nil)
    }

    private static func makeCutout(
        from image: CGImage,
        cropToSubject: Bool,
        limits: BoundedImageDecoder.Limits,
        cancellation: VisionCancellation?
    ) throws -> Cutout {
        guard isAvailable else { throw Error.unavailable }
        do {
            try BoundedImageDecoder.validate(image, limits: limits)
        } catch let error as BoundedImageDecoder.Error {
            throw Error.invalidSource(error)
        }
        if #available(macOS 14.0, *) {
            return try liftForeground(
                from: image,
                cropToSubject: cropToSubject,
                limits: limits,
                cancellation: cancellation)
        }
        throw Error.unavailable
    }

    /// Encodes a transparent image without metadata. This is also useful to a future mask editor.
    static func pngData(
        for image: CGImage,
        maximumBytes: Int = maximumPNGBytes
    ) throws -> Data {
        guard maximumBytes > 0 else {
            throw Error.pngTooLarge(maximumBytes: maximumBytes)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil) else {
            throw Error.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.pngEncodingFailed
        }
        let data = output as Data
        guard data.count <= maximumBytes else {
            throw Error.pngTooLarge(maximumBytes: maximumBytes)
        }
        return data
    }

    @available(macOS 14.0, *)
    private static func liftForeground(
        from image: CGImage,
        cropToSubject: Bool,
        limits: BoundedImageDecoder.Limits,
        cancellation: VisionCancellation?
    ) throws -> Cutout {
        let request = VNGenerateForegroundInstanceMaskRequest()
        cancellation?.install(request)
        defer { cancellation?.clear(request) }
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            if Task.isCancelled || cancellation?.isCancelled == true {
                throw CancellationError()
            }
            throw Error.visionFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }

        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else {
            throw Error.noForegroundSubject
        }

        let pixelBuffer: CVPixelBuffer
        do {
            pixelBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: cropToSubject)
        } catch {
            if Task.isCancelled || cancellation?.isCancelled == true {
                throw CancellationError()
            }
            throw Error.visionFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }

        guard let maskedImage = cgImage(from: pixelBuffer) else {
            throw Error.invalidMaskedImage
        }
        do {
            try BoundedImageDecoder.validate(maskedImage, limits: limits)
        } catch {
            throw Error.invalidMaskedImage
        }
        guard let rgbaImage = normalizedRGBA(maskedImage) else {
            throw Error.invalidMaskedImage
        }
        return Cutout(image: rgbaImage, pngData: try pngData(for: rgbaImage))
    }

    private static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = source.extent.integral
        guard !extent.isEmpty else { return nil }
        return CIContext(options: [.cacheIntermediates: false])
            .createCGImage(source, from: extent)
    }

    private static func normalizedRGBA(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0,
              height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow else { return nil }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

extension ForegroundCutoutService.Error: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Foreground cut-outs require macOS 14 or later."
        case .invalidSource(let error):
            return error.localizedDescription
        case .noForegroundSubject:
            return "Apple Vision could not find a foreground subject in this image."
        case .visionFailed(let description):
            return "Apple Vision could not separate the foreground: \(description)"
        case .invalidMaskedImage:
            return "The foreground mask did not produce a usable transparent image."
        case .pngEncodingFailed:
            return "The transparent cut-out could not be encoded as PNG."
        case .pngTooLarge(let maximumBytes):
            return "The cut-out exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)) PNG limit."
        }
    }
}
