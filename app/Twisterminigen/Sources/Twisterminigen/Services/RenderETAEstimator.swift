import Foundation

/// A deterministic ETA estimator driven by timestamps from a monotonic clock.
///
/// The first completed step is an anchor only: it commonly includes MLX graph compilation and
/// other warm-up work, so extrapolating it would produce a misleading ETA. Starting with the
/// second completed step, the estimator uses the median duration between accepted callbacks.
///
/// `monotonicSeconds` must use one stable monotonic epoch for the lifetime of this value. The
/// estimator deliberately does not read `Date` or any clock itself, which keeps it pure and makes
/// delayed, duplicated, and malformed callbacks deterministic to test.
struct RenderETAEstimator: Sendable {
    private(set) var totalSteps: Int
    private(set) var completedSteps = 0
    private(set) var steadySampleCount = 0

    private var lastAcceptedTimestamp: Double?
    private var steadyStepIntervals: [Double] = []

    init(totalSteps: Int) {
        self.totalSteps = max(0, totalSteps)
    }

    /// Starts a new render and discards every timing sample from the preceding one.
    mutating func reset(totalSteps: Int) {
        self = RenderETAEstimator(totalSteps: totalSteps)
    }

    /// Records a completed step if both progress and time move strictly forwards.
    ///
    /// Returns `false` without changing state for duplicate/out-of-order steps, non-finite
    /// timestamps, backwards/equal timestamps, or a timestamp delta that overflows. If callbacks
    /// skip one or more steps, their elapsed interval is divided by the step gap instead of being
    /// mistaken for one very slow step.
    @discardableResult
    mutating func recordCompletedStep(
        _ step: Int,
        at monotonicSeconds: Double
    ) -> Bool {
        guard monotonicSeconds.isFinite,
              step > completedSteps,
              step > 0,
              step <= totalSteps
        else { return false }

        guard let previousTimestamp = lastAcceptedTimestamp else {
            completedSteps = step
            lastAcceptedTimestamp = monotonicSeconds
            return true
        }

        guard monotonicSeconds > previousTimestamp else { return false }
        let elapsed = monotonicSeconds - previousTimestamp
        let advancedSteps = step - completedSteps
        let perStep = elapsed / Double(advancedSteps)
        guard elapsed.isFinite,
              perStep.isFinite,
              perStep > 0
        else { return false }

        steadyStepIntervals.append(perStep)
        steadySampleCount = steadyStepIntervals.count
        completedSteps = step
        lastAcceptedTimestamp = monotonicSeconds
        return true
    }

    /// Median duration of the accepted post-warm-up step intervals. With an even sample count the
    /// lower median is deliberate: one newly observed slow interval cannot make ETA jump before a
    /// second interval confirms the slowdown.
    var estimatedSecondsPerStep: Double? {
        Self.median(of: steadyStepIntervals)
    }

    /// Estimated denoising time remaining at the latest accepted step boundary.
    ///
    /// `nil` means that no steady interval is available yet (normally while step 1 is the latest
    /// callback), or that a finite estimate cannot be represented. A completed/zero-step render
    /// always reports exactly zero.
    var estimatedRemainingSeconds: Double? {
        let remainingSteps = max(0, totalSteps - completedSteps)
        guard remainingSteps > 0 else { return 0 }
        guard let secondsPerStep = estimatedSecondsPerStep else { return nil }

        let estimate = secondsPerStep * Double(remainingSteps)
        guard estimate.isFinite, estimate >= 0 else { return nil }
        return estimate
    }

    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if !sorted.count.isMultiple(of: 2) {
            return sorted[middle]
        }

        let result = sorted[middle - 1]
        return result.isFinite && result >= 0 ? result : nil
    }
}
