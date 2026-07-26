import SwiftUI

struct QueueLabView: View {
    @Bindable var vm: GenerateViewModel
    let sourceRecipe: GenerationRecipe

    @Environment(\.dismiss) private var dismiss
    @State private var configuration: QueueLab.Configuration
    @State private var seedText: String
    @State private var isEnqueueing = false
    @State private var enqueueError: String?

    init(vm: GenerateViewModel, sourceRecipe: GenerationRecipe) {
        self.vm = vm
        self.sourceRecipe = sourceRecipe
        let initial = QueueLab.Configuration(recipe: sourceRecipe, seedCount: 4)
        _configuration = State(initialValue: initial)
        _seedText = State(initialValue: String(initial.seedStart))
    }

    /// Gallery uses this initializer to reopen a persisted Queue Lab 2.0 table exactly as authored.
    /// Legacy provenance has no context and therefore deliberately cannot call this path.
    init(vm: GenerateViewModel, context: ExperimentContext) {
        self.vm = vm
        sourceRecipe = context.sourceRecipe
        _configuration = State(initialValue: context.configuration)
        _seedText = State(initialValue: String(context.configuration.seedStart))
    }

    var body: some View {
        let outcome = previewOutcome
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.fxBorder)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 24) {
                    seedSection
                    Divider().overlay(Color.fxBorder)
                    sweepSection
                    Divider().overlay(Color.fxBorder)
                    previewSection(outcome)
                }
                .padding(24)
            }
            .accessibilityIdentifier("queue-lab.content-scroll")
            .help("Scroll through the seed grid, X and Y sweep controls, and recipe preview.")

            Divider().overlay(Color.fxBorder)
            footer(outcome)
        }
        .frame(minWidth: 820, idealWidth: 920, minHeight: 680, idealHeight: 760)
        .fxStandalonePageBackground()
        .accessibilityIdentifier("queue-lab.sheet")
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.fxAccent)
                .frame(width: 34, height: 34)
                .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text("Queue Lab")
                    .fxFont(18, weight: .bold)
                    .foregroundStyle(Color.fxText)
                Text(sourceRecipe.prompts.positive)
                    .fxFont(11.5)
                    .foregroundStyle(Color.fxText3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 16)

            HStack(spacing: 7) {
                sourceChip("\(sourceRecipe.canvas.width)x\(sourceRecipe.canvas.height)")
                sourceChip("\(sourceRecipe.sampler.steps) steps")
                if sourceRecipe.inputImage != nil { sourceChip("Remix") }
                if !sourceRecipe.loras.isEmpty {
                    sourceChip("\(sourceRecipe.loras.count) LoRA")
                }
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.fxText2)
            .help("Close Queue Lab")
            .accessibilityIdentifier("queue-lab.close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
    }

    private var seedSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeading("Seed grid", symbol: "number")
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("START SEED")
                    TextField("0", text: $seedText)
                        .fxMonoFont(12)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .frame(width: 220, height: 34)
                        .modifier(QueueLabInsetSurfaceModifier(strongBorder: true))
                        .accessibilityIdentifier("queue-lab.seed.start")
                        .help("Enter the first unsigned 64-bit seed in this deterministic grid.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("SEEDS")
                    Stepper(
                        value: $configuration.seedCount,
                        in: 1 ... QueueLab.maximumJobCount
                    ) {
                        Text("\(configuration.seedCount)")
                            .fxMonoFont(12, weight: .semibold)
                            .foregroundStyle(Color.fxText)
                            .frame(width: 36, alignment: .leading)
                    }
                    .frame(height: 34)
                    .accessibilityIdentifier("queue-lab.seed.count")
                    .help("Choose how many consecutive seeds to include, up to the 64-job grid limit.")
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var sweepSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeading("X / Y sweeps", symbol: "arrow.left.and.right")
            HStack(alignment: .top, spacing: 24) {
                axisEditor(
                    title: "X AXIS",
                    accessibilityAxis: "x",
                    axis: $configuration.xAxis,
                    excluding: configuration.yAxis.parameter)
                Divider().overlay(Color.fxBorder).frame(minHeight: 150)
                axisEditor(
                    title: "Y AXIS",
                    accessibilityAxis: "y",
                    axis: $configuration.yAxis,
                    excluding: configuration.xAxis.parameter)
            }
        }
    }

    private func axisEditor(
        title: String,
        accessibilityAxis: String,
        axis: Binding<QueueLab.Axis>,
        excluding otherParameter: QueueLab.Parameter?
    ) -> some View {
        let selection = Binding<QueueLab.Parameter?>(
            get: { axis.wrappedValue.parameter },
            set: { parameter in
                axis.wrappedValue = parameter.map {
                    QueueLab.Axis.defaults(for: $0, in: sourceRecipe)
                } ?? .disabled
            })

        return VStack(alignment: .leading, spacing: 10) {
            fieldLabel(title)
            Picker("", selection: selection) {
                Text("Off").tag(Optional<QueueLab.Parameter>.none)
                ForEach(availableParameters(excluding: otherParameter)) { parameter in
                    Text(parameter.title).tag(Optional(parameter))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("queue-lab.axis.\(accessibilityAxis).parameter")
            .help("Choose the variation parameter for the \(title.lowercased()), or turn this axis off.")

            if let parameter = axis.wrappedValue.parameter {
                axisValueEditor(
                    parameter: parameter,
                    accessibilityAxis: accessibilityAxis,
                    axis: axis)
            } else {
                Text("Choose a variation for this axis.")
                    .fxFont(10.5)
                    .foregroundStyle(Color.fxText3)
                    .frame(height: 88, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func axisValueEditor(
        parameter: QueueLab.Parameter,
        accessibilityAxis: String,
        axis: Binding<QueueLab.Axis>
    ) -> some View {
        switch parameter {
        case .promptVariants:
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    "A {red|blue} subject in {daylight|moonlight}",
                    text: axis.promptTemplate,
                    axis: .vertical)
                    .fxFont(11.5)
                    .textFieldStyle(.plain)
                    .lineLimit(2 ... 4)
                    .padding(9)
                    .modifier(QueueLabInsetSurfaceModifier(strongBorder: true))
                    .accessibilityIdentifier(
                        "queue-lab.axis.\(accessibilityAxis).prompt-template")
                    .help("Enter prompt alternatives in braces, such as {red|blue}, for this sweep axis.")
                let expansion = QueueLab.expandWildcards(axis.wrappedValue.promptTemplate)
                Text(wildcardSummary(expansion))
                    .fxMonoFont(9.5, weight: .medium)
                    .foregroundStyle(expansion.truncated ? Color.fxDanger : Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .canvasSize:
            VStack(alignment: .leading, spacing: 6) {
                Text("Select one or more exact canvases")
                    .fxFont(10.5)
                    .foregroundStyle(Color.fxText3)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(canvasChoices, id: \.self) { canvas in
                        let selected = axis.wrappedValue.canvasSizes.contains(canvas)
                        Button {
                            toggleCanvas(canvas, in: axis)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: selected ? "checkmark.square.fill" : "square")
                                Text("\(canvas.width)×\(canvas.height)")
                            }
                            .fxMonoFont(9.5, weight: .medium)
                            .foregroundStyle(selected ? Color.fxAccent : Color.fxText2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 7)
                            .modifier(QueueLabChoiceSurfaceModifier(selected: selected))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "queue-lab.axis.\(accessibilityAxis).canvas.\(canvas.width)x\(canvas.height)")
                        .help(selected
                              ? "Remove \(canvas.width) by \(canvas.height) from this canvas-size sweep."
                              : "Add \(canvas.width) by \(canvas.height) to this canvas-size sweep.")
                    }
                }
                Text("\(axis.wrappedValue.canvasSizes.count) size\(axis.wrappedValue.canvasSizes.count == 1 ? "" : "s")")
                    .fxMonoFont(9.5)
                    .foregroundStyle(Color.fxText3)
            }

        case .firstLoRAScale:
            VStack(alignment: .leading, spacing: 7) {
                let selection = Binding<UUID>(
                    get: {
                        axis.wrappedValue.loRAID
                            ?? sourceRecipe.loras.first?.managedID
                            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                    },
                    set: { axis.wrappedValue.loRAID = $0 })
                Picker("Adapter", selection: selection) {
                    ForEach(Array(sourceRecipe.loras.enumerated()), id: \.element.managedID) { index, lora in
                        Text("LoRA \(index + 1) · \(lora.managedID.uuidString.prefix(8))")
                            .tag(lora.managedID)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("queue-lab.axis.\(accessibilityAxis).lora")
                .help("Choose which active LoRA adapter scale this axis varies.")
                numericAxisEditor(axis, accessibilityAxis: accessibilityAxis)
            }

        case .steps, .guidance, .imageToImageStrength:
            numericAxisEditor(axis, accessibilityAxis: accessibilityAxis)
        }
    }

    private func numericAxisEditor(
        _ axis: Binding<QueueLab.Axis>,
        accessibilityAxis: String
    ) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            axisNumberField(
                "FROM",
                value: axis.start,
                accessibilityID: "queue-lab.axis.\(accessibilityAxis).from")
            axisNumberField(
                "TO",
                value: axis.end,
                accessibilityID: "queue-lab.axis.\(accessibilityAxis).to")
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("VALUES")
                Stepper(
                    value: axis.valueCount,
                    in: 1 ... QueueLab.maximumJobCount
                ) {
                    Text("\(axis.wrappedValue.valueCount)")
                        .fxMonoFont(11.5, weight: .semibold)
                        .frame(width: 26, alignment: .leading)
                }
                .frame(height: 32)
                .accessibilityIdentifier("queue-lab.axis.\(accessibilityAxis).value-count")
                .help("Choose how many evenly spaced values this sweep axis contains.")
            }
        }
    }

    private func axisNumberField(
        _ label: String,
        value: Binding<Double>,
        accessibilityID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            TextField(
                "0",
                value: value,
                format: .number.precision(.fractionLength(0 ... 3)))
                .fxMonoFont(11.5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .modifier(QueueLabInsetSurfaceModifier(strongBorder: true))
                .accessibilityIdentifier(accessibilityID)
                .help("Set the \(label.lowercased()) value for this sweep axis.")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func previewSection(_ outcome: PreviewOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("Preview", symbol: "list.number")
                Spacer()
                switch outcome {
                case .valid(let preview):
                    Text("\(preview.jobCount) / \(QueueLab.maximumJobCount) jobs")
                        .fxMonoFont(11.5, weight: .semibold)
                        .foregroundStyle(Color.fxAccent)
                case .invalid:
                    Text("- / \(QueueLab.maximumJobCount) jobs")
                        .fxMonoFont(11.5, weight: .semibold)
                        .foregroundStyle(Color.fxText3)
                }
            }

            switch outcome {
            case .valid(let preview):
                previewTable(preview)
            case .invalid(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                }
                .fxFont(11.5, weight: .medium)
                .foregroundStyle(Color.fxDanger)
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                .modifier(QueueLabInsetSurfaceModifier(strongBorder: false))
            }
        }
    }

    private func previewTable(_ preview: QueueLab.Preview) -> some View {
        VStack(spacing: 0) {
            previewRow(
                index: "#",
                seed: "SEED",
                x: QueueLab.axisLabel(
                    configuration.xAxis,
                    in: sourceRecipe)?.uppercased() ?? "X",
                y: QueueLab.axisLabel(
                    configuration.yAxis,
                    in: sourceRecipe)?.uppercased() ?? "Y",
                isHeader: true)
            Divider().overlay(Color.fxBorder)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(preview.entries) { entry in
                        previewRow(
                            index: String(entry.index + 1),
                            seed: String(entry.seed),
                            x: formatted(entry.xValue),
                            y: formatted(entry.yValue),
                            isHeader: false)
                        if entry.index < preview.entries.count - 1 {
                            Divider().overlay(Color.fxBorder.opacity(0.65))
                        }
                    }
                }
            }
            .accessibilityIdentifier("queue-lab.preview-scroll")
            .help("Scroll through every immutable job that this Queue Lab grid will create.")
        }
        .frame(height: 220)
        .modifier(QueueLabInsetSurfaceModifier(strongBorder: false))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func previewRow(
        index: String,
        seed: String,
        x: String,
        y: String,
        isHeader: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Text(index).frame(width: 34, alignment: .trailing)
            Text(seed).frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text(x).lineLimit(1).frame(width: 170, alignment: .leading)
            Text(y).lineLimit(1).frame(width: 170, alignment: .leading)
        }
        .fxMonoFont(
            isHeader ? 9.5 : 11,
            weight: isHeader ? .semibold : .regular)
        .foregroundStyle(isHeader ? Color.fxText3 : Color.fxText2)
        .padding(.horizontal, 12)
        .frame(height: isHeader ? 30 : 31)
    }

    @ViewBuilder
    private func footer(_ outcome: PreviewOutcome) -> some View {
        HStack(spacing: 12) {
            if let enqueueError {
                Label(enqueueError, systemImage: "exclamationmark.circle.fill")
                    .fxFont(11)
                    .foregroundStyle(Color.fxDanger)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Cancel") { dismiss() }
                .buttonStyle(FxSecondaryButtonStyle(height: 36))
                .accessibilityIdentifier("queue-lab.cancel")
                .help("Close Queue Lab without adding these jobs to Queue.")
            Button {
                guard case .valid(let preview) = outcome else { return }
                isEnqueueing = true
                enqueueError = nil
                Task {
                    let added = await vm.enqueueQueueLab(preview)
                    isEnqueueing = false
                    if added {
                        dismiss()
                    } else {
                        enqueueError = vm.errorMessage ?? "The grid could not be added."
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    if isEnqueueing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "text.badge.plus")
                    }
                    Text(enqueueButtonTitle(outcome))
                }
            }
            .buttonStyle(FxPrimaryButtonStyle(height: 36))
            .disabled(!outcome.isValid || isEnqueueing || vm.isQueueRunning)
            .help(enqueueHelp(outcome))
            .accessibilityIdentifier("queue-lab.enqueue")
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 64)
    }

    private var previewOutcome: PreviewOutcome {
        let trimmedSeed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seed = UInt64(trimmedSeed) else {
            return .invalid("Start seed must be an unsigned 64-bit integer.")
        }
        var resolved = configuration
        resolved.seedStart = seed
        do {
            return .valid(try QueueLab.preview(
                for: sourceRecipe,
                configuration: resolved))
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    private func availableParameters(
        excluding parameter: QueueLab.Parameter?
    ) -> [QueueLab.Parameter] {
        QueueLab.availableParameters(for: sourceRecipe).filter { $0 != parameter }
    }

    private func formatted(_ value: QueueLab.ParameterValue?) -> String {
        value?.displayText ?? "-"
    }

    private var canvasChoices: [GenerationRecipe.Canvas] {
        var seen = Set<GenerationRecipe.Canvas>()
        return ([sourceRecipe.canvas] + QueueLab.standardCanvasSizes).filter {
            seen.insert($0).inserted
        }
    }

    private func toggleCanvas(
        _ canvas: GenerationRecipe.Canvas,
        in axis: Binding<QueueLab.Axis>
    ) {
        if let index = axis.wrappedValue.canvasSizes.firstIndex(of: canvas) {
            axis.wrappedValue.canvasSizes.remove(at: index)
        } else {
            axis.wrappedValue.canvasSizes.append(canvas)
            axis.wrappedValue.canvasSizes.sort {
                let left = canvasChoices.firstIndex(of: $0) ?? .max
                let right = canvasChoices.firstIndex(of: $1) ?? .max
                return left < right
            }
        }
    }

    private func wildcardSummary(_ expansion: QueueLab.WildcardExpansion) -> String {
        if expansion.truncated {
            return "\(expansion.totalCombinations) combinations exceed the \(QueueLab.maximumJobCount)-job safety limit"
        }
        return "Use {one|two} choices · \(expansion.prompts.count) deterministic prompt variant\(expansion.prompts.count == 1 ? "" : "s")"
    }

    private func enqueueButtonTitle(_ outcome: PreviewOutcome) -> String {
        guard case .valid(let preview) = outcome else { return "Add grid" }
        return "Add \(preview.jobCount) jobs"
    }

    private func enqueueHelp(_ outcome: PreviewOutcome) -> String {
        if isEnqueueing {
            return "Queue Lab is adding the previewed jobs. Wait for it to finish."
        }
        if vm.isQueueRunning {
            return "Stop the running queue before adding a Queue Lab grid."
        }
        if case .invalid(let message) = outcome {
            return "Fix the Queue Lab configuration before adding jobs: \(message)"
        }
        return "Add every job in the preview to the immutable generation queue."
    }

    private func sectionHeading(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .fxFont(13, weight: .bold)
            .foregroundStyle(Color.fxText)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .fxMonoFont(9.5, weight: .semibold)
            .foregroundStyle(Color.fxText3)
    }

    private func sourceChip(_ text: String) -> some View {
        Text(text)
            .fxMonoFont(9.5, weight: .medium)
            .foregroundStyle(Color.fxHdrMuted)
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .modifier(QueueLabNeutralChipSurfaceModifier())
    }
}

private struct QueueLabInsetSurfaceModifier: ViewModifier {
    let strongBorder: Bool
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .dark {
            content
                .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(strongBorder ? Color.fxBorderStrong : Color.fxBorder, lineWidth: 1))
        } else if strongBorder {
            content
                .fxThemedSurface(.inset, radius: 6, bordered: false)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(FxGlassPalette.borderStrong, lineWidth: 1))
        } else {
            content.fxThemedSurface(.inset, radius: 6)
        }
    }
}

private struct QueueLabChoiceSurfaceModifier: ViewModifier {
    let selected: Bool
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if selected {
            content.background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 5))
        } else if theme == .dark {
            content.background(Color.fxInset, in: RoundedRectangle(cornerRadius: 5))
        } else {
            content.fxThemedSurface(.inset, radius: 5, bordered: false, interactive: true)
        }
    }
}

private struct QueueLabNeutralChipSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .dark {
            content.background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        } else {
            content.fxThemedSurface(.inset, radius: 5, bordered: false)
        }
    }
}

private enum PreviewOutcome {
    case valid(QueueLab.Preview)
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}
