import AppKit
import SwiftUI

/// Visual editor for `GenerationRecipe.InputImageReference.crop`.
/// It only changes source-space crop coordinates; Fit, Fill, and Stretch remain independent.
struct RemixCropEditor: View {
    let image: NSImage
    @Binding var crop: GenerationRecipe.NormalizedRect?
    let resizeMode: GenerationRecipe.ResizeMode

    @State private var workingCrop: GenerationRecipe.NormalizedRect?

    @Environment(\.dismiss) private var dismiss

    init(
        image: NSImage,
        crop: Binding<GenerationRecipe.NormalizedRect?>,
        resizeMode: GenerationRecipe.ResizeMode
    ) {
        self.image = image
        _crop = crop
        self.resizeMode = resizeMode
        _workingCrop = State(initialValue: crop.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                Divider().overlay(Color.white.opacity(0.08))
                inspector
                    .frame(width: 260)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .fxStandalonePageBackground()
        .accessibilityIdentifier("remix-crop.sheet")
        .interactiveDismissDisabled(workingCrop != crop)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "crop")
                .foregroundStyle(Color.fxAccent)
            Text("Remix Crop")
                .fxFont(16, weight: .semibold)
            Text(workingCrop == nil ? "Full image" : "Custom crop")
                .fxMonoFont(11, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.55))
            Spacer()
            Button("Reset crop") { workingCrop = nil }
                .disabled(workingCrop == nil)
                .help(workingCrop == nil
                    ? "Reset crop is unavailable because the complete source image is already selected."
                    : "Clear the crop and use the complete source image")
                .accessibilityIdentifier("remix-crop.reset")
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .help("Discard crop changes")
                .accessibilityIdentifier("remix-crop.cancel")
            Button("Apply crop") {
                crop = workingCrop
                dismiss()
            }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Apply these source crop coordinates to the Remix recipe")
                .accessibilityIdentifier("remix-crop.apply")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .modifier(RemixGlassPanelModifier())
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let imageSize = fittedImageSize(in: proxy.size)
            ZStack {
                Color.black.opacity(0.36)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imageSize.width, height: imageSize.height)
                    RemixCropCanvasOverlay(
                        selection: selectionBinding,
                        canvasSize: imageSize)
                }
                .frame(width: imageSize.width, height: imageSize.height)
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Remix source crop")
            .accessibilityValue(selectionDescription)
            .accessibilityHint("Drag inside the frame to move it, drag a handle to resize it, or enter exact values in the inspector.")
            .accessibilityIdentifier("remix-crop.canvas")
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Source coordinates")
                    .fxFont(12, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.82))
                Text("Drag the crop or edit exact percentages. The crop is applied before \(resizeModeName).")
                    .fxFont(11.5)
                    .foregroundStyle(Color.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 10) {
                exactField("X", component: .x, accessibilityLabel: "Crop x position")
                exactField("Y", component: .y, accessibilityLabel: "Crop y position")
                exactField("Width", component: .width, accessibilityLabel: "Crop width")
                exactField("Height", component: .height, accessibilityLabel: "Crop height")
            }

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 7) {
                Text("Resize mode")
                    .fxFont(11, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.52))
                Text(resizeModeName)
                    .fxMonoFont(12, weight: .semibold)
                    .foregroundStyle(Color.fxAccent)
                Text("Crop does not change the selected Fit, Fill, or Stretch behavior.")
                    .fxFont(11.5)
                    .foregroundStyle(Color.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                workingCrop = nil
            } label: {
                Label("Use full image", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .disabled(workingCrop == nil)
            .help(workingCrop == nil
                ? "Use full image is unavailable because no custom crop is active."
                : "Remove the custom crop from this Remix recipe")
            .accessibilityIdentifier("remix-crop.use-full-image")
        }
        .padding(20)
        .modifier(RemixGlassPanelModifier())
    }

    private enum Component {
        case x, y, width, height

        var accessibilityID: String {
            switch self {
            case .x: "x"
            case .y: "y"
            case .width: "width"
            case .height: "height"
            }
        }
    }

    private func exactField(
        _ title: String,
        component: Component,
        accessibilityLabel: String
    ) -> some View {
        GridRow {
            Text(title)
                .fxFont(11.5, weight: .medium)
                .foregroundStyle(Color.white.opacity(0.62))
            TextField("", value: percentBinding(component), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 86)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(percentValue(component))
                .accessibilityIdentifier("remix-crop.field.\(component.accessibilityID)")
                .help("Enter the exact \(accessibilityLabel.lowercased()) as a percentage of the source image.")
            Text("%")
                .fxMonoFont(11)
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }

    private var selection: GenerationRecipe.NormalizedRect {
        RemixCropGeometry.clamped(workingCrop ?? RemixCropGeometry.fullImage)
    }

    private var selectionBinding: Binding<GenerationRecipe.NormalizedRect> {
        Binding(
            get: { selection },
            set: { workingCrop = RemixCropGeometry.clamped($0) })
    }

    private func percentBinding(_ component: Component) -> Binding<Double> {
        Binding(
            get: { componentValue(component) * 100 },
            set: { newValue in
                let normalized = newValue / 100
                switch component {
                case .x:
                    workingCrop = RemixCropGeometry.replacing(selection, x: normalized)
                case .y:
                    workingCrop = RemixCropGeometry.replacing(selection, y: normalized)
                case .width:
                    workingCrop = RemixCropGeometry.replacing(selection, width: normalized)
                case .height:
                    workingCrop = RemixCropGeometry.replacing(selection, height: normalized)
                }
            })
    }

    private func componentValue(_ component: Component) -> Double {
        switch component {
        case .x: selection.x
        case .y: selection.y
        case .width: selection.width
        case .height: selection.height
        }
    }

    private func percentValue(_ component: Component) -> String {
        String(format: "%.2f percent", componentValue(component) * 100)
    }

    private var selectionDescription: String {
        String(
            format: "X %.2f percent, Y %.2f percent, width %.2f percent, height %.2f percent",
            selection.x * 100,
            selection.y * 100,
            selection.width * 100,
            selection.height * 100)
    }

    private var resizeModeName: String {
        switch resizeMode {
        case .fit: "Fit"
        case .fill: "Fill"
        case .stretch: "Stretch"
        }
    }

    private var sourcePixelSize: CGSize {
        if let representation = image.representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }), representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
    }

    private func fittedImageSize(in available: CGSize) -> CGSize {
        let source = sourcePixelSize
        let width = max(1, available.width)
        let height = max(1, available.height)
        let sourceAspect = source.width / source.height
        let availableAspect = width / height
        if availableAspect > sourceAspect {
            return CGSize(width: height * sourceAspect, height: height)
        }
        return CGSize(width: width, height: width / sourceAspect)
    }
}

/// Keep the original editor chrome untouched in Dark; Glass gets legible local
/// material panels because this sheet owns its own aurora backdrop.
private struct RemixGlassPanelModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            content.fxThemedSurface(.panel, radius: 0, bordered: false)
        } else {
            content
        }
    }
}

private struct RemixCropCanvasOverlay: View {
    @Binding var selection: GenerationRecipe.NormalizedRect
    let canvasSize: CGSize

    @State private var moveOrigin: GenerationRecipe.NormalizedRect?
    @State private var resizeOrigin: GenerationRecipe.NormalizedRect?

    var body: some View {
        let frame = selectionFrame
        ZStack {
            dimmedOutsideSelection(frame)
            ZStack {
                thirdsGrid
                Rectangle().strokeBorder(Color.fxAccent, lineWidth: 2)
                ForEach(RemixCropGeometry.Handle.allCases) { handle in
                    resizeHandle(handle)
                }
            }
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .position(x: frame.midX, y: frame.midY)
            .contentShape(Rectangle())
            .gesture(moveGesture)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Crop selection")
            .accessibilityValue(selectionDescription)
            .accessibilityHint("Drag to move the crop selection within the source image.")
            .accessibilityIdentifier("remix-crop.selection")
        }
    }

    private var selectionFrame: CGRect {
        CGRect(
            x: selection.x * canvasSize.width,
            y: selection.y * canvasSize.height,
            width: selection.width * canvasSize.width,
            height: selection.height * canvasSize.height)
    }

    private func dimmedOutsideSelection(_ frame: CGRect) -> some View {
        Canvas { context, size in
            var path = Path()
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(frame)
            context.fill(
                path,
                with: .color(.black.opacity(0.58)),
                style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    private var thirdsGrid: some View {
        Canvas { context, size in
            var path = Path()
            for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                path.move(to: CGPoint(x: size.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * fraction))
                path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
            context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }

    private func resizeHandle(_ handle: RemixCropGeometry.Handle) -> some View {
        Circle()
            .fill(Color.fxAccent)
            .overlay(Circle().stroke(Color.black.opacity(0.68), lineWidth: 1))
            .frame(width: 13, height: 13)
            .contentShape(Rectangle().inset(by: -6))
            .position(handlePosition(handle))
            .highPriorityGesture(resizeGesture(handle))
            .help("Resize crop")
            .accessibilityElement()
            .accessibilityLabel(handleAccessibilityLabel(handle))
            .accessibilityHint("Drag this handle to resize the crop selection.")
            .accessibilityIdentifier("remix-crop.handle.\(handle.rawValue)")
    }

    private func handlePosition(_ handle: RemixCropGeometry.Handle) -> CGPoint {
        let frame = selectionFrame
        return switch handle {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: frame.width / 2, y: 0)
        case .topRight: CGPoint(x: frame.width, y: 0)
        case .right: CGPoint(x: frame.width, y: frame.height / 2)
        case .bottomRight: CGPoint(x: frame.width, y: frame.height)
        case .bottom: CGPoint(x: frame.width / 2, y: frame.height)
        case .bottomLeft: CGPoint(x: 0, y: frame.height)
        case .left: CGPoint(x: 0, y: frame.height / 2)
        }
    }

    private func handleAccessibilityLabel(_ handle: RemixCropGeometry.Handle) -> String {
        switch handle {
        case .topLeft: "Top-left crop handle"
        case .top: "Top crop handle"
        case .topRight: "Top-right crop handle"
        case .right: "Right crop handle"
        case .bottomRight: "Bottom-right crop handle"
        case .bottom: "Bottom crop handle"
        case .bottomLeft: "Bottom-left crop handle"
        case .left: "Left crop handle"
        }
    }

    private var selectionDescription: String {
        String(
            format: "X %.2f percent, Y %.2f percent, width %.2f percent, height %.2f percent",
            selection.x * 100,
            selection.y * 100,
            selection.width * 100,
            selection.height * 100)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if moveOrigin == nil { moveOrigin = selection }
                guard let origin = moveOrigin else { return }
                selection = RemixCropGeometry.moved(
                    origin,
                    deltaX: value.translation.width / max(1, canvasSize.width),
                    deltaY: value.translation.height / max(1, canvasSize.height))
            }
            .onEnded { _ in moveOrigin = nil }
    }

    private func resizeGesture(_ handle: RemixCropGeometry.Handle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeOrigin == nil { resizeOrigin = selection }
                guard let origin = resizeOrigin else { return }
                selection = RemixCropGeometry.resized(
                    origin,
                    handle: handle,
                    deltaX: value.translation.width / max(1, canvasSize.width),
                    deltaY: value.translation.height / max(1, canvasSize.height))
            }
            .onEnded { _ in resizeOrigin = nil }
    }
}
