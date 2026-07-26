import AppKit
import SwiftUI

// ============================================================
//  Twisterminigen design system.
//
//  Dark is the original Slate Steel interface and remains the
//  default. Light uses an opaque, high-contrast semantic palette.
//  Glass is an opt-in Tahoe treatment layered over the bundled
//  aurora artwork and intentionally keeps dark system controls.
// ============================================================

/// Resolves a semantic token through the view's effective Aqua/Dark Aqua
/// appearance. `preferredColorScheme` therefore updates existing `Color.fx…`
/// call sites without requiring every screen to branch on `AppTheme`.
private func fxAdaptiveColor(
    light: UInt,
    dark: UInt,
    lightAlpha: Double = 1,
    darkAlpha: Double = 1
) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [
            .accessibilityHighContrastDarkAqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .aqua,
        ])
        let usesDarkPalette = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let hex = usesDarkPalette ? dark : light
        let alpha = usesDarkPalette ? darkAlpha : lightAlpha
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    })
}

extension Color {
    /// Hex with optional alpha, sRGB. e.g. `Color(hex: 0x93A7B5)`.
    init(hex: UInt, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    // Opaque Light surfaces paired with the original Dark Slate Steel values.
    static let fxBg        = fxAdaptiveColor(light: 0xF4F6F8, dark: 0x12151A)
    static let fxTabBar    = fxAdaptiveColor(light: 0xF8FAFC, dark: 0x14171D)
    static let fxStatusBar = fxAdaptiveColor(light: 0xEDF1F4, dark: 0x10131A)
    static let fxPanel     = fxAdaptiveColor(light: 0xFFFFFF, dark: 0x171B21)
    static let fxCardFill = fxAdaptiveColor(
        light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.92, darkAlpha: 0.03)
    static let fxSheet  = fxAdaptiveColor(light: 0xF8FAFC, dark: 0x1A1E24)
    /// The Generate canvas highlight must stay light in Aqua instead of exposing
    /// the original hard-coded dark spotlight.
    static let fxCanvasTop = fxAdaptiveColor(light: 0xF2F5F7, dark: 0x1A1E26)
    static let fxCanvas = fxAdaptiveColor(light: 0xE8EDF2, dark: 0x161A20)
    static let fxInset = fxAdaptiveColor(
        light: 0x17212B, dark: 0xFFFFFF, lightAlpha: 0.055, darkAlpha: 0.04)
    static let fxLogBg = fxAdaptiveColor(light: 0xE9EEF2, dark: 0x0F1216)

    // Opaque fallback used by Glass when transparency is disabled.
    static let fxOpaqueBg = Color(hex: 0x080B18)

    // Lines / hover remain visible without becoming heavy in Light.
    static let fxHover = fxAdaptiveColor(
        light: 0x17212B, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.06)
    static let fxBorder = fxAdaptiveColor(
        light: 0x17212B, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.08)
    static let fxBorderStrong = fxAdaptiveColor(
        light: 0x17212B, dark: 0xFFFFFF, lightAlpha: 0.24, darkAlpha: 0.12)

    // Text. Light's faintest semantic text remains readable on white cards.
    static let fxText      = fxAdaptiveColor(light: 0x182027, dark: 0xE7EAEC)
    static let fxText2     = fxAdaptiveColor(light: 0x4B5864, dark: 0x9AA3AC)
    static let fxText3     = fxAdaptiveColor(light: 0x64717D, dark: 0x7F8790)
    static let fxTextLabel = fxAdaptiveColor(light: 0x34434E, dark: 0xC6CCD2)

    // Accent. Light uses the darker end of the steel family for sufficient contrast.
    static let fxAccent     = fxAdaptiveColor(light: 0x456777, dark: 0x93A7B5)
    static let fxAccentDeep = fxAdaptiveColor(light: 0x2F5364, dark: 0x5E7080)
    static let fxAccentLine = fxAdaptiveColor(
        light: 0x456777, dark: 0x93A7B5, lightAlpha: 0.38, darkAlpha: 0.30)
    static let fxAccentSoft = fxAdaptiveColor(
        light: 0x456777, dark: 0x93A7B5, lightAlpha: 0.14, darkAlpha: 0.14)
    static let fxAccentHi = fxAdaptiveColor(light: 0x274A5B, dark: 0xB3C6D2)
    static let fxOnAccent = fxAdaptiveColor(light: 0xFFFFFF, dark: 0x0F161C)

    // Success (teal) — downloaded / MLX / green dots.
    static let fxOk = fxAdaptiveColor(light: 0x14745D, dark: 0x6FB9A0)
    static let fxOkSoft = fxAdaptiveColor(
        light: 0x14745D, dark: 0x6FB9A0, lightAlpha: 0.13, darkAlpha: 0.12)
    static let fxOkDeep = fxAdaptiveColor(light: 0x0B604A, dark: 0x4F8F7C)

    // Danger.
    static let fxDanger = fxAdaptiveColor(light: 0xB42318, dark: 0xE5685F)
    static let fxDangerSoft = fxAdaptiveColor(
        light: 0xB42318, dark: 0xE5685F, lightAlpha: 0.13, darkAlpha: 0.18)

    // Window chrome + model-chip family.
    static let fxHdrBg     = fxAdaptiveColor(light: 0xFBFCFD, dark: 0x171B21)
    static let fxHdrBorder = fxAdaptiveColor(light: 0xD8E0E6, dark: 0x1A1E24)
    static let fxHdrText   = fxAdaptiveColor(light: 0x182027, dark: 0xE7EAEC)
    static let fxHdrMuted  = fxAdaptiveColor(light: 0x53616D, dark: 0x8A929B)
    static let fxHdrFaint  = fxAdaptiveColor(light: 0x64717D, dark: 0x757E87)
    static let fxHdrBtnBg = fxAdaptiveColor(
        light: 0x17212B, dark: 0xFFFFFF, lightAlpha: 0.055, darkAlpha: 0.05)
    static let fxHdrBtnBorder = fxAdaptiveColor(
        light: 0x17212B, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.10)
    static let fxEmberHi = fxAdaptiveColor(light: 0x2F4653, dark: 0xCDD3D9)
    static let fxEmberBg = fxAdaptiveColor(
        light: 0x456777, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.05)
    static let fxEmberBorder = fxAdaptiveColor(
        light: 0x456777, dark: 0xFFFFFF, lightAlpha: 0.20, darkAlpha: 0.10)
    static let fxOnEmber = fxAdaptiveColor(light: 0xFFFFFF, dark: 0x0F161C)
    static let fxGreen   = fxAdaptiveColor(light: 0x137A4A, dark: 0x5CC685)
}

/// Glass-specific values are deliberately separate from the original semantic
/// colours. This prevents the opt-in appearance from changing Dark by accident.
enum FxGlassPalette {
    static let workspaceVeil = Color(hex: 0x403E41, alpha: 0.45)
    static let tabBar        = Color(hex: 0x403E4B, alpha: 0.42)
    static let statusBar     = Color(hex: 0x22242F, alpha: 0.61)
    static let panel         = Color(hex: 0x14182A)
    static let cardFill      = Color.white.opacity(0.065)
    static let sheet         = Color(hex: 0x151A30)
    static let canvas        = Color(hex: 0x10162C, alpha: 0.20)
    static let inset         = Color.white.opacity(0.075)
    static let log           = Color(hex: 0x070A15)

    static let tint          = Color(hex: 0xB8C7FF, alpha: 0.055)
    static let control       = Color.white.opacity(0.085)
    static let floating      = Color(hex: 0xB9C9F5, alpha: 0.115)
    static let stroke        = Color.white.opacity(0.20)
    static let strokeSoft    = Color.white.opacity(0.105)
    static let highlight     = Color.white.opacity(0.26)

    static let hover         = Color.white.opacity(0.10)
    static let border        = Color.white.opacity(0.105)
    static let borderStrong  = Color.white.opacity(0.19)
    static let text          = Color(hex: 0xF3F5FF)
    static let text2         = Color(hex: 0xBEC6DB)
    static let text3         = Color(hex: 0x929BB5)
    static let textLabel     = Color(hex: 0xD8DDF0)

    static let header        = Color(hex: 0x403E4B, alpha: 0.42)
    static let headerBorder  = Color.white.opacity(0.105)
    static let headerText    = Color(hex: 0xF4F6FF)
    static let headerMuted   = Color(hex: 0xA4ADC5)
    static let headerFaint   = Color(hex: 0x8992AB)
    static let headerButton  = Color.white.opacity(0.085)
    static let headerButtonBorder = Color.white.opacity(0.15)
    static let ember         = Color(hex: 0xE3E8F8)
    static let emberFill     = Color.white.opacity(0.085)
    static let emberBorder   = Color.white.opacity(0.16)
}

enum FxTypography {
    static func scaledPointSize(_ baseSize: CGFloat, factor: CGFloat) -> CGFloat {
        guard baseSize.isFinite, factor.isFinite else { return max(1, baseSize) }
        return max(1, baseSize * factor)
    }
}

private struct FxScaledFontModifier: ViewModifier {
    @Environment(\.fxTextScale) private var textScale

    let size: CGFloat
    let weight: Font.Weight
    let monospaced: Bool

    func body(content: Content) -> some View {
        let name = monospaced
            ? FxFontResolver.monospacedFontName(for: weight)
            : FxFontResolver.systemFontName(for: weight)
        content.font(.custom(
            name,
            fixedSize: FxTypography.scaledPointSize(size, factor: textScale)))
    }
}

extension View {
    func fxFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        monospaced: Bool = false
    ) -> some View {
        modifier(FxScaledFontModifier(
            size: size,
            weight: weight,
            monospaced: monospaced))
    }

    func fxMonoFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular
    ) -> some View {
        fxFont(size, weight: weight, monospaced: true)
    }
}

/// Resolves the exact platform font face for a requested weight.
///
/// Passing an internal system *family* to `Font.custom` and applying `.weight` later makes SwiftUI
/// repeatedly search for a face that it cannot resolve, which floods the unified log. Exact
/// PostScript names avoid that fallback path; `FxScaledFontModifier` applies the live app scale.
enum FxFontResolver {
    static func systemFontName(for weight: Font.Weight) -> String {
        NSFont.systemFont(
            ofSize: NSFont.systemFontSize,
            weight: weight.appKitWeight).fontName
    }

    static func monospacedFontName(for weight: Font.Weight) -> String {
        NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: weight.appKitWeight).fontName
    }
}

private extension Font.Weight {
    var appKitWeight: NSFont.Weight {
        if self == .ultraLight { return .ultraLight }
        if self == .thin { return .thin }
        if self == .light { return .light }
        if self == .medium { return .medium }
        if self == .semibold { return .semibold }
        if self == .bold { return .bold }
        if self == .heavy { return .heavy }
        if self == .black { return .black }
        return .regular
    }
}

/// Original Dark geometry. Existing call sites keep these values by default.
enum FxRadius {
    static let card: CGFloat   = 14
    static let field: CGFloat  = 11
    static let button: CGFloat = 11
    static let pill: CGFloat   = 8
    static let sheet: CGFloat  = 18
}

enum FxGlassRadius {
    static let card: CGFloat   = 16
    static let field: CGFloat  = 12
    static let button: CGFloat = 12
    static let pill: CGFloat   = 10
    static let sheet: CGFloat  = 20
}

/// Common non-semantic surface roles used by screens that draw custom cards
/// instead of the shared `fxCard` / `fxInsetField` components.
enum FxSurfaceRole {
    case card
    case inset
    case panel
    case sheet
    case log

    fileprivate var opaqueFill: Color {
        switch self {
        case .card: Color.fxCardFill
        case .inset: Color.fxInset
        case .panel: Color.fxPanel
        case .sheet: Color.fxSheet
        case .log: Color.fxLogBg
        }
    }

    fileprivate var glassTint: Color {
        switch self {
        case .card: FxGlassPalette.cardFill
        case .inset: FxGlassPalette.inset
        case .panel: Color(hex: 0x14182A, alpha: 0.34)
        case .sheet: Color(hex: 0x151A30, alpha: 0.45)
        case .log: Color(hex: 0x070A15, alpha: 0.56)
        }
    }

    fileprivate var opaqueFallbackFill: Color {
        switch self {
        case .card, .inset: Color.fxPanel
        case .panel: Color.fxPanel
        case .sheet: Color.fxSheet
        case .log: Color.fxLogBg
        }
    }
}

private struct FxThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .dark
}

extension EnvironmentValues {
    var fxTheme: AppTheme {
        get { self[FxThemeKey.self] }
        set { self[FxThemeKey.self] = newValue }
    }
}

/// Bundled aurora used exclusively by the Glass appearance.
enum FxBackdropAsset {
    static let resourceName = "Twisterminigen_fon_1"

    static var resourceURL: URL? {
        Bundle.module.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: "Backgrounds")
            ?? Bundle.module.url(forResource: resourceName, withExtension: "png")
    }

    static let image: NSImage? = resourceURL.flatMap(NSImage.init(contentsOf:))
}

/// One continuous root backdrop. Dark and Light are intentionally solid colours;
/// only Glass loads and displays the supplied artwork.
struct FxAppBackdrop: View {
    @Environment(\.fxTheme) private var theme
    @Environment(\.fxReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if theme != .glass {
                    Color.fxBg
                } else if reduceTransparency {
                    Color.fxOpaqueBg
                } else if let image = FxBackdropAsset.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [Color(hex: 0x14275A), Color(hex: 0x321466), Color.fxOpaqueBg],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                }

                if theme == .glass, !reduceTransparency {
                    LinearGradient(
                        stops: [
                            .init(color: Color.clear, location: 0),
                            .init(color: Color(hex: 0x090D20, alpha: 0.02), location: 0.58),
                            .init(color: Color(hex: 0x050816, alpha: 0.12), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

extension View {
    func fxLabel() -> some View {
        modifier(FxLabelModifier())
    }

    func fxCard(
        padding: CGFloat = 16,
        radius: CGFloat? = nil,
        shadow: Bool = false
    ) -> some View {
        modifier(FxCardModifier(padding: padding, radius: radius, shadow: shadow))
    }

    func fxChip(
        accent: Bool = false,
        padV: CGFloat = 5,
        padH: CGFloat = 10,
        radius: CGFloat? = nil
    ) -> some View {
        modifier(FxChipModifier(
            accent: accent,
            padV: padV,
            padH: padH,
            radius: radius))
    }

    func fxPillOk() -> some View {
        modifier(FxPillOkModifier())
    }

    func fxInsetField(radius: CGFloat? = nil) -> some View {
        modifier(FxInsetFieldModifier(radius: radius))
    }

    /// Theme-aware page fill. Opaque themes get their solid workspace; Glass leaves
    /// a tinted veil through which the single root backdrop remains visible.
    func fxPageBackground() -> some View {
        modifier(FxPageBackgroundModifier())
    }

    /// Sheets may be hosted in their own window and therefore cannot assume the
    /// main ContentView backdrop is behind them. This helper provides a local copy.
    func fxStandalonePageBackground() -> some View {
        modifier(FxStandalonePageBackgroundModifier())
    }

    /// Theme-aware replacement for custom `background + stroke` card shells.
    /// Opaque themes keep their semantic role fill; Glass gets native/material glass.
    func fxThemedSurface(
        _ role: FxSurfaceRole,
        radius: CGFloat,
        bordered: Bool = true,
        interactive: Bool = false,
        shadow: CGFloat = 0
    ) -> some View {
        modifier(FxThemedSurfaceModifier(
            role: role,
            radius: radius,
            bordered: bordered,
            interactive: interactive,
            shadow: shadow))
    }

    /// Cross-version Tahoe surface. Native Liquid Glass is used on macOS 26;
    /// macOS 14–15 retain the same composition via ultra-thin material.
    func fxGlassSurface(
        radius: CGFloat,
        tint: Color = FxGlassPalette.tint,
        stroke: Color = FxGlassPalette.strokeSoft,
        interactive: Bool = false,
        shadow: CGFloat = 0
    ) -> some View {
        modifier(FxGlassSurfaceModifier(
            radius: radius,
            tint: tint,
            stroke: stroke,
            interactive: interactive,
            shadow: shadow))
    }
}

private struct FxLabelModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    func body(content: Content) -> some View {
        content
            .fxFont(12, weight: .medium)
            .foregroundStyle(theme == .glass ? FxGlassPalette.textLabel : Color.fxTextLabel)
    }
}

private struct FxPageBackgroundModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme
    @Environment(\.fxReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background(
            theme == .glass
                ? (reduceTransparency ? Color.fxOpaqueBg : FxGlassPalette.workspaceVeil)
                : Color.fxBg)
    }
}

private struct FxStandalonePageBackgroundModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme
    @Environment(\.fxReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                FxAppBackdrop()
                if theme == .glass, !reduceTransparency {
                    FxGlassPalette.workspaceVeil
                }
            }
        }
    }
}

private struct FxThemedSurfaceModifier: ViewModifier {
    let role: FxSurfaceRole
    let radius: CGFloat
    let bordered: Bool
    let interactive: Bool
    let shadow: CGFloat

    @Environment(\.fxTheme) private var theme
    @Environment(\.fxReduceTransparency) private var reduceTransparency
    @Environment(\.fxIncreaseContrast) private var increaseContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if theme == .glass {
            content.modifier(FxGlassSurfaceModifier(
                radius: radius,
                tint: role.glassTint,
                stroke: bordered ? FxGlassPalette.border : Color.clear,
                interactive: interactive,
                shadow: shadow))
        } else {
            content
                .background(
                    reduceTransparency ? role.opaqueFallbackFill : role.opaqueFill,
                    in: shape)
                .overlay(shape.strokeBorder(
                    bordered
                        ? (increaseContrast ? Color.fxBorderStrong : Color.fxBorder)
                        : Color.clear,
                    lineWidth: bordered ? (increaseContrast ? 1.5 : 1) : 0))
                .shadow(
                    color: .black.opacity(shadow > 0 ? 0.30 : 0),
                    radius: shadow,
                    y: shadow > 0 ? 6 : 0)
        }
    }
}

private struct FxGlassSurfaceModifier: ViewModifier {
    let radius: CGFloat
    let tint: Color
    let stroke: Color
    let interactive: Bool
    let shadow: CGFloat

    @Environment(\.fxTheme) private var theme
    @Environment(\.fxReduceTransparency) private var reduceTransparency
    @Environment(\.fxIncreaseContrast) private var increaseContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if theme != .glass {
            content
                .background(reduceTransparency ? Color.fxPanel : Color.fxInset, in: shape)
                .overlay(shape.strokeBorder(
                    increaseContrast ? Color.fxBorderStrong : Color.fxBorder,
                    lineWidth: increaseContrast ? 1.5 : 1))
                .shadow(
                    color: .black.opacity(shadow > 0 ? 0.30 : 0),
                    radius: shadow,
                    y: shadow * 0.4)
        } else if reduceTransparency {
            content
                .background(FxGlassPalette.panel, in: shape)
                .overlay(shape.strokeBorder(
                    increaseContrast ? Color.white.opacity(0.38) : FxGlassPalette.borderStrong,
                    lineWidth: increaseContrast ? 1.5 : 1))
                .shadow(
                    color: .black.opacity(shadow > 0 ? 0.35 : 0),
                    radius: shadow,
                    y: shadow * 0.4)
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    Glass.regular.tint(tint).interactive(interactive),
                    in: shape)
                .overlay(shape.strokeBorder(
                    increaseContrast ? Color.white.opacity(0.38) : stroke,
                    lineWidth: increaseContrast ? 1.5 : 1))
                .overlay(shape.strokeBorder(
                    LinearGradient(
                        colors: [FxGlassPalette.highlight, Color.clear, Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 0.65))
                .shadow(
                    color: .black.opacity(shadow > 0 ? 0.30 : 0),
                    radius: shadow,
                    y: shadow * 0.45)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(tint, in: shape)
                .overlay(shape.strokeBorder(
                    increaseContrast ? Color.white.opacity(0.38) : stroke,
                    lineWidth: increaseContrast ? 1.5 : 1))
                .overlay(shape.strokeBorder(
                    LinearGradient(
                        colors: [FxGlassPalette.highlight, Color.clear, Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 0.65))
                .shadow(
                    color: .black.opacity(shadow > 0 ? 0.30 : 0),
                    radius: shadow,
                    y: shadow * 0.45)
        }
    }
}

private struct FxCardModifier: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat?
    let shadow: Bool

    @Environment(\.fxTheme) private var theme
    @Environment(\.fxReduceTransparency) private var reduceTransparency
    @Environment(\.fxIncreaseContrast) private var increaseContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let resolvedRadius = radius ?? (theme == .glass ? FxGlassRadius.card : FxRadius.card)
        if theme == .glass {
            content
                .padding(padding)
                .modifier(FxGlassSurfaceModifier(
                    radius: resolvedRadius,
                    tint: FxGlassPalette.cardFill,
                    stroke: FxGlassPalette.border,
                    interactive: false,
                    shadow: shadow ? 10 : 0))
        } else {
            content
                .padding(padding)
                .background(
                    reduceTransparency ? Color.fxPanel : Color.fxCardFill,
                    in: RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous).strokeBorder(
                    increaseContrast ? Color.fxBorderStrong : Color.fxBorder,
                    lineWidth: increaseContrast ? 1.5 : 1))
                .shadow(color: .black.opacity(shadow ? 0.30 : 0), radius: 10, x: 0, y: 6)
        }
    }
}

private struct FxChipModifier: ViewModifier {
    let accent: Bool
    let padV: CGFloat
    let padH: CGFloat
    let radius: CGFloat?

    @Environment(\.fxTheme) private var theme
    @Environment(\.fxReduceTransparency) private var reduceTransparency
    @Environment(\.fxIncreaseContrast) private var increaseContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let resolvedRadius = radius ?? (theme == .glass ? FxGlassRadius.pill : CGFloat(8))
        if theme == .glass {
            content
                .padding(.vertical, padV)
                .padding(.horizontal, padH)
                .modifier(FxGlassSurfaceModifier(
                    radius: resolvedRadius,
                    tint: accent ? Color.fxAccentSoft : FxGlassPalette.inset,
                    stroke: accent ? Color.fxAccentLine : FxGlassPalette.border,
                    interactive: false,
                    shadow: 0))
        } else {
            content
                .padding(.vertical, padV)
                .padding(.horizontal, padH)
                .background(
                    reduceTransparency
                        ? (accent ? Color.fxAccentDeep : Color.fxPanel)
                        : (accent ? Color.fxAccentSoft : Color.fxInset),
                    in: RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous).strokeBorder(
                    accent
                        ? Color.fxAccentLine
                        : (increaseContrast ? Color.fxBorderStrong : Color.fxBorder),
                    lineWidth: increaseContrast ? 1.5 : 1))
        }
    }
}

private struct FxPillOkModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    func body(content: Content) -> some View {
        let radius = theme == .glass ? FxGlassRadius.pill : FxRadius.pill
        content
            .fxMonoFont(11)
            .foregroundStyle(Color.fxOk)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Color.fxOkSoft, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.fxOkSoft, lineWidth: 1))
    }
}

private struct FxInsetFieldModifier: ViewModifier {
    let radius: CGFloat?

    @Environment(\.fxTheme) private var theme
    @Environment(\.fxReduceTransparency) private var reduceTransparency
    @Environment(\.fxIncreaseContrast) private var increaseContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let resolvedRadius = radius ?? (theme == .glass ? FxGlassRadius.field : FxRadius.field)
        if theme == .glass {
            content.modifier(FxGlassSurfaceModifier(
                radius: resolvedRadius,
                tint: FxGlassPalette.inset,
                stroke: FxGlassPalette.border,
                interactive: false,
                shadow: 0))
        } else {
            content
                .background(
                    reduceTransparency ? Color.fxPanel : Color.fxInset,
                    in: RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous).strokeBorder(
                    increaseContrast ? Color.fxBorderStrong : Color.fxBorder,
                    lineWidth: increaseContrast ? 1.5 : 1))
        }
    }
}
