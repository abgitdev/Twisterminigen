import AppKit
import SwiftUI

struct RegionalPromptsSheet: View {
    @Bindable var vm: GenerateViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fxTheme) private var theme

    private var preferredSheetSize: CGSize {
        let visibleScreenSize = NSApp.keyWindow?.screen?.visibleFrame.size
            ?? NSScreen.main?.visibleFrame.size
            ?? CGSize(width: 1_440, height: 900)
        return RegionalPromptsLayout.preferredSheetSize(visibleScreenSize: visibleScreenSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(Color.fxAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Regional prompts")
                        .fxFont(16, weight: .bold)
                    Text("Place up to eight prompt regions on the canvas. Experimental — identity isolation is not guaranteed.")
                        .fxFont(10.5)
                        .foregroundStyle(theme == .glass ? FxGlassPalette.text3 : Color.fxText3)
                }
                Spacer()
                Text("CFG 0 only")
                    .fxMonoFont(9.5, weight: .semibold)
                    .foregroundStyle(Color.orange)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.orange.opacity(0.1), in: Capsule())
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close Regional prompts")
                .accessibilityIdentifier("generate.regions.close")
                .help("Close Regional prompts and keep the current recipe regions.")
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 58)

            Divider().overlay(Color.fxBorder)

            if !vm.regions.isEmpty, vm.guidanceValue != 0 {
                HStack(spacing: 10) {
                    Label(
                        "Regional prompts render only with Turbo CFG 0.",
                        systemImage: "exclamationmark.triangle.fill")
                        .fxFont(11.5, weight: .medium)
                        .foregroundStyle(Color.orange)
                    Spacer()
                    Button("Use CFG 0") {
                        vm.guidanceText = "0"
                        vm.normalizeGuidanceText()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("generate.regions.use-cfg-zero")
                    .disabled(vm.isEnhancing)
                    .help(vm.isEnhancing
                        ? "Regional prompt settings are locked while Enhance is rewriting the global prompt."
                        : "Restore the required Turbo CFG 0 setting for Regional prompts.")
                }
                .padding(12)
                .fxThemedSurface(.panel, radius: 10)
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }

            RegionalPromptsView(
                regions: $vm.regions,
                globalPrompt: $vm.prompt,
                width: vm.width,
                height: vm.height,
                referenceImage: vm.inputImagePreview ?? vm.resultImage,
                isEditingLocked: vm.isEnhancing,
                onAdd: vm.addRegion,
                onRemove: vm.removeRegion,
                onMove: vm.moveRegion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)
        }
        .frame(width: preferredSheetSize.width, height: preferredSheetSize.height)
        .fxStandalonePageBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("generate.regions.sheet")
    }
}

struct RegionalPromptsView: View {
    @Binding var regions: [GenerationRecipe.BBoxRegion]
    @Binding var globalPrompt: String
    let width: Int
    let height: Int
    let referenceImage: NSImage?
    let isEditingLocked: Bool
    let onAdd: () -> Void
    let onRemove: (UUID) -> Void
    let onMove: (UUID, Int) -> Void
    @State private var canvasDragSession: SpatialRegionCanvasInteraction.Session?

    private let palette: [Color] = [
        Color(hex: 0x59D7C4), Color(hex: 0xF3B64A),
        Color(hex: 0x9E95FF), Color(hex: 0xE879D7),
        Color(hex: 0x68A7FF), Color(hex: 0x92D36E),
        Color(hex: 0xFF7E79), Color(hex: 0xC9A56B),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Color.white.opacity(0.08))
            if regions.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    canvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                    Divider().overlay(Color.white.opacity(0.08))
                    inspector.frame(width: 360)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .fxThemedSurface(.panel, radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("generate.regions.editor")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .foregroundStyle(Color.fxAccent)
            Text("Regional prompts")
                .fxFont(16, weight: .semibold)
            Text("\(regions.count) / \(GenerationRecipe.maximumRegionCount)")
                .fxMonoFont(11)
                .foregroundStyle(Color.white.opacity(0.5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Regional prompt limit")
                .accessibilityValue("\(regions.count) of \(GenerationRecipe.maximumRegionCount)")
                .accessibilityIdentifier("generate.regions.limit")
            Text("EXPERIMENTAL · CFG 0")
                .fxMonoFont(9.5, weight: .semibold)
                .foregroundStyle(Color.orange)
            Spacer()
            if !regions.isEmpty {
                Button(action: onAdd) {
                    Label("Add region", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(isEditingLocked || regions.count >= GenerationRecipe.maximumRegionCount)
                .accessibilityIdentifier("generate.regions.add")
                .help(isEditingLocked
                      ? "Regional prompts are locked while Enhance is rewriting the global prompt."
                      : regions.count >= GenerationRecipe.maximumRegionCount
                          ? "Regional prompts are limited to \(GenerationRecipe.maximumRegionCount) regions."
                          : "Add region \(regions.count + 1) of \(GenerationRecipe.maximumRegionCount)")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .modifier(SpatialGlassPanelModifier())
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.fxAccent)
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text("Regional prompts")
                    .fxFont(22, weight: .bold)
                Text("Place up to eight prompt regions on the canvas. Experimental — identity isolation is not guaranteed.")
                    .fxFont(13)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 510)
            }
            Button(action: onAdd) {
                Label("Add first region", systemImage: "plus.rectangle.on.rectangle")
                    .fxFont(14, weight: .semibold)
                    .frame(minWidth: 220, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isEditingLocked)
            .accessibilityIdentifier("generate.regions.add")
            .help(isEditingLocked
                  ? "Regional prompts are locked while Enhance is rewriting the global prompt."
                  : "Create the first of up to eight prompt regions and switch the recipe to CFG 0")
            Text("Turbo · CFG 0 only")
                .fxMonoFont(10.5, weight: .medium)
                .foregroundStyle(Color.orange)
        }
        .padding(40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("generate.regions.empty")
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let size = fittedSize(in: proxy.size)
            ZStack {
                Rectangle().fill(Color.black.opacity(0.42))
                if let referenceImage {
                    Image(nsImage: referenceImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .opacity(0.76)
                } else {
                    CanvasGrid()
                }
                ForEach($regions) { $region in
                    let index = regions.firstIndex(where: { $0.id == region.id }) ?? 0
                    SpatialRegionOverlay(
                        region: $region,
                        index: index,
                        color: palette[index % palette.count],
                        canvasSize: size,
                        isEditable: !isEditingLocked)
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(canvasDragGesture(canvasSize: size), including: isEditingLocked ? .none : .all)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private func canvasDragGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                guard !isEditingLocked else { return }
                if canvasDragSession == nil {
                    canvasDragSession = SpatialRegionCanvasInteraction.begin(
                        at: value.startLocation,
                        regions: regions,
                        canvasSize: canvasSize)
                }
                guard let session = canvasDragSession,
                      let index = regions.firstIndex(where: { $0.id == session.regionID })
                else { return }
                regions[index].rect = SpatialRegionCanvasInteraction.updatedRect(
                    for: session,
                    translation: value.translation,
                    canvasSize: canvasSize)
            }
            .onEnded { _ in
                canvasDragSession = nil
            }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Global prompt")
                    .fxFont(11, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.55))
                TextField(
                    "",
                    text: $globalPrompt,
                    prompt: Text("Describe the whole scene…")
                        .foregroundColor(Color.white.opacity(0.42)),
                    axis: .vertical)
                    .textFieldStyle(.plain)
                    .fxFont(12.5)
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(1 ... 3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .modifier(SpatialPromptSurfaceModifier())
                    .disabled(isEditingLocked)
                    .accessibilityLabel("Global prompt")
                    .accessibilityIdentifier("generate.regions.global-prompt")
                    .help(isEditingLocked
                          ? "The global prompt is locked while Enhance is rewriting it."
                          : "Describe the whole scene. This prompt remains visible to every image region.")
            }
            .padding(18)
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($regions) { $region in
                        let index = regions.firstIndex(where: { $0.id == region.id }) ?? 0
                        regionRow($region, index: index)
                        Divider().overlay(Color.white.opacity(0.07))
                    }
                }
            }
        }
        .modifier(SpatialGlassPanelModifier())
    }

    private func regionRow(
        _ region: Binding<GenerationRecipe.BBoxRegion>,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(palette[index % palette.count]).frame(width: 8, height: 8)
                Text("Region \(index + 1)")
                    .fxFont(11.5, weight: .semibold)
                Spacer()
                iconButton(
                    "arrow.up",
                    accessibilityID: "generate.regions.region.\(index + 1).move-forward",
                    help: "Move region forward") {
                    onMove(region.wrappedValue.id, -1)
                }
                .disabled(isEditingLocked || index == 0)
                .help(isEditingLocked
                      ? "Regional prompts are locked while Enhance is rewriting the global prompt."
                      : index == 0 ? "Region is already first." : "Move region forward")
                iconButton(
                    "arrow.down",
                    accessibilityID: "generate.regions.region.\(index + 1).move-backward",
                    help: "Move region backward") {
                    onMove(region.wrappedValue.id, 1)
                }
                .disabled(isEditingLocked || index == regions.count - 1)
                .help(isEditingLocked
                      ? "Regional prompts are locked while Enhance is rewriting the global prompt."
                      : index == regions.count - 1
                          ? "Region is already last."
                          : "Move region backward")
                iconButton(
                    "trash",
                    accessibilityID: "generate.regions.region.\(index + 1).remove",
                    help: "Delete region",
                    role: .destructive) {
                    onRemove(region.wrappedValue.id)
                }
                .disabled(isEditingLocked)
                .help(isEditingLocked
                      ? "Regional prompts are locked while Enhance is rewriting the global prompt."
                      : "Delete region")
            }
            TextField("Region prompt", text: region.prompt)
                .textFieldStyle(.plain)
                .fxFont(12.5)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .modifier(SpatialPromptSurfaceModifier())
                .disabled(isEditingLocked)
                .help(isEditingLocked
                      ? "Regional prompts are locked while Enhance is rewriting the global prompt."
                      : "Describe what should appear inside this region.")
                .accessibilityIdentifier("generate.regions.region.\(index + 1).prompt")
            VStack(alignment: .leading, spacing: 7) {
                Text("Canvas coordinates")
                    .fxFont(10.5, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.5))
                Grid(alignment: .trailing, horizontalSpacing: 7, verticalSpacing: 7) {
                    regionField("X", region: region, index: index, component: .x)
                    regionField("Y", region: region, index: index, component: .y)
                    regionField("W", region: region, index: index, component: .width)
                    regionField("H", region: region, index: index, component: .height)
                }
            }
        }
        .padding(16)
    }

    private enum RegionComponent {
        case x, y, width, height
    }

    private func regionField(
        _ title: String,
        region: Binding<GenerationRecipe.BBoxRegion>,
        index: Int,
        component: RegionComponent
    ) -> some View {
        GridRow {
            Text(title)
                .fxMonoFont(10.5, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.55))
            TextField(
                "",
                value: regionPercentBinding(region, component: component),
                format: .number.precision(.fractionLength(0 ... 2)))
                .textFieldStyle(.roundedBorder)
                .fxMonoFont(11.5)
                .multilineTextAlignment(.trailing)
                .frame(width: 82)
                .accessibilityLabel("Region \(regionComponentName(component))")
                .accessibilityValue(String(
                    format: "%.2f percent",
                    regionComponentValue(region.wrappedValue.rect, component: component) * 100))
                .accessibilityIdentifier(
                    "generate.regions.region.\(index + 1).\(regionComponentAccessibilityID(component))")
                .disabled(isEditingLocked)
                .help(isEditingLocked
                      ? "Regional prompts are locked while Enhance is rewriting the global prompt."
                      : "Edit the region's normalized \(regionComponentName(component)).")
            Text("%")
                .fxMonoFont(10.5)
                .foregroundStyle(Color.white.opacity(0.42))
        }
    }

    private func regionComponentName(_ component: RegionComponent) -> String {
        switch component {
        case .x: "x position"
        case .y: "y position"
        case .width: "width"
        case .height: "height"
        }
    }

    private func regionComponentAccessibilityID(_ component: RegionComponent) -> String {
        switch component {
        case .x: "x"
        case .y: "y"
        case .width: "width"
        case .height: "height"
        }
    }

    private func regionPercentBinding(
        _ region: Binding<GenerationRecipe.BBoxRegion>,
        component: RegionComponent
    ) -> Binding<Double> {
        Binding(
            get: { regionComponentValue(region.wrappedValue.rect, component: component) * 100 },
            set: { rawPercent in
                guard !isEditingLocked else { return }
                let normalized = rawPercent / 100
                var value = region.wrappedValue
                switch component {
                case .x:
                    value.rect = SpatialRegionGeometry.replacing(value.rect, x: normalized)
                case .y:
                    value.rect = SpatialRegionGeometry.replacing(value.rect, y: normalized)
                case .width:
                    value.rect = SpatialRegionGeometry.replacing(value.rect, width: normalized)
                case .height:
                    value.rect = SpatialRegionGeometry.replacing(value.rect, height: normalized)
                }
                region.wrappedValue = value
            })
    }

    private func regionComponentValue(
        _ rect: GenerationRecipe.NormalizedRect,
        component: RegionComponent
    ) -> Double {
        let rect = SpatialRegionGeometry.clamped(rect)
        return switch component {
        case .x: rect.x
        case .y: rect.y
        case .width: rect.width
        case .height: rect.height
        }
    }

    private func iconButton(
        _ symbol: String,
        accessibilityID: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .help(help)
    }

    private func fittedSize(in available: CGSize) -> CGSize {
        let aspect = CGFloat(max(1, width)) / CGFloat(max(1, height))
        let availableAspect = available.width / max(1, available.height)
        if availableAspect > aspect {
            return CGSize(width: available.height * aspect, height: available.height)
        }
        return CGSize(width: available.width, height: available.width / aspect)
    }
}

private struct SpatialGlassPanelModifier: ViewModifier {
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

private struct SpatialPromptSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .dark {
            content
                .background(Color.white.opacity(0.04))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        } else {
            content.fxThemedSurface(.inset, radius: 6)
        }
    }
}

private struct CanvasGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                path.move(to: CGPoint(x: size.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * fraction))
                path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
        }
    }
}

private struct SpatialRegionOverlay: View {
    @Binding var region: GenerationRecipe.BBoxRegion
    let index: Int
    let color: Color
    let canvasSize: CGSize
    let isEditable: Bool

    var body: some View {
        let rect = region.rect
        let frame = CGRect(
            x: CGFloat(rect.x0) * canvasSize.width,
            y: CGFloat(rect.y0) * canvasSize.height,
            width: CGFloat(rect.width) * canvasSize.width,
            height: CGFloat(rect.height) * canvasSize.height)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(color.opacity(0.08))
            Rectangle().strokeBorder(color, lineWidth: 2)
            Text("\(index + 1)")
                .fxMonoFont(11, weight: .bold)
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: 22, height: 20)
                .background(color)
            resizeHandle
        }
        .frame(width: max(1, frame.width), height: max(1, frame.height))
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Regional prompt \(index + 1)")
        .accessibilityValue(String(
            format: "X %.2f percent, Y %.2f percent, width %.2f percent, height %.2f percent",
            rect.x * 100,
            rect.y * 100,
            rect.width * 100,
            rect.height * 100))
        .accessibilityHint(isEditable
            ? "Use the exact coordinate fields in the region inspector to move or resize this region."
            : "Regional prompts are locked while Enhance is rewriting the global prompt.")
        .accessibilityIdentifier("generate.regions.region.\(index + 1).canvas")
        .help(isEditable
              ? "Drag to move region \(index + 1) on the canvas."
              : "Regional prompts are locked while Enhance is rewriting the global prompt.")
    }

    private var resizeHandle: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .frame(width: 20, height: 20)
                    .background(color)
                    .accessibilityElement()
                    .accessibilityLabel("Resize regional prompt \(index + 1)")
                    .accessibilityHint(isEditable
                        ? "Drag to resize this prompt region."
                        : "Regional prompts are locked while Enhance is rewriting the global prompt.")
                    .accessibilityIdentifier("generate.regions.region.\(index + 1).resize-handle")
                    .help(isEditable
                          ? "Resize region \(index + 1)."
                          : "Regional prompts are locked while Enhance is rewriting the global prompt.")
            }
        }
    }
}
