import SwiftUI
import AppKit

// ============================================================
//  QueueView — FUNCTIONAL. Jobs are added from Generate ("Add to
//  Queue") and run sequentially here through the same engine call
//  path as an ordinary render (GenerateViewModel.runQueue()).
// ============================================================

struct QueueView: View {
    @Bindable var vm: GenerateViewModel
    @Binding var section: AppSection
    @Environment(\.fxTheme) private var theme
    @State private var queueLabPresentation: QueueLabPresentation?
    @State private var editingSession: QueueJobEditSession?
    @State private var isSavingEdit = false
    @State private var editError: String?
    @FocusState private var focusedJobID: UUID?

    private var canMutateQueue: Bool { !vm.isQueueRunning }
    private var canStartQueue: Bool { vm.canRunQueue && editingSession == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Group {
                if vm.runningQueueJob == nil && vm.queue.isEmpty {
                    emptyState
                    Spacer(minLength: 16)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 12) {
                                if let job = vm.runningQueueJob { runningRow(job) }
                                ForEach(Array(vm.queue.enumerated()), id: \.element.id) { i, job in
                                    idleRow(
                                        job,
                                        index: i + 1,
                                        canMoveUp: i > 0,
                                        canMoveDown: i < vm.queue.count - 1)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: editingSession?.id) { _, jobID in
                            guard let jobID else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(queueEditorAnchor(jobID), anchor: .center)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("queue.job-list")

            if let err = vm.errorMessage {
                Text(err).fxFont(11).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Text("Pencil edits a pending recipe · Return opens a Generate copy · Delete removes the job")
                .fxMonoFont(11, weight: .medium)
                .foregroundStyle(Color(hex: 0x697079))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .fxPageBackground()
        .sheet(item: $queueLabPresentation) { presentation in
            QueueLabView(vm: vm, sourceRecipe: presentation.recipe)
        }
        .onChange(of: vm.queue.map(\.id)) { _, ids in
            if let focusedJobID, !ids.contains(focusedJobID) {
                self.focusedJobID = nil
            }
            if let editingSession, !ids.contains(editingSession.id) {
                cancelEditing()
            }
        }
    }

    // ── Header ───────────────────────────────────────────────────────────────
    private var header: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Queue")
                    .fxFont(24, weight: .bold)
                    .foregroundStyle(Color.fxText)
                    .tracking(-0.3)
                Text(subtitle)
                    .fxFont(12)
                    .foregroundStyle(Color.fxText3)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("queue.job-details")

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                livePreviewMenu

                Button {
                    queueLabPresentation = QueueLabPresentation(
                        recipe: vm.queueLabBaseRecipe())
                } label: {
                    Label("Queue Lab", systemImage: "square.grid.3x3")
                }
                .buttonStyle(FxSecondaryButtonStyle(height: 38, accentText: true))
                .accessibilityIdentifier("queue.lab.open")
                .disabled(!vm.canAddToQueue)
                .help(vm.addToQueueUnavailableReason
                    ?? "Build a seed grid and parameter sweeps from the current Generate settings.")

                if vm.runningQueueJob != nil {
                    Button { vm.cancel() } label: {
                        HStack(spacing: 7) {
                            if vm.isStopping {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "stop.fill").font(.system(size: 12))
                            }
                            Text(vm.isStopping ? "Stopping..." : "Stop now")
                        }
                        .fxFont(12, weight: .semibold)
                        .foregroundStyle(Color.fxText2)
                        .frame(height: 38)
                        .padding(.horizontal, 15)
                        .fxThemedSurface(
                            .inset,
                            radius: FxRadius.button,
                            bordered: false,
                            interactive: true)
                        .overlay(RoundedRectangle(cornerRadius: FxRadius.button, style: .continuous)
                            .strokeBorder(
                                theme == .glass ? FxGlassPalette.borderStrong : Color.fxBorderStrong,
                                lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("queue.stop-now")
                    .disabled(vm.isStopping)
                    .help(vm.isStopping
                          ? "The current Queue job is already stopping."
                          : "Stop after the current Metal operation and return this job to the queue.")
                }

                Button { vm.stopAfterCurrentQueueJob.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: vm.stopAfterCurrentQueueJob ? "checkmark.square" : "square")
                            .font(.system(size: 14))
                        Text("Stop after this")
                    }
                    .fxFont(12, weight: .semibold)
                    .foregroundStyle(Color.fxText2)
                    .frame(height: 38)
                    .padding(.horizontal, 15)
                    .fxThemedSurface(
                        .inset,
                        radius: FxRadius.button,
                        bordered: false,
                        interactive: true)
                    .overlay(RoundedRectangle(cornerRadius: FxRadius.button, style: .continuous)
                        .strokeBorder(
                            theme == .glass ? FxGlassPalette.borderStrong : Color.fxBorderStrong,
                            lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("queue.stop-after-current")
                .disabled(vm.runningQueueJob == nil)
                .opacity(vm.runningQueueJob == nil ? 0.5 : 1)
                .help(vm.runningQueueJob == nil
                      ? "Start Queue before requesting a stop after the current job."
                      : "Finish the job that's rendering now, then leave the rest queued instead of continuing.")

                Button { vm.runQueue() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play").font(.system(size: 14))
                        Text("Run all (\(vm.queue.count))")
                    }
                    .fxFont(12.5, weight: .bold)
                    .foregroundStyle(Color.fxOnAccent)
                    .frame(height: 38)
                    .padding(.horizontal, 18)
                    .background(
                        LinearGradient(colors: [.fxAccent, .fxAccentDeep],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: FxRadius.button, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("queue.run-all")
                .disabled(!canStartQueue)
                .opacity(canStartQueue ? 1 : 0.5)
                .help(editingSession == nil
                      ? (vm.runQueueUnavailableReason
                         ?? "Render every saved queued recipe in order.")
                      : "Save or cancel the open Queue edit before running.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("queue.job-actions")
        }
    }

    private var livePreviewMenu: some View {
        Menu {
            ForEach(GenerateViewModel.LivePreviewMode.allCases, id: \.self) { mode in
                Button {
                    vm.setLivePreviewMode(mode)
                } label: {
                    Label(
                        mode.displayName,
                        systemImage: vm.livePreviewMode == mode ? "checkmark" : "circle")
                }
                .accessibilityIdentifier(queuePreviewModeAccessibilityID(mode))
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: vm.livePreviewMode == .off ? "eye.slash" : "eye")
                    .font(.system(size: 12, weight: .semibold))
                Text("Preview · \(vm.livePreviewMode.displayName)")
                    .lineLimit(1)
            }
            .fxFont(12, weight: .semibold)
            .foregroundStyle(Color.fxText2)
            .frame(height: 38)
            .padding(.horizontal, 13)
            .fxThemedSurface(
                .inset,
                radius: FxRadius.button,
                bordered: false,
                interactive: true)
            .overlay(RoundedRectangle(cornerRadius: FxRadius.button, style: .continuous)
                .strokeBorder(
                    theme == .glass ? FxGlassPalette.borderStrong : Color.fxBorderStrong,
                    lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("queue.preview.mode")
        .accessibilityLabel("Queue live preview")
        .accessibilityValue(vm.livePreviewMode.displayName)
        .help(vm.isQueueRunning
              ? "Off hides the current latent preview immediately. Other modes apply to the next Queue job."
              : "Choose the diagnostic latent preview cadence for Queue renders.")
    }

    private func queuePreviewModeAccessibilityID(
        _ mode: GenerateViewModel.LivePreviewMode
    ) -> String {
        switch mode {
        case .off: "queue.preview.off"
        case .everyFourSteps: "queue.preview.every-4-steps"
        case .everyStep: "queue.preview.every-step"
        }
    }

    private var subtitle: String {
        if let job = vm.runningQueueJob {
            var s = "Running · \(vm.busySubline)"
            if let eta = vm.etaText { s += " · \(eta)" }
            return s + " · “\(job.prompt.prefix(40))”"
        }
        if vm.queue.isEmpty { return "Nothing queued — add a job from Generate." }
        return "\(vm.queue.count) job\(vm.queue.count == 1 ? "" : "s") queued"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your queue is empty.").fxFont(13, weight: .semibold).foregroundStyle(Color.fxText2)
            Text("Set up a prompt on Generate, then tap “Add to Queue” instead of Generate to line it up here.")
                .fxFont(12).foregroundStyle(Color.fxText3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxThemedSurface(.card, radius: FxRadius.card)
    }

    // ── Running row ───────────────────────────────────────────────────────────
    private func runningRow(_ job: QueueJob) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.fxAccent, .fxAccentDeep],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "bolt")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.fxOnAccent)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 8) {
                Text(job.prompt)
                    .fxFont(13, weight: .medium)
                    .foregroundStyle(Color.fxText)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    chip("\(job.width)×\(job.height)")
                    chip("\(job.steps) steps")
                    if let input = job.recipe.inputImage {
                        chip("Remix \(input.strength.formatted(.number.precision(.fractionLength(2))))", accent: true)
                    }
                    if !job.recipe.regions.isEmpty {
                        chip("\(job.recipe.regions.count) regions", accent: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(vm.activityText)
                    .fxMonoFont(12, weight: .semibold)
                    .foregroundStyle(Color.fxAccentHi)
                if let eta = vm.etaText {
                    Text(eta).fxMonoFont(11, weight: .medium).foregroundStyle(Color.fxText3)
                }
            }
        }
        .padding(16)
        .background(Color(hex: 0x93A7B5, alpha: 0.08),
                    in: RoundedRectangle(cornerRadius: FxRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FxRadius.card, style: .continuous)
            .strokeBorder(Color(hex: 0x93A7B5, alpha: 0.28), lineWidth: 1))
    }

    // ── Idle rows (pending) ───────────────────────────────────────────────────
    private func idleRow(
        _ job: QueueJob,
        index: Int,
        canMoveUp: Bool,
        canMoveDown: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("\(index)")
                    .fxMonoFont(12, weight: .semibold)
                    .foregroundStyle(Color.fxText2)
                    .frame(width: 30, height: 30)
                    .background(
                        theme == .glass ? FxGlassPalette.inset : Color.white.opacity(0.05),
                        in: Circle())
                    .overlay(Circle().strokeBorder(
                        theme == .glass ? FxGlassPalette.borderStrong : Color.fxBorderStrong,
                        lineWidth: 1))

                VStack(alignment: .leading, spacing: 8) {
                    Text(job.prompt)
                        .fxFont(13, weight: .medium)
                        .foregroundStyle(Color.fxEmberHi)
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 6) {
                        chip("\(job.width)×\(job.height)")
                        chip("\(job.steps) steps")
                        chip(job.seedText.isEmpty ? "random seed" : "seed \(job.seedText)")
                        if let input = job.recipe.inputImage {
                            chip("Remix \(input.strength.formatted(.number.precision(.fractionLength(2))))", accent: true)
                        }
                        if !job.recipe.regions.isEmpty {
                            chip("\(job.recipe.regions.count) regions", accent: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    iconAction("chevron.up", size: 16,
                               accessibilityID: queueJobAccessibilityID(index, action: "move-up"),
                               help: canMoveUp
                                   ? "Move this pending job up. The current render keeps running."
                                   : "This job is already first.",
                               enabled: canMoveUp) {
                        Task { await vm.moveQueueJobUp(id: job.id) }
                    }
                    iconAction("chevron.down", size: 16,
                               accessibilityID: queueJobAccessibilityID(index, action: "move-down"),
                               help: canMoveDown
                                   ? "Move this pending job down. The current render keeps running."
                                   : "This job is already last.",
                               enabled: canMoveDown) {
                        Task { await vm.moveQueueJobDown(id: job.id) }
                    }
                    iconAction("pencil", size: 14,
                               accessibilityID: queueJobAccessibilityID(index, action: "edit"),
                               accessibilityLabel: "Edit queue job",
                               help: vm.isQueueRunning
                                   ? "Edit this pending recipe while the current job keeps rendering."
                                   : "Edit this pending Queue recipe in place.",
                               enabled: true) {
                        if editingSession?.id == job.id {
                            cancelEditing()
                        } else {
                            beginEditing(job)
                        }
                    }
                    iconAction("arrow.up.forward.app", size: 14,
                               accessibilityID: queueJobAccessibilityID(index, action: "open-copy"),
                               help: canMutateQueue
                                   ? "Open an editable copy on Generate. The queued snapshot stays unchanged."
                                   : "Queued snapshots are locked while Queue is running.",
                               enabled: canMutateQueue) {
                        Task {
                            if await vm.openQueueJobCopy(id: job.id) { section = .generate }
                        }
                    }
                    iconAction("doc.badge.arrow.up", size: 14,
                               accessibilityID: queueJobAccessibilityID(index, action: "export"),
                               help: canMutateQueue
                                   ? "Export full immutable recipe metadata as JSON."
                                   : "Recipe metadata export is locked while Queue is running.",
                               enabled: canMutateQueue) {
                        exportMetadata(job)
                    }
                    duplicateMenu(for: job, index: index)
                    iconAction("xmark", size: 15,
                               accessibilityID: queueJobAccessibilityID(index, action: "remove"),
                               help: "Remove this pending job. The current render keeps running.",
                               enabled: true) {
                        remove(job)
                    }
                }
            }
            .padding(16)

            if editingSession?.id == job.id {
                Divider()
                    .overlay(theme == .glass ? FxGlassPalette.border : Color.fxBorder)
                    .padding(.horizontal, 16)

                QueueJobInlineEditor(
                    job: job,
                    index: index,
                    draft: editDraftBinding(for: job),
                    isSaving: isSavingEdit,
                    errorMessage: editError,
                    onSave: { saveEditing(job) },
                    onCancel: cancelEditing)
                    .padding(16)
                    .padding(.top, 2)
                    .id(queueEditorAnchor(job.id))
            }
        }
        .fxThemedSurface(.card, radius: FxRadius.card, bordered: false)
        .overlay(RoundedRectangle(cornerRadius: FxRadius.card, style: .continuous)
            .strokeBorder(
                focusedJobID == job.id
                    ? Color.fxAccentLine
                    : (theme == .glass ? FxGlassPalette.border : Color.fxBorder),
                lineWidth: focusedJobID == job.id ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: FxRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(queueJobAccessibilityID(index, action: "row"))
        .help(vm.isQueueRunning
            ? "Pending Queue job \(index). Arrow buttons reorder it; Delete removes it while the current job keeps rendering."
            : "Queue job \(index). Press Return to open an editable copy; Delete removes this immutable snapshot.")
        .focusable()
        .focused($focusedJobID, equals: job.id)
        .simultaneousGesture(TapGesture().onEnded { focusedJobID = job.id })
        .onKeyPress(.return) {
            guard canMutateQueue else { return .ignored }
            Task {
                if await vm.openQueueJobCopy(id: job.id) { section = .generate }
            }
            return .handled
        }
        .onDeleteCommand {
            remove(job)
        }
    }

    // ── Small building blocks ────────────────────────────────────────────────
    private func chip(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .fxMonoFont(10, weight: .medium)
            .foregroundStyle(accent ? Color.fxAccent : Color.fxHdrMuted)
            .padding(.vertical, 2).padding(.horizontal, 7)
            .modifier(QueueChipSurfaceModifier(accent: accent))
    }

    private func iconAction(
        _ symbol: String,
        size: CGFloat,
        accessibilityID: String,
        accessibilityLabel: String? = nil,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        QueueIconButton(
            symbol: symbol,
            size: size,
            accessibilityID: accessibilityID,
            accessibilityLabel: accessibilityLabel ?? help,
            help: help,
            enabled: enabled,
            action: action)
    }

    private func duplicateMenu(for job: QueueJob, index: Int) -> some View {
        Menu {
            Menu("Duplicate once") {
                duplicateActions(for: job, count: 1, index: index)
            }
            .help("Choose how the duplicate resolves its seed.")
            .accessibilityIdentifier(queueJobAccessibilityID(index, action: "duplicate-once"))
            Menu("Generate Again") {
                ForEach([3, 5, 10], id: \.self) { count in
                    Menu("\(count) copies") {
                        duplicateActions(for: job, count: count, index: index)
                    }
                    .help("Choose how all \(count) copies resolve their seeds.")
                    .accessibilityIdentifier(
                        queueJobAccessibilityID(index, action: "duplicate-\(count)-copies"))
                }
            }
            .help("Choose a copy count and seed behavior.")
            .accessibilityIdentifier(queueJobAccessibilityID(index, action: "generate-again"))
        } label: {
            Image(systemName: "square.on.square")
                .font(.system(size: 15))
                .foregroundStyle(Color.fxHdrMuted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!canMutateQueue)
        .opacity(canMutateQueue ? 1 : 0.35)
        .help(canMutateQueue
              ? "Duplicate once or enqueue 3, 5, or 10 independent copies."
              : "Queue jobs cannot be duplicated while Queue is running.")
        .accessibilityLabel("Duplicate queue job")
        .accessibilityIdentifier(queueJobAccessibilityID(index, action: "duplicate"))
    }

    @ViewBuilder
    private func duplicateActions(for job: QueueJob, count: Int, index: Int) -> some View {
        ForEach(QueueDuplicateSeedMode.allCases) { mode in
            Button(mode.title) {
                Task {
                    await vm.duplicateQueueJob(
                        id: job.id,
                        count: count,
                        seedMode: mode)
                }
            }
            .disabled(
                job.recipe.sampler.seed.fixedValue == nil
                    && (mode == .same || mode == .sequential))
            .help(job.recipe.sampler.seed.fixedValue == nil
                    && (mode == .same || mode == .sequential)
                  ? "This mode requires a fixed seed; choose Fresh random or edit a copy on Generate."
                  : mode.help)
            .accessibilityIdentifier(
                queueJobAccessibilityID(
                    index,
                    action: "duplicate-\(count)-\(mode.rawValue)-seed"))
        }
    }

    private func queueJobAccessibilityID(_ index: Int, action: String) -> String {
        "queue.job.\(index).\(action)"
    }

    private func queueEditorAnchor(_ id: UUID) -> String {
        "queue.editor.\(id.uuidString)"
    }

    private func beginEditing(_ job: QueueJob) {
        guard vm.queue.contains(where: { $0.id == job.id }) else { return }
        focusedJobID = job.id
        editingSession = QueueJobEditSession(
            id: job.id,
            draft: QueueJobEditDraft(job: job))
        editError = nil
        isSavingEdit = false
    }

    private func cancelEditing() {
        editingSession = nil
        editError = nil
        isSavingEdit = false
    }

    private func editDraftBinding(for job: QueueJob) -> Binding<QueueJobEditDraft> {
        Binding(
            get: {
                guard let editingSession, editingSession.id == job.id else {
                    return QueueJobEditDraft(job: job)
                }
                return editingSession.draft
            },
            set: { draft in
                guard var session = editingSession, session.id == job.id else { return }
                session.draft = draft
                editingSession = session
                editError = nil
            })
    }

    private func saveEditing(_ job: QueueJob) {
        guard !isSavingEdit,
              let editingSession,
              editingSession.id == job.id else { return }
        do {
            let recipe = try editingSession.draft.applying(to: job)
            isSavingEdit = true
            editError = nil
            Task { @MainActor in
                let saved = await vm.updateQueueJob(id: job.id, recipe: recipe)
                isSavingEdit = false
                if saved {
                    self.editingSession = nil
                } else {
                    editError = vm.errorMessage ?? "The Queue job could not be saved."
                }
            }
        } catch {
            editError = error.localizedDescription
        }
    }

    private func remove(_ job: QueueJob) {
        if focusedJobID == job.id { focusedJobID = nil }
        if editingSession?.id == job.id { cancelEditing() }
        Task { await vm.removeQueueJob(id: job.id) }
    }

    private func exportMetadata(_ job: QueueJob) {
        let panel = NSSavePanel()
        panel.title = "Export Full Queue Recipe Metadata"
        panel.prompt = "Export JSON"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Twisterminigen-Queue-\(job.id.uuidString.prefix(8)).json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in
            do {
                let outcome = try await vm.exportQueueRecipeMetadata(job, to: destination)
                switch outcome {
                case .publishedDurable:
                    vm.errorMessage = nil
                case .publishedDurabilityWarning(let url, let code):
                    vm.errorMessage = "\(url.lastPathComponent) is visible, but filesystem durability could not be confirmed (POSIX \(code))."
                case .failedBeforeVisibility(_, let error):
                    throw error
                case .stateUnknown(let url, let error):
                    throw ExternalPublicationStateError.stateUnknown(url, underlying: error)
                }
            } catch {
                vm.errorMessage = "Queue metadata export failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct QueueChipSurfaceModifier: ViewModifier {
    let accent: Bool
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if accent {
            content.background(
                Color.fxAccentSoft,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if theme == .dark {
            content.background(
                Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            content.fxThemedSurface(.inset, radius: 6, bordered: false)
        }
    }
}

private struct QueueLabPresentation: Identifiable {
    let id = UUID()
    let recipe: GenerationRecipe
}

private struct QueueJobEditSession: Identifiable {
    let id: UUID
    var draft: QueueJobEditDraft
}

private struct QueueJobInlineEditor: View {
    let job: QueueJob
    let index: Int
    @Binding var draft: QueueJobEditDraft
    let isSaving: Bool
    let errorMessage: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Edit queued job", systemImage: "pencil")
                    .fxFont(13, weight: .semibold)
                    .foregroundStyle(Color.fxText)
                Spacer(minLength: 12)
                Text(preservedRecipeSummary)
                    .fxMonoFont(10, weight: .medium)
                    .foregroundStyle(Color.fxText3)
                    .lineLimit(1)
            }

            QueueInlineTextArea(
                label: "Prompt",
                placeholder: "Describe what to generate…",
                text: $draft.prompt,
                height: 84,
                accessibilityID: "queue.job.\(index).editor.prompt")

            numericControls

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    QueueInlineTextField(
                        label: "Negative prompt",
                        placeholder: "Optional exclusions…",
                        text: $draft.negativePrompt,
                        accessibilityID: "queue.job.\(index).editor.negative-prompt")
                    QueueInlineTextField(
                        label: "Text to appear",
                        placeholder: "No lettering",
                        text: $draft.exactText,
                        accessibilityID: "queue.job.\(index).editor.exact-text")
                }
                VStack(alignment: .leading, spacing: 12) {
                    QueueInlineTextField(
                        label: "Negative prompt",
                        placeholder: "Optional exclusions…",
                        text: $draft.negativePrompt,
                        accessibilityID: "queue.job.\(index).editor.negative-prompt")
                    QueueInlineTextField(
                        label: "Text to appear",
                        placeholder: "No lettering",
                        text: $draft.exactText,
                        accessibilityID: "queue.job.\(index).editor.exact-text")
                }
            }

            Label(
                "Model, LoRA, Remix, Regions, schedule, precision, and guidance are preserved.",
                systemImage: "checkmark.shield")
                .fxFont(10.5)
                .foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .fxFont(11, weight: .medium)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("queue.job.\(index).editor.error")
            }

            HStack(spacing: 10) {
                Button {
                    onSave()
                } label: {
                    if isSaving {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.mini)
                            Text("Saving…")
                        }
                    } else {
                        Label("Save", systemImage: "checkmark")
                    }
                }
                .buttonStyle(FxPrimaryButtonStyle(height: 34))
                .disabled(isSaving || !draft.seedIsValid)
                .accessibilityIdentifier("queue.job.\(index).editor.save")
                .help(draft.seedIsValid
                      ? "Replace this pending Queue recipe and keep its position."
                      : "Enter a valid non-negative seed or leave Seed empty for random.")

                Button("Cancel", action: onCancel)
                    .buttonStyle(FxSecondaryButtonStyle(height: 34))
                    .disabled(isSaving)
                    .accessibilityIdentifier("queue.job.\(index).editor.cancel")
                    .help("Discard these changes and close the editor.")

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .fxThemedSurface(.inset, radius: 10)
        .disabled(isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.job.\(index).editor")
    }

    @ViewBuilder
    private var numericControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                widthControl
                heightControl
                stepsControl
                seedControl
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    widthControl
                    heightControl
                }
                HStack(alignment: .top, spacing: 12) {
                    stepsControl
                    seedControl
                }
            }
        }
    }

    private var widthControl: some View {
        FxStepper(
            label: "Width",
            value: $draft.width,
            range: GenerationRecipe.minimumDimension ... GenerationRecipe.maximumDimension,
            step: GenerationRecipe.dimensionMultiple,
            accessibilityIDBase: "queue.job.\(index).editor.width")
            .frame(maxWidth: .infinity)
    }

    private var heightControl: some View {
        FxStepper(
            label: "Height",
            value: $draft.height,
            range: GenerationRecipe.minimumDimension ... GenerationRecipe.maximumDimension,
            step: GenerationRecipe.dimensionMultiple,
            accessibilityIDBase: "queue.job.\(index).editor.height")
            .frame(maxWidth: .infinity)
    }

    private var stepsControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Steps").fxLabel()
            Stepper(
                value: $draft.steps,
                in: GenerationRecipe.minimumSteps ... GenerationRecipe.maximumSteps
            ) {
                Text("\(draft.steps)")
                    .fxMonoFont(12)
                    .foregroundStyle(Color.fxText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .fxInsetField(radius: 8)
            .accessibilityIdentifier("queue.job.\(index).editor.steps")
            .help("Choose \(GenerationRecipe.minimumSteps)–\(GenerationRecipe.maximumSteps) denoising steps.")
        }
        .frame(maxWidth: .infinity)
    }

    private var seedControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Seed").fxLabel()
            TextField("Random", text: $draft.seedText)
                .textFieldStyle(.plain)
                .fxMonoFont(12)
                .foregroundStyle(draft.seedIsValid ? Color.fxText : Color.red)
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                .fxInsetField(radius: 8)
                .accessibilityIdentifier("queue.job.\(index).editor.seed")
                .help("Enter a non-negative whole number, or leave empty for a fresh random seed.")
        }
        .frame(maxWidth: .infinity)
    }

    private var preservedRecipeSummary: String {
        var values = [job.recipe.model.quantizationTier.qualityName]
        if !job.recipe.loras.isEmpty { values.append("\(job.recipe.loras.count) LoRA") }
        if job.recipe.inputImage != nil { values.append("Remix") }
        if !job.recipe.regions.isEmpty { values.append("\(job.recipe.regions.count) regions") }
        return values.joined(separator: " · ")
    }
}

private struct QueueInlineTextArea: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let height: CGFloat
    let accessibilityID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).fxLabel()
                Spacer()
                Text("\(text.utf8.count) / \(GenerationRecipe.maximumPromptUTF8Bytes)")
                    .fxMonoFont(9.5)
                    .foregroundStyle(Color.fxText3)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .fxFont(12)
                        .foregroundStyle(Color.fxText3)
                        .padding(.horizontal, 9)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .fxFont(12)
                    .foregroundStyle(Color.fxText)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(accessibilityID)
            }
            .frame(height: height)
            .fxInsetField(radius: 8)
        }
    }
}

private struct QueueInlineTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let accessibilityID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).fxLabel()
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1 ... 3)
                .textFieldStyle(.plain)
                .fxFont(12)
                .foregroundStyle(Color.fxText)
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                .fxInsetField(radius: 8)
                .accessibilityIdentifier(accessibilityID)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Row action icon — flat by default, soft hover fill, real action + disabled state.
private struct QueueIconButton: View {
    let symbol: String
    let size: CGFloat
    let accessibilityID: String
    let accessibilityLabel: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(Color.fxHdrMuted)
                .frame(width: 30, height: 30)
                .background(hover ? Color.fxHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityID)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .onHover { hover = $0 }
    }
}
