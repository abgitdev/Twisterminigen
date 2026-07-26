import Foundation

/// Presentation-only destinations for the compact settings card above Generate's command bar.
/// The main prompt deliberately is not a section: it has one authoritative editor in the composer.
enum GenerateSettingsPanel: CaseIterable, Equatable {
    enum Section: Hashable {
        case exactText
        case remixSource
        case canvas
        case render
        case variations
        case expert
    }

    case text
    case remix
    case more

    var title: String {
        switch self {
        case .text: "Lettering"
        case .remix: "Remix source"
        case .more: "Fine-tuning"
        }
    }

    var icon: String {
        switch self {
        case .text: "textformat"
        case .remix: "photo"
        case .more: "slider.horizontal.3"
        }
    }

    var accessibilityID: String {
        switch self {
        case .text: "lettering"
        case .remix: "remix"
        case .more: "generation"
        }
    }

    var sections: [Section] {
        switch self {
        case .text:
            [.exactText]
        case .remix:
            [.remixSource]
        case .more:
            [.canvas, .render, .variations, .expert]
        }
    }

    static func toggled(
        current: GenerateSettingsPanel?,
        requested: GenerateSettingsPanel
    ) -> GenerateSettingsPanel? {
        current == requested ? nil : requested
    }
}

enum GenerateSettingsPanelLayout {
    static let compactMaximumWidth: CGFloat = 404
    static let compactAccessibilityMaximumWidth: CGFloat = 480
    /// The owner-approved crop is a 284 pt tool column. Larger text wraps and scrolls vertically;
    /// accessibility layout must never widen Fine-tuning back into a sheet.
    static let moreMaximumWidth: CGFloat = 284
    static let moreAccessibilityMaximumWidth: CGFloat = 284
    /// Preserve the former left edge while moving the right edge to the owner's marked crop line.
    static let moreTrailingCrop: CGFloat = 88
    static let moreHeaderHeight: CGFloat = 42
    static let moreContentPadding: CGFloat = 14
    static let moreContentSpacing: CGFloat = 12
    /// Keep macOS's overlay scroller fully inside the narrow card instead of centring it on the
    /// trailing border. The bottom inset also keeps the track clear of the rounded lower corner.
    static let moreScrollIndicatorTrailingInset: CGFloat = 8
    static let moreScrollIndicatorBottomInset: CGFloat = 8
    static let moreInnerWidth: CGFloat = moreMaximumWidth - (moreContentPadding * 2)
    static let moreAspectColumns = 4
    static let moreAspectSpacing: CGFloat = 5
    static let moreExactSizeSpacing: CGFloat = 5
    static let moreExactSizeFieldWidth: CGFloat =
        (moreInnerWidth - moreExactSizeSpacing) / 2
    static let moreExpertSpacing: CGFloat = 10
    static let moreGuidanceFieldWidth: CGFloat = 64
    static let moreGuidanceFieldHeight: CGFloat = 30
    static let moreLoRAPadding: CGFloat = 8
    static let letteringMaximumHeight: CGFloat = 300
    static let letteringAccessibilityMaximumHeight: CGFloat = 380
    static let compactMaximumHeight: CGFloat = 560
    static let moreMaximumHeight: CGFloat = 760

    static func contentWidth(
        panel: GenerateSettingsPanel,
        panelWidth: CGFloat
    ) -> CGFloat? {
        guard panel == .more else { return nil }
        return max(0, panelWidth - (moreContentPadding * 2))
    }

    static func width(
        panel: GenerateSettingsPanel,
        availableWidth: CGFloat,
        usesAccessibilityLayout: Bool
    ) -> CGFloat {
        let maximum = switch panel {
        case .more:
            usesAccessibilityLayout ? moreAccessibilityMaximumWidth : moreMaximumWidth
        case .text, .remix:
            usesAccessibilityLayout ? compactAccessibilityMaximumWidth : compactMaximumWidth
        }
        return min(availableWidth, maximum)
    }

    static func height(
        panel: GenerateSettingsPanel,
        availableHeight: CGFloat,
        usesAccessibilityLayout: Bool
    ) -> CGFloat {
        let minimum: CGFloat
        let maximum: CGFloat
        switch panel {
        case .text:
            minimum = 260
            maximum = usesAccessibilityLayout
                ? letteringAccessibilityMaximumHeight
                : letteringMaximumHeight
        case .remix:
            minimum = 220
            maximum = compactMaximumHeight
        case .more:
            minimum = 320
            maximum = moreMaximumHeight
        }
        let bottomControlsReserve: CGFloat = usesAccessibilityLayout ? 185 : 132
        return max(minimum, min(maximum, availableHeight - bottomControlsReserve))
    }
}
