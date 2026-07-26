// VAEDecoderTests.swift
//
// Host-safe tests use pure tensor metadata: no forward, eval, item(), MLXArray allocation,
// safetensors files, or real weights. The live Module-tree assertion is explicitly Metal-gated.

import Foundation
import Testing
import MLX
@testable import Krea2VAE

@Test func vaeDecoderOnlyStructureContractHasExactRoots() {
    #expect(Krea2VAEDecoderModel.parameterRoots == ["decoder", "post_quant_conv"])
    #expect(
        Krea2VAE.parameterRoots
            == ["decoder", "post_quant_conv", "encoder", "quant_conv"])
    #expect(Krea2VAEWeightLoader.decodePrefixes == ["decoder.", "post_quant_conv."])
    #expect(Krea2VAEDecoderModel.spatialScale == Krea2VAE.spatialScale)
    #expect(Krea2VAEDecoderModel.latentChannels == Krea2VAE.latentChannels)
}

@Test func vaeLiveModuleTreesMatchStructureContractWhenMetalIsEnabled() {
    guard ProcessInfo.processInfo.environment["TWISTER_RUN_METAL_TESTS"] == "1" else {
        return
    }

    let decoderOnly = Krea2VAEDecoderModel()
    let decoderRoots = Set(decoderOnly.children().keys)
    let decoderParameters = decoderOnly.parameters().flattened()
    #expect(decoderRoots == Set(Krea2VAEDecoderModel.parameterRoots))
    #expect(decoderParameters.count == 108)
    #expect(decoderParameters.allSatisfy {
        Krea2VAEWeightLoader.acceptsDecodeCheckpointKey($0.0)
    })
    #expect(!decoderParameters.contains { $0.0.hasPrefix("encoder.") })
    #expect(!decoderParameters.contains { $0.0.hasPrefix("quant_conv.") })

    let full = Krea2VAE()
    let fullKeys = full.parameters().flattened().map(\.0)
    #expect(Set(full.children().keys) == Set(Krea2VAE.parameterRoots))
    #expect(fullKeys.count == 194)
    #expect(fullKeys.contains { $0.hasPrefix("encoder.") })
    #expect(fullKeys.contains { $0.hasPrefix("quant_conv.") })
}

@Test func vaeDecodePrefixFilterIsExact() {
    #expect(Krea2VAEWeightLoader.acceptsDecodeCheckpointKey("decoder.conv_in.weight"))
    #expect(Krea2VAEWeightLoader.acceptsDecodeCheckpointKey("post_quant_conv.bias"))

    #expect(!Krea2VAEWeightLoader.acceptsDecodeCheckpointKey("encoder.conv_in.weight"))
    #expect(!Krea2VAEWeightLoader.acceptsDecodeCheckpointKey("quant_conv.weight"))
    #expect(!Krea2VAEWeightLoader.acceptsDecodeCheckpointKey("decoder"))
    #expect(!Krea2VAEWeightLoader.acceptsDecodeCheckpointKey("decoder_extra.weight"))
}

@Test func vaeDecodePreparationFiltersEncodeWeightsAndConvertsLayout() throws {
    let expected = [
        "decoder.conv.weight": Krea2VAEWeightMetadata(shape: [2, 1, 1, 1, 3]),
        "decoder.block.resample_conv.weight": Krea2VAEWeightMetadata(shape: [4, 1, 1, 3]),
        "post_quant_conv.bias": Krea2VAEWeightMetadata(shape: [2]),
    ]
    let checkpoint = [
        "decoder.conv.weight": Krea2VAEWeightMetadata(shape: [2, 3, 1, 1, 1]),
        "decoder.block.resample.1.weight": Krea2VAEWeightMetadata(shape: [4, 3, 1, 1]),
        "post_quant_conv.bias": Krea2VAEWeightMetadata(shape: [2]),
        // Excluded namespaces must not participate in decode validation, even with bad dtype.
        "encoder.conv_in.weight": Krea2VAEWeightMetadata(shape: [1], dtype: .int32),
        "quant_conv.weight": Krea2VAEWeightMetadata(shape: [1], dtype: .int32),
    ]

    let prepared = try Krea2VAEWeightLoader.prepareDecoderMetadata(
        checkpoint, expected: expected)

    #expect(Set(prepared.keys) == Set(expected.keys))
    #expect(prepared["decoder.conv.weight"]?.shape == [2, 1, 1, 1, 3])
    #expect(prepared["decoder.block.resample_conv.weight"]?.shape == [4, 1, 1, 3])
    #expect(prepared.values.allSatisfy { $0.dtype == .float32 })
}

@Test func vaeDecodePreparationRejectsMissingAndUnexpectedKeys() {
    let expected = [
        "decoder.bias": Krea2VAEWeightMetadata(shape: [2]),
        "post_quant_conv.bias": Krea2VAEWeightMetadata(shape: [2]),
    ]
    let checkpoint = [
        "decoder.bias": Krea2VAEWeightMetadata(shape: [2]),
        "decoder.unexpected": Krea2VAEWeightMetadata(shape: [1]),
        "encoder.ignored": Krea2VAEWeightMetadata(shape: [1]),
    ]

    do {
        _ = try Krea2VAEWeightLoader.prepareDecoderMetadata(checkpoint, expected: expected)
        Issue.record("Expected strict decoder key validation to fail")
    } catch Krea2VAEWeightsError.keyMismatch(let missing, let unexpected) {
        #expect(missing == ["post_quant_conv.bias"])
        #expect(unexpected == ["decoder.unexpected"])
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func vaeDecodePreparationRejectsShapeAndDTypeMismatches() {
    let expectedWeight = [
        "decoder.weight": Krea2VAEWeightMetadata(shape: [2, 1, 1, 1, 3]),
    ]
    do {
        _ = try Krea2VAEWeightLoader.prepareDecoderMetadata(
            ["decoder.weight": Krea2VAEWeightMetadata(shape: [2, 4, 1, 1, 1])],
            expected: expectedWeight)
        Issue.record("Expected decoder shape validation to fail")
    } catch Krea2VAEWeightsError.shapeMismatch(let key, let expected, let actual) {
        #expect(key == "decoder.weight")
        #expect(expected == [2, 1, 1, 1, 3])
        #expect(actual == [2, 1, 1, 1, 4])
    } catch {
        Issue.record("Unexpected shape error: \(error)")
    }

    let expectedBias = ["decoder.bias": Krea2VAEWeightMetadata(shape: [2])]
    do {
        _ = try Krea2VAEWeightLoader.prepareDecoderMetadata(
            ["decoder.bias": Krea2VAEWeightMetadata(shape: [2], dtype: .int32)],
            expected: expectedBias)
        Issue.record("Expected decoder dtype validation to fail")
    } catch Krea2VAEWeightsError.dtypeMismatch(let key, let expected, let actual) {
        #expect(key == "decoder.bias")
        #expect(expected == .float32)
        #expect(actual == .int32)
    } catch {
        Issue.record("Unexpected dtype error: \(error)")
    }
}

@Test func vaeDecoderPreparationCastsValidatedWeightsToBF16() throws {
    let expected = ["decoder.bias": Krea2VAEWeightMetadata(shape: [1])]
    let checkpoint = ["decoder.bias": Krea2VAEWeightMetadata(shape: [1])]

    let prepared = try Krea2VAEWeightLoader.prepareDecoderMetadata(
        checkpoint, expected: expected, computeDType: .bfloat16)
    #expect(prepared["decoder.bias"]?.shape == [1])
    #expect(prepared["decoder.bias"]?.dtype == .bfloat16)
}

@Test func vaeDecoderPreparationRejectsUnsupportedComputeDType() {
    let expected = ["decoder.bias": Krea2VAEWeightMetadata(shape: [1])]
    let checkpoint = ["decoder.bias": Krea2VAEWeightMetadata(shape: [1])]

    do {
        _ = try Krea2VAEWeightLoader.prepareDecoderMetadata(
            checkpoint, expected: expected, computeDType: .float16)
        Issue.record("Expected unsupported float16 decoder loading to fail")
    } catch Krea2VAEWeightsError.unsupportedComputeDType(let dtype) {
        #expect(dtype == .float16)
    } catch {
        Issue.record("Unexpected compute dtype error: \(error)")
    }
}
