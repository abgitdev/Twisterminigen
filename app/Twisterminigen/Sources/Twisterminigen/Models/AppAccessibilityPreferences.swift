import Foundation
import Observation
import SwiftUI

/// User-controlled accessibility overrides. System accessibility settings remain authoritative:
/// the app wrapper combines them with these local, persisted preferences instead of replacing
/// an operating-system request with a less accessible value.
@MainActor
@Observable
final class AppAccessibilityPreferences {
    static let minimumTextScalePercent = 85
    static let maximumTextScalePercent = 160
    static let defaultTextScalePercent = 100

    private enum Key {
        static let textScalePercent = "accessibility.textScalePercent"
        static let reduceTransparency = "accessibility.reduceTransparency"
        static let increaseContrast = "accessibility.increaseContrast"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var textScalePercent: Int {
        didSet {
            let normalized = Self.normalizedTextScale(textScalePercent)
            if normalized != textScalePercent {
                textScalePercent = normalized
                return
            }
            defaults.set(textScalePercent, forKey: Key.textScalePercent)
        }
    }

    var reduceTransparency: Bool {
        didSet { defaults.set(reduceTransparency, forKey: Key.reduceTransparency) }
    }

    var increaseContrast: Bool {
        didSet { defaults.set(increaseContrast, forKey: Key.increaseContrast) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.textScalePercent) == nil {
            textScalePercent = Self.defaultTextScalePercent
        } else {
            textScalePercent = Self.normalizedTextScale(
                defaults.integer(forKey: Key.textScalePercent))
        }
        reduceTransparency = defaults.bool(forKey: Key.reduceTransparency)
        increaseContrast = defaults.bool(forKey: Key.increaseContrast)
    }

    func reset() {
        textScalePercent = Self.defaultTextScalePercent
        reduceTransparency = false
        increaseContrast = false
    }

    static func normalizedTextScale(_ value: Int) -> Int {
        SteppedIntegerValue.normalized(
            value,
            in: minimumTextScalePercent ... maximumTextScalePercent,
            step: 5)
    }

    /// SwiftUI exposes Dynamic Type as semantic sizes. This bounded mapping keeps the app's
    /// explicit 85–160% control predictable while retaining Apple's text-layout behavior.
    var dynamicTypeSize: DynamicTypeSize {
        switch textScalePercent {
        case ...87: .xSmall
        case ...92: .small
        case ...97: .medium
        case ...104: .large
        case ...114: .xLarge
        case ...127: .xxLarge
        case ...147: .xxxLarge
        default: .accessibility1
        }
    }

    /// A macOS size above the standard Large baseline remains authoritative. At the normal
    /// baseline the explicit app control is allowed to shrink as well as enlarge text; otherwise
    /// the advertised 85–100% half of the slider would be inert.
    static func effectiveDynamicTypeSize(
        system: DynamicTypeSize,
        local: DynamicTypeSize
    ) -> DynamicTypeSize {
        system > .large ? max(system, local) : local
    }

    /// Exact scale used by the app's custom typography. SwiftUI's semantic Dynamic Type
    /// environment is not sufficient for fixed custom faces on macOS, so the design system also
    /// receives this explicit factor. Larger macOS accessibility sizes still establish a floor.
    static func effectiveTextScaleFactor(
        system: DynamicTypeSize,
        localPercent: Int
    ) -> CGFloat {
        let local = CGFloat(normalizedTextScale(localPercent)) / 100
        guard system > .large else { return local }
        return max(local, systemTextScaleFactor(system))
    }

    private static func systemTextScaleFactor(_ size: DynamicTypeSize) -> CGFloat {
        if size >= .accessibility5 { return 3.10 }
        if size >= .accessibility4 { return 2.75 }
        if size >= .accessibility3 { return 2.35 }
        if size >= .accessibility2 { return 1.95 }
        if size >= .accessibility1 { return 1.60 }
        if size >= .xxxLarge { return 1.45 }
        if size >= .xxLarge { return 1.25 }
        if size >= .xLarge { return 1.10 }
        return 1
    }
}

/// Shared breakpoint for layouts that need to trade columns for vertical scrolling.
enum AccessibilityLayoutPolicy {
    static func usesStackedLayout(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }
}

/// Applies local overrides while preserving stronger settings inherited from macOS.
struct AppAccessibilityRoot<Content: View>: View {
    @Bindable var preferences: AppAccessibilityPreferences
    @ViewBuilder let content: () -> Content

    @Environment(\.dynamicTypeSize) private var systemDynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var systemReducesTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast

    private var reducesTransparency: Bool {
        systemReducesTransparency || preferences.reduceTransparency
    }

    private var increasesContrast: Bool {
        systemContrast == .increased || preferences.increaseContrast
    }

    private var effectiveDynamicTypeSize: DynamicTypeSize {
        AppAccessibilityPreferences.effectiveDynamicTypeSize(
            system: systemDynamicTypeSize,
            local: preferences.dynamicTypeSize)
    }

    private var effectiveTextScaleFactor: CGFloat {
        AppAccessibilityPreferences.effectiveTextScaleFactor(
            system: systemDynamicTypeSize,
            localPercent: preferences.textScalePercent)
    }

    var body: some View {
        content()
            .environment(\.dynamicTypeSize, effectiveDynamicTypeSize)
            .environment(\.fxTextScale, effectiveTextScaleFactor)
            .environment(\.fxReduceTransparency, reducesTransparency)
            .environment(\.fxIncreaseContrast, increasesContrast)
            // Keep an opaque Dark-compatible safety base. Glass supplies its own opaque navy
            // fallback inside FxAppBackdrop / fxPageBackground.
            .background(reducesTransparency ? Color.fxBg : Color.clear)
    }
}

private struct FxReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

private struct FxIncreaseContrastKey: EnvironmentKey {
    static let defaultValue = false
}

private struct FxTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var fxTextScale: CGFloat {
        get { self[FxTextScaleKey.self] }
        set { self[FxTextScaleKey.self] = newValue }
    }

    var fxReduceTransparency: Bool {
        get { self[FxReduceTransparencyKey.self] }
        set { self[FxReduceTransparencyKey.self] = newValue }
    }

    var fxIncreaseContrast: Bool {
        get { self[FxIncreaseContrastKey.self] }
        set { self[FxIncreaseContrastKey.self] = newValue }
    }
}
