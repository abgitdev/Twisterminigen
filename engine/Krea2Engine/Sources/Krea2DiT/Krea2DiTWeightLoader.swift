// Krea2DiTWeightLoader.swift
//





import Foundation
import MLX
import MLXNN

public enum Krea2DiTWeightsError: Error, CustomStringConvertible {
    case noSafetensors(String)
    case keyMismatch(missing: [String], extra: [String])

    public var description: String {
        switch self {
        case .noSafetensors(let dir):
            return "No *.safetensors files were found in \(dir)"
        case .keyMismatch(let missing, let extra):
            return "DiT key mismatch: missing=\(missing.count) \(missing.prefix(5)), "
                + "extra=\(extra.count) \(extra.prefix(5))"
        }
    }
}

public enum Krea2DiTWeightLoader {
    public struct Stats { public let tensors: Int }


    @discardableResult
    public static func load(
        into model: Krea2SingleStreamDiT,
        directory: URL,
        computeDType: DType = .bfloat16
    ) throws -> Stats {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".safetensors") }
            .sorted()
        guard !files.isEmpty else { throw Krea2DiTWeightsError.noSafetensors(directory.path) }

        var weights: [String: MLXArray] = [:]
        for file in files {
            for (key, value) in try loadArrays(url: directory.appendingPathComponent(file)) {
                weights[key] = value.asType(computeDType)
            }
        }

        let expected = Set(model.parameters().flattened().map(\.0))
        let provided = Set(weights.keys)
        let missing = expected.subtracting(provided).sorted()
        let extra = provided.subtracting(expected).sorted()
        guard missing.isEmpty, extra.isEmpty else {
            throw Krea2DiTWeightsError.keyMismatch(missing: missing, extra: extra)
        }

        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        eval(model)
        return Stats(tensors: weights.count)
    }




    @discardableResult
    public static func loadQuantized(into model: Krea2SingleStreamDiT, file: URL) throws -> Stats {
        var weights: [String: MLXArray] = [:]
        for (key, value) in try loadArrays(url: file) {
            if key.hasSuffix(".scales") || key.hasSuffix(".biases") {
                weights[key] = value
            } else if value.dtype == .float32 || value.dtype == .float16 {


                weights[key] = value.asType(.bfloat16)
            } else {
                weights[key] = value
            }
        }

        let expected = Set(model.parameters().flattened().map(\.0))
        let provided = Set(weights.keys)
        let missing = expected.subtracting(provided).sorted()
        let extra = provided.subtracting(expected).sorted()
        guard missing.isEmpty, extra.isEmpty else {
            throw Krea2DiTWeightsError.keyMismatch(missing: missing, extra: extra)
        }

        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        eval(model)
        return Stats(tensors: weights.count)
    }
}




public enum Krea2DiTQuantRecipe {
    static let nLayers = 28
    static let endpoints = 2

    public static func mixed48Filter(_ path: String, _ m: Module)
        -> (groupSize: Int, bits: Int, mode: QuantizationMode)?
    {
        guard m is Linear,
              path.hasPrefix("blocks."),
              path.contains(".attn.") || path.contains(".mlp.")
        else { return nil }
        let comps = path.split(separator: ".")
        guard comps.count >= 2, let n = Int(comps[1]) else { return nil }
        let isEndpoint = n < endpoints || n >= nLayers - endpoints
        if path.contains(".mlp.down") || (isEndpoint && path.contains(".attn.")) {
            return (64, 8, .affine)
        }
        return (64, 4, .affine)
    }



    public static func q8Filter(_ path: String, _ m: Module)
        -> (groupSize: Int, bits: Int, mode: QuantizationMode)?
    {
        guard m is Linear,
              path.hasPrefix("blocks."),
              path.contains(".attn.") || path.contains(".mlp.")
        else { return nil }
        return (64, 8, .affine)
    }


    public static func quantizeMixed48(_ model: Krea2SingleStreamDiT) {
        quantize(model: model, filter: mixed48Filter)
    }



    public static func quantizeQ8(_ model: Krea2SingleStreamDiT) {
        quantize(model: model, filter: q8Filter)
    }
}


public enum Krea2DiTQuantization: String, CaseIterable, Equatable, Hashable, Sendable {
    case mixed4And8 = "mixed-4-8"
    case q8

    public func quantize(_ model: Krea2SingleStreamDiT) {
        switch self {
        case .mixed4And8:
            Krea2DiTQuantRecipe.quantizeMixed48(model)
        case .q8:
            Krea2DiTQuantRecipe.quantizeQ8(model)
        }
    }
}
