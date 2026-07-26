import Testing
@testable import Twisterminigen

@Suite("Gallery detail layout")
struct GalleryDetailLayoutTests {
    @Test("Gallery toolbar uses one consistent control rhythm")
    func toolbarControlRhythm() {
        #expect(GalleryToolbarLayout.controlHeight == 30)
        #expect(GalleryToolbarLayout.controlSpacing == 8)
        #expect(GalleryToolbarLayout.rowSpacing == 8)
        #expect(GalleryToolbarLayout.cornerRadius == 7)
        #expect(GalleryToolbarLayout.searchMaximumWidth == 300)
        #expect(GalleryToolbarLayout.previewSliderWidth == 72)
    }

    @Test("Bulk actions remain contextual like the Cyclon Gallery toolbar")
    func contextualSelectionToolbar() {
        #expect(GalleryToolbarLayout.selectionMode(selectedCount: 0, isSelecting: false) == .entry)
        #expect(GalleryToolbarLayout.selectionMode(selectedCount: 0, isSelecting: true) == .actions)
        #expect(GalleryToolbarLayout.selectionMode(selectedCount: 1, isSelecting: false) == .actions)
        #expect(GalleryToolbarLayout.selectionMode(selectedCount: 4, isSelecting: false) == .actions)
    }

    @Test("Context delete targets the active multi-selection")
    func contextualBulkDelete() {
        #expect(
            GalleryToolbarLayout.contextDeleteMode(
                isItemSelected: true,
                selectedCount: 4)
                == .selection(count: 4))
        #expect(
            GalleryToolbarLayout.contextDeleteMode(
                isItemSelected: true,
                selectedCount: 1)
                == .single)
        #expect(
            GalleryToolbarLayout.contextDeleteMode(
                isItemSelected: false,
                selectedCount: 4)
                == .single)
    }

    @Test("Gallery details open in image-first preview mode")
    func defaultDisplayMode() {
        #expect(GalleryDetailLayout.defaultDisplayMode == .preview)
        #expect(GalleryDetailLayout.defaultDisplayMode.toggled == .details)
        #expect(GalleryDetailLayout.defaultDisplayMode.toggled.toggled == .preview)
    }

    @Test("Large preview is at least twice the prior standard image height")
    func largePreviewHeight() {
        let preview = GalleryDetailLayout.imageMinimumHeight(
            mode: .preview,
            usesAccessibilityLayout: false)
        let details = GalleryDetailLayout.imageMinimumHeight(
            mode: .details,
            usesAccessibilityLayout: false)

        #expect(preview >= details * 2)
    }

    @Test("Long prompts collapse behind an explicit expansion control")
    func longPromptExpansion() {
        let prompt = String(repeating: "architectural detail, ", count: 18)

        #expect(GalleryDetailLayout.promptNeedsExpansion(prompt))
        #expect(GalleryDetailLayout.collapsedPromptLineLimit == 4)
    }

    @Test("Short prompts remain fully visible")
    func shortPromptRemainsVisible() {
        let prompt = "A blue cube on white."

        #expect(!GalleryDetailLayout.promptNeedsExpansion(prompt))
        #expect(GalleryDetailLayout.promptLineLimit(for: prompt, expanded: false) == nil)
    }

    @Test("Explicit prompt lines can expand without a long character count")
    func multilinePromptExpansion() {
        #expect(GalleryDetailLayout.promptNeedsExpansion("one\ntwo\nthree\nfour\nfive"))
    }

    @Test("Only collapsed long prompts receive a line limit")
    func promptLineLimit() {
        let prompt = String(repeating: "architectural detail, ", count: 18)

        #expect(GalleryDetailLayout.promptLineLimit(for: prompt, expanded: false) == 4)
        #expect(GalleryDetailLayout.promptLineLimit(for: prompt, expanded: true) == nil)
    }

    @Test("Expanded long prompts scroll inside a bounded viewport")
    func expandedPromptViewportIsBounded() throws {
        let prompt = String(repeating: "architectural detail, ", count: 80)
        let collapsedHeight = try #require(GalleryDetailLayout.promptViewportHeight(
            for: prompt,
            expanded: false,
            usesAccessibilityLayout: false))
        let expandedHeight = try #require(GalleryDetailLayout.promptViewportHeight(
            for: prompt,
            expanded: true,
            usesAccessibilityLayout: false))

        #expect(!GalleryDetailLayout.promptUsesScroll(for: prompt, expanded: false))
        #expect(GalleryDetailLayout.promptUsesScroll(for: prompt, expanded: true))
        #expect(expandedHeight > collapsedHeight)
        #expect(expandedHeight == GalleryDetailLayout.expandedPromptViewportHeight)
    }

    @Test("Prompt viewport remains finite with accessibility text")
    func accessibilityPromptViewportIsBounded() throws {
        let prompt = String(repeating: "long prompt ", count: 100)
        let expandedHeight = try #require(GalleryDetailLayout.promptViewportHeight(
            for: prompt,
            expanded: true,
            usesAccessibilityLayout: true))

        #expect(expandedHeight == GalleryDetailLayout.accessibilityExpandedPromptViewportHeight)
        #expect(expandedHeight < GalleryDetailLayout.sheetIdealHeight(mode: .details))
        #expect(GalleryDetailLayout.promptViewportHeight(
            for: "Short prompt.",
            expanded: false,
            usesAccessibilityLayout: false) == nil)
    }

    @Test("Gallery actions reduce columns for accessibility text")
    func actionGridRows() {
        #expect(GalleryDetailLayout.actionColumnCount(usesStackedLayout: false) == 4)
        #expect(GalleryDetailLayout.actionColumnCount(usesStackedLayout: true) == 3)
        #expect(GalleryDetailLayout.actionRowCount(
            for: 0,
            usesStackedLayout: false) == 0)
        #expect(GalleryDetailLayout.actionRowCount(
            for: 8,
            usesStackedLayout: false) == 2)
        #expect(GalleryDetailLayout.actionRowCount(
            for: 8,
            usesStackedLayout: true) == 3)
    }

    @Test("Details sheet stays shorter than the image-first preview")
    func detailsSheetUsesCompactStableHeight() {
        #expect(
            GalleryDetailLayout.sheetIdealHeight(mode: .details)
                < GalleryDetailLayout.sheetIdealHeight(mode: .preview))
        #expect(
            GalleryDetailLayout.sheetMaximumHeight(mode: .details)
                < GalleryDetailLayout.sheetMaximumHeight(mode: .preview))
    }

    @Test("Persisted 150 percent scale forces accessibility layout")
    func persistedScaleForcesAccessibilityLayout() {
        #expect(!GalleryDetailLayout.usesAccessibilityLayout(
            textScalePercent: 145,
            dynamicTypeIsAccessibility: false))
        #expect(GalleryDetailLayout.usesAccessibilityLayout(
            textScalePercent: 150,
            dynamicTypeIsAccessibility: false))
        #expect(GalleryDetailLayout.usesAccessibilityLayout(
            textScalePercent: 100,
            dynamicTypeIsAccessibility: true))
    }
}
