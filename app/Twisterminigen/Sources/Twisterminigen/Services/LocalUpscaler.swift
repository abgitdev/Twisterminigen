import Foundation

/// Intrinsic scale of an actual local super-resolution network. Twisterminigen intentionally has
/// no arbitrary-resize case: a 4× result must come from a verified native 4× model.
enum LocalUpscaleFactor: Int, Codable, CaseIterable, Sendable, Hashable {
    case fourX = 4

    var label: String { "\(rawValue)×" }
}

struct LocalUpscaleModel: Codable, Sendable, Hashable {
    let id: String
    let displayName: String
    let nativeFactor: LocalUpscaleFactor
    /// Immutable Hub commit SHA, never a mutable branch name.
    let revision: String
}

struct LocalUpscalePixelSize: Codable, Sendable, Hashable {
    let width: Int
    let height: Int

    func scaled(by factor: LocalUpscaleFactor) throws -> Self {
        guard width > 0, height > 0 else {
            throw LocalUpscalerError.invalidSourceDimensions(width: width, height: height)
        }
        let (scaledWidth, widthOverflow) = width.multipliedReportingOverflow(by: factor.rawValue)
        let (scaledHeight, heightOverflow) = height.multipliedReportingOverflow(by: factor.rawValue)
        guard !widthOverflow, !heightOverflow, scaledWidth > 0, scaledHeight > 0 else {
            throw LocalUpscalerError.outputDimensionsOverflow
        }
        return Self(width: scaledWidth, height: scaledHeight)
    }
}

/// In-memory request. The executor receives already verified Gallery PNG bytes and has no output
/// pathname capability; only the later reviewed publication boundary may touch user storage.
struct LocalUpscaleRequest: Sendable, Hashable {
    let sourcePNGData: Data
    let sourceSize: LocalUpscalePixelSize
    let factor: LocalUpscaleFactor
    let model: LocalUpscaleModel

    var expectedOutputSize: LocalUpscalePixelSize {
        get throws { try sourceSize.scaled(by: factor) }
    }

    func validate() throws {
        guard !sourcePNGData.isEmpty else { throw LocalUpscalerError.emptySourceData }
        guard model.nativeFactor == factor else {
            throw LocalUpscalerError.modelDoesNotMatchRequestedFactor(
                modelID: model.id,
                requested: factor)
        }
        _ = try expectedOutputSize
    }
}

/// Private encoded inference output. It cannot become a user-visible file until its exact bytes are
/// wrapped as a ReviewablePNG and pass the single-use output-review publisher.
struct LocalUpscaleDataResult: Sendable, Hashable {
    let pngData: Data
    let pixelSize: LocalUpscalePixelSize
    let model: LocalUpscaleModel

    func validate(against request: LocalUpscaleRequest) throws {
        try request.validate()
        guard !pngData.isEmpty else { throw LocalUpscalerError.emptyResultData }
        guard model == request.model,
              pixelSize == (try request.expectedOutputSize) else {
            throw LocalUpscalerError.resultDoesNotMatchRequest
        }
    }
}

/// A reviewed result that the external publisher confirmed at the selected destination.
struct LocalUpscaleResult: Sendable, Hashable {
    let outputURL: URL
    let pixelSize: LocalUpscalePixelSize
    let model: LocalUpscaleModel
}

enum LocalUpscalerAvailability: Sendable, Hashable {
    case unavailable(message: String)
    case ready(models: [LocalUpscaleModel])
}

enum LocalUpscalerError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(message: String)
    case modelDoesNotMatchRequestedFactor(modelID: String, requested: LocalUpscaleFactor)
    case invalidSourceDimensions(width: Int, height: Int)
    case outputDimensionsOverflow
    case emptySourceData
    case emptyResultData
    case resultDoesNotMatchRequest

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .modelDoesNotMatchRequestedFactor(let modelID, let requested):
            "The local model \(modelID) does not provide a native \(requested.label) upscale."
        case .invalidSourceDimensions(let width, let height):
            "The source image dimensions \(width)×\(height) are invalid."
        case .outputDimensionsOverflow:
            "The requested 4× output dimensions exceed the supported integer range."
        case .emptySourceData:
            "Local upscaling requires non-empty verified PNG bytes."
        case .emptyResultData:
            "The local upscaler returned an empty PNG payload."
        case .resultDoesNotMatchRequest:
            "The local upscaler result does not match the requested model and exact 4× size."
        }
    }
}

protocol LocalImageUpscaling: Sendable {
    var availability: LocalUpscalerAvailability { get }
    func upscale(_ request: LocalUpscaleRequest) async throws -> LocalUpscaleDataResult
}

typealias LocalUpscalerFactory = @Sendable (
    URL,
    LocalUpscaleWeightManifest,
    LocalUpscaleLicenseAcceptance
) -> any LocalImageUpscaling

/// Shipping-safe state until the real SRVGG executor passes its golden and visual seam gates in
/// this app. This service performs no image decode, resize, model load, or filesystem mutation.
struct UnavailableLocalUpscaler: LocalImageUpscaling {
    static let verificationRequiredMessage =
        "Local AI 4× is not enabled: the pinned model is known, but this app still requires an executor golden test and visual seam review."

    let availability: LocalUpscalerAvailability

    init(message: String = Self.verificationRequiredMessage) {
        availability = .unavailable(message: message)
    }

    func upscale(_ request: LocalUpscaleRequest) async throws -> LocalUpscaleDataResult {
        try request.validate()
        guard case .unavailable(let message) = availability else {
            throw LocalUpscalerError.unavailable(message: Self.verificationRequiredMessage)
        }
        throw LocalUpscalerError.unavailable(message: message)
    }
}
