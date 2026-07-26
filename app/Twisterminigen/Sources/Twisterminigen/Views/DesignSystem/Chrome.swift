import SwiftUI

// ============================================================
//  Window chrome. Dark and Glass share the original 52/46/30pt
//  geometry and typography; only their surface treatment differs.
//  Real macOS traffic lights are preserved.
// ============================================================

/// 20×20 gradient logo mark — shown in the header only while the sidebar is
/// collapsed, so app identity is never lost.
struct FxLogoMark: View {
    var body: some View {
        Group {
            if let img = Self.image {
                // The literal app-icon artwork, so the title-bar mark and the Dock
                // icon are the exact same image.
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                // Dev fallback (swift build, no bundle) — vector funnel.
                FunnelMark(color: Color(hex: 0x141A20))
                    .padding(5)
                    .background(LinearGradient(colors: [Color(hex: 0xD4DCE2), Color(hex: 0x8C9EAB)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    /// Loaded once from the app bundle's Resources/AppLogo.png (nil in dev builds).
    static let image: NSImage? = {
        guard let path = Bundle.main.resourcePath else { return nil }
        return NSImage(contentsOfFile: path + "/AppLogo.png")
    }()
}

/// Brand mark — the "funnel": four CENTERED rounded bars narrowing downward, the
/// whole group tilted −10° (up to the right). Identical geometry to the app icon.
struct FunnelMark: View {
    var color: Color = .black
    // (widthFrac of box, yFrac of box) — centered horizontally.
    private let bars: [(CGFloat, CGFloat)] = [
        (0.64, 0.12), (0.48, 0.38), (0.32, 0.63), (0.14, 0.88)
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let th = w * 0.10
            ZStack {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, b in
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: max(th, b.0 * w), height: th)
                        .position(x: w / 2, y: b.1 * h)
                }
            }
            .rotationEffect(.degrees(-10))
        }
    }
}

/// Read-only model status chip (header, right group): glowing ember dot,
/// model name, dimmed state suffix.
struct FxModelChip: View {
    let name: String
    let state: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    var body: some View {
        let content = HStack(spacing: 7) {
            Circle().fill(state == "ready" ? Color.fxOk : Color.fxAccent)
                .frame(width: 6, height: 6)
                .shadow(color: (state == "ready" ? Color.fxOk : Color.fxAccent).opacity(0.8), radius: 3)
            Text(name).foregroundStyle(theme == .glass ? FxGlassPalette.ember : Color.fxEmberHi)
            Text("· \(state)").foregroundStyle(
                (theme == .glass ? FxGlassPalette.ember : Color.fxEmberHi).opacity(0.55))
        }

        if theme == .glass {
            content
                .fxMonoFont(11.5)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 40 : 26)
                .fxGlassSurface(
                    radius: 6,
                    tint: FxGlassPalette.emberFill,
                    stroke: FxGlassPalette.emberBorder,
                    shadow: 5)
                .accessibilityIdentifier("model.status")
        } else {
            content
                .fxMonoFont(11.5)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 40 : 26)
                .background(
                    Color.fxEmberBg,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.fxEmberBorder, lineWidth: 1))
                .accessibilityIdentifier("model.status")
        }
    }
}

/// Compact glass title bar. Leaves room for the real traffic lights, then the
/// logo mark + "Twisterminigen" wordmark; caller supplies the right
/// group (live progress, model chip, rail toggle). Section tabs live in FxTabBar below.
struct FxTitleBar<Trailing: View>: View {
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fxTheme) private var theme

    // Trailing edge of the real traffic lights — queried from the window because
    // their position varies across macOS versions. 0 = lights hidden (fullscreen).
    @State private var lightsMaxX: CGFloat = 58

    var body: some View {
        HStack(spacing: 9) {
            FxLogoMark()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Twisterminigen")
                    .fxFont(14, weight: .bold)
                    .foregroundStyle(theme == .glass ? FxGlassPalette.headerText : Color.fxHdrText)
                BuildBadge(version: AppVersion.current)
                Link("[GitHub]", destination: ProjectLinks.githubURL)
                    .buttonStyle(.plain)
                    .fxMonoFont(10, weight: .semibold)
                    .foregroundStyle(
                        theme == .glass
                            ? FxGlassPalette.headerMuted
                            : Color.fxHdrMuted)
                    .lineLimit(1)
                    .accessibilityLabel("Open the Twisterminigen project on GitHub")
                    .help("Open the public Twisterminigen source repository.")
            }

            Spacer()

            HStack(spacing: 12) { trailing() }
        }
        // Logo hugs the traffic lights (tight gap); fullscreen (0) → edge-hug.
        .padding(.leading, lightsMaxX <= 0 ? 12 : 14)
        .padding(.trailing, 18)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 56 : 52)
        .modifier(FxTitleBarSurfaceModifier())
        .background(TrafficLightsInsetReader(maxX: $lightsMaxX))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme == .glass ? FxGlassPalette.headerBorder : Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }
}

/// Reports where the window's traffic lights actually end (window coordinates),
/// so the header's left group can hug them instead of guessing an inset.
/// Reports 0 while the window is fullscreen — the lights are hidden there.
private struct TrafficLightsInsetReader: NSViewRepresentable {
    @Binding var maxX: CGFloat

    func makeNSView(context: Context) -> LightsProbeView {
        let v = LightsProbeView()
        v.onChange = { x in
            DispatchQueue.main.async {
                if abs(maxX - x) > 0.5 { maxX = x }
            }
        }
        return v
    }
    func updateNSView(_ nsView: LightsProbeView, context: Context) {}

    final class LightsProbeView: NSView {
        var onChange: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let w = window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowStateChanged),
                    name: NSWindow.didEnterFullScreenNotification, object: w)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowStateChanged),
                    name: NSWindow.didExitFullScreenNotification, object: w)
            }
            report()
        }
        override func layout() {
            super.layout()
            report()
        }
        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func windowStateChanged() { report() }

        private func report() {
            guard let w = window else { return }
            if w.styleMask.contains(.fullScreen) {
                onChange?(0)
                return
            }
            guard let zoom = w.standardWindowButton(.zoomButton),
                  let bar = zoom.superview else { return }
            onChange?(bar.convert(zoom.frame, to: nil).maxX)
        }
    }
}

/// Top glass navigation. 8 sections; the active tab gets a slim luminous underline
/// and bright label. Trailing accessories (counts, live dot,
/// "soon") come from the caller via `tail`.
struct FxTabBar: View {
    @Binding var section: AppSection
    /// A render is in progress — the active tab shows a leading live dot (maket frames a, c).
    var busy: Bool = false
    let tail: (AppSection) -> AnyView?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fxTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSection.allCases) { item in
                TabItem(item: item, isActive: section == item, busy: busy, tail: tail(item)) { section = item }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 52 : 46)
        .modifier(FxTabBarSurfaceModifier())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme == .glass ? FxGlassPalette.headerBorder : Color.fxHdrBorder)
                .frame(height: 1)
        }
    }
}

private struct TabItem: View {
    let item: AppSection
    let isActive: Bool
    let busy: Bool
    let tail: AnyView?
    let action: () -> Void
    @State private var hover = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fxTheme) private var theme

    // Text-only tabs (maket): no per-tab glyphs. Active tab shows a live dot while rendering.
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isActive && busy {
                    Circle().fill(Color.fxAccent)
                        .frame(width: 6, height: 6)
                        .shadow(color: Color.fxAccent.opacity(0.8), radius: 3)
                }
                Text(item.title)
                    .fxFont(12.5, weight: isActive ? .semibold : .medium)
                    .foregroundStyle(
                        isActive
                            ? (theme == .glass ? FxGlassPalette.text : Color.fxText)
                            : (theme == .glass ? FxGlassPalette.text3 : Color(hex: 0x757E87)))
                if let tail { tail }
            }
            .padding(.horizontal, 14)
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 52 : 46)
            .background(
                (hover && !isActive)
                    ? (theme == .glass ? FxGlassPalette.hover : Color.fxHover)
                    : Color.clear)
            .overlay(alignment: .bottom) {
                if isActive {
                    LinearGradient(colors: [.fxAccent, .fxAccentDeep],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 2)
                        .padding(.horizontal, 14)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.help)
        .accessibilityIdentifier("nav.\(item.rawValue)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Bottom status bar — live telemetry stats on the right (same on every view;
/// telemetry lives here permanently). Version metadata lives beside the wordmark.
enum FxStatusBarLayout {
    static let leadingInset: CGFloat = 24
    /// Keep the final Disk value close to the window edge while clearing the rounded corner.
    static let trailingInset: CGFloat = 24
    static let standardHeight: CGFloat = 30
    static let accessibilityHeight: CGFloat = 44
    /// The optical baseline sits slightly below mathematical center.
    static let telemetryVerticalNudge: CGFloat = 2
}

struct FxStatusBar<Trailing: View>: View {
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fxTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(spacing: 14) { trailing() }
                    .frame(
                        minWidth: max(
                            0,
                            geometry.size.width
                                - FxStatusBarLayout.leadingInset
                                - FxStatusBarLayout.trailingInset),
                        minHeight: geometry.size.height,
                        alignment: .trailing)
                    .padding(.leading, FxStatusBarLayout.leadingInset)
                    .padding(.trailing, FxStatusBarLayout.trailingInset)
                    .offset(y: FxStatusBarLayout.telemetryVerticalNudge)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity)
        .frame(height: dynamicTypeSize.isAccessibilitySize
            ? FxStatusBarLayout.accessibilityHeight
            : FxStatusBarLayout.standardHeight)
        .modifier(FxStatusBarSurfaceModifier())
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme == .glass ? FxGlassPalette.headerBorder : Color.fxHdrBorder)
                .frame(height: 1)
        }
    }
}

/// One status-bar telemetry stat: faint label + value. `accent` renders the
/// value in ember — reserved for the signature stat.
struct FxStat: View {
    let label: String
    let value: String
    var accent: Bool = false
    @Environment(\.fxTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(theme == .glass ? FxGlassPalette.headerFaint : Color.fxHdrFaint)
            Text(value).foregroundStyle(
                accent
                    ? (theme == .glass ? FxGlassPalette.ember : Color.fxEmberHi)
                    : (theme == .glass ? FxGlassPalette.headerText : Color.fxHdrText))
        }
        .fxMonoFont(11)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier("status.\(label.lowercased())")
    }
}

/// Thin vertical divider between status items.
struct StatusSep: View {
    var tint: Color = .fxBorder
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    var body: some View {
        if theme == .glass {
            Rectangle()
                .fill(tint.opacity(0.72))
                .frame(width: 1, height: 14)
                .shadow(color: tint.opacity(0.36), radius: 2)
                .accessibilityHidden(true)
        } else {
            Rectangle()
                .fill(Color.fxBorder)
                .frame(width: 1, height: 14)
                .accessibilityHidden(true)
        }
    }
}

private struct FxTitleBarSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            content.fxGlassSurface(radius: 0, tint: FxGlassPalette.header, stroke: Color.clear)
        } else {
            content.background(Color.fxHdrBg)
        }
    }
}

private struct FxTabBarSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            content.fxGlassSurface(radius: 0, tint: FxGlassPalette.tabBar, stroke: Color.clear)
        } else {
            content.background(Color.fxTabBar)
        }
    }
}

private struct FxStatusBarSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            content.fxGlassSurface(radius: 0, tint: FxGlassPalette.statusBar, stroke: Color.clear)
        } else {
            content.background(Color.fxStatusBar)
        }
    }
}
