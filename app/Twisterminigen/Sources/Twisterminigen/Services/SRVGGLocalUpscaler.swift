import CoreGraphics
import Foundation
import ImageIO
import MLX

struct SRVGGLocalUpscaleConfiguration: Equatable, Sendable {
    static let maximumOutputPixels = 100_000_000

    let coreSize: Int
    let halo: Int
    let maximumOutputPixels: Int

    init(
        coreSize: Int = SRVGGTilePlan.defaultCoreSize,
        halo: Int = SRVGGTilePlan.defaultHalo,
        maximumOutputPixels: Int = SRVGGLocalUpscaleConfiguration.maximumOutputPixels
    ) {
        self.coreSize = coreSize
        self.halo = halo
        self.maximumOutputPixels = maximumOutputPixels
    }
}

enum SRVGGLocalUpscalerError: Error, LocalizedError, Equatable, Sendable {
    case licenseNotAccepted
    case requestDoesNotMatchPinnedModel
    case weightsUnavailable(String)
    case unreadableImage
    case unsupportedImage
    case sourceSizeMismatch(expected: LocalUpscalePixelSize, actual: LocalUpscalePixelSize)
    case outputTooLarge(maximumPixels: Int)
    case tileOutputDimensions(expectedWidth: Int, expectedHeight: Int, actual: [Int])
    case outputImageCreationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .licenseNotAccepted: "The exact BSD-3-Clause model notice has not been accepted."
        case .requestDoesNotMatchPinnedModel:
            "This executor accepts only its exact verified native 4× SRVGG model."
        case .weightsUnavailable(let reason): "The local upscaler weights are not ready: \(reason)"
        case .unreadableImage: "Could not read the in-memory source as an image."
        case .unsupportedImage: "The source image could not be converted to an sRGB RGBA bitmap."
        case .sourceSizeMismatch(let expected, let actual):
            "The source is \(actual.width)×\(actual.height), not the requested \(expected.width)×\(expected.height)."
        case .outputTooLarge(let maximum):
            "The 4× result exceeds the \(maximum)-pixel safety limit."
        case .tileOutputDimensions(let width, let height, let actual):
            "An SRVGG tile returned \(actual), expected [1, \(height), \(width), 3]."
        case .outputImageCreationFailed: "Could not create the local upscaler output image."
        case .pngEncodingFailed: "Could not encode the local upscaler output as PNG."
        }
    }
}

/// Real, on-device, tiled SRVGGNetCompact ×4 executor for an already downloaded checkpoint.
///
/// This type deliberately does not acquire `InferenceCoordinator`: the app-level caller must hold
/// one `.upscale` lease from before invoking this method until it returns (including cancellation
/// and final PNG encoding). That makes the process-wide MLX exclusion visible at composition
/// time and prevents a hidden second scheduler. There is no resize fallback.
struct SRVGGLocalUpscaler: LocalImageUpscaling {
    let weightsDirectory: URL
    let manifest: LocalUpscaleWeightManifest
    let acceptance: LocalUpscaleLicenseAcceptance?
    let configuration: SRVGGLocalUpscaleConfiguration
    let availability: LocalUpscalerAvailability

    init(
        weightsDirectory: URL,
        manifest: LocalUpscaleWeightManifest = .realESRGANGeneralX4V3,
        acceptance: LocalUpscaleLicenseAcceptance?,
        configuration: SRVGGLocalUpscaleConfiguration = SRVGGLocalUpscaleConfiguration()
    ) {
        self.weightsDirectory = weightsDirectory.standardizedFileURL
        self.manifest = manifest
        self.acceptance = acceptance
        self.configuration = configuration
        do {
            guard let acceptance else {
                throw SRVGGLocalUpscalerError.licenseNotAccepted
            }
            _ = try LocalUpscaleManifestVerifier.verify(
                manifest,
                in: weightsDirectory,
                acceptance: acceptance)
            availability = .ready(models: [manifest.model])
        } catch {
            availability = .unavailable(message: error.localizedDescription)
        }
    }

    func upscale(_ request: LocalUpscaleRequest) async throws -> LocalUpscaleDataResult {
        try request.validate()
        guard request.factor == .fourX, request.model == manifest.model else {
            throw SRVGGLocalUpscalerError.requestDoesNotMatchPinnedModel
        }
        guard let acceptance else { throw SRVGGLocalUpscalerError.licenseNotAccepted }
        guard case .ready = availability else {
            let reason: String
            if case .unavailable(let message) = availability {
                reason = message
            } else {
                reason = "No verified model is available."
            }
            throw SRVGGLocalUpscalerError.weightsUnavailable(reason)
        }

        let worker = Task.detached(priority: .userInitiated) {
            defer { MLXRuntimeSafety.drainCompletions() }
            try Task.checkCancellation()
            return try Self.execute(
                request,
                weightsDirectory: weightsDirectory,
                manifest: manifest,
                acceptance: acceptance,
                configuration: configuration)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func execute(
        _ request: LocalUpscaleRequest,
        weightsDirectory: URL,
        manifest: LocalUpscaleWeightManifest,
        acceptance: LocalUpscaleLicenseAcceptance,
        configuration: SRVGGLocalUpscaleConfiguration
    ) throws -> LocalUpscaleDataResult {
        try Task.checkCancellation()

        let source = try SRVGGRGBASourceImage.load(
            from: request.sourcePNGData,
            expectedSize: request.sourceSize,
            scale: request.factor.rawValue,
            maximumOutputPixels: configuration.maximumOutputPixels)
        let actualSize = LocalUpscalePixelSize(width: source.width, height: source.height)
        guard actualSize == request.sourceSize else {
            throw SRVGGLocalUpscalerError.sourceSizeMismatch(
                expected: request.sourceSize,
                actual: actualSize)
        }
        let plan = try SRVGGTilePlan.make(
            sourceWidth: source.width,
            sourceHeight: source.height,
            coreSize: configuration.coreSize,
            halo: configuration.halo,
            scale: request.factor.rawValue)
        let (outputPixels, pixelOverflow) = plan.outputWidth.multipliedReportingOverflow(
            by: plan.outputHeight)
        guard !pixelOverflow, outputPixels <= configuration.maximumOutputPixels else {
            throw SRVGGLocalUpscalerError.outputTooLarge(
                maximumPixels: configuration.maximumOutputPixels)
        }

        // The model lives only inside the helper. Once it returns or throws, all of its parameters
        // have left lexical scope; only then do we clear MLX's cache while the external `.upscale`
        // lease is still held.
        let rgb: [Float]
        do {
            rgb = try inferRGBWithLoadedModel(
                source: source,
                plan: plan,
                weightsDirectory: weightsDirectory,
                manifest: manifest,
                acceptance: acceptance)
        } catch {
            MLX.Memory.clearCache()
            throw error
        }
        MLX.Memory.clearCache()
        try Task.checkCancellation()

        guard let output = source.makeOutput(rgb: rgb, scale: request.factor.rawValue) else {
            throw SRVGGLocalUpscalerError.outputImageCreationFailed
        }
        let png = try pngData(output)
        try Task.checkCancellation()

        let result = LocalUpscaleDataResult(
            pngData: png,
            pixelSize: LocalUpscalePixelSize(
                width: plan.outputWidth,
                height: plan.outputHeight),
            model: manifest.model)
        try result.validate(against: request)
        return result
    }

    private static func inferRGBWithLoadedModel(
        source: SRVGGRGBASourceImage,
        plan: SRVGGTilePlan,
        weightsDirectory: URL,
        manifest: LocalUpscaleWeightManifest,
        acceptance: LocalUpscaleLicenseAcceptance
    ) throws -> [Float] {
        try LocalUpscaleManifestVerifier.validate(manifest)
        try acceptance.validate(for: manifest)
        let snapshot = try VerifiedModelSnapshot.create(inputs: manifest.artifacts.map { artifact in
            VerifiedModelSnapshotInput(
                sourceURL: weightsDirectory.appendingPathComponent(artifact.filename),
                relativePath: artifact.filename,
                expectedBytes: artifact.expectedBytes,
                expectedSHA256: artifact.expectedSHA256)
        })
        var model: SRVGGNetCompact? = try SRVGGWeightLoader.load(
            from: snapshot.root,
            manifest: manifest,
            acceptance: acceptance)
        defer {
            model = nil
            MLX.Memory.clearCache()
            withExtendedLifetime(snapshot) {}
        }
        return try inferRGB(source: source, plan: plan, model: model!)
    }

    private static func inferRGB(
        source: SRVGGRGBASourceImage,
        plan: SRVGGTilePlan,
        model: SRVGGNetCompact
    ) throws -> [Float] {
        let outputComponents = try checkedComponentCount(
            width: plan.outputWidth,
            height: plan.outputHeight,
            components: 3)
        var output = [Float](repeating: 0, count: outputComponents)

        for tile in plan.tiles {
            try Task.checkCancellation()
            let context = tile.context
            let input = MLXArray(source.rgbValues(in: context))
                .reshaped([1, context.height, context.width, 3])
                .asType(.float16)
            let tileOutput = model(input)
            eval(tileOutput)
            let expectedWidth = context.width * plan.scale
            let expectedHeight = context.height * plan.scale
            guard tileOutput.shape == [1, expectedHeight, expectedWidth, 3] else {
                throw SRVGGLocalUpscalerError.tileOutputDimensions(
                    expectedWidth: expectedWidth,
                    expectedHeight: expectedHeight,
                    actual: tileOutput.shape)
            }
            let values = tileOutput.asType(.float32).asArray(Float.self)
            try Task.checkCancellation()
            stitch(
                values,
                tile: tile,
                output: &output,
                outputWidth: plan.outputWidth)
        }
        return output
    }

    /// Only non-overlapping cores are copied; every final pixel is written exactly once. No blend
    /// is allowed to conceal a bad halo or a numerical boundary mismatch.
    private static func stitch(
        _ tileRGB: [Float],
        tile: SRVGGTile,
        output: inout [Float],
        outputWidth: Int
    ) {
        let copyWidth = tile.core.width * tile.scale
        let copyHeight = tile.core.height * tile.scale
        let contextOutputWidth = tile.context.width * tile.scale
        let destination = tile.outputCore
        let componentsPerRow = copyWidth * 3
        for row in 0 ..< copyHeight {
            let sourceStart = (
                (tile.outputCropY + row) * contextOutputWidth + tile.outputCropX) * 3
            let destinationStart = (
                (destination.y + row) * outputWidth + destination.x) * 3
            output.replaceSubrange(
                destinationStart ..< destinationStart + componentsPerRow,
                with: tileRGB[sourceStart ..< sourceStart + componentsPerRow])
        }
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil) else {
            throw SRVGGLocalUpscalerError.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SRVGGLocalUpscalerError.pngEncodingFailed
        }
        return data as Data
    }

    fileprivate static func checkedComponentCount(
        width: Int,
        height: Int,
        components: Int
    ) throws -> Int {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (count, componentOverflow) = pixels.multipliedReportingOverflow(by: components)
        guard !pixelOverflow, !componentOverflow, count > 0 else {
            throw SRVGGTilePlanError.dimensionsOverflow
        }
        return count
    }
}

/// Normalized, unpremultiplied sRGB input. Alpha never enters MLX: it is expanded by exact nearest
/// 4× and re-premultiplied after learned RGB inference, preserving hard transparency boundaries.
private struct SRVGGRGBASourceImage {
    let width: Int
    let height: Int
    let rgb: [Float]
    let alpha: [UInt8]

    static func load(
        from encoded: Data,
        expectedSize: LocalUpscalePixelSize,
        scale: Int,
        maximumOutputPixels: Int
    ) throws -> Self {
        let (scaleSquared, scaleOverflow) = scale.multipliedReportingOverflow(by: scale)
        guard !scaleOverflow, scaleSquared > 0, maximumOutputPixels > 0 else {
            throw SRVGGLocalUpscalerError.outputTooLarge(maximumPixels: maximumOutputPixels)
        }
        let maximumSourcePixels = maximumOutputPixels / scaleSquared
        let limits = BoundedImageDecoder.Limits(
            maximumEncodedBytes: 256 * 1_024 * 1_024,
            maximumPixelCount: maximumSourcePixels,
            maximumDimension: max(expectedSize.width, expectedSize.height))
        let image: CGImage
        do {
            image = try BoundedImageDecoder.decode(encoded, limits: limits)
        } catch {
            throw SRVGGLocalUpscalerError.unreadableImage
        }
        let decodedSize = LocalUpscalePixelSize(width: image.width, height: image.height)
        guard decodedSize == expectedSize else {
            throw SRVGGLocalUpscalerError.sourceSizeMismatch(
                expected: expectedSize,
                actual: decodedSize)
        }
        let (outputWidth, widthOverflow) = decodedSize.width.multipliedReportingOverflow(by: scale)
        let (outputHeight, heightOverflow) = decodedSize.height.multipliedReportingOverflow(by: scale)
        let (outputPixels, pixelOverflow) = outputWidth.multipliedReportingOverflow(by: outputHeight)
        guard !widthOverflow, !heightOverflow, !pixelOverflow,
              outputPixels > 0,
              maximumOutputPixels > 0,
              outputPixels <= maximumOutputPixels else {
            throw SRVGGLocalUpscalerError.outputTooLarge(maximumPixels: maximumOutputPixels)
        }
        return try Self(image: image)
    }

    init(image: CGImage) throws {
        width = image.width
        height = image.height
        guard width > 0,
              height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SRVGGLocalUpscalerError.unsupportedImage
        }
        let componentCount = try SRVGGLocalUpscaler.checkedComponentCount(
            width: width,
            height: height,
            components: 4)
        var bytes = [UInt8](repeating: 0, count: componentCount)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw SRVGGLocalUpscalerError.unsupportedImage
        }
        context.setBlendMode(CGBlendMode.copy)
        context.interpolationQuality = CGInterpolationQuality.none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rgb = [Float](repeating: 0, count: width * height * 3)
        var alpha = [UInt8](repeating: 0, count: width * height)
        for pixel in 0 ..< width * height {
            let sourceOffset = pixel * 4
            let alphaValue = bytes[sourceOffset + 3]
            alpha[pixel] = alphaValue
            let unpremultiply = alphaValue == 0 ? Float.zero : 255 / Float(alphaValue)
            rgb[pixel * 3] = min(1, Float(bytes[sourceOffset]) / 255 * unpremultiply)
            rgb[pixel * 3 + 1] = min(
                1,
                Float(bytes[sourceOffset + 1]) / 255 * unpremultiply)
            rgb[pixel * 3 + 2] = min(
                1,
                Float(bytes[sourceOffset + 2]) / 255 * unpremultiply)
        }
        self.rgb = rgb
        self.alpha = alpha
    }

    func rgbValues(in rect: SRVGGPixelRect) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(rect.width * rect.height * 3)
        for y in rect.y ..< rect.maxY {
            let start = (y * width + rect.x) * 3
            values.append(contentsOf: rgb[start ..< start + rect.width * 3])
        }
        return values
    }

    func makeOutput(rgb: [Float], scale: Int) -> CGImage? {
        let outputWidth = width * scale
        let outputHeight = height * scale
        guard rgb.count == outputWidth * outputHeight * 3,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
        for y in 0 ..< outputHeight {
            let sourceY = y / scale
            for x in 0 ..< outputWidth {
                let sourceX = x / scale
                let sourceAlpha = Float(alpha[sourceY * width + sourceX]) / 255
                let inputOffset = (y * outputWidth + x) * 3
                let outputOffset = (y * outputWidth + x) * 4
                bytes[outputOffset] = quantize(rgb[inputOffset] * sourceAlpha)
                bytes[outputOffset + 1] = quantize(rgb[inputOffset + 1] * sourceAlpha)
                bytes[outputOffset + 2] = quantize(rgb[inputOffset + 2] * sourceAlpha)
                bytes[outputOffset + 3] = quantize(sourceAlpha)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outputWidth * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)
    }

    private func quantize(_ value: Float) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded())
    }
}
