import SwiftUI

// ============================================================
//  Reusable indicator + control atoms (Dot, Sparkline, Ring,
//  Meter, badges, buttons, stepper).
// ============================================================

enum FxTone { case ok, amber, danger, idle }

/// Status dot with optional soft glow ring + gentle "breathing" when `live`
/// (opacity 1 → 0.35 → 1, ease-in-out — NOT a hard blink).
struct FxDot: View {
    var tone: FxTone = .ok
    var live: Bool = false
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var color: Color {
        switch tone { case .ok: .fxOk; case .amber: .fxAccent; case .danger: .fxDanger; case .idle: .fxText3 }
    }
    private var glow: Color {
        switch tone { case .ok: .fxOkSoft; case .amber: .fxAccentSoft; case .danger: .fxDangerSoft; case .idle: .clear }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(tone == .idle ? 0.6 : (breathe ? 0.35 : 1))
            .background(Circle().fill(glow).frame(width: size + 6, height: size + 6))
            .onAppear { updateBreathing() }
            .onChange(of: live) { _, _ in updateBreathing() }
            .onChange(of: reduceMotion) { _, _ in updateBreathing() }
    }

    private func updateBreathing() {
        if live && !reduceMotion {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                breathe = true
            }
        } else if reduceMotion {
            withAnimation(nil) { breathe = false }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { breathe = false }
        }
    }
}

/// Mini line chart with a soft gradient fill beneath the stroke.
struct Sparkline: View {
    var data: [Double]
    var color: Color = .fxAccent
    var fill: Bool = true
    var lineWidth: CGFloat = 1.6

    var body: some View {
        Canvas { ctx, size in
            guard data.count > 1 else { return }
            let minV = data.min() ?? 0
            let maxV = data.max() ?? 1
            let span = (maxV - minV) == 0 ? 1 : (maxV - minV)
            func pt(_ i: Int) -> CGPoint {
                let x = CGFloat(i) / CGFloat(data.count - 1) * size.width
                let y = size.height - 2 - CGFloat((data[i] - minV) / span) * (size.height - 4)
                return CGPoint(x: x, y: y)
            }
            var line = Path()
            line.move(to: pt(0))
            for i in 1..<data.count { line.addLine(to: pt(i)) }

            if fill {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.22), color.opacity(0)]),
                    startPoint: CGPoint(x: size.width / 2, y: 0),
                    endPoint: CGPoint(x: size.width / 2, y: size.height)))
            }
            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .drawingGroup(opaque: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend graph")
        .accessibilityValue(MetricAccessibilitySummary.trend(data))
    }
}

/// Circular progress ring (track + accent arc, rounded caps, starts at top).
struct Ring: View {
    var pct: Double          // 0…1
    var size: CGFloat = 66
    var lineWidth: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fxReduceTransparency) private var reduceTransparency
    @Environment(\.fxTheme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(
                reduceTransparency
                    ? (theme == .glass ? FxGlassPalette.panel : Color.fxPanel)
                    : (theme == .glass ? FxGlassPalette.inset : Color.fxInset),
                lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, pct)))
                .stroke(Color.fxAccent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: pct)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((max(0, min(1, pct)) * 100).rounded())) percent")
    }
}

/// Horizontal progress meter (6pt). Amber by default, green via `ok`.
struct Meter: View {
    var value: Double        // 0…1
    var ok: Bool = false
    var height: CGFloat = 6

    @Environment(\.fxReduceTransparency) private var reduceTransparency
    @Environment(\.fxTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            Capsule(style: .continuous).fill(
                reduceTransparency
                    ? (theme == .glass ? FxGlassPalette.panel : Color.fxPanel)
                    : (theme == .glass ? FxGlassPalette.inset : Color.fxInset))
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(
                            colors: ok ? [.fxOkDeep, .fxOk] : [.fxAccentDeep, .fxAccent],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, min(1, value)) * geo.size.width)
                }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int((max(0, min(1, value)) * 100).rounded())) percent")
    }
}

/// Quiet version tag beside the title-bar wordmark. It stays readable without
/// competing with the model state or the bottom telemetry.
struct BuildBadge: View {
    var version: String
    @Environment(\.fxTheme) private var theme

    var body: some View {
        Text("v\(version) · build \(AppVersion.build)")
            .fxMonoFont(10, weight: .medium)
            .foregroundStyle(theme == .glass ? FxGlassPalette.headerFaint : Color.fxHdrFaint)
            .lineLimit(1)
            .accessibilityLabel("Version \(version), build \(AppVersion.build)")
    }
}

// ── Button styles ────────────────────────────────────────────────────────────

/// Primary amber-gradient button (dark text + inner top highlight).
struct FxPrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fxFont(13, weight: .semibold)
            .foregroundStyle(Color.fxOnAccent)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, 16)
            .background(
                LinearGradient(colors: [.fxAccent, .fxAccentDeep], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: FxRadius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FxRadius.button, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// Secondary button — inset surface + hairline, hover highlight.
struct FxSecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    var accentText: Bool = false
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(
            configuration: configuration,
            height: height,
            accentText: accentText,
            ghost: false,
            fullWidth: fullWidth)
    }
}

/// Ghost button — transparent until hover.
struct FxGhostButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    var accentText: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(
            configuration: configuration,
            height: height,
            accentText: accentText,
            ghost: true,
            fullWidth: false)
    }
}

private struct HoverBody: View {
    let configuration: ButtonStyle.Configuration
    var height: CGFloat
    var accentText: Bool
    var ghost: Bool
    var fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.fxReduceTransparency) private var reduceTransparency
    @Environment(\.fxIncreaseContrast) private var increaseContrast
    @Environment(\.fxTheme) private var theme
    @State private var hover = false
    var body: some View {
        configuration.label
            .fxFont(13, weight: .semibold)
            .foregroundStyle(
                accentText
                    ? Color.fxAccent
                    : (theme == .glass ? FxGlassPalette.text : Color.fxText))
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, 14)
            .background(
                hover && isEnabled
                    ? (reduceTransparency
                        ? (theme == .glass ? FxGlassPalette.panel : Color.fxSheet)
                        : (theme == .glass ? FxGlassPalette.hover : Color.fxHover))
                    : (ghost
                        ? Color.clear
                        : (reduceTransparency
                            ? (theme == .glass ? FxGlassPalette.panel : Color.fxPanel)
                            : (theme == .glass ? FxGlassPalette.inset : Color.fxInset))),
                in: RoundedRectangle(
                    cornerRadius: theme == .glass ? FxGlassRadius.button : FxRadius.button,
                    style: .continuous))
            .overlay(RoundedRectangle(
                cornerRadius: theme == .glass ? FxGlassRadius.button : FxRadius.button,
                style: .continuous)
                .strokeBorder(
                    ghost
                        ? Color.clear
                        : (increaseContrast
                            ? (theme == .glass ? FxGlassPalette.borderStrong : Color.fxBorderStrong)
                            : (theme == .glass ? FxGlassPalette.border : Color.fxBorder)),
                    lineWidth: increaseContrast ? 1.5 : 1))
            // A .disabled(true) button using this style must LOOK inert, not just BE inert —
            // otherwise it reads as broken (looks clickable, click does nothing).
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.7 : 1))
            .onHover { hover = $0 }
            .contentShape(Rectangle())
    }
}

/// Custom horizontal slider matching the maket: thin rounded track, light-steel
/// fill left of the knob, white circular knob, NO tick marks.
struct FxSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var knob: CGFloat = 16
    var track: CGFloat = 6
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil
    var accessibilityID: String

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.fxReduceTransparency) private var reduceTransparency
    @Environment(\.fxIncreaseContrast) private var increaseContrast
    @Environment(\.fxTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = range.upperBound - range.lowerBound
            let clampedValue = Self.clampedValue(value, in: range)
            let frac = span > 0 ? (clampedValue - range.lowerBound) / span : 0
            let knobX = CGFloat(frac) * max(0, w - knob)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(
                        reduceTransparency
                            ? (theme == .glass ? FxGlassPalette.panel : Color.fxPanel)
                            : (theme == .glass ? FxGlassPalette.inset : Color.fxInset))
                    .frame(height: track)
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [Color.fxAccentDeep, Color.fxAccent],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: knobX + knob / 2, height: track)
                Circle().fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.45), radius: 2.5, x: 0, y: 1)
                    .offset(x: knobX)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    guard isEnabled else { return }
                    let f = min(1, max(0, (g.location.x - knob / 2) / max(1, w - knob)))
                    let raw = range.lowerBound + Double(f) * span
                    value = Self.snappedValue(raw, in: range, step: step)
                }
            )
        }
        .frame(height: knob)
        .overlay {
            if isFocused {
                Capsule(style: .continuous)
                    .stroke(Color.fxAccent, lineWidth: increaseContrast ? 2 : 1.5)
                    .padding(-4)
                    .accessibilityHidden(true)
            }
        }
        .focusable()
        .focused($isFocused)
        .onMoveCommand { direction in
            switch direction {
            case .right, .up: adjust(by: 1)
            case .left, .down: adjust(by: -1)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(accessibilityLabel ?? "Slider")
        .accessibilityValue(accessibilityValue ?? Self.defaultAccessibilityValue(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: 1)
            case .decrement: adjust(by: -1)
            @unknown default: break
            }
        }
    }

    private func adjust(by direction: Int) {
        guard isEnabled else { return }
        value = Self.adjustedValue(value, in: range, step: step, direction: direction)
    }

    static func clampedValue(_ raw: Double, in range: ClosedRange<Double>) -> Double {
        guard raw.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, raw))
    }

    static func snappedValue(
        _ raw: Double,
        in range: ClosedRange<Double>,
        step: Double
    ) -> Double {
        let clamped = clampedValue(raw, in: range)
        guard step.isFinite, step > 0 else { return clamped }
        let offset = ((clamped - range.lowerBound) / step).rounded() * step
        return clampedValue(range.lowerBound + offset, in: range)
    }

    static func adjustedValue(
        _ current: Double,
        in range: ClosedRange<Double>,
        step: Double,
        direction: Int
    ) -> Double {
        let span = range.upperBound - range.lowerBound
        let increment = step.isFinite && step > 0 ? step : span / 100
        guard increment > 0, direction != 0 else { return clampedValue(current, in: range) }
        let raw = clampedValue(current, in: range) + (direction > 0 ? increment : -increment)
        return snappedValue(raw, in: range, step: increment)
    }

    private static func defaultAccessibilityValue(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }
}

/// Custom "− [editable number] +" stepper with a label above.
struct FxStepper: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int
    var compactControls = false
    var unavailableReason: String? = nil
    var accessibilityIDBase: String

    @State private var draft = ""
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).fxLabel()
            HStack(spacing: compactControls ? 2 : 6) {
                pm(
                    "minus",
                    accessibilityLabel: "Decrease \(label)",
                    help: unavailableReason
                        ?? (value <= range.lowerBound
                            ? "\(label) is already at the minimum of \(range.lowerBound) pixels."
                            : "Decrease \(label).")) {
                    adjust(by: -1)
                }
                .disabled(unavailableReason != nil || value <= range.lowerBound)
                .accessibilityIdentifier("\(accessibilityIDBase).decrement")
                if !compactControls {
                    Spacer(minLength: 0)
                }
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .fxMonoFont(12)
                    .foregroundStyle(Color.fxText)
                    .multilineTextAlignment(.center)
                    .frame(
                        minWidth: compactControls ? 34 : 44,
                        idealWidth: compactControls ? 40 : 58,
                        maxWidth: compactControls ? 46 : 72)
                    .focused($fieldIsFocused)
                    .disabled(unavailableReason != nil)
                    .onSubmit(commitDraft)
                    .accessibilityLabel(label)
                    .accessibilityValue("\(value) pixels")
                    .accessibilityIdentifier(accessibilityIDBase)
                    .help(unavailableReason
                          ?? "Enter \(range.lowerBound)–\(range.upperBound). Values snap to the nearest multiple of \(step).")
                if !compactControls {
                    Spacer(minLength: 0)
                }
                pm(
                    "plus",
                    accessibilityLabel: "Increase \(label)",
                    help: unavailableReason
                        ?? (value >= range.upperBound
                            ? "\(label) is already at the maximum of \(range.upperBound) pixels."
                            : "Increase \(label).")) {
                    adjust(by: 1)
                }
                .disabled(unavailableReason != nil || value >= range.upperBound)
                .accessibilityIdentifier("\(accessibilityIDBase).increment")
            }
            .padding(.vertical, compactControls ? 3 : 4)
            .padding(.horizontal, compactControls ? 4 : 8)
            .frame(maxWidth: .infinity)
            .fxInsetField(radius: 8)
        }
        .onAppear { syncDraft() }
        .onChange(of: value) { _, _ in
            if !fieldIsFocused { syncDraft() }
        }
        .onChange(of: fieldIsFocused) { _, isFocused in
            if !isFocused { commitDraft() }
        }
    }

    private func commitDraft() {
        value = SteppedIntegerValue.committedValue(
            from: draft,
            current: value,
            in: range,
            step: step)
        syncDraft()
    }

    private func adjust(by direction: Int) {
        value = SteppedIntegerValue.adjusted(
            value,
            direction: direction,
            in: range,
            step: step)
        syncDraft()
    }

    private func syncDraft() {
        draft = String(value)
    }

    private func pm(
        _ symbol: String,
        accessibilityLabel: String,
        help: String,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.fxText3)
                .frame(width: 18, height: 18)
                .background(Color.fxHover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }
}
