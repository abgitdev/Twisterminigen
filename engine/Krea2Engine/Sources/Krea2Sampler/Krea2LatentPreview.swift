import Foundation
import MLX

public enum Krea2LatentPreviewError: Error, Equatable, Sendable {
    case invalidShape([Int])
    case invalidStep(step: Int, total: Int)
}

/// A deliberately low-resolution visualization of the current latent. It is diagnostic only and
/// never feeds back into denoising. RGB bytes are interleaved in top-to-bottom row order.
public struct Krea2LatentPreviewFrame: Sendable, Equatable {
    public let step: Int
    public let totalSteps: Int
    public let width: Int
    public let height: Int
    public let rgb: [UInt8]

    public init(
        step: Int,
        totalSteps: Int,
        width: Int,
        height: Int,
        rgb: [UInt8]
    ) {
        self.step = step
        self.totalSteps = totalSteps
        self.width = width
        self.height = height
        self.rgb = rgb
    }
}

public enum Krea2LatentPreviewRenderer {
    /// Fixed, parameter-free 16-channel projection. This exposes coarse color/composition changes
    /// without loading VAE weights alongside the transformer.
    public static func render(
        latent: MLXArray,
        step: Int,
        totalSteps: Int
    ) throws -> Krea2LatentPreviewFrame {
        guard latent.shape.count == 4,
              latent.dim(0) == 1,
              latent.dim(1) == 16,
              latent.dim(2) > 0,
              latent.dim(3) > 0 else {
            throw Krea2LatentPreviewError.invalidShape(latent.shape)
        }
        guard totalSteps > 0, step > 0, step <= totalSteps else {
            throw Krea2LatentPreviewError.invalidStep(step: step, total: totalSteps)
        }

        // Sampling already evaluated the latent. Projecting its tiny host copy avoids compiling
        // extra Metal tanh/stack/transpose kernels just to draw a diagnostic thumbnail.
        let values = latent[0].asArray(Float.self)
        let pixelCount = latent.dim(2) * latent.dim(3)
        var bytes = [UInt8](repeating: 127, count: pixelCount * 3)
        for pixel in 0 ..< pixelCount {
            let red = values[pixel]
                * 0.58 + values[3 * pixelCount + pixel] * 0.28
                - values[6 * pixelCount + pixel] * 0.14
            let green = values[pixelCount + pixel]
                * 0.58 + values[4 * pixelCount + pixel] * 0.28
                - values[7 * pixelCount + pixel] * 0.14
            let blue = values[2 * pixelCount + pixel]
                * 0.58 + values[5 * pixelCount + pixel] * 0.28
                - values[8 * pixelCount + pixel] * 0.14
            bytes[pixel * 3] = displayByte(red)
            bytes[pixel * 3 + 1] = displayByte(green)
            bytes[pixel * 3 + 2] = displayByte(blue)
        }
        return Krea2LatentPreviewFrame(
            step: step,
            totalSteps: totalSteps,
            width: latent.dim(3),
            height: latent.dim(2),
            rgb: bytes)
    }

    private static func displayByte(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 127 }
        let scaled = (Foundation.tanh(Double(value) * 0.45) + 1) * 127.5
        return UInt8(min(255, max(0, Int(scaled))))
    }
}
