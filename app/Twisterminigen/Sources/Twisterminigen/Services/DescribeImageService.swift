import CoreImage
import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

enum DescribeImageProgress: Sendable, Equatable {
    case validatingImage
    case loadingModel
    case analyzing
    case finalizing

    var message: String {
        switch self {
        case .validatingImage: "Checking image…"
        case .loadingModel: "Loading local Qwen3-VL…"
        case .analyzing: "Reading image…"
        case .finalizing: "Finishing description…"
        }
    }
}

enum DescribeImageError: LocalizedError, Equatable {
    case modelNotInstalled
    case notAFile
    case emptyFile
    case fileTooLarge(maxBytes: Int64)
    case unreadableImage
    case imageTooLarge(maxPixels: Int64)
    case emptyDescription
    case busy(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            "Install the optional Describe Image model first."
        case .notAFile:
            "Choose a local image file."
        case .emptyFile:
            "The selected image file is empty."
        case .fileTooLarge(let maxBytes):
            "The selected file is too large (maximum \(ByteFormat.string(maxBytes)))."
        case .unreadableImage:
            "Twisterminigen couldn't read that image."
        case .imageTooLarge(let maxPixels):
            "The image dimensions are too large (maximum \(maxPixels / 1_000_000) megapixels)."
        case .emptyDescription:
            "The local model returned an empty description."
        case .busy(let message):
            message
        }
    }
}

struct DescribeImageInputPolicy: Sendable {
    static let production = DescribeImageInputPolicy()

    var maximumFileBytes: Int64 = 100 * 1_024 * 1_024
    var maximumSourcePixels: Int64 = 120_000_000
    var maximumSourceDimension = 32_768
    var thumbnailDimension = 2_048

    func validate(fileBytes: Int64, width: Int, height: Int) throws {
        guard fileBytes > 0 else { throw DescribeImageError.emptyFile }
        guard fileBytes <= maximumFileBytes else {
            throw DescribeImageError.fileTooLarge(maxBytes: maximumFileBytes)
        }
        guard width > 0, height > 0,
              width <= maximumSourceDimension, height <= maximumSourceDimension,
              Int64(width) <= maximumSourcePixels / Int64(height) else {
            throw DescribeImageError.imageTooLarge(maxPixels: maximumSourcePixels)
        }
    }
}

/// Bounded decode keeps a maliciously huge source from becoming a huge bitmap before Qwen's own
/// processor gets a chance to resize it.
enum DescribeImageLoader {
    static func load(
        from url: URL,
        policy: DescribeImageInputPolicy = .production
    ) throws -> CIImage {
        guard url.isFileURL else { throw DescribeImageError.notAFile }
        let maximumBytes = Int(clamping: policy.maximumFileBytes)
        let maximumPixels = Int(clamping: policy.maximumSourcePixels)
        let limits = BoundedImageDecoder.Limits(
            maximumEncodedBytes: maximumBytes,
            maximumPixelCount: maximumPixels,
            maximumDimension: policy.maximumSourceDimension)
        do {
            let data = try BoundedImageDecoder.data(at: url, limits: limits)
            let thumbnail = try BoundedImageDecoder.decode(
                data,
                maximumOutputDimension: max(64, policy.thumbnailDimension),
                limits: limits)
            return CIImage(cgImage: thumbnail)
        } catch let error as BoundedImageDecoder.Error {
            switch error {
            case .emptyPayload:
                throw DescribeImageError.emptyFile
            case .payloadTooLarge:
                throw DescribeImageError.fileTooLarge(maxBytes: policy.maximumFileBytes)
            case .imageTooLarge:
                throw DescribeImageError.imageTooLarge(maxPixels: policy.maximumSourcePixels)
            case .unsafeFile:
                throw DescribeImageError.notAFile
            case .unreadableImage, .invalidAnalysisDimension:
                throw DescribeImageError.unreadableImage
            }
        }
    }
}

enum DescribeImageOutput {
    static let maximumCharacters = 12_000

    static func cleaned(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some Qwen variants may expose an internal reasoning block despite the system request.
        // Never place that block into the user's generation prompt.
        while let start = value.range(of: "<think>", options: .caseInsensitive),
              let end = value.range(
                of: "</think>", options: .caseInsensitive,
                range: start.upperBound..<value.endIndex) {
            value.removeSubrange(start.lowerBound..<end.upperBound)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let unmatched = value.range(of: "<think>", options: .caseInsensitive) {
            value.removeSubrange(unmatched.lowerBound..<value.endIndex)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty else { throw DescribeImageError.emptyDescription }
        return String(value.prefix(maximumCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol DescribeImageBackend: Sendable {
    func describe(
        imageURL: URL,
        onProgress: @escaping @Sendable (DescribeImageProgress) -> Void
    ) async throws -> String
}

/// Production backend. It loads only the already verified app-owned directory: Describe never
/// starts a surprise 5 GB download. Install is a separate explicit model-management action.
struct MLXDescribeImageBackend: DescribeImageBackend, Sendable {
    static let systemPrompt = """
        You turn a reference image into a prompt that can recreate it with a text-to-image model.
        Return one vivid, concrete paragraph covering subject, composition, spatial relationships,
        setting, lighting, color, materials, camera or medium, and overall style. Preserve visible
        text verbatim in quotation marks when it is legible; never guess unreadable text. Do not
        identify real people. No preamble, headings, lists, markdown, or hidden reasoning. Output
        only the reusable image-generation description.
        """

    var modelRoot: URL = DescribeImageModel.defaultRoot
    var inputPolicy: DescribeImageInputPolicy = .production

    func describe(
        imageURL: URL,
        onProgress: @escaping @Sendable (DescribeImageProgress) -> Void
    ) async throws -> String {
        defer { MLXRuntimeSafety.drainCompletions() }
        onProgress(.validatingImage)
        let image = try DescribeImageLoader.load(from: imageURL, policy: inputPolicy)
        try Task.checkCancellation()

        let catalog = DescribeImageModel.catalog(root: modelRoot)
        let snapshot: VerifiedModelSnapshot
        do {
            snapshot = try VerifiedModelSnapshot.create(
                inputs: catalog.allFiles.map(VerifiedModelSnapshotInput.init))
        } catch {
            throw DescribeImageError.modelNotInstalled
        }
        // The third-party VLM loader may retain lazy safetensor mappings. Keep the private snapshot
        // through the complete container/session response and the final MLX cache clear.
        defer { withExtendedLifetime(snapshot) {} }

        onProgress(.loadingModel)
        let raw: String
        do {
            raw = try await runModel(
                image: image,
                modelDirectory: snapshot.root,
                onProgress: onProgress)
        } catch {
            MLX.Memory.clearCache()
            throw error
        }
        // `runModel` owns the container/session scope; clear only after both have been released.
        MLX.Memory.clearCache()
        onProgress(.finalizing)
        return try DescribeImageOutput.cleaned(raw)
    }

    private func runModel(
        image: CIImage,
        modelDirectory: URL,
        onProgress: @escaping @Sendable (DescribeImageProgress) -> Void
    ) async throws -> String {
        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader())
        try Task.checkCancellation()
        onProgress(.analyzing)

        let parameters = GenerateParameters(
            maxTokens: 400,
            maxKVSize: 2_048,
            kvBits: 8,
            temperature: 0,
            seed: 0)
        let session = ChatSession(
            container,
            instructions: Self.systemPrompt,
            generateParameters: parameters,
            processing: .init(maxPixels: 1_048_576))
        return try await session.respond(
            to: "Describe this image as a reusable generation prompt.",
            image: .ciImage(image))
    }
}

/// Owns the process-wide inference lease. The backend is fully injectable, so unit tests exercise
/// busy, failure, cancellation, and lease release without loading MLX or touching model weights.
@MainActor
final class DescribeImageService {
    private let coordinator: InferenceCoordinator
    private let backend: any DescribeImageBackend
    private var activeLease: InferenceCoordinator.Lease?
    private var backendTask: Task<String, Error>?

    init(coordinator: InferenceCoordinator, backend: any DescribeImageBackend) {
        self.coordinator = coordinator
        self.backend = backend
    }

    var isRunning: Bool { activeLease != nil }

    func describe(
        imageURL: URL,
        onProgress: @escaping @Sendable (DescribeImageProgress) -> Void
    ) async throws -> String {
        guard activeLease == nil else {
            throw DescribeImageError.busy("Describe Image is already running.")
        }
        guard let lease = coordinator.begin(.describe) else {
            throw DescribeImageError.busy(coordinator.busyMessage(for: .describe))
        }
        activeLease = lease
        let backend = backend
        let task = Task.detached(priority: .userInitiated) {
            try await backend.describe(imageURL: imageURL, onProgress: onProgress)
        }
        backendTask = task

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            backendTask = nil
            if activeLease == lease { activeLease = nil }
            coordinator.finish(lease)
            return result
        } catch is CancellationError {
            backendTask = nil
            if activeLease == lease { activeLease = nil }
            coordinator.finish(lease)
            throw CancellationError()
        } catch {
            backendTask = nil
            if activeLease == lease { activeLease = nil }
            coordinator.fail(error.localizedDescription, lease: lease)
            throw error
        }
    }

    func cancel() {
        guard let activeLease else { return }
        coordinator.markStopping(activeLease)
        backendTask?.cancel()
    }
}
