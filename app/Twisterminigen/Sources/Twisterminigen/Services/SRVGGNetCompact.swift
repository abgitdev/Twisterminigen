import MLX
import MLXNN

/// Clean-room MLX-Swift implementation of the compact Real-ESRGAN SRVGG network.
///
/// The topology is reconstructed from the pinned public model configuration: 34 sequential 3×3
/// convolutions, 33 per-channel PReLUs, a channel-to-space ×4 projection, and a nearest-neighbour
/// residual. It accepts and returns NHWC arrays in `[0, 1]`; no interpolation-only output path
/// exists. The upstream architecture and checkpoint are BSD-3-Clause (see the embedded manifest
/// evidence in `LocalUpscaleWeightManifest`).
final class SRVGGNetCompact: Module, @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        let inputChannels: Int
        let outputChannels: Int
        let features: Int
        /// Feature→feature convolution/PReLU pairs after the first pair.
        let convolutionCount: Int
        let upscaleFactor: LocalUpscaleFactor

        init(
            inputChannels: Int = 3,
            outputChannels: Int = 3,
            features: Int = 64,
            convolutionCount: Int = 32,
            upscaleFactor: LocalUpscaleFactor = .fourX
        ) {
            precondition(inputChannels > 0 && outputChannels > 0 && features > 0)
            precondition(convolutionCount >= 0)
            self.inputChannels = inputChannels
            self.outputChannels = outputChannels
            self.features = features
            self.convolutionCount = convolutionCount
            self.upscaleFactor = upscaleFactor
        }

        static let realESRGANGeneralX4V3 = Self()
    }

    let configuration: Configuration

    /// Upstream checkpoint order: conv, PReLU, repeated conv/PReLU, final conv. These names match
    /// the converted MLX safetensors (`body.<index>.<weight|bias>`) without a remapping table.
    let body: [Module]

    init(configuration: Configuration = .realESRGANGeneralX4V3) {
        self.configuration = configuration
        let factor = configuration.upscaleFactor.rawValue
        var stages: [Module] = [
            Conv2d(
                inputChannels: configuration.inputChannels,
                outputChannels: configuration.features,
                kernelSize: 3,
                padding: 1),
            PReLU(count: configuration.features),
        ]
        stages.reserveCapacity(2 + configuration.convolutionCount * 2 + 1)
        for _ in 0 ..< configuration.convolutionCount {
            stages.append(Conv2d(
                inputChannels: configuration.features,
                outputChannels: configuration.features,
                kernelSize: 3,
                padding: 1))
            stages.append(PReLU(count: configuration.features))
        }
        stages.append(Conv2d(
            inputChannels: configuration.features,
            outputChannels: configuration.outputChannels * factor * factor,
            kernelSize: 3,
            padding: 1))
        body = stages
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        precondition(input.ndim == 4, "SRVGGNetCompact expects an NHWC image batch.")
        precondition(
            input.shape[3] == configuration.inputChannels,
            "SRVGGNetCompact received an unexpected channel count.")

        var output = input
        for index in stride(from: 0, to: body.count - 1, by: 2) {
            guard let convolution = body[index] as? Conv2d,
                  let activation = body[index + 1] as? PReLU else {
                preconditionFailure("SRVGGNetCompact body ordering is corrupt at stage \(index).")
            }
            output = activation(convolution(output))
        }
        guard let finalConvolution = body.last as? Conv2d else {
            preconditionFailure("SRVGGNetCompact final convolution is missing.")
        }
        output = Self.pixelShuffleNHWC(
            finalConvolution(output),
            scale: configuration.upscaleFactor.rawValue)
        return output + Self.nearestUpsampleNHWC(
            input,
            scale: configuration.upscaleFactor.rawValue)
    }

    /// PixelShuffle channel order: destination `(c,y,x)` reads source channel
    /// `c*scale² + y*scale + x`. Shape-only tests cannot detect an order mismatch.
    static func pixelShuffleNHWC(_ input: MLXArray, scale: Int) -> MLXArray {
        precondition(scale > 0)
        precondition(input.ndim == 4, "PixelShuffle expects NHWC input.")
        let batch = input.shape[0]
        let height = input.shape[1]
        let width = input.shape[2]
        let inputChannels = input.shape[3]
        let divisor = scale * scale
        precondition(inputChannels % divisor == 0)
        let channels = inputChannels / divisor
        return input
            .reshaped([batch, height, width, channels, scale, scale])
            .transposed(0, 1, 4, 2, 5, 3)
            .reshaped([batch, height * scale, width * scale, channels])
    }

    /// Exact integer nearest-neighbour residual used by the network itself. This is not exposed as
    /// a successful upscaler result and cannot substitute for the learned SRVGG forward pass.
    static func nearestUpsampleNHWC(_ input: MLXArray, scale: Int) -> MLXArray {
        precondition(scale > 0)
        precondition(input.ndim == 4, "Nearest SRVGG residual expects NHWC input.")
        let batch = input.shape[0]
        let height = input.shape[1]
        let width = input.shape[2]
        let channels = input.shape[3]
        let expanded = input.reshaped([batch, height, 1, width, 1, channels])
        return broadcast(
            expanded,
            to: [batch, height, scale, width, scale, channels])
            .reshaped([batch, height * scale, width * scale, channels])
    }
}
