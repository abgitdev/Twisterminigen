import Foundation
import MLX
import MLXNN

/// Fails closed while loading the pinned converted MLX checkpoint. Arbitrary folders, `.pth`
/// checkpoints, changed revisions, unaccepted notices, and partial parameter sets are rejected.
enum SRVGGWeightLoader {
    enum LoaderError: Error, LocalizedError, Equatable, Sendable {
        case missingModelArtifact
        case unsupportedNativeFactor(LocalUpscaleFactor)
        case keyMismatch(missing: [String], unexpected: [String])

        var errorDescription: String? {
            switch self {
            case .missingModelArtifact:
                "The verified upscaler manifest did not provide model.safetensors."
            case .unsupportedNativeFactor(let factor):
                "SRVGGNetCompact in this build is an intrinsic 4× model, not \(factor.label)."
            case .keyMismatch(let missing, let unexpected):
                "SRVGGNetCompact weights do not match the pinned architecture (missing \(missing.count), unexpected \(unexpected.count))."
            }
        }
    }

    static func load(
        from directory: URL,
        manifest: LocalUpscaleWeightManifest = .realESRGANGeneralX4V3,
        acceptance: LocalUpscaleLicenseAcceptance,
        computeDType: DType = .float16
    ) throws -> SRVGGNetCompact {
        guard manifest.model.nativeFactor == .fourX else {
            throw LoaderError.unsupportedNativeFactor(manifest.model.nativeFactor)
        }
        let artifacts = try LocalUpscaleManifestVerifier.verify(
            manifest,
            in: directory,
            acceptance: acceptance)
        guard let modelURL = artifacts["model.safetensors"] else {
            throw LoaderError.missingModelArtifact
        }

        let model = SRVGGNetCompact()
        let source = try loadArrays(url: modelURL)
        let expected = Set(model.parameters().flattened().map(\.0))
        let found = Set(source.keys)
        let missing = expected.subtracting(found).sorted()
        let unexpected = found.subtracting(expected).sorted()
        guard missing.isEmpty, unexpected.isEmpty else {
            throw LoaderError.keyMismatch(missing: missing, unexpected: unexpected)
        }

        var converted: [String: MLXArray] = [:]
        converted.reserveCapacity(source.count)
        for (key, value) in source {
            // The Hub artifact is already converted to MLX Conv2d OHWI layout. Transposing it as
            // PyTorch OIHW would keep shapes plausible while producing numerically wrong images.
            if value.dtype == .float16 || value.dtype == .float32 || value.dtype == .bfloat16 {
                converted[key] = value.asType(computeDType)
            } else {
                converted[key] = value
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(converted), verify: .all)
        return model
    }
}
