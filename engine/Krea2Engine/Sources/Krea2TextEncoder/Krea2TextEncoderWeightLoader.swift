// Krea2TextEncoderWeightLoader.swift
//








import Foundation
import MLX
import MLXNN

public enum Krea2TextEncoderWeightsError: Error, CustomStringConvertible {
    case noSafetensors(String)
    case keyMismatch(missing: [String], extra: [String])

    public var description: String {
        switch self {
        case .noSafetensors(let dir):
            return "No *.safetensors files were found in \(dir)"
        case .keyMismatch(let missing, let extra):
            return "Weight-key mismatch: missing=\(missing.count) \(missing.prefix(4)), "
                + "extra=\(extra.count) \(extra.prefix(4))"
        }
    }
}

public enum Krea2TextEncoderWeightLoader {
    public struct Stats {
        public let languageTensors: Int
        public let skippedTensors: Int
    }



    private static let languagePrefixes = ["language_model.", "model.language_model."]



    @discardableResult
    public static func load(
        into model: Qwen3VLTextModel,
        directory: URL,
        computeDType: DType = .bfloat16
    ) throws -> Stats {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".safetensors") }
            .sorted()
        guard !files.isEmpty else {
            throw Krea2TextEncoderWeightsError.noSafetensors(directory.path)
        }

        var weights: [String: MLXArray] = [:]
        var skipped = 0
        for file in files {
            let url = directory.appendingPathComponent(file)
            for (key, value) in try loadArrays(url: url) {
                if let prefix = languagePrefixes.first(where: { key.hasPrefix($0) }) {
                    weights[String(key.dropFirst(prefix.count))] = value.asType(computeDType)
                } else {
                    skipped += 1
                }
            }
        }


        let expected = Set(model.parameters().flattened().map(\.0))
        let provided = Set(weights.keys)
        let missing = expected.subtracting(provided).sorted()
        let extra = provided.subtracting(expected).sorted()
        guard missing.isEmpty, extra.isEmpty else {
            throw Krea2TextEncoderWeightsError.keyMismatch(missing: missing, extra: extra)
        }

        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        eval(model)

        return Stats(languageTensors: weights.count, skippedTensors: skipped)
    }
}
