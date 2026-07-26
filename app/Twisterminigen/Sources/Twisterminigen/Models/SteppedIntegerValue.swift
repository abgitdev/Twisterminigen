import Foundation

/// Pure normalization used by exact numeric fields and their stepper buttons.
/// Values are clamped first, then snapped to the nearest step anchored at the lower bound.
enum SteppedIntegerValue {
    static func normalized(
        _ value: Int,
        in range: ClosedRange<Int>,
        step: Int
    ) -> Int {
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        guard step > 0, range.lowerBound < range.upperBound else { return clamped }

        let offset = clamped - range.lowerBound
        let lowerStep = offset / step
        let remainder = offset % step
        let nearestStep = remainder >= (step + 1) / 2 ? lowerStep + 1 : lowerStep
        let snapped = range.lowerBound + nearestStep * step
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    static func committedValue(
        from draft: String,
        current: Int,
        in range: ClosedRange<Int>,
        step: Int
    ) -> Int {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed) else {
            return normalized(current, in: range, step: step)
        }
        return normalized(parsed, in: range, step: step)
    }

    static func adjusted(
        _ value: Int,
        direction: Int,
        in range: ClosedRange<Int>,
        step: Int
    ) -> Int {
        let normalized = normalized(value, in: range, step: step)
        guard direction != 0, step > 0 else { return normalized }
        let delta = direction > 0 ? step : -step
        let (candidate, overflow) = normalized.addingReportingOverflow(delta)
        if overflow { return direction > 0 ? range.upperBound : range.lowerBound }
        return Self.normalized(candidate, in: range, step: step)
    }
}
