import Foundation

public enum Krea2VAEPrecisionMetricsError: Error, Equatable, Sendable {
    case shapeMismatch(reference: Int, candidate: Int)
    case invalidImageShape([Int])
    case nonFiniteInput(index: Int)
}

public struct Krea2VAEPrecisionMetrics: Equatable, Sendable {
    public let cosineSimilarity: Double
    public let meanAbsoluteError: Double
    public let rootMeanSquaredError: Double
    public let peakSignalToNoiseRatio: Double
    public let maximumAbsoluteError: Double
    public let globalSSIM: Double

    public var passesProductionGate: Bool {
        cosineSimilarity >= 0.999
            && peakSignalToNoiseRatio >= 40
            && globalSSIM >= 0.995
    }
}

public enum Krea2VAEPrecisionComparator {
    /// Compares two materialized NCHW images in the final `[0, 1]` pixel range.
    /// `globalSSIM` is the mean of per-channel global SSIM values; it is deliberately paired with
    /// cosine and PSNR rather than presented as a windowed perceptual metric.
    public static func compare(
        reference: [Float],
        candidate: [Float],
        shape: [Int]
    ) throws -> Krea2VAEPrecisionMetrics {
        guard reference.count == candidate.count else {
            throw Krea2VAEPrecisionMetricsError.shapeMismatch(
                reference: reference.count,
                candidate: candidate.count)
        }
        guard shape.count == 4,
              shape[0] == 1,
              shape[1] == 3,
              shape[2] > 0,
              shape[3] > 0,
              shape.reduce(1, *) == reference.count
        else {
            throw Krea2VAEPrecisionMetricsError.invalidImageShape(shape)
        }

        var dot = 0.0
        var referenceNorm = 0.0
        var candidateNorm = 0.0
        var absoluteError = 0.0
        var squaredError = 0.0
        var maximumError = 0.0

        for index in reference.indices {
            let lhs = Double(reference[index])
            let rhs = Double(candidate[index])
            guard lhs.isFinite, rhs.isFinite else {
                throw Krea2VAEPrecisionMetricsError.nonFiniteInput(index: index)
            }
            let difference = lhs - rhs
            let magnitude = abs(difference)
            dot += lhs * rhs
            referenceNorm += lhs * lhs
            candidateNorm += rhs * rhs
            absoluteError += magnitude
            squaredError += difference * difference
            maximumError = max(maximumError, magnitude)
        }

        let count = Double(reference.count)
        let meanAbsoluteError = absoluteError / count
        let rootMeanSquaredError = sqrt(squaredError / count)
        let cosineDenominator = sqrt(referenceNorm * candidateNorm)
        let cosineSimilarity = cosineDenominator == 0
            ? (referenceNorm == candidateNorm ? 1 : 0)
            : dot / cosineDenominator
        let peakSignalToNoiseRatio = rootMeanSquaredError == 0
            ? .infinity
            : 20 * log10(1 / rootMeanSquaredError)

        return Krea2VAEPrecisionMetrics(
            cosineSimilarity: cosineSimilarity,
            meanAbsoluteError: meanAbsoluteError,
            rootMeanSquaredError: rootMeanSquaredError,
            peakSignalToNoiseRatio: peakSignalToNoiseRatio,
            maximumAbsoluteError: maximumError,
            globalSSIM: globalSSIM(reference: reference, candidate: candidate, shape: shape))
    }

    private static func globalSSIM(
        reference: [Float],
        candidate: [Float],
        shape: [Int]
    ) -> Double {
        let channelSize = shape[2] * shape[3]
        let count = Double(channelSize)
        let c1 = 0.01 * 0.01
        let c2 = 0.03 * 0.03
        var channelScores = 0.0

        for channel in 0 ..< shape[1] {
            let start = channel * channelSize
            let end = start + channelSize
            var referenceMean = 0.0
            var candidateMean = 0.0
            for index in start ..< end {
                referenceMean += Double(reference[index])
                candidateMean += Double(candidate[index])
            }
            referenceMean /= count
            candidateMean /= count

            var referenceVariance = 0.0
            var candidateVariance = 0.0
            var covariance = 0.0
            for index in start ..< end {
                let lhs = Double(reference[index]) - referenceMean
                let rhs = Double(candidate[index]) - candidateMean
                referenceVariance += lhs * lhs
                candidateVariance += rhs * rhs
                covariance += lhs * rhs
            }
            referenceVariance /= count
            candidateVariance /= count
            covariance /= count

            let luminance = (2 * referenceMean * candidateMean + c1)
                / (referenceMean * referenceMean + candidateMean * candidateMean + c1)
            let structure = (2 * covariance + c2)
                / (referenceVariance + candidateVariance + c2)
            channelScores += luminance * structure
        }
        return channelScores / Double(shape[1])
    }
}
