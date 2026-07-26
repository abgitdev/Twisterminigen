import Foundation
import Testing
@testable import Twisterminigen

@Suite("Render ETA estimator")
struct RenderETAEstimatorTests {
    @Test("The first step is warm-up and is never extrapolated")
    func firstStepIsWarmUp() {
        var estimator = RenderETAEstimator(totalSteps: 8)

        let acceptedWarmUp = estimator.recordCompletedStep(1, at: 63)
        #expect(acceptedWarmUp)
        #expect(estimator.completedSteps == 1)
        #expect(estimator.steadySampleCount == 0)
        #expect(estimator.estimatedSecondsPerStep == nil)
        #expect(estimator.estimatedRemainingSeconds == nil)

        let acceptedSecondStep = estimator.recordCompletedStep(2, at: 71)
        #expect(acceptedSecondStep)
        #expect(estimator.estimatedSecondsPerStep == 8)
        #expect(estimator.estimatedRemainingSeconds == 48)
    }

    @Test("Steady step prediction uses the median and rejects a slow outlier")
    func medianSteadyIntervals() {
        var estimator = RenderETAEstimator(totalSteps: 8)

        let acceptedWarmUp = estimator.recordCompletedStep(1, at: 60)
        let acceptedSecondStep = estimator.recordCompletedStep(2, at: 68)   // 8 seconds
        let acceptedThirdStep = estimator.recordCompletedStep(3, at: 168)  // 100-second outlier
        let remainingAfterOutlier = estimator.estimatedRemainingSeconds
        let acceptedFourthStep = estimator.recordCompletedStep(4, at: 176)  // 8 seconds
        #expect(acceptedWarmUp)
        #expect(acceptedSecondStep)
        #expect(acceptedThirdStep)
        #expect(remainingAfterOutlier == 40)
        #expect(acceptedFourthStep)

        #expect(estimator.steadySampleCount == 3)
        #expect(estimator.estimatedSecondsPerStep == 8)
        #expect(estimator.estimatedRemainingSeconds == 32)
    }

    @Test("Malformed and backwards callbacks leave the accepted timeline unchanged")
    func invalidCallbacksAreIgnored() {
        var estimator = RenderETAEstimator(totalSteps: 8)

        let acceptedWarmUp = estimator.recordCompletedStep(1, at: 100)
        let acceptedNaN = estimator.recordCompletedStep(2, at: .nan)
        let acceptedInfinity = estimator.recordCompletedStep(2, at: .infinity)
        let acceptedEqualTimestamp = estimator.recordCompletedStep(2, at: 100)
        let acceptedBackwardsTimestamp = estimator.recordCompletedStep(2, at: 99)
        let acceptedDuplicateStep = estimator.recordCompletedStep(1, at: 108)
        let acceptedZeroStep = estimator.recordCompletedStep(0, at: 108)
        let acceptedPastEnd = estimator.recordCompletedStep(9, at: 108)
        #expect(acceptedWarmUp)
        #expect(!acceptedNaN)
        #expect(!acceptedInfinity)
        #expect(!acceptedEqualTimestamp)
        #expect(!acceptedBackwardsTimestamp)
        #expect(!acceptedDuplicateStep)
        #expect(!acceptedZeroStep)
        #expect(!acceptedPastEnd)

        #expect(estimator.completedSteps == 1)
        #expect(estimator.steadySampleCount == 0)
        #expect(estimator.estimatedRemainingSeconds == nil)

        let acceptedValidSecondStep = estimator.recordCompletedStep(2, at: 108)
        #expect(acceptedValidSecondStep)
        #expect(estimator.completedSteps == 2)
        #expect(estimator.estimatedSecondsPerStep == 8)
        #expect(estimator.estimatedRemainingSeconds == 48)
    }

    @Test("A skipped callback is normalized by the number of advanced steps")
    func skippedCallbackIsNormalized() {
        var estimator = RenderETAEstimator(totalSteps: 8)

        let acceptedWarmUp = estimator.recordCompletedStep(1, at: 40)
        let acceptedSkippedStep = estimator.recordCompletedStep(3, at: 56)
        #expect(acceptedWarmUp)
        #expect(acceptedSkippedStep)

        #expect(estimator.completedSteps == 3)
        #expect(estimator.steadySampleCount == 1)
        #expect(estimator.estimatedSecondsPerStep == 8)
        #expect(estimator.estimatedRemainingSeconds == 40)
    }

    @Test("Unrepresentable products never escape as infinity")
    func remainingEstimateIsFiniteOrUnavailable() {
        var estimator = RenderETAEstimator(totalSteps: .max)

        let acceptedWarmUp = estimator.recordCompletedStep(1, at: 0)
        let acceptedHugeInterval = estimator.recordCompletedStep(
            2,
            at: Double.greatestFiniteMagnitude / 2)
        #expect(acceptedWarmUp)
        #expect(acceptedHugeInterval)
        #expect(estimator.estimatedSecondsPerStep?.isFinite == true)
        #expect(estimator.estimatedRemainingSeconds == nil)
    }

    @Test("Completion and reset produce a bounded clean state")
    func completionAndReset() {
        var estimator = RenderETAEstimator(totalSteps: 1)

        let acceptedOnlyStep = estimator.recordCompletedStep(1, at: -5)
        #expect(acceptedOnlyStep)
        #expect(estimator.estimatedRemainingSeconds == 0)

        estimator.reset(totalSteps: 4)
        #expect(estimator.totalSteps == 4)
        #expect(estimator.completedSteps == 0)
        #expect(estimator.steadySampleCount == 0)
        #expect(estimator.estimatedSecondsPerStep == nil)
        #expect(estimator.estimatedRemainingSeconds == nil)

        estimator.reset(totalSteps: -4)
        #expect(estimator.totalSteps == 0)
        #expect(estimator.estimatedRemainingSeconds == 0)
    }
}
