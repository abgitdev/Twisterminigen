// Krea2DiTLoRALoader.swift
//










import Foundation
import MLX
import MLXNN

public enum Krea2DiTLoRAError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case fileNotFound(String)
    case unsafeFile(String)
    case duplicateFile(String)
    case invalidScale(Float)
    case noMatchedTargets(String)
    case incompletePair(target: String, role: String)
    case ambiguousKeys(target: String, role: String, keys: [String])
    case unsupportedDType(key: String, dtype: String)
    case invalidRank(key: String, value: Int)
    case invalidShape(key: String, expected: [Int], actual: [Int])
    case nonFiniteTensor(String)
    case invalidAlpha(String)
    case targetNotFound(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path): return "LoRA file not found: \(path)"
        case .unsafeFile(let path): return "LoRA file is unsafe or is not a regular file: \(path)"
        case .duplicateFile(let path): return "LoRA file was added more than once: \(path)"
        case .invalidScale(let value): return "LoRA scale must be finite and |scale| <= 10; received \(value)"
        case .noMatchedTargets(let file): return "LoRA \(file) contains no compatible Krea 2 targets"
        case let .incompletePair(target, role): return "LoRA target \(target) has no \(role) matrix"
        case let .ambiguousKeys(target, role, keys):
            return "LoRA target \(target) contains ambiguous \(role) keys: \(keys.joined(separator: ", "))"
        case let .unsupportedDType(key, dtype): return "LoRA tensor \(key) has unsupported dtype \(dtype)"
        case let .invalidRank(key, value): return "LoRA tensor \(key) has invalid rank \(value)"
        case let .invalidShape(key, expected, actual):
            return "LoRA tensor \(key) has shape \(actual); expected \(expected)"
        case .nonFiniteTensor(let key): return "LoRA tensor \(key) contains NaN or Inf"
        case .invalidAlpha(let key): return "LoRA alpha \(key) must be one finite scalar"
        case .targetNotFound(let path): return "Target \(path) was not found in the DiT module tree"
        }
    }

    public var errorDescription: String? { description }
}




public final class Krea2LoRALinear: Linear {
    public struct Adapter {
        public let loraA: MLXArray   // (in, rank), float32
        public let loraB: MLXArray
        public let scale: Float
    }

    public let base: Linear
    public let adapters: [Adapter]

    public init(base: Linear, adapters: [Adapter]) {
        self.base = base
        self.adapters = adapters
        super.init(weight: base.weight, bias: base.bias)
    }

    public override var shape: (Int, Int) { base.shape }

    public override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let baseOut = base(x)
        guard !adapters.isEmpty else { return baseOut }
        let xf = x.asType(.float32)
        var delta = matmul(matmul(xf, adapters[0].loraA), adapters[0].loraB) * adapters[0].scale
        for adapter in adapters.dropFirst() {
            delta = delta + matmul(matmul(xf, adapter.loraA), adapter.loraB) * adapter.scale
        }
        return baseOut + delta.asType(baseOut.dtype)
    }
}


public struct Krea2DiTLoRAConfig: Sendable {
    public var path: URL
    public var scale: Float
    public init(path: URL, scale: Float = 1.0) {
        self.path = path
        self.scale = scale
    }
}

public enum Krea2DiTLoRALoader {
    /// Import-time inspection evaluates every matched tensor. Keeping the ceiling at 2 GiB avoids
    /// turning a malformed or unusually large adapter into an uncontrolled memory-pressure event.
    public static let maximumFileBytes: Int64 = 2 * 1_024 * 1_024 * 1_024


    public struct Stats: Sendable, Equatable {
        public let file: String
        public let matchedTargets: Int
        public let totalTargets: Int
        public let matchedKeys: Int
        public let totalKeys: Int
        public let unmatchedKeys: [String]
        public let tensorBytes: Int64

        public var coverage: Double {
            totalTargets > 0 ? Double(matchedTargets) / Double(totalTargets) : 0
        }
    }

    private static let prefixes = ["", "transformer.", "diffusion_model.", "base_model.model."]
    private static let matrixSuffixPairs: [(up: String, down: String)] = [
        ("lora_B.weight", "lora_A.weight"),
        ("lora_B.default.weight", "lora_A.default.weight"),
        ("lora_up.weight", "lora_down.weight"),
        ("lora_up.default.weight", "lora_down.default.weight"),
        ("lora.up.weight", "lora.down.weight"),
        ("lora.up.default.weight", "lora.down.default.weight"),
    ]

    private struct ValidatedPair {
        let target: Krea2DiTLoRAMapping.Target
        let upKey: String
        let up: MLXArray
        let downKey: String
        let down: MLXArray
        let alphaScale: Float
    }

    private struct ValidatedAdapter {
        let config: Krea2DiTLoRAConfig
        let pairs: [ValidatedPair]
        let stats: Stats
    }

    /// Validates LoRA files without constructing or loading the base DiT. This is the same
    /// validation path used by `apply`, so an adapter accepted during import cannot fail later
    /// because of key, dtype, rank, shape, or finite-value differences.
    public static func inspect(
        adapters: [Krea2DiTLoRAConfig], config: Krea2DiTConfig = Krea2DiTConfig()
    ) throws -> [Stats] {
        try validate(adapters: adapters, modelConfig: config).map(\.stats)
    }




    @discardableResult
    public static func apply(
        to model: Krea2SingleStreamDiT, adapters: [Krea2DiTLoRAConfig]
    ) throws -> [Stats] {
        guard !adapters.isEmpty else { return [] }
        let validated = try validate(adapters: adapters, modelConfig: model.config)

        var perTarget: [String: [Krea2LoRALinear.Adapter]] = [:]

        for adapter in validated {
            for pair in adapter.pairs {
                let loraA = pair.down.asType(.float32).transposed()                 // (in, rank)
                let loraB = pair.up.asType(.float32).transposed() * pair.alphaScale // (rank, out)
                perTarget[pair.target.modulePath, default: []].append(
                    Krea2LoRALinear.Adapter(
                        loraA: loraA,
                        loraB: loraB,
                        scale: adapter.config.scale))
            }
        }

        let leaves = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
        var wrapped: [(String, Module)] = []
        var wrappedPaths = Set<String>()
        for (path, targetAdapters) in perTarget {
            guard let base = leaves[path] as? Linear else {
                throw Krea2DiTLoRAError.targetNotFound(path)
            }
            let (outputFeatures, inputFeatures) = base.shape
            for adapter in targetAdapters {
                let expectedA = [inputFeatures, adapter.loraA.dim(1)]
                guard adapter.loraA.shape == expectedA else {
                    throw Krea2DiTLoRAError.invalidShape(
                        key: "\(path).lora_A", expected: expectedA, actual: adapter.loraA.shape)
                }
                let expectedB = [adapter.loraA.dim(1), outputFeatures]
                guard adapter.loraB.shape == expectedB else {
                    throw Krea2DiTLoRAError.invalidShape(
                        key: "\(path).lora_B", expected: expectedB, actual: adapter.loraB.shape)
                }
            }
            wrapped.append((path, Krea2LoRALinear(base: base, adapters: targetAdapters)))
            wrappedPaths.insert(path)
        }






        for (prefix, count) in [("tmlp", 3), ("tproj", 2), ("txtmlp", 4)] {
            guard (0 ..< count).contains(where: { wrappedPaths.contains("\(prefix).\($0)") }) else { continue }
            for i in 0 ..< count {
                let path = "\(prefix).\(i)"
                guard !wrappedPaths.contains(path), let original = leaves[path] else { continue }
                wrapped.append((path, original))
                wrappedPaths.insert(path)
            }
        }

        model.update(modules: ModuleChildren.unflattened(wrapped))
        eval(model)
        return validated.map(\.stats)
    }

    private static func validate(
        adapters: [Krea2DiTLoRAConfig], modelConfig: Krea2DiTConfig
    ) throws -> [ValidatedAdapter] {
        let targets = Krea2DiTLoRAMapping.targets(config: modelConfig)
        var seenPaths = Set<String>()
        var result: [ValidatedAdapter] = []
        result.reserveCapacity(adapters.count)

        for requested in adapters {
            guard requested.scale.isFinite, abs(requested.scale) <= 10 else {
                throw Krea2DiTLoRAError.invalidScale(requested.scale)
            }
            let url = requested.path.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Krea2DiTLoRAError.fileNotFound(url.path)
            }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard url.pathExtension.lowercased() == "safetensors",
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  FileManager.default.isReadableFile(atPath: url.path),
                  let fileBytes = values.fileSize,
                  fileBytes > 0,
                  Int64(fileBytes) <= maximumFileBytes else {
                throw Krea2DiTLoRAError.unsafeFile(url.path)
            }

            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard seenPaths.insert(canonicalPath).inserted else {
                throw Krea2DiTLoRAError.duplicateFile(canonicalPath)
            }

            let weights = try loadArrays(url: url)
            var tensorBytes: Int64 = 0
            for tensor in weights.values {
                let (sum, overflow) = tensorBytes.addingReportingOverflow(Int64(tensor.nbytes))
                guard !overflow, sum <= maximumFileBytes else {
                    throw Krea2DiTLoRAError.unsafeFile(url.path)
                }
                tensorBytes = sum
            }

            var claimedKeys: [String: String] = [:]
            var matchedKeys = Set<String>()
            var pairs: [ValidatedPair] = []

            for target in targets {
                let candidates = [target.modulePath] + target.aliases
                let upMatches = matrixMatches(weights, candidates, isUp: true)
                let downMatches = matrixMatches(weights, candidates, isUp: false)
                guard !upMatches.isEmpty || !downMatches.isEmpty else { continue }

                guard !upMatches.isEmpty else {
                    throw Krea2DiTLoRAError.incompletePair(target: target.modulePath, role: "up")
                }
                guard !downMatches.isEmpty else {
                    throw Krea2DiTLoRAError.incompletePair(target: target.modulePath, role: "down")
                }
                guard upMatches.count == 1 else {
                    throw Krea2DiTLoRAError.ambiguousKeys(
                        target: target.modulePath, role: "up", keys: upMatches.map(\.0))
                }
                guard downMatches.count == 1 else {
                    throw Krea2DiTLoRAError.ambiguousKeys(
                        target: target.modulePath, role: "down", keys: downMatches.map(\.0))
                }

                let (upKey, up) = upMatches[0]
                let (downKey, down) = downMatches[0]
                try claim(key: upKey, for: target.modulePath, claimedKeys: &claimedKeys)
                try claim(key: downKey, for: target.modulePath, claimedKeys: &claimedKeys)
                try validateMatrix(up, key: upKey)
                try validateMatrix(down, key: downKey)

                let rank = down.shape[0]
                guard rank > 0 else {
                    throw Krea2DiTLoRAError.invalidRank(key: downKey, value: rank)
                }
                guard up.shape[1] == rank else {
                    throw Krea2DiTLoRAError.invalidShape(
                        key: upKey, expected: [up.shape[0], rank], actual: up.shape)
                }

                let expected = expectedLinearShape(for: target.modulePath, config: modelConfig)
                guard let expected else {
                    throw Krea2DiTLoRAError.targetNotFound(target.modulePath)
                }
                let expectedDown = [rank, expected.input]
                guard down.shape == expectedDown else {
                    throw Krea2DiTLoRAError.invalidShape(
                        key: downKey, expected: expectedDown, actual: down.shape)
                }
                let expectedUp = [expected.output, rank]
                guard up.shape == expectedUp else {
                    throw Krea2DiTLoRAError.invalidShape(
                        key: upKey, expected: expectedUp, actual: up.shape)
                }

                let alphaMatches = alphaMatches(weights, candidates)
                guard alphaMatches.count <= 1 else {
                    throw Krea2DiTLoRAError.ambiguousKeys(
                        target: target.modulePath, role: "alpha", keys: alphaMatches.map(\.0))
                }
                var alphaScale: Float = 1
                if let (alphaKey, alpha) = alphaMatches.first {
                    try claim(key: alphaKey, for: target.modulePath, claimedKeys: &claimedKeys)
                    guard supported(dtype: alpha.dtype), alpha.size == 1,
                          MLX.all(MLX.isFinite(alpha)).item(Bool.self) else {
                        throw Krea2DiTLoRAError.invalidAlpha(alphaKey)
                    }
                    let alphaValue = alpha.asType(.float32).item(Float.self)
                    guard alphaValue.isFinite else {
                        throw Krea2DiTLoRAError.invalidAlpha(alphaKey)
                    }
                    alphaScale = alphaValue / Float(rank)
                    guard alphaScale.isFinite else {
                        throw Krea2DiTLoRAError.invalidAlpha(alphaKey)
                    }
                    matchedKeys.insert(alphaKey)
                }

                matchedKeys.insert(upKey)
                matchedKeys.insert(downKey)
                pairs.append(ValidatedPair(
                    target: target,
                    upKey: upKey,
                    up: up,
                    downKey: downKey,
                    down: down,
                    alphaScale: alphaScale))
            }

            guard !pairs.isEmpty else {
                throw Krea2DiTLoRAError.noMatchedTargets(url.lastPathComponent)
            }
            let unmatched = Set(weights.keys).subtracting(matchedKeys).sorted()
            let stats = Stats(
                file: url.lastPathComponent,
                matchedTargets: pairs.count,
                totalTargets: targets.count,
                matchedKeys: matchedKeys.count,
                totalKeys: weights.count,
                unmatchedKeys: unmatched,
                tensorBytes: tensorBytes)
            result.append(ValidatedAdapter(
                config: Krea2DiTLoRAConfig(path: url, scale: requested.scale),
                pairs: pairs,
                stats: stats))
        }
        return result
    }

    private static func validateMatrix(_ tensor: MLXArray, key: String) throws {
        guard supported(dtype: tensor.dtype) else {
            throw Krea2DiTLoRAError.unsupportedDType(key: key, dtype: "\(tensor.dtype)")
        }
        guard tensor.ndim == 2 else {
            throw Krea2DiTLoRAError.invalidRank(key: key, value: tensor.ndim)
        }
        guard MLX.all(MLX.isFinite(tensor)).item(Bool.self) else {
            throw Krea2DiTLoRAError.nonFiniteTensor(key)
        }
    }

    private static func supported(dtype: DType) -> Bool {
        dtype == .float16 || dtype == .bfloat16 || dtype == .float32
    }

    private static func claim(
        key: String, for target: String, claimedKeys: inout [String: String]
    ) throws {
        if let previous = claimedKeys[key], previous != target {
            throw Krea2DiTLoRAError.ambiguousKeys(
                target: "\(previous) / \(target)", role: "mapping", keys: [key])
        }
        claimedKeys[key] = target
    }

    private static func expectedLinearShape(
        for path: String, config: Krea2DiTConfig
    ) -> (output: Int, input: Int)? {
        switch path {
        case "first": return (config.features, config.inChannels)
        case "tmlp.0": return (config.features, config.tdim)
        case "tmlp.2": return (config.features, config.features)
        case "tproj.1": return (config.features * 6, config.features)
        case "txtmlp.1": return (config.features, config.txtdim)
        case "txtmlp.3": return (config.features, config.features)
        case "txtfusion.projector": return (1, config.txtlayers)
        case "last.linear": return (config.patch * config.patch * config.channels, config.features)
        default: break
        }

        let isTextFusion = path.hasPrefix("txtfusion.")
        guard isTextFusion || path.hasPrefix("blocks.") else { return nil }
        let features = isTextFusion ? config.txtdim : config.features
        let heads = isTextFusion ? config.txtheads : config.heads
        let kvheads = isTextFusion ? config.txtkvheads : config.kvheads
        guard features > 0, heads > 0, features % heads == 0 else { return nil }
        let kvFeatures = features / heads * kvheads
        let intermediate = ((2 * features / 3 * config.multiplier + 127) / 128) * 128

        if path.hasSuffix(".attn.wq") || path.hasSuffix(".attn.gate")
            || path.hasSuffix(".attn.wo") {
            return (features, features)
        }
        if path.hasSuffix(".attn.wk") || path.hasSuffix(".attn.wv") {
            return (kvFeatures, features)
        }
        if path.hasSuffix(".mlp.gate") || path.hasSuffix(".mlp.up") {
            return (intermediate, features)
        }
        if path.hasSuffix(".mlp.down") {
            return (features, intermediate)
        }
        return nil
    }

    /// Finds every matching key. Accepting the first one silently would make adapter behavior
    /// dependent on suffix ordering when a file contains two naming conventions for one target.
    private static func matrixMatches(
        _ weights: [String: MLXArray], _ candidates: [String], isUp: Bool
    ) -> [(String, MLXArray)] {
        var keys = Set<String>()
        for candidate in candidates {
            for prefix in prefixes {
                for pair in matrixSuffixPairs {
                    let suffix = isUp ? pair.up : pair.down
                    let key = "\(prefix)\(candidate).\(suffix)"
                    if weights[key] != nil { keys.insert(key) }
                }
            }
            let flat = candidate.replacingOccurrences(of: ".", with: "_")
            let flatSuffix = isUp ? "lora_up" : "lora_down"
            for key in ["lora_unet_\(flat).\(flatSuffix).weight", "lora_unet_\(flat).\(flatSuffix).default.weight"] {
                if weights[key] != nil { keys.insert(key) }
            }
        }
        return keys.sorted().compactMap { key in weights[key].map { (key, $0) } }
    }

    private static func alphaMatches(
        _ weights: [String: MLXArray], _ candidates: [String]
    ) -> [(String, MLXArray)] {
        var keys = Set<String>()
        for candidate in candidates {
            for prefix in prefixes {
                let key = "\(prefix)\(candidate).alpha"
                if weights[key] != nil { keys.insert(key) }
            }
            let flat = candidate.replacingOccurrences(of: ".", with: "_")
            let key = "lora_unet_\(flat).alpha"
            if weights[key] != nil { keys.insert(key) }
        }
        return keys.sorted().compactMap { key in weights[key].map { (key, $0) } }
    }
}
