import Foundation
import Testing
@testable import Krea2VAE

@Test func vaePrecisionMetricsAcceptIdenticalPixels() throws {
    let pixels: [Float] = [0, 0.25, 0.5, 0.75, 1, 0.1]
    let metrics = try Krea2VAEPrecisionComparator.compare(
        reference: pixels,
        candidate: pixels,
        shape: [1, 3, 1, 2])

    #expect(metrics.cosineSimilarity == 1)
    #expect(metrics.meanAbsoluteError == 0)
    #expect(metrics.rootMeanSquaredError == 0)
    #expect(metrics.peakSignalToNoiseRatio.isInfinite)
    #expect(metrics.maximumAbsoluteError == 0)
    #expect(abs(metrics.globalSSIM - 1) < 1e-12)
    #expect(metrics.passesProductionGate)
}

@Test func vaePrecisionMetricsRejectVisibleDrift() throws {
    let reference = [Float](repeating: 0.5, count: 12)
    let candidate = [Float](repeating: 0.6, count: 12)
    let metrics = try Krea2VAEPrecisionComparator.compare(
        reference: reference,
        candidate: candidate,
        shape: [1, 3, 2, 2])

    #expect(abs(metrics.meanAbsoluteError - 0.1) < 1e-6)
    #expect(abs(metrics.rootMeanSquaredError - 0.1) < 1e-6)
    #expect(abs(metrics.peakSignalToNoiseRatio - 20) < 1e-5)
    #expect(abs(metrics.maximumAbsoluteError - 0.1) < 1e-6)
    #expect(!metrics.passesProductionGate)
}

@Test func vaePrecisionMetricsValidateShapeAndFiniteValues() {
    #expect(throws: Krea2VAEPrecisionMetricsError.self) {
        _ = try Krea2VAEPrecisionComparator.compare(
            reference: [0], candidate: [0, 1], shape: [1, 3, 1, 1])
    }
    #expect(throws: Krea2VAEPrecisionMetricsError.self) {
        _ = try Krea2VAEPrecisionComparator.compare(
            reference: [0, 0, 0], candidate: [0, 0, 0], shape: [1, 1, 1, 3])
    }
    #expect(throws: Krea2VAEPrecisionMetricsError.self) {
        _ = try Krea2VAEPrecisionComparator.compare(
            reference: [.nan, 0, 0], candidate: [0, 0, 0], shape: [1, 3, 1, 1])
    }
}
