import Foundation

/// Pure normalized-coordinate operations shared by the Remix crop editor and its tests.
/// Coordinates use the same top-left origin as `InputImagePreprocessor`.
enum RemixCropGeometry {
    static let minimumExtent = 0.02
    static let fullImage = GenerationRecipe.NormalizedRect(x0: 0, y0: 0, x1: 1, y1: 1)

    enum Handle: String, CaseIterable, Identifiable, Sendable {
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left

        var id: String { rawValue }

        fileprivate var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        fileprivate var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        fileprivate var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        fileprivate var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    /// Returns a finite, ordered rectangle entirely inside the normalized image plane.
    static func clamped(
        _ rect: GenerationRecipe.NormalizedRect,
        minimumExtent: Double = minimumExtent
    ) -> GenerationRecipe.NormalizedRect {
        let minimum = normalizedMinimum(minimumExtent)
        var x0 = unit(rect.x0, fallback: 0)
        var y0 = unit(rect.y0, fallback: 0)
        var x1 = unit(rect.x1, fallback: 1)
        var y1 = unit(rect.y1, fallback: 1)

        if x0 > x1 { swap(&x0, &x1) }
        if y0 > y1 { swap(&y0, &y1) }
        (x0, x1) = expandedInterval(lower: x0, upper: x1, minimum: minimum)
        (y0, y1) = expandedInterval(lower: y0, upper: y1, minimum: minimum)
        return .init(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// Moves without changing the crop size and stops precisely at image boundaries.
    static func moved(
        _ rect: GenerationRecipe.NormalizedRect,
        deltaX: Double,
        deltaY: Double
    ) -> GenerationRecipe.NormalizedRect {
        let source = clamped(rect)
        let dx = deltaX.isFinite ? deltaX : 0
        let dy = deltaY.isFinite ? deltaY : 0
        let x0 = min(1 - source.width, max(0, source.x0 + dx))
        let y0 = min(1 - source.height, max(0, source.y0 + dy))
        return .init(
            x0: x0,
            y0: y0,
            x1: x0 + source.width,
            y1: y0 + source.height)
    }

    /// Resizes the selected edge/corner while keeping the opposite edges anchored.
    static func resized(
        _ rect: GenerationRecipe.NormalizedRect,
        handle: Handle,
        deltaX: Double,
        deltaY: Double,
        minimumExtent: Double = minimumExtent
    ) -> GenerationRecipe.NormalizedRect {
        let minimum = normalizedMinimum(minimumExtent)
        let source = clamped(rect, minimumExtent: minimum)
        let dx = deltaX.isFinite ? deltaX : 0
        let dy = deltaY.isFinite ? deltaY : 0
        var x0 = source.x0
        var y0 = source.y0
        var x1 = source.x1
        var y1 = source.y1

        if handle.movesLeft { x0 = min(x1 - minimum, max(0, source.x0 + dx)) }
        if handle.movesRight { x1 = min(1, max(x0 + minimum, source.x1 + dx)) }
        if handle.movesTop { y0 = min(y1 - minimum, max(0, source.y0 + dy)) }
        if handle.movesBottom { y1 = min(1, max(y0 + minimum, source.y1 + dy)) }
        return .init(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// Applies exact inspector values. Omitted values retain their current component.
    static func replacing(
        _ rect: GenerationRecipe.NormalizedRect,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        minimumExtent: Double = minimumExtent
    ) -> GenerationRecipe.NormalizedRect {
        let minimum = normalizedMinimum(minimumExtent)
        let source = clamped(rect, minimumExtent: minimum)
        let horizontal = replacedInterval(
            lower: source.x0,
            upper: source.x1,
            newLower: x,
            newExtent: width,
            minimum: minimum)
        let vertical = replacedInterval(
            lower: source.y0,
            upper: source.y1,
            newLower: y,
            newExtent: height,
            minimum: minimum)
        return .init(
            x0: horizontal.0,
            y0: vertical.0,
            x1: horizontal.1,
            y1: vertical.1)
    }

    private static func unit(_ value: Double, fallback: Double) -> Double {
        min(1, max(0, finite(value, fallback: fallback)))
    }

    private static func finite(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return value
    }

    private static func normalizedMinimum(_ value: Double) -> Double {
        min(1, max(0.000_001, value.isFinite ? value : minimumExtent))
    }

    private static func expandedInterval(
        lower: Double,
        upper: Double,
        minimum: Double
    ) -> (Double, Double) {
        guard upper - lower < minimum else { return (lower, upper) }
        let midpoint = (lower + upper) / 2
        let adjustedLower = min(1 - minimum, max(0, midpoint - minimum / 2))
        return (adjustedLower, adjustedLower + minimum)
    }

    private static func replacedInterval(
        lower: Double,
        upper: Double,
        newLower: Double?,
        newExtent: Double?,
        minimum: Double
    ) -> (Double, Double) {
        if newExtent == nil, let newLower {
            let adjustedLower = min(upper - minimum, max(0, finite(newLower, fallback: lower)))
            return (adjustedLower, upper)
        }

        guard newLower != nil || newExtent != nil else { return (lower, upper) }
        let extent = min(1, max(minimum, finite(newExtent, fallback: upper - lower)))
        if let newLower {
            let adjustedLower = min(1 - extent, max(0, finite(newLower, fallback: lower)))
            return (adjustedLower, adjustedLower + extent)
        }
        let adjustedExtent = min(1 - lower, extent)
        return (lower, lower + max(minimum, adjustedExtent))
    }
}
