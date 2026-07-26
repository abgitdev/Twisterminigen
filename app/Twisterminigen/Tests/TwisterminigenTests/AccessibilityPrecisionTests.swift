import Foundation
import SwiftUI
import Testing
@testable import Twisterminigen

@Suite("Accessibility and precision controls")
@MainActor
struct AccessibilityPrecisionTests {
    @Test("Exact integers clamp, snap to the nearest step, and reject invalid drafts")
    func steppedIntegerNormalization() {
        let range = 256 ... 2_048
        #expect(SteppedIntegerValue.normalized(10, in: range, step: 16) == 256)
        #expect(SteppedIntegerValue.normalized(263, in: range, step: 16) == 256)
        #expect(SteppedIntegerValue.normalized(264, in: range, step: 16) == 272)
        #expect(SteppedIntegerValue.normalized(2_999, in: range, step: 16) == 2_048)
        #expect(SteppedIntegerValue.committedValue(
            from: " 270 ", current: 512, in: range, step: 16) == 272)
        #expect(SteppedIntegerValue.committedValue(
            from: "invalid", current: 513, in: range, step: 16) == 512)
        #expect(SteppedIntegerValue.adjusted(
            2_048, direction: 1, in: range, step: 16) == 2_048)
        #expect(GenerateViewModel.snap16(271) == 272)
    }

    @Test("Accessibility preferences clamp and persist independently")
    func accessibilityPreferencesPersist() {
        let defaults = VolatileUserDefaults()

        let preferences = AppAccessibilityPreferences(defaults: defaults)
        #expect(preferences.textScalePercent == 100)
        #expect(!preferences.reduceTransparency)
        #expect(!preferences.increaseContrast)

        preferences.textScalePercent = 158
        preferences.reduceTransparency = true
        preferences.increaseContrast = true
        #expect(preferences.textScalePercent == 160)
        #expect(preferences.dynamicTypeSize == .accessibility1)

        let restored = AppAccessibilityPreferences(defaults: defaults)
        #expect(restored.textScalePercent == 160)
        #expect(restored.reduceTransparency)
        #expect(restored.increaseContrast)

        restored.textScalePercent = 1
        #expect(restored.textScalePercent == 85)
        restored.reset()
        #expect(restored.textScalePercent == 100)
        #expect(!restored.reduceTransparency)
        #expect(!restored.increaseContrast)
    }

    @Test("App text scale is exact while larger system accessibility sizes remain authoritative")
    func effectiveDynamicTypeAndLayoutPolicy() {
        #expect(AppAccessibilityPreferences.effectiveDynamicTypeSize(
            system: .accessibility3,
            local: .large) == .accessibility3)
        #expect(AppAccessibilityPreferences.effectiveDynamicTypeSize(
            system: .small,
            local: .xxxLarge) == .xxxLarge)
        #expect(AppAccessibilityPreferences.effectiveDynamicTypeSize(
            system: .xLarge,
            local: .xLarge) == .xLarge)
        #expect(AppAccessibilityPreferences.effectiveDynamicTypeSize(
            system: .large,
            local: .small) == .small)

        #expect(close(
            Double(AppAccessibilityPreferences.effectiveTextScaleFactor(
                system: .large,
                localPercent: 85)),
            0.85))
        #expect(close(
            Double(AppAccessibilityPreferences.effectiveTextScaleFactor(
                system: .large,
                localPercent: 105)),
            1.05))
        #expect(close(
            Double(AppAccessibilityPreferences.effectiveTextScaleFactor(
                system: .accessibility3,
                localPercent: 85)),
            2.35))
        #expect(close(Double(FxTypography.scaledPointSize(12, factor: 0.85)), 10.2))
        #expect(close(Double(FxTypography.scaledPointSize(12, factor: 1.60)), 19.2))

        #expect(!AccessibilityLayoutPolicy.usesStackedLayout(for: .xxxLarge))
        #expect(AccessibilityLayoutPolicy.usesStackedLayout(for: .accessibility1))
        #expect(AccessibilityLayoutPolicy.usesStackedLayout(for: .accessibility5))
    }

    @Test("Regional prompt exact fields preserve a valid minimum-sized rectangle")
    func spatialRegionGeometryIsBounded() {
        let source = GenerationRecipe.NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        let moved = SpatialRegionGeometry.replacing(source, x: 0.9, y: -1)
        #expect(close(moved.x, 0.6))
        #expect(close(moved.y, 0))
        #expect(close(moved.width, 0.4))
        #expect(close(moved.height, 0.5))

        let resized = SpatialRegionGeometry.replacing(moved, width: 0, height: 8)
        #expect(close(resized.width, SpatialRegionGeometry.minimumExtent))
        #expect(close(resized.height, 1))
        #expect(resized.x0 >= 0 && resized.y0 >= 0)
        #expect(resized.x1 <= 1 && resized.y1 <= 1)

        let dragged = SpatialRegionGeometry.moved(
            resized,
            deltaX: .infinity,
            deltaY: .nan)
        #expect(dragged == resized)
    }

    @Test("Regional canvas drag selects only the visible region under its start point")
    func regionalCanvasDragHitTesting() {
        let first = GenerationRecipe.BBoxRegion(
            id: UUID(),
            prompt: "First",
            rect: .init(x: 0.05, y: 0.05, width: 0.45, height: 0.45))
        let second = GenerationRecipe.BBoxRegion(
            id: UUID(),
            prompt: "Second",
            rect: .init(x: 0.55, y: 0.55, width: 0.4, height: 0.4))
        let size = CGSize(width: 1_000, height: 1_000)

        let firstSession = SpatialRegionCanvasInteraction.begin(
            at: CGPoint(x: 200, y: 200),
            regions: [first, second],
            canvasSize: size)
        #expect(firstSession?.regionID == first.id)
        #expect(firstSession?.kind == .move)

        let moved = firstSession.map {
            SpatialRegionCanvasInteraction.updatedRect(
                for: $0,
                translation: CGSize(width: 100, height: 150),
                canvasSize: size)
        }
        #expect(moved.map { close($0.x, 0.15) } == true)
        #expect(moved.map { close($0.y, 0.20) } == true)
        #expect(second.rect.x == 0.55)
        #expect(second.rect.y == 0.55)
    }

    @Test("Regional canvas overlap follows visual order and the corner starts resize")
    func regionalCanvasOverlapAndResizeHitTesting() {
        let first = GenerationRecipe.BBoxRegion(
            id: UUID(),
            prompt: "First",
            rect: .init(x: 0.05, y: 0.05, width: 0.45, height: 0.45))
        let second = GenerationRecipe.BBoxRegion(
            id: UUID(),
            prompt: "Second",
            rect: .init(x: 0.12, y: 0.12, width: 0.45, height: 0.45))
        let size = CGSize(width: 1_000, height: 1_000)

        let overlap = SpatialRegionCanvasInteraction.begin(
            at: CGPoint(x: 200, y: 200),
            regions: [first, second],
            canvasSize: size)
        #expect(overlap?.regionID == second.id)
        #expect(overlap?.kind == .move)

        let firstHandle = SpatialRegionCanvasInteraction.begin(
            at: CGPoint(x: 490, y: 490),
            regions: [first],
            canvasSize: size)
        #expect(firstHandle?.regionID == first.id)
        #expect(firstHandle?.kind == .resize)
    }

    @Test("Eight Regional prompts start as large in-bounds cascade rectangles")
    func regionalPromptInitialPlacement() {
        let rectangles = (0 ..< GenerationRecipe.maximumRegionCount)
            .map(RegionalPromptPlacement.initialRect(index:))

        #expect(rectangles.count == 8)
        #expect(Set(rectangles).count == 8)
        #expect(rectangles.allSatisfy { rect in
            abs(rect.width - RegionalPromptPlacement.initialExtent) < 1e-12
                && abs(rect.height - RegionalPromptPlacement.initialExtent) < 1e-12
                && rect.x0 >= -1e-12 && rect.y0 >= -1e-12
                && rect.x1 <= 1 + 1e-12 && rect.y1 <= 1 + 1e-12
        })
    }

    @Test("Regional prompts sheet uses the available screen and remains bounded")
    func regionalPromptsSheetSize() {
        #expect(RegionalPromptsLayout.preferredSheetSize(
            visibleScreenSize: .init(width: 1_440, height: 1_000))
            == .init(width: 1_392, height: 920))
        #expect(RegionalPromptsLayout.preferredSheetSize(
            visibleScreenSize: .init(width: 900, height: 700))
            == .init(width: 852, height: 620))
    }

    @Test("Telemetry summaries describe direction and range without a graph")
    func metricAccessibilitySummary() {
        let rising = MetricAccessibilitySummary.trend([10, 15, .nan, 25])
        #expect(rising.contains("rising"))
        #expect(rising.contains("minimum 10"))
        #expect(rising.contains("maximum 25"))
        #expect(MetricAccessibilitySummary.trend([]) == "No recent trend samples.")
    }

    @Test("Footer telemetry is centered and optically lowered")
    func footerTelemetryLayout() {
        #expect(FxStatusBarLayout.standardHeight == 30)
        #expect(FxStatusBarLayout.accessibilityHeight == 44)
        #expect(FxStatusBarLayout.telemetryVerticalNudge == 2)
        #expect(FxStatusBarLayout.leadingInset == 24)
        #expect(FxStatusBarLayout.trailingInset == 24)
    }

    @Test("Command navigation covers the eight visible top sections")
    func navigationShortcuts() {
        #expect(AppSection.allCases.map(\.shortcutNumber) == Array(1 ... 8))
        #expect(AppSection.generate.shortcutNumber == 1)
        #expect(AppSection.queue.shortcutNumber == 2)
        #expect(AppSection.help.shortcutNumber == 8)
    }

    private func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }
}
