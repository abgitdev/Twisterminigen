import SwiftUI
import UniformTypeIdentifiers

struct LoRAView: View {
    @Bindable var vm: LoRAViewModel

    @Environment(\.fxTheme) private var theme

    @State private var showsImporter = false
    @State private var showsOfficialCatalog = false
    @State private var isDropTarget = false
    @State private var editingTriggersID: UUID?
    @State private var triggerDraft = ""
    @State private var pendingRemoval: LoRAAsset?

    private var primaryText: Color {
        theme == .glass ? FxGlassPalette.text : Color.fxText
    }

    private var secondaryText: Color {
        theme == .glass ? FxGlassPalette.text2 : Color.fxText2
    }

    private var tertiaryText: Color {
        theme == .glass ? FxGlassPalette.text3 : Color.fxText3
    }

    private var safeTensorType: UTType {
        UTType(filenameExtension: "safetensors") ?? .data
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let message = vm.operationMessage { operationBanner(message) }
            if let error = vm.errorMessage { errorBanner(error) }
            dropZone
            library
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fxPageBackground()
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [safeTensorType],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): Task { await vm.importFiles(urls) }
            case .failure(let error): vm.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsOfficialCatalog) {
            OfficialKreaStyleLoRACatalogView(vm: vm)
        }
        .alert(
            vm.removalWillWaitForInference ? "Remove LoRA after render?" : "Remove LoRA?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { asset in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
                .accessibilityIdentifier("lora.remove-alert.cancel")
                .help("Keep this adapter in the local LoRA library.")
            Button(
                vm.removalWillWaitForInference ? "Remove after render" : "Remove",
                role: .destructive
            ) {
                pendingRemoval = nil
                Task { await vm.remove(asset.id) }
            }
            .disabled(vm.removalRequestUnavailableReason(for: asset.id) != nil)
            .accessibilityIdentifier("lora.remove-alert.confirm")
            .help(vm.removalRequestUnavailableReason(for: asset.id)
                  ?? (vm.removalWillWaitForInference
                      ? "Schedule safe removal after the active render or Queue run releases its inference lease."
                      : "Remove this adapter from the local LoRA library."))
        } message: { asset in
            Text(vm.removalWillWaitForInference
                 ? "\(asset.name) will stay available to the active Queue and will be removed automatically when the complete run finishes."
                 : "\(asset.name) will be removed from the private LoRA library.")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LoRA adapters")
                    .fxFont(24, weight: .bold)
                    .foregroundStyle(primaryText)
                Text("\(vm.active.count) active · \(vm.assets.count) in library")
                    .fxMonoFont(11)
                    .foregroundStyle(tertiaryText)
            }
            Spacer(minLength: 16)
            if vm.isWorking {
                ProgressView().controlSize(.small).tint(Color.fxAccent)
            }
            Button {
                showsOfficialCatalog = true
            } label: {
                Label("Krea styles", systemImage: "checkmark.seal")
            }
            .buttonStyle(FxSecondaryButtonStyle(height: 36))
            .disabled(!vm.isAvailable || !vm.canMutateFiles || vm.isWorking)
            .accessibilityIdentifier("lora.official-styles")
            .help(vm.fileMutationUnavailableReason
                  ?? "Import a pinned style-LoRA published by the verified Krea organization")
            Button {
                showsImporter = true
            } label: {
                Label("Import", systemImage: "plus")
            }
            .buttonStyle(FxPrimaryButtonStyle(height: 36))
            .disabled(!vm.isAvailable || !vm.canMutateFiles || vm.isWorking)
            .accessibilityIdentifier("lora.manage")
            .help(vm.fileMutationUnavailableReason ?? "Import a local .safetensors adapter")
        }
    }

    private var dropZone: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.fxAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop .safetensors here")
                    .fxFont(13, weight: .semibold)
                    .foregroundStyle(primaryText)
                Text("kohya · ComfyUI · diffusers · Krea 2")
                    .fxMonoFont(10.5)
                    .foregroundStyle(tertiaryText)
            }
            Spacer()
            Image(systemName: isDropTarget ? "checkmark.circle.fill" : "shield.checkered")
                .foregroundStyle(isDropTarget ? Color.fxAccent : Color.fxText3)
        }
        .padding(.horizontal, 18)
        .frame(height: 68)
        .modifier(LoRADropSurfaceModifier(isTargeted: isDropTarget))
        .dropDestination(for: URL.self) { urls, _ in
            guard vm.fileMutationUnavailableReason == nil else { return false }
            let adapters = urls.filter { $0.pathExtension.lowercased() == "safetensors" }
            guard !adapters.isEmpty else { return false }
            Task { await vm.importFiles(adapters) }
            return true
        } isTargeted: { isDropTarget = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lora.drop-zone")
        .help(vm.fileMutationUnavailableReason
              ?? "Drop one or more local .safetensors adapters to verify and import them.")
    }

    @ViewBuilder private var library: some View {
        if vm.assets.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 30))
                    .foregroundStyle(tertiaryText)
                Text("No LoRA adapters")
                    .fxFont(13, weight: .semibold)
                    .foregroundStyle(secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lora.active-stack")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(orderedAssets.enumerated()), id: \.element.id) { index, asset in
                        adapterRow(asset, ordinal: index + 1)
                    }
                }
                .padding(.bottom, 4)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lora.active-stack")
        }
    }

    private var orderedAssets: [LoRAAsset] {
        let activeAssets = vm.active.compactMap { selection in
            vm.assets.first { $0.id == selection.assetID }
        }
        let activeIDs = Set(activeAssets.map(\.id))
        return activeAssets + vm.assets.filter { !activeIDs.contains($0.id) }
    }

    private func adapterRow(_ asset: LoRAAsset, ordinal: Int) -> some View {
        let enabled = vm.isActive(asset.id)
        let index = vm.activeIndex(asset.id)
        let accessibilityIDBase = "lora.item.\(ordinal)"
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Toggle("", isOn: Binding(
                    get: { vm.isActive(asset.id) },
                    set: { value in Task { await vm.setActive(asset.id, enabled: value) } }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Color.fxAccent)
                    .disabled(vm.fileMutationUnavailableReason != nil)
                    .accessibilityIdentifier("\(accessibilityIDBase).enabled")
                    .help(vm.fileMutationUnavailableReason
                          ?? (enabled ? "Disable adapter" : "Enable adapter"))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(asset.name)
                            .fxFont(13.5, weight: .semibold)
                            .foregroundStyle(enabled ? primaryText : secondaryText)
                            .lineLimit(1)
                        Text("\(asset.matchedTargets)/\(asset.totalTargets) targets")
                            .fxMonoFont(9.5, weight: .medium)
                            .foregroundStyle(Color.fxAccent)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 6)
                            .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 5))
                        if asset.origin.kind == .officialKreaStyle {
                            Text("Official Krea")
                                .fxMonoFont(9.5, weight: .medium)
                                .foregroundStyle(Color.fxAccent)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 6)
                                .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 5))
                        }
                        if vm.isRemovalPending(asset.id) {
                            Text("Removes after render")
                                .fxMonoFont(9.5, weight: .medium)
                                .foregroundStyle(Color.orange)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 6)
                                .background(
                                    Color.orange.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(ByteFormat.string(asset.byteCount))
                        Text("·")
                        Text(String(asset.sha256.prefix(10)))
                        if !asset.triggers.isEmpty {
                            Text("·")
                            Text(asset.triggers.joined(separator: ", "))
                                .lineLimit(1)
                            if asset.automaticallyInsertTriggers {
                                Text("· Auto-insert")
                                    .foregroundStyle(Color.fxAccent)
                            }
                        }
                    }
                    .fxMonoFont(10)
                    .foregroundStyle(tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if enabled {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(String(format: "%.2f", vm.scale(for: asset.id)))
                            .fxMonoFont(10.5, weight: .semibold)
                            .foregroundStyle(secondaryText)
                        Slider(
                            value: Binding(
                                get: { vm.scale(for: asset.id) },
                                set: { vm.setScaleLocally(asset.id, scale: $0) }),
                            in: 0.05 ... GenerationRecipe.maximumLoRAScale,
                            step: 0.05,
                            onEditingChanged: { editing in
                                if !editing { Task { await vm.persistScale(asset.id) } }
                            })
                            .tint(Color.fxAccent)
                            .frame(width: 170)
                            .disabled(vm.fileMutationUnavailableReason != nil)
                            .accessibilityIdentifier("\(accessibilityIDBase).scale")
                            .help(vm.fileMutationUnavailableReason
                                  ?? "Set this adapter's scale for new immutable recipes.")
                    }
                }

                if let index {
                    HStack(spacing: 2) {
                        iconButton(
                            "arrow.up",
                            accessibilityID: "\(accessibilityIDBase).move-earlier",
                            help: "Move earlier",
                            disabled: index == 0) {
                            Task { await vm.move(asset.id, offset: -1) }
                        }
                        iconButton(
                            "arrow.down",
                            accessibilityID: "\(accessibilityIDBase).move-later",
                            help: "Move later",
                            disabled: index == vm.active.count - 1
                        ) {
                            Task { await vm.move(asset.id, offset: 1) }
                        }
                    }
                }

                Menu {
                    Button("Edit trigger phrases") {
                        triggerDraft = asset.triggers.joined(separator: ", ")
                        editingTriggersID = asset.id
                    }
                    .disabled(vm.fileMutationUnavailableReason != nil || editingTriggersID != nil)
                    .help(vm.fileMutationUnavailableReason
                          ?? (editingTriggersID == nil
                              ? "Edit this adapter's saved trigger phrases."
                              : "Finish or cancel the trigger editor that is already open."))
                    .accessibilityIdentifier("\(accessibilityIDBase).edit-triggers")
                    Toggle(
                        "Insert triggers automatically when enabled",
                        isOn: Binding(
                            get: { asset.automaticallyInsertTriggers },
                            set: { enabled in
                                Task {
                                    _ = await vm.setAutomaticallyInsertTriggers(
                                        asset.id,
                                        enabled: enabled)
                                }
                            }))
                    .disabled(vm.fileMutationUnavailableReason != nil || asset.triggers.isEmpty)
                    .help(vm.fileMutationUnavailableReason
                          ?? (asset.triggers.isEmpty
                              ? "Add at least one trigger phrase before enabling automatic insertion."
                              : "Default off. When opted in, the saved phrases are appended on the next disabled-to-enabled transition and become ordinary recipe prompt text."))
                    .accessibilityIdentifier("\(accessibilityIDBase).auto-triggers")
                    Divider()
                    Button(
                        vm.isRemovalPending(asset.id)
                            ? "Removal scheduled"
                            : vm.removalWillWaitForInference
                                ? "Remove after render…"
                                : "Remove",
                        role: .destructive
                    ) {
                        pendingRemoval = asset
                    }
                    .disabled(vm.removalRequestUnavailableReason(for: asset.id) != nil)
                    .help(vm.removalRequestUnavailableReason(for: asset.id)
                          ?? (vm.removalWillWaitForInference
                              ? "Schedule removal after the active render or Queue run finishes."
                              : "Remove this adapter from the local library."))
                    .accessibilityIdentifier("\(accessibilityIDBase).remove")
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Adapter actions")
                .accessibilityIdentifier("\(accessibilityIDBase).triggers")
            }
            .padding(14)

            if editingTriggersID == asset.id {
                Divider().overlay(Color.fxBorder)
                HStack(spacing: 8) {
                    TextField("trigger phrase, another phrase", text: $triggerDraft)
                        .textFieldStyle(.plain)
                        .fxMonoFont(11)
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .fxThemedSurface(.inset, radius: 6, bordered: false)
                        .accessibilityIdentifier("\(accessibilityIDBase).trigger-text")
                        .help("Enter comma-separated trigger phrases for this adapter.")
                    Button("Save") {
                        let submittedID = asset.id
                        let submittedDraft = triggerDraft
                        Task {
                            if await vm.updateTriggers(submittedID, text: submittedDraft),
                               editingTriggersID == submittedID,
                               triggerDraft == submittedDraft {
                                editingTriggersID = nil
                            }
                        }
                    }
                    .buttonStyle(FxPrimaryButtonStyle(height: 30))
                    .disabled(vm.fileMutationUnavailableReason != nil)
                    .help(vm.fileMutationUnavailableReason ?? "Validate and save these trigger phrases.")
                    .accessibilityIdentifier("\(accessibilityIDBase).trigger-save")
                    Button {
                        editingTriggersID = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                    .accessibilityIdentifier("\(accessibilityIDBase).trigger-cancel")
                }
                .padding(10)
                Text("Comma-separated · up to \(LoRAStore.maximumTriggerCount) phrases · \(LoRAStore.maximumTriggerBytes) UTF-8 bytes each")
                    .fxMonoFont(9.5)
                    .foregroundStyle(tertiaryText)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .modifier(LoRAAdapterSurfaceModifier(enabled: enabled))
        .opacity(enabled ? 1 : 0.72)
    }

    private func iconButton(
        _ systemName: String,
        accessibilityID: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .foregroundStyle(disabled ? tertiaryText.opacity(0.35) : secondaryText)
        .disabled(disabled || vm.fileMutationUnavailableReason != nil)
        .help(vm.fileMutationUnavailableReason
              ?? (disabled ? "This adapter is already at that edge of the active stack." : help))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).lineLimit(2)
            Spacer()
            Button {
                vm.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lora.error.dismiss")
            .help("Dismiss this LoRA error message.")
        }
        .fxFont(11.5)
        .foregroundStyle(Color.fxDanger)
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Color.fxDanger.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func operationBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: vm.pendingRemovalIDs.isEmpty ? "checkmark.circle.fill" : "clock.fill")
            Text(text).lineLimit(2)
            Spacer()
            Button {
                vm.operationMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lora.operation.dismiss")
            .help("Dismiss this LoRA status message.")
        }
        .fxFont(11.5)
        .foregroundStyle(Color.fxAccent)
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Color.fxAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct OfficialKreaStyleLoRACatalogView: View {
    @Bindable var vm: LoRAViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Official Krea style-LoRAs")
                        .fxFont(20, weight: .bold)
                    Text("Pinned Krea releases · RAW-trained · Turbo 8 steps · CFG 0 · scale 1.0")
                        .fxFont(11.5)
                        .foregroundStyle(Color.fxText3)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("lora.official-catalog.done")
                    .help("Close the official Krea style catalog.")
            }
            if let error = vm.errorMessage {
                Text(error)
                    .fxFont(11)
                    .foregroundStyle(Color.fxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !vm.hasAcceptedKreaLicense {
                Label(
                    "Review and accept the Krea 2 Community License in Models before importing official Krea styles.",
                    systemImage: "doc.text.magnifyingglass")
                    .fxFont(11, weight: .semibold)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(
                        Array(OfficialKreaStyleLoRACatalog.styles.enumerated()),
                        id: \.element.id
                    ) { index, style in
                        let ordinal = index + 1
                        HStack(spacing: 12) {
                            Image(systemName: "paintpalette")
                                .foregroundStyle(Color.fxAccent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(style.title).fxFont(13, weight: .semibold)
                                Text("Trigger: \(style.trigger)")
                                    .fxMonoFont(10)
                                    .foregroundStyle(Color.fxText3)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Text(ByteFormat.string(style.byteCount))
                                .fxMonoFont(10)
                                .foregroundStyle(Color.fxText3)
                            if vm.hasOfficialStyle(style) {
                                Label("Imported", systemImage: "checkmark.circle.fill")
                                    .fxFont(11, weight: .semibold)
                                    .foregroundStyle(Color.fxAccent)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier(
                                        "lora.official-catalog.style.\(ordinal).imported")
                                    .help("This official Krea style is already imported and verified.")
                            } else {
                                Button("Import") {
                                    Task { await vm.importOfficialStyle(style) }
                                }
                                .buttonStyle(FxPrimaryButtonStyle(height: 30))
                                .disabled(vm.fileMutationUnavailableReason != nil || !vm.hasAcceptedKreaLicense)
                                .help(vm.fileMutationUnavailableReason
                                      ?? (vm.hasAcceptedKreaLicense
                                          ? "Download and verify this official Krea style."
                                          : "Accept the Krea 2 license in Models first."))
                                .accessibilityIdentifier(
                                    "lora.official-catalog.style.\(ordinal).import")
                            }
                        }
                        .padding(12)
                        .fxThemedSurface(.card, radius: 8)
                    }
                }
            }
            Text("Each download is verified by pinned revision, byte count, and SHA-256 before it enters the private LoRA library. Trigger insertion remains opt-in.")
                .fxFont(10.5)
                .foregroundStyle(Color.fxText3)
        }
        .padding(20)
        .frame(width: 680, height: 610)
        .fxPageBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lora.official-catalog.sheet")
    }
}

private struct LoRADropSurfaceModifier: ViewModifier {
    let isTargeted: Bool

    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if theme == .dark {
            content
                .background(isTargeted ? Color.fxAccent.opacity(0.11) : Color.fxInset, in: shape)
                .overlay(shape.strokeBorder(
                    isTargeted ? Color.fxAccent : Color.fxBorder,
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
        } else {
            content
                .fxThemedSurface(.inset, radius: 8, bordered: false, interactive: true)
                .overlay(shape.strokeBorder(
                    isTargeted ? Color.fxAccent : FxGlassPalette.border,
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
                .overlay(shape.fill(isTargeted ? Color.fxAccent.opacity(0.07) : Color.clear)
                    .allowsHitTesting(false))
        }
    }
}

private struct LoRAAdapterSurfaceModifier: ViewModifier {
    let enabled: Bool

    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if theme == .dark {
            content
                .background(Color.fxPanel, in: shape)
                .overlay(shape.strokeBorder(
                    enabled ? Color.fxAccent.opacity(0.35) : Color.fxBorder,
                    lineWidth: 1))
        } else {
            content
                .fxThemedSurface(.panel, radius: 8)
                .overlay(shape.strokeBorder(
                    enabled ? Color.fxAccent.opacity(0.35) : Color.clear,
                    lineWidth: enabled ? 1 : 0))
        }
    }
}
