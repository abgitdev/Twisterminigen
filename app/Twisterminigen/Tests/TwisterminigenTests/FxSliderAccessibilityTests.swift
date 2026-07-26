import Testing
@testable import Twisterminigen

@Suite("FxSlider accessibility adjustment")
@MainActor
struct FxSliderAccessibilityTests {
    @Test("Adjustments use the configured step and stop at both bounds")
    func steppedAdjustmentsClampToBounds() {
        let range = 0.05...1.0

        #expect(close(FxSlider.adjustedValue(0.95, in: range, step: 0.05, direction: 1), 1.0))
        #expect(close(FxSlider.adjustedValue(1.0, in: range, step: 0.05, direction: 1), 1.0))
        #expect(close(FxSlider.adjustedValue(0.1, in: range, step: 0.05, direction: -1), 0.05))
        #expect(close(FxSlider.adjustedValue(0.05, in: range, step: 0.05, direction: -1), 0.05))
    }

    @Test("Step snapping is anchored to a nonzero lower bound")
    func snappingUsesRangeOrigin() {
        let range = 10.0...20.0

        #expect(close(FxSlider.snappedValue(14, in: range, step: 3), 13))
        #expect(close(FxSlider.snappedValue(15, in: range, step: 3), 16))
    }

    @Test("Continuous sliders receive a one-percent adjustable increment")
    func continuousAdjustmentHasUsefulIncrement() {
        let range = 0.0...1.0

        #expect(close(FxSlider.adjustedValue(0.5, in: range, step: 0, direction: 1), 0.51))
        #expect(close(FxSlider.adjustedValue(0.5, in: range, step: 0, direction: -1), 0.49))
    }

    private func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }
}
