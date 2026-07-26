// Krea2VAEWeightLoader.swift
//
// Strict Qwen-Image VAE loading from diffusers safetensors.
// - Production txt2img loads only decoder.* + post_quant_conv.* into Krea2VAEDecoderModel.
// - Production image encoding loads only encoder.* + quant_conv.* into Krea2VAEEncoderModel.
// - Full Krea2VAE loading remains available for encode/Remix.
// - PyTorch conv layouts are converted to MLX layouts before shape validation.
// - One-way production loading supports FP32 and BF16; encoder-only prefers BF16 for memory.

import Foundation
import MLX
import MLXNN

public enum Krea2VAEWeightsError: Error, CustomStringConvertible {
    case unsupportedComputeDType(DType)
    case keyMismatch(missing: [String], unexpected: [String])
    case duplicateMappedKey(String)
    case shapeMismatch(key: String, expected: [Int], actual: [Int])
    case dtypeMismatch(key: String, expected: DType, actual: DType)

    public var description: String {
        switch self {
        case .unsupportedComputeDType(let dtype):
            return "VAE compute dtype \(dtype) is unsupported"
        case .keyMismatch(let missing, let unexpected):
            return "VAE key mismatch: missing=\(missing.count) \(missing.prefix(6)), "
                + "unexpected=\(unexpected.count) \(unexpected.prefix(6))"
        case .duplicateMappedKey(let key):
            return "Two checkpoint keys map to the same VAE parameter: \(key)"
        case .shapeMismatch(let key, let expected, let actual):
            return "Invalid VAE parameter shape for \(key): expected=\(expected), actual=\(actual)"
        case .dtypeMismatch(let key, let expected, let actual):
            return "Invalid VAE parameter dtype for \(key): expected=\(expected), actual=\(actual)"
        }
    }
}

struct Krea2VAEWeightMetadata: Equatable, Sendable {
    let shape: [Int]
    let dtype: DType

    init(shape: [Int], dtype: DType = .float32) {
        self.shape = shape
        self.dtype = dtype
    }
}

public enum Krea2VAEWeightLoader {
    /// These are the only checkpoint namespaces admitted to the production encoder model.
    static let encodePrefixes = Krea2VAEEncoderModel.parameterRoots.map { $0 + "." }
    /// These are the only checkpoint namespaces admitted to the production decoder model.
    static let decodePrefixes = Krea2VAEDecoderModel.parameterRoots.map { $0 + "." }
    private static let fullPrefixes = Krea2VAE.parameterRoots.map { $0 + "." }

    /// (resnet count, has downsampler) for each `Krea2VAEEncoder3D.down_blocks` stage.
    private static let encoderStages: [(resnets: Int, hasDownsample: Bool)] = [
        (2, true), (2, true), (2, true), (2, false),
    ]

    static func acceptsEncodeCheckpointKey(_ key: String) -> Bool {
        encodePrefixes.contains { key.hasPrefix($0) }
    }

    static func acceptsDecodeCheckpointKey(_ key: String) -> Bool {
        decodePrefixes.contains { key.hasPrefix($0) }
    }

    /// Loads and materializes only the production decoder. Encoder and quant_conv tensors in the
    /// shared VAE file are deliberately ignored and never become part of this model's eval graph.
    @discardableResult
    public static func load(
        into model: Krea2VAEDecoderModel,
        file: URL,
        computeDType: DType = .float32
    ) throws -> Int {
        let checkpoint = try loadArrays(url: file)
        let expected = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        let weights = try prepareDecoderWeights(
            checkpoint, expected: expected, computeDType: computeDType)

        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        eval(model)
        return weights.count
    }

    /// Loads and materializes only the production encoder. Decoder and post_quant_conv tensors in
    /// the shared VAE file are deliberately ignored and never become part of this model's graph.
    @discardableResult
    public static func load(
        into model: Krea2VAEEncoderModel,
        file: URL,
        computeDType: DType = .bfloat16
    ) throws -> Int {
        let checkpoint = try loadArrays(url: file)
        let expected = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        let weights = try prepareEncoderWeights(
            checkpoint, expected: expected, computeDType: computeDType)

        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        eval(model)
        return weights.count
    }

    /// Full encode+decode loading retained for Remix/img2img. Production txt2img should use the
    /// `Krea2VAEDecoderModel` overload above so encoder parameters are neither loaded nor eval'd.
    @discardableResult
    public static func load(
        into vae: Krea2VAE,
        file: URL,
        computeDType: DType = .float32
    ) throws -> Int {
        let checkpoint = try loadArrays(url: file)
        let expected = Dictionary(uniqueKeysWithValues: vae.parameters().flattened())
        let weights = try prepareFullWeights(
            checkpoint, expected: expected, computeDType: computeDType)

        try vae.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        eval(vae)
        return weights.count
    }

    /// Array path used by the loader. Tests use `prepareDecoderMetadata` below so they do not
    /// initialize an MLX device or create a Metal stream.
    static func prepareDecoderWeights(
        _ checkpoint: [String: MLXArray],
        expected: [String: MLXArray],
        computeDType: DType = .float32
    ) throws -> [String: MLXArray] {
        try prepareValues(
            checkpoint,
            expected: expected.mapValues(metadata),
            computeDType: computeDType,
            accepts: acceptsDecodeCheckpointKey,
            remap: remapDecodeKey,
            metadata: metadata,
            convertLayout: { key, value in
                convertWeightLayout(key: key, value: value).asType(computeDType)
            })
    }

    /// Pure metadata seam for host-safe structure/filtering tests.
    static func prepareDecoderMetadata(
        _ checkpoint: [String: Krea2VAEWeightMetadata],
        expected: [String: Krea2VAEWeightMetadata],
        computeDType: DType = .float32
    ) throws -> [String: Krea2VAEWeightMetadata] {
        try prepareValues(
            checkpoint,
            expected: expected,
            computeDType: computeDType,
            accepts: acceptsDecodeCheckpointKey,
            remap: remapDecodeKey,
            metadata: { $0 },
            convertLayout: { key, value in
                Krea2VAEWeightMetadata(
                    shape: convertedWeightShape(key: key, shape: value.shape),
                    dtype: computeDType)
            })
    }

    /// Array path used by the encoder-only loader.
    static func prepareEncoderWeights(
        _ checkpoint: [String: MLXArray],
        expected: [String: MLXArray],
        computeDType: DType = .bfloat16
    ) throws -> [String: MLXArray] {
        let encoderRemap = encoderFlatRemap()
        return try prepareValues(
            checkpoint,
            expected: expected.mapValues(metadata),
            computeDType: computeDType,
            accepts: acceptsEncodeCheckpointKey,
            remap: { remapEncoderKey($0, encoderRemap: encoderRemap) },
            metadata: metadata,
            convertLayout: { key, value in
                convertWeightLayout(key: key, value: value).asType(computeDType)
            })
    }

    /// Pure metadata seam for host-safe encoder structure/filtering tests.
    static func prepareEncoderMetadata(
        _ checkpoint: [String: Krea2VAEWeightMetadata],
        expected: [String: Krea2VAEWeightMetadata],
        computeDType: DType = .bfloat16
    ) throws -> [String: Krea2VAEWeightMetadata] {
        let encoderRemap = encoderFlatRemap()
        return try prepareValues(
            checkpoint,
            expected: expected,
            computeDType: computeDType,
            accepts: acceptsEncodeCheckpointKey,
            remap: { remapEncoderKey($0, encoderRemap: encoderRemap) },
            metadata: { $0 },
            convertLayout: { key, value in
                Krea2VAEWeightMetadata(
                    shape: convertedWeightShape(key: key, shape: value.shape),
                    dtype: computeDType)
            })
    }

    private static func prepareFullWeights(
        _ checkpoint: [String: MLXArray],
        expected: [String: MLXArray],
        computeDType: DType
    ) throws -> [String: MLXArray] {
        guard computeDType == .float32 else {
            throw Krea2VAEWeightsError.unsupportedComputeDType(computeDType)
        }
        let encoderRemap = encoderFlatRemap()
        return try prepareValues(
            checkpoint,
            expected: expected.mapValues(metadata),
            computeDType: computeDType,
            accepts: { key in fullPrefixes.contains { key.hasPrefix($0) } },
            remap: { remapFullKey($0, encoderRemap: encoderRemap) },
            metadata: metadata,
            convertLayout: { key, value in
                convertWeightLayout(key: key, value: value).asType(computeDType)
            })
    }

    private static func prepareValues<Value>(
        _ checkpoint: [String: Value],
        expected: [String: Krea2VAEWeightMetadata],
        computeDType: DType,
        accepts: (String) -> Bool,
        remap: (String) -> String,
        metadata: (Value) -> Krea2VAEWeightMetadata,
        convertLayout: (String, Value) -> Value
    ) throws -> [String: Value] {
        guard computeDType == .float32 || computeDType == .bfloat16 else {
            throw Krea2VAEWeightsError.unsupportedComputeDType(computeDType)
        }

        var prepared: [String: Value] = [:]
        for sourceKey in checkpoint.keys.sorted() where accepts(sourceKey) {
            guard let source = checkpoint[sourceKey] else { continue }
            let sourceMetadata = metadata(source)
            guard sourceMetadata.dtype == .float32 || sourceMetadata.dtype == .bfloat16 else {
                throw Krea2VAEWeightsError.dtypeMismatch(
                    key: sourceKey,
                    expected: computeDType,
                    actual: sourceMetadata.dtype)
            }
            let key = remap(sourceKey)
            guard prepared[key] == nil else {
                throw Krea2VAEWeightsError.duplicateMappedKey(key)
            }
            prepared[key] = convertLayout(key, source)
        }

        let expectedKeys = Set(expected.keys)
        let providedKeys = Set(prepared.keys)
        let missing = expectedKeys.subtracting(providedKeys).sorted()
        let unexpected = providedKeys.subtracting(expectedKeys).sorted()
        guard missing.isEmpty, unexpected.isEmpty else {
            throw Krea2VAEWeightsError.keyMismatch(missing: missing, unexpected: unexpected)
        }

        for key in expected.keys.sorted() {
            guard let expectedValue = expected[key], let value = prepared[key] else { continue }
            let actual = metadata(value)
            guard actual.shape == expectedValue.shape else {
                throw Krea2VAEWeightsError.shapeMismatch(
                    key: key, expected: expectedValue.shape, actual: actual.shape)
            }
            guard actual.dtype == computeDType else {
                throw Krea2VAEWeightsError.dtypeMismatch(
                    key: key, expected: computeDType, actual: actual.dtype)
            }
        }

        return prepared
    }

    private static func remapDecodeKey(_ key: String) -> String {
        key.replacingOccurrences(of: ".resample.1.", with: ".resample_conv.")
    }

    private static func remapEncoderKey(
        _ sourceKey: String, encoderRemap: [String: String]
    ) -> String {
        var key = sourceKey
        if key.hasPrefix("encoder.") {
            let suffix = String(key.dropFirst("encoder.".count))
            for from in encoderRemap.keys.sorted() where suffix.hasPrefix(from) {
                guard let to = encoderRemap[from] else { continue }
                key = "encoder." + to + suffix.dropFirst(from.count)
                break
            }
        }
        return remapDecodeKey(key)
    }

    private static func remapFullKey(
        _ sourceKey: String, encoderRemap: [String: String]
    ) -> String {
        remapEncoderKey(sourceKey, encoderRemap: encoderRemap)
    }

    private static func metadata(_ value: MLXArray) -> Krea2VAEWeightMetadata {
        Krea2VAEWeightMetadata(shape: value.shape, dtype: value.dtype)
    }

    private static func convertedWeightShape(key: String, shape: [Int]) -> [Int] {
        guard key.hasSuffix(".weight") else { return shape }
        if shape.count == 5 {
            return [shape[0], shape[2], shape[3], shape[4], shape[1]]
        }
        if shape.count == 4 {
            return [shape[0], shape[2], shape[3], shape[1]]
        }
        return shape
    }

    private static func convertWeightLayout(key: String, value: MLXArray) -> MLXArray {
        guard key.hasSuffix(".weight") else { return value }
        if value.ndim == 5 {
            return value.transposed(0, 2, 3, 4, 1) // conv3d [O,I,kt,kh,kw] -> [O,kt,kh,kw,I]
        }
        if value.ndim == 4 {
            return value.transposed(0, 2, 3, 1) // conv2d [O,I,kh,kw] -> [O,kh,kw,I]
        }
        return value
    }

    /// `down_blocks.<flat>.` -> nested Swift stage/resnet or downsampler path.
    private static func encoderFlatRemap() -> [String: String] {
        var remap: [String: String] = [:]
        var flat = 0
        for (stage, cfg) in encoderStages.enumerated() {
            for k in 0 ..< cfg.resnets {
                remap["down_blocks.\(flat)."] = "down_blocks.\(stage).resnets.\(k)."
                flat += 1
            }
            if cfg.hasDownsample {
                remap["down_blocks.\(flat)."] = "down_blocks.\(stage).downsamplers.0."
                flat += 1
            }
        }
        return remap
    }
}
