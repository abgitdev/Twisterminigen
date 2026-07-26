import Foundation
import Testing
@testable import Twisterminigen

@Suite struct GenerateSettingsPanelTests {
    @Test("Wide prompt composer does not move the accepted settings anchor")
    func widePromptComposer() {
        #expect(GenerateWorkspaceLayout.preferredComposerWidth == 1_320)
        #expect(GenerateWorkspaceLayout.preferredSettingsDeckWidth == 860)
        #expect(GenerateWorkspaceLayout.composerWidth(availableWidth: 1_800) == 1_320)
        #expect(GenerateWorkspaceLayout.settingsDeckWidth(availableWidth: 1_800) == 860)
        #expect(GenerateWorkspaceLayout.composerWidth(availableWidth: 720) == 720)
        #expect(GenerateWorkspaceLayout.settingsDeckWidth(availableWidth: 720) == 720)
    }

    @Test("Only one settings entry point remains")
    func settingsEntryPoints() {
        #expect(GenerateSettingsPanel.allCases == [.text, .remix, .more])
    }

    @Test("Floating settings panels never duplicate the main prompt")
    func panelSectionsStayFocused() {
        #expect(GenerateSettingsPanel.text.sections == [.exactText])
        #expect(GenerateSettingsPanel.remix.sections == [.remixSource])
        #expect(GenerateSettingsPanel.more.sections == [
            .canvas,
            .render,
            .variations,
            .expert,
        ])
    }

    @Test("Pressing the active settings chip closes its floating panel")
    func repeatedChipTogglesPanel() {
        #expect(GenerateSettingsPanel.toggled(current: nil, requested: .more) == .more)
        #expect(GenerateSettingsPanel.toggled(current: .more, requested: .more) == nil)
        #expect(GenerateSettingsPanel.toggled(current: .text, requested: .more) == .more)
    }

    @Test("Panel titles remain concise and specific")
    func titles() {
        #expect(GenerateSettingsPanel.text.title == "Lettering")
        #expect(GenerateSettingsPanel.remix.title == "Remix source")
        #expect(GenerateSettingsPanel.more.title == "Fine-tuning")
    }

    @Test("Fine-tuning is tall and deliberately narrow")
    func morePanelIsTallAndNarrow() {
        let availableWidth: CGFloat = 860
        let compactWidth = GenerateSettingsPanelLayout.width(
            panel: .remix,
            availableWidth: availableWidth,
            usesAccessibilityLayout: false)
        let moreWidth = GenerateSettingsPanelLayout.width(
            panel: .more,
            availableWidth: availableWidth,
            usesAccessibilityLayout: false)

        #expect(moreWidth < compactWidth)
        #expect(moreWidth == 284)
        #expect(GenerateSettingsPanelLayout.width(
            panel: .more,
            availableWidth: availableWidth,
            usesAccessibilityLayout: true) == 284)
        #expect(GenerateSettingsPanelLayout.moreMaximumHeight
            > GenerateSettingsPanelLayout.compactMaximumHeight)
    }

    @Test("Fine-tuning keeps the owner-approved cropped column contract")
    func morePanelDensityContract() {
        #expect(GenerateSettingsPanelLayout.moreMaximumWidth == 284)
        #expect(GenerateSettingsPanelLayout.moreAccessibilityMaximumWidth == 284)
        #expect(GenerateSettingsPanelLayout.moreTrailingCrop == 88)
        #expect(GenerateSettingsPanelLayout.moreMaximumWidth
            + GenerateSettingsPanelLayout.moreTrailingCrop == 372)
        #expect(GenerateSettingsPanelLayout.moreHeaderHeight == 42)
        #expect(GenerateSettingsPanelLayout.moreContentPadding == 14)
        #expect(GenerateSettingsPanelLayout.moreContentSpacing == 12)
        #expect(GenerateSettingsPanelLayout.moreScrollIndicatorTrailingInset == 8)
        #expect(GenerateSettingsPanelLayout.moreScrollIndicatorBottomInset == 8)
        #expect(GenerateSettingsPanelLayout.moreInnerWidth == 256)
        #expect(GenerateSettingsPanelLayout.contentWidth(
            panel: .more,
            panelWidth: 284) == 256)
        #expect(GenerateSettingsPanelLayout.contentWidth(
            panel: .more,
            panelWidth: 260) == 232)
        #expect(GenerateSettingsPanelLayout.contentWidth(
            panel: .text,
            panelWidth: 404) == nil)
        #expect(GenerateSettingsPanelLayout.moreAspectColumns == 4)
        #expect(GenerateSettingsPanelLayout.moreAspectSpacing == 5)
        #expect(GenerateSettingsPanelLayout.moreExactSizeSpacing == 5)
        #expect(GenerateSettingsPanelLayout.moreExactSizeFieldWidth == 125.5)
        #expect(
            (GenerateSettingsPanelLayout.moreExactSizeFieldWidth * 2)
                + GenerateSettingsPanelLayout.moreExactSizeSpacing
                == GenerateSettingsPanelLayout.moreInnerWidth)
        #expect(GenerateSettingsPanelLayout.moreExpertSpacing == 10)
        #expect(GenerateSettingsPanelLayout.moreGuidanceFieldWidth == 64)
        #expect(GenerateSettingsPanelLayout.moreGuidanceFieldHeight == 30)
        #expect(GenerateSettingsPanelLayout.moreLoRAPadding == 8)
    }

    @MainActor
    @Test("Fine-tuning aspect grid matches the Cyclon four-column composition")
    func fineTuningAspectGrid() {
        #expect(Array(GenerateViewModel.aspectPresets.prefix(4)).map(\.id)
            == ["1:1", "4:3", "3:2", "16:9"])
        #expect(Array(GenerateViewModel.aspectPresets.dropFirst(4)).map(\.id)
            == ["3:4", "2:3", "9:16"])
    }

    @MainActor
    @Test("Live preview modes keep their explicit off and cadence contract")
    func livePreviewModes() {
        #expect(GenerateViewModel.LivePreviewMode.allCases == [
            .off,
            .everyFourSteps,
            .everyStep,
        ])
        #expect(GenerateViewModel.LivePreviewMode.allCases.map(\.previewEverySteps)
            == [0, 4, 1])
        #expect(GenerateViewModel.LivePreviewMode.allCases.map(\.displayName)
            == ["Off", "Every 4 steps", "Every step"])
    }

    @Test("Lettering uses a compact direct-input panel")
    func letteringPanelIsCompact() {
        #expect(GenerateSettingsPanelLayout.height(
            panel: .text,
            availableHeight: 1_200,
            usesAccessibilityLayout: false)
            == GenerateSettingsPanelLayout.letteringMaximumHeight)
        #expect(GenerateSettingsPanelLayout.height(
            panel: .text,
            availableHeight: 1_200,
            usesAccessibilityLayout: true)
            == GenerateSettingsPanelLayout.letteringAccessibilityMaximumHeight)
        #expect(GenerateSettingsPanelLayout.letteringMaximumHeight
            < GenerateSettingsPanelLayout.compactMaximumHeight)
    }

    @Test("Fine-tuning remains inside narrow workspaces")
    func morePanelRespectsAvailableWidth() {
        #expect(GenerateSettingsPanelLayout.width(
            panel: .more,
            availableWidth: 260,
            usesAccessibilityLayout: false) == 260)
        #expect(GenerateSettingsPanelLayout.height(
            panel: .more,
            availableHeight: 900,
            usesAccessibilityLayout: false)
            == GenerateSettingsPanelLayout.moreMaximumHeight)
        #expect(GenerateSettingsPanelLayout.height(
            panel: .more,
            availableHeight: 750,
            usesAccessibilityLayout: false) == 618)
    }

    @Test("A missing or obsolete draft returns to the official Turbo step default")
    func officialTurboStepDefault() {
        #expect(GenerateViewModel.restoredDraftSteps(nil) == 8)
        #expect(GenerateViewModel.restoredDraftSteps(0) == 8)
        #expect(GenerateViewModel.restoredDraftSteps(13) == 8)
        #expect(GenerateViewModel.restoredDraftSteps(4) == 4)
        #expect(GenerateViewModel.restoredDraftSteps(12) == 12)
    }
}
