// VAEEncoderTests.swift
//
// Metadata tests are host-safe. Module-tree and forward assertions are explicitly Metal-gated.

import Foundation
import Testing
import MLX
@testable import Krea2VAE

@Test func vaeEncoderOnlyStructureContractHasExactRoots() {
    #expect(Krea2VAEEncoderModel.parameterRoots == ["encoder", "quant_conv"])
    #expect(Krea2VAEWeightLoader.encodePrefixes == ["encoder.", "quant_conv."])
    #expect(Krea2VAEEncoderModel.spatialScale == Krea2VAE.spatialScale)
    #expect(Krea2VAEEncoderModel.latentChannels == Krea2VAE.latentChannels)
}

@Test func vaeEncodePrefixFilterIsExact() {
    #expect(Krea2VAEWeightLoader.acceptsEncodeCheckpointKey("encoder.conv_in.weight"))
    #expect(Krea2VAEWeightLoader.acceptsEncodeCheckpointKey("quant_conv.bias"))

    #expect(!Krea2VAEWeightLoader.acceptsEncodeCheckpointKey("decoder.conv_out.weight"))
    #expect(!Krea2VAEWeightLoader.acceptsEncodeCheckpointKey("post_quant_conv.bias"))
    #expect(!Krea2VAEWeightLoader.acceptsEncodeCheckpointKey("encoder"))
    #expect(!Krea2VAEWeightLoader.acceptsEncodeCheckpointKey("encoder_extra.weight"))
}

@Test func vaeEncodePreparationFiltersDecodeWeightsRemapsAndDefaultsToBF16() throws {
    let expected = [
        "encoder.down_blocks.0.resnets.0.conv1.weight":
            Krea2VAEWeightMetadata(shape: [2, 1, 1, 1, 3]),
        "encoder.down_blocks.0.downsamplers.0.resample_conv.weight":
            Krea2VAEWeightMetadata(shape: [4, 1, 1, 3]),
        "quant_conv.weight": Krea2VAEWeightMetadata(shape: [32, 1, 1, 1, 32]),
        "quant_conv.bias": Krea2VAEWeightMetadata(shape: [32]),
    ]
    let checkpoint = [
        "encoder.down_blocks.0.conv1.weight":
            Krea2VAEWeightMetadata(shape: [2, 3, 1, 1, 1]),
        "encoder.down_blocks.2.resample.1.weight":
            Krea2VAEWeightMetadata(shape: [4, 3, 1, 1], dtype: .bfloat16),
        "quant_conv.weight": Krea2VAEWeightMetadata(shape: [32, 32, 1, 1, 1]),
        "quant_conv.bias": Krea2VAEWeightMetadata(shape: [32], dtype: .bfloat16),
        // Excluded namespaces must not participate in encode validation, even with bad dtype.
        "decoder.conv_out.weight": Krea2VAEWeightMetadata(shape: [1], dtype: .int32),
        "post_quant_conv.bias": Krea2VAEWeightMetadata(shape: [1], dtype: .int32),
    ]

    let prepared = try Krea2VAEWeightLoader.prepareEncoderMetadata(
        checkpoint, expected: expected)

    #expect(prepared.count == 4)
    #expect(Set(prepared.keys) == Set(expected.keys))
    #expect(
        prepared["encoder.down_blocks.0.resnets.0.conv1.weight"]?.shape
            == [2, 1, 1, 1, 3])
    #expect(
        prepared["encoder.down_blocks.0.downsamplers.0.resample_conv.weight"]?.shape
            == [4, 1, 1, 3])
    #expect(prepared["quant_conv.weight"]?.shape == [32, 1, 1, 1, 32])
    #expect(prepared.values.allSatisfy { $0.dtype == .bfloat16 })
    #expect(!prepared.keys.contains { $0.hasPrefix("decoder.") })
    #expect(!prepared.keys.contains { $0.hasPrefix("post_quant_conv.") })
}

@Test func vaeEncoderPreparationSupportsExplicitFloat32() throws {
    let expected = [
        "encoder.bias": Krea2VAEWeightMetadata(shape: [2]),
        "quant_conv.bias": Krea2VAEWeightMetadata(shape: [2]),
    ]
    let checkpoint = [
        "encoder.bias": Krea2VAEWeightMetadata(shape: [2], dtype: .bfloat16),
        "quant_conv.bias": Krea2VAEWeightMetadata(shape: [2]),
    ]

    let prepared = try Krea2VAEWeightLoader.prepareEncoderMetadata(
        checkpoint, expected: expected, computeDType: .float32)

    #expect(prepared.count == 2)
    #expect(prepared.values.allSatisfy { $0.dtype == .float32 })
}

@Test func vaeEncodePreparationRejectsMissingAndUnexpectedEncoderKeys() {
    let expected = [
        "encoder.bias": Krea2VAEWeightMetadata(shape: [2]),
        "quant_conv.bias": Krea2VAEWeightMetadata(shape: [2]),
    ]
    let checkpoint = [
        "encoder.bias": Krea2VAEWeightMetadata(shape: [2]),
        "encoder.unexpected": Krea2VAEWeightMetadata(shape: [1]),
        "decoder.ignored": Krea2VAEWeightMetadata(shape: [1]),
    ]

    do {
        _ = try Krea2VAEWeightLoader.prepareEncoderMetadata(checkpoint, expected: expected)
        Issue.record("Expected strict encoder key validation to fail")
    } catch Krea2VAEWeightsError.keyMismatch(let missing, let unexpected) {
        #expect(missing == ["quant_conv.bias"])
        #expect(unexpected == ["encoder.unexpected"])
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func vaeEncodePreparationRejectsShapeAndDTypeMismatches() {
    let expectedWeight = [
        "encoder.weight": Krea2VAEWeightMetadata(shape: [2, 1, 1, 1, 3]),
    ]
    do {
        _ = try Krea2VAEWeightLoader.prepareEncoderMetadata(
            ["encoder.weight": Krea2VAEWeightMetadata(shape: [2, 4, 1, 1, 1])],
            expected: expectedWeight,
            computeDType: .float32)
        Issue.record("Expected encoder shape validation to fail")
    } catch Krea2VAEWeightsError.shapeMismatch(let key, let expected, let actual) {
        #expect(key == "encoder.weight")
        #expect(expected == [2, 1, 1, 1, 3])
        #expect(actual == [2, 1, 1, 1, 4])
    } catch {
        Issue.record("Unexpected shape error: \(error)")
    }

    let expectedBias = ["quant_conv.bias": Krea2VAEWeightMetadata(shape: [2])]
    do {
        _ = try Krea2VAEWeightLoader.prepareEncoderMetadata(
            ["quant_conv.bias": Krea2VAEWeightMetadata(shape: [2], dtype: .int32)],
            expected: expectedBias)
        Issue.record("Expected encoder dtype validation to fail")
    } catch Krea2VAEWeightsError.dtypeMismatch(let key, let expected, let actual) {
        #expect(key == "quant_conv.bias")
        #expect(expected == .bfloat16)
        #expect(actual == .int32)
    } catch {
        Issue.record("Unexpected dtype error: \(error)")
    }
}

@Test func vaeEncoderPreparationRejectsUnsupportedComputeDType() {
    let expected = ["quant_conv.bias": Krea2VAEWeightMetadata(shape: [1])]
    let checkpoint = ["quant_conv.bias": Krea2VAEWeightMetadata(shape: [1])]

    do {
        _ = try Krea2VAEWeightLoader.prepareEncoderMetadata(
            checkpoint, expected: expected, computeDType: .float16)
        Issue.record("Expected unsupported float16 encoder loading to fail")
    } catch Krea2VAEWeightsError.unsupportedComputeDType(let dtype) {
        #expect(dtype == .float16)
    } catch {
        Issue.record("Unexpected compute dtype error: \(error)")
    }
}

@Test func vaeEncoderLiveModuleTreeHasExpectedCountShapesAndDTypesWhenMetalIsEnabled() {
    guard ProcessInfo.processInfo.environment["TWISTER_RUN_METAL_TESTS"] == "1" else {
        return
    }

    let model = Krea2VAEEncoderModel()
    let parameters = model.parameters().flattened()
    let byKey = Dictionary(uniqueKeysWithValues: parameters)

    #expect(Set(model.children().keys) == Set(Krea2VAEEncoderModel.parameterRoots))
    #expect(parameters.count == 86)
    #expect(parameters.allSatisfy { Krea2VAEWeightLoader.acceptsEncodeCheckpointKey($0.0) })
    #expect(parameters.allSatisfy { $0.1.dtype == .float32 })
    #expect(!parameters.contains { $0.0.hasPrefix("decoder.") })
    #expect(!parameters.contains { $0.0.hasPrefix("post_quant_conv.") })
    #expect(byKey["encoder.conv_in.weight"]?.shape == [96, 3, 3, 3, 3])
    #expect(byKey["encoder.conv_out.weight"]?.shape == [32, 3, 3, 3, 384])
    #expect(byKey["quant_conv.weight"]?.shape == [32, 1, 1, 1, 32])
    #expect(byKey["quant_conv.bias"]?.shape == [32])
}

@Test func vaeEncoderTinyEncodeMatchesFullVAEInFloat32AndBF16WhenMetalIsEnabled() {
    guard ProcessInfo.processInfo.environment["TWISTER_RUN_METAL_TESTS"] == "1" else {
        return
    }

    let encoderOnly = Krea2VAEEncoderModel()
    encoderOnly.update(parameters: encoderOnly.mapParameters { $0 + Float(0.001) })
    eval(encoderOnly)

    let full = Krea2VAE()
    full.update(parameters: encoderOnly.parameters())

    let pixelCount = 3 * 16 * 24
    let pixelValues: [Float] = (0 ..< pixelCount).map { index -> Float in
        let value = Float((index * 37) % 257)
        return value / Float(128) - Float(1)
    }
    let pixels = MLXArray(pixelValues).reshaped([1, 3, 16, 24])
    let encoderFloat32 = encoderOnly.encode(pixels)
    let fullFloat32 = full.encode(pixels)
    eval(encoderFloat32, fullFloat32)

    #expect(encoderFloat32.shape == [1, 16, 2, 3])
    #expect(encoderFloat32.dtype == DType.float32)
    #expect(allClose(encoderFloat32, fullFloat32, rtol: 0, atol: 0).item(Bool.self))

    encoderOnly.update(parameters: encoderOnly.mapParameters { $0.asType(DType.bfloat16) })
    eval(encoderOnly)
    full.update(parameters: encoderOnly.parameters())

    let pixelsBF16 = pixels.asType(DType.bfloat16)
    let encoderBF16 = encoderOnly.encode(pixelsBF16)
    let fullBF16 = full.encode(pixelsBF16)
    eval(encoderBF16, fullBF16)

    #expect(encoderBF16.shape == [1, 16, 2, 3])
    #expect(encoderBF16.dtype == DType.bfloat16)
    #expect(allClose(encoderBF16, fullBF16, rtol: 0, atol: 0).item(Bool.self))
    #expect(
        allClose(
            encoderBF16.asType(DType.float32), encoderFloat32,
            rtol: 0.05, atol: 0.05
        ).item(Bool.self))
    #expect(
        encoderBF16.asType(DType.float32).asArray(Float.self).allSatisfy { $0.isFinite })
}

@Test func vaeEncoderRealWeightBF16ParityWhenExplicitlyEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["TWISTER_RUN_REAL_VAE_ENCODER"] == "1" else { return }
    guard let path = environment["TWISTER_VAE_WEIGHTS"], !path.isEmpty else {
        Issue.record("TWISTER_VAE_WEIGHTS is required for the real encoder parity gate")
        return
    }

    let side = 256
    let plane = side * side
    var values = [Float](repeating: 0, count: 3 * plane)
    for y in 0 ..< side {
        for x in 0 ..< side {
            let index = y * side + x
            values[index] = Float(x) / Float(side - 1) * 2 - 1
            values[plane + index] = Float(y) / Float(side - 1) * 2 - 1
            values[2 * plane + index] = Float((x * 17 + y * 31) % 257) / 128 - 1
        }
    }
    let weights = URL(fileURLWithPath: path)

    func encode(_ dtype: DType) throws -> (shape: [Int], values: [Float]) {
        defer { MLX.Memory.clearCache() }
        let model = Krea2VAEEncoderModel()
        try Krea2VAEWeightLoader.load(into: model, file: weights, computeDType: dtype)
        let pixels = MLXArray(values).reshaped([1, 3, side, side]).asType(dtype)
        let latent = model.encode(pixels).asType(.float32)
        eval(latent)
        return (latent.shape, latent.asArray(Float.self))
    }

    let reference = try encode(.float32)
    let candidate = try encode(.bfloat16)
    #expect(reference.shape == candidate.shape)
    #expect(reference.values.count == candidate.values.count)
    var dot = 0.0
    var referenceNorm = 0.0
    var candidateNorm = 0.0
    var squaredError = 0.0
    for index in reference.values.indices {
        let lhs = Double(reference.values[index])
        let rhs = Double(candidate.values[index])
        #expect(lhs.isFinite && rhs.isFinite)
        dot += lhs * rhs
        referenceNorm += lhs * lhs
        candidateNorm += rhs * rhs
        squaredError += (lhs - rhs) * (lhs - rhs)
    }
    let cosine = dot / sqrt(referenceNorm * candidateNorm)
    let normalizedRMSE = sqrt(squaredError / referenceNorm)
    print(String(format: "real VAE encoder BF16: cosine=%.9f normalized-RMSE=%.7f",
                 cosine, normalizedRMSE))
    #expect(cosine >= 0.999)
    #expect(normalizedRMSE <= 0.03)
}

@Test func vaeRealWeight512RoundTripWhenExplicitlyEnabled() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["TWISTER_RUN_REAL_VAE_ENCODER"] == "1" else { return }
    guard let path = environment["TWISTER_VAE_WEIGHTS"], !path.isEmpty else {
        Issue.record("TWISTER_VAE_WEIGHTS is required for the real VAE round-trip gate")
        return
    }

    let side = 512
    let plane = side * side
    var source = [Float](repeating: 0, count: 3 * plane)
    for y in 0 ..< side {
        for x in 0 ..< side {
            let index = y * side + x
            source[index] = Float(x) / Float(side - 1) * 2 - 1
            source[plane + index] = Float(y) / Float(side - 1) * 2 - 1
            source[2 * plane + index] = Float((x / 32 + y / 32) % 2) * 1.6 - 0.8
        }
    }
    let weights = URL(fileURLWithPath: path)

    func encode() throws -> [Float] {
        defer { MLX.Memory.clearCache() }
        let encoder = Krea2VAEEncoderModel()
        try Krea2VAEWeightLoader.load(
            into: encoder,
            file: weights,
            computeDType: .bfloat16)
        let pixels = MLXArray(source).reshaped([1, 3, side, side]).asType(.bfloat16)
        let latent = encoder.encode(pixels).asType(.float32)
        eval(latent)
        #expect(latent.shape == [1, 16, 64, 64])
        return latent.asArray(Float.self)
    }

    func decode(_ latentValues: [Float]) throws -> [Float] {
        defer { MLX.Memory.clearCache() }
        let decoder = Krea2VAEDecoderModel()
        try Krea2VAEWeightLoader.load(
            into: decoder,
            file: weights,
            computeDType: .bfloat16)
        let latent = MLXArray(latentValues)
            .reshaped([1, 16, 64, 64])
            .asType(.bfloat16)
        let pixels = try decoder.decode(latent).asType(.float32)
        eval(pixels)
        #expect(pixels.shape == [1, 3, side, side])
        return pixels.asArray(Float.self)
    }

    let latent = try encode()
    #expect(latent.allSatisfy { $0.isFinite })
    let reconstructed = try decode(latent)
    #expect(reconstructed.allSatisfy { $0.isFinite })
    #expect(reconstructed.min() ?? -.infinity > -4)
    #expect(reconstructed.max() ?? .infinity < 4)
}
