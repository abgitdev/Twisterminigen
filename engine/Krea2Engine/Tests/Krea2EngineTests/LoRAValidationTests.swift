import Foundation
import Krea2DiT
import MLX
import Testing

@Suite(.serialized) struct LoRAValidationTests {
    @Test func inspectAndApplyUseTheSameValidatedAdapter() throws {
        let fixture = try Fixture(arrays: Self.validArrays(includeAlpha: true))
        defer { fixture.remove() }
        let config = Self.tinyConfig()

        let stats = try Krea2DiTLoRALoader.inspect(
            adapters: [.init(path: fixture.url, scale: 0.5)], config: config)
        let item = try #require(stats.first)
        #expect(item.matchedTargets == 1)
        #expect(item.totalTargets == 40)
        #expect(item.matchedKeys == 3)
        #expect(item.totalKeys == 3)
        #expect(item.unmatchedKeys.isEmpty)
        #expect(item.tensorBytes == 100)
        #expect(abs(item.coverage - 0.025) < 1e-12)

        let model = Krea2SingleStreamDiT(config: config)
        let input = MLXArray.ones([1, config.inChannels])
        let before = model.first(input)
        let applied = try Krea2DiTLoRALoader.apply(
            to: model, adapters: [.init(path: fixture.url, scale: 0.5)])
        let after = model.first(input)
        eval(before, after)

        #expect(applied == stats)
        #expect(model.first is Krea2LoRALinear)
        let maximumError = MLX.max(MLX.abs((after - before) - 4)).item(Float.self)
        #expect(maximumError < 1e-5)
    }

    @Test func rejectsFilesWithoutCompatibleTargets() throws {
        let fixture = try Fixture(arrays: ["unrelated.weight": MLXArray.ones([2, 2])])
        defer { fixture.remove() }

        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: fixture.url)], config: Self.tinyConfig())
        }) {
            if case .noMatchedTargets = $0 { return true }
            return false
        }
    }

    @Test func rejectsIncompleteAndAmbiguousPairs() throws {
        let incomplete = try Fixture(arrays: ["first.lora_B.weight": MLXArray.ones([8, 2])])
        defer { incomplete.remove() }
        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: incomplete.url)], config: Self.tinyConfig())
        }) {
            if case .incompletePair(target: "first", role: "down") = $0 { return true }
            return false
        }

        var arrays = Self.validArrays()
        arrays["first.lora_up.weight"] = MLXArray.ones([8, 2])
        let ambiguous = try Fixture(arrays: arrays)
        defer { ambiguous.remove() }
        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: ambiguous.url)], config: Self.tinyConfig())
        }) {
            if case .ambiguousKeys(target: "first", role: "up", keys: let keys) = $0 {
                return keys.count == 2
            }
            return false
        }
    }

    @Test func rejectsWrongRankAndArchitectureShape() throws {
        let rankOne = try Fixture(arrays: [
            "first.lora_A.weight": MLXArray.ones([8]),
            "first.lora_B.weight": MLXArray.ones([8, 2]),
        ])
        defer { rankOne.remove() }
        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: rankOne.url)], config: Self.tinyConfig())
        }) {
            if case .invalidRank(key: "first.lora_A.weight", value: 1) = $0 { return true }
            return false
        }

        let wrongShape = try Fixture(arrays: [
            "first.lora_A.weight": MLXArray.ones([2, 5]),
            "first.lora_B.weight": MLXArray.ones([8, 2]),
        ])
        defer { wrongShape.remove() }
        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: wrongShape.url)], config: Self.tinyConfig())
        }) {
            if case .invalidShape(
                key: "first.lora_A.weight", expected: [2, 4], actual: [2, 5]) = $0 { return true }
            return false
        }
    }

    @Test func rejectsNonFiniteUnsupportedAndInvalidAlphaTensors() throws {
        var nonFiniteArrays = Self.validArrays()
        nonFiniteArrays["first.lora_B.weight"] = MLXArray(
            [Float.nan] + Array(repeating: Float(1), count: 15)).reshaped([8, 2])
        let nonFinite = try Fixture(arrays: nonFiniteArrays)
        defer { nonFinite.remove() }
        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: nonFinite.url)], config: Self.tinyConfig())
        }) {
            if case .nonFiniteTensor("first.lora_B.weight") = $0 { return true }
            return false
        }

        var integerArrays = Self.validArrays()
        integerArrays["first.lora_A.weight"] = MLXArray(Array(repeating: Int32(1), count: 8))
            .reshaped([2, 4])
        let integer = try Fixture(arrays: integerArrays)
        defer { integer.remove() }
        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: integer.url)], config: Self.tinyConfig())
        }) {
            if case .unsupportedDType(key: "first.lora_A.weight", dtype: _) = $0 { return true }
            return false
        }

        var alphaArrays = Self.validArrays()
        alphaArrays["first.alpha"] = MLXArray([Float(1), 2])
        let invalidAlpha = try Fixture(arrays: alphaArrays)
        defer { invalidAlpha.remove() }
        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: invalidAlpha.url)], config: Self.tinyConfig())
        }) {
            if case .invalidAlpha("first.alpha") = $0 { return true }
            return false
        }
    }

    @Test func rejectsDuplicatePathsInvalidScalesAndSymlinks() throws {
        let fixture = try Fixture(arrays: Self.validArrays())
        defer { fixture.remove() }

        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: fixture.url), .init(path: fixture.url)],
                config: Self.tinyConfig())
        }) {
            if case .duplicateFile = $0 { return true }
            return false
        }

        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: fixture.url, scale: .nan)], config: Self.tinyConfig())
        }) {
            if case .invalidScale = $0 { return true }
            return false
        }

        let link = fixture.directory.appendingPathComponent("linked.safetensors")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.url)
        Self.expectError({
            _ = try Krea2DiTLoRALoader.inspect(
                adapters: [.init(path: link)], config: Self.tinyConfig())
        }) {
            if case .unsafeFile = $0 { return true }
            return false
        }
    }

    private static func validArrays(includeAlpha: Bool = false) -> [String: MLXArray] {
        var arrays = [
            "first.lora_A.weight": MLXArray.ones([2, 4]),
            "first.lora_B.weight": MLXArray.ones([8, 2]),
        ]
        if includeAlpha { arrays["first.alpha"] = MLXArray(Float(2)) }
        return arrays
    }

    private static func tinyConfig() -> Krea2DiTConfig {
        var config = Krea2DiTConfig()
        config.features = 8
        config.tdim = 4
        config.txtdim = 8
        config.heads = 1
        config.kvheads = 1
        config.multiplier = 2
        config.layers = 0
        config.patch = 2
        config.channels = 1
        config.txtheads = 1
        config.txtkvheads = 1
        config.txtlayers = 1
        return config
    }

    private static func expectError(
        _ body: () throws -> Void,
        matches: (Krea2DiTLoRAError) -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            try body()
            Issue.record("Expected Krea2DiTLoRAError", sourceLocation: sourceLocation)
        } catch let error as Krea2DiTLoRAError {
            #expect(matches(error), "Unexpected error: \(error)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error type: \(error)", sourceLocation: sourceLocation)
        }
    }
}

private struct Fixture {
    let directory: URL
    let url: URL

    init(arrays: [String: MLXArray]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Twisterminigen-LoRA-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("adapter.safetensors")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try MLX.save(arrays: arrays, url: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
