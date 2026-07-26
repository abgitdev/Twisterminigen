import SwiftUI
import AppKit

enum ModelsQualityCardLayout {
    static let minimumHeight: CGFloat = 136
    static let actionRowMinimumHeight: CGFloat = 28
}

// ============================================================
//  Models — components + catalog model schema (maket frame g).
//  Checkpoint/quantization labels come from ModelCatalog; the component rows, the
//  "N of 3 · X GB on disk" summary and every status/size/action
//  are LIVE from ModelsViewModel (real on-disk presence).
// ============================================================

struct ModelsFaithfulView: View {
    @Bindable var vm: ModelsViewModel
    @Environment(\.fxTheme) private var theme

    private var primaryText: Color {
        theme == .glass ? FxGlassPalette.text : Color.fxText
    }

    private var secondaryText: Color {
        theme == .glass ? FxGlassPalette.text2 : Color.fxText2
    }

    private var tertiaryText: Color {
        theme == .glass ? FxGlassPalette.text3 : Color.fxText3
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                modelFolderRow
                if let err = vm.errorMessage { errorBanner(err) }
                qualitySection
                componentRows
                licenseFooter
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .fxPageBackground()
        .task { vm.refresh() }
        .alert("Delete \(vm.component(id: vm.pendingDeleteID)?.title ?? "component")?",
               isPresented: deleteAlertBinding) {
            Button("Cancel", role: .cancel) { vm.cancelDelete() }
                .accessibilityIdentifier("models.delete-cancel")
                .help("Keep the verified model component on this Mac.")
            Button("Delete", role: .destructive) { vm.confirmDelete() }
                .accessibilityIdentifier("models.delete-confirm")
                .help("Remove only the selected app-managed model component after this confirmation.")
        } message: {
            Text("This removes the files from disk to free space. You can download them again later.")
        }
        .sheet(isPresented: $vm.showsKreaLicenseReview) {
            KreaLicenseReviewSheet(
                onCancel: vm.cancelKreaLicenseReview,
                onAccept: vm.acceptKreaLicenseAndContinue)
        }
    }

    private var licenseFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: vm.hasAcceptedKreaLicense ? "checkmark.shield" : "doc.text.magnifyingglass")
                    .foregroundStyle(vm.hasAcceptedKreaLicense ? Color.fxOk : Color.orange)
                Text(vm.hasAcceptedKreaLicense
                     ? "Krea 2 license accepted for this version"
                     : "Krea 2 license review required before download or rendering")
                    .fxFont(12, weight: .semibold)
                    .foregroundStyle(theme == .glass ? FxGlassPalette.text2 : Color.fxText2)
                Button(vm.hasAcceptedKreaLicense ? "Review terms" : "Review & accept…") {
                    vm.reviewKreaLicense()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.fxAccent)
                .accessibilityIdentifier("models.license-sheet")
                .help("Review the exact bundled Krea 2 license and local acceptance state.")
            }
            HStack(spacing: 4) {
                Text("Local input safety filter · explicit export review · TE stays bf16 ·")
                    .fxMonoFont(11, weight: .medium)
                    .foregroundStyle(theme == .glass ? FxGlassPalette.text3 : Color(hex: 0x697079))
                Button {
                    NSWorkspace.shared.open(KreaLegal.acceptableUsePolicyURL)
                } label: {
                    Text("usage policy").underline()
                }
                .buttonStyle(.plain)
                .fxMonoFont(11, weight: .medium)
                .foregroundStyle(Color.fxAccent)
                .help("Krea 2 Acceptable Use Policy")
                .accessibilityIdentifier("models.usage-policy")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { vm.pendingDeleteID != nil }, set: { if !$0 { vm.cancelDelete() } })
    }

    // MARK: Header (live summary)

    private var header: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Models")
                    .fxFont(24, weight: .bold).tracking(-0.3)
                    .foregroundStyle(primaryText)
                Text("Krea 2 weights · everything runs locally")
                    .fxFont(12).foregroundStyle(tertiaryText)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                FxDot(tone: vm.selectedModelReady ? .ok : .amber, live: vm.isRefreshing, size: 8)
                Text(headerSummary)
                    .fxMonoFont(12, weight: .medium).foregroundStyle(secondaryText)
            }
        }
    }

    private var headerSummary: String {
        if vm.isSwitchingRoot { return "Switching model folder…" }
        if vm.isRefreshing { return "Verifying model files…" }
        return vm.componentSummary
    }

    private var modelFolderRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: vm.isLinkedReadOnly ? "link" : "internaldrive")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(vm.isLinkedReadOnly ? Color.fxAccent : tertiaryText)
                Text(vm.isLinkedReadOnly ? "Read-only linked weights" : "App-managed weights")
                    .fxFont(11.5, weight: .semibold)
                    .foregroundStyle(secondaryText)
                Text(vm.weightsRootDisplayPath)
                    .fxMonoFont(11)
                    .foregroundStyle(tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(vm.weightsRoot.path)
                Spacer(minLength: 12)
                Button("Import…") { vm.requestImportFolder() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .disabled(!vm.canChooseFolder)
                    .help(vm.chooseFolderUnavailableReason
                          ?? "Verify and copy a complete compatible checkpoint into app-managed storage.")
                    .accessibilityIdentifier("models.import")
                Button("Link…") { vm.requestLinkedFolder() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .disabled(!vm.canChooseFolder)
                    .help(vm.chooseFolderUnavailableReason
                          ?? "Verify and use a complete compatible checkpoint in place, read-only.")
                    .accessibilityIdentifier("models.link")
                if vm.isLinkedReadOnly {
                    Button("Use app-managed storage") { vm.useManagedDownloads() }
                        .buttonStyle(FxSecondaryButtonStyle(height: 30))
                        .disabled(!vm.canChooseFolder)
                        .help(vm.chooseFolderUnavailableReason
                              ?? "Switch to app-managed storage where Download and Delete are available.")
                        .accessibilityIdentifier("models.official-downloads")
                }
                Button { vm.revealFolder() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.fxBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reveal model folder")
                .accessibilityIdentifier("models.reveal-folder")
                .help("Reveal in Finder")
            }
            Text(vm.isLinkedReadOnly
                 ? "External files are verified in place. Download and Delete are disabled; Twisterminigen never writes beside or removes linked weights."
                 : "Import makes an owned copy. Managed files may be completed by pinned downloads or removed from this screen.")
                .fxFont(10.5)
                .foregroundStyle(tertiaryText)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.import-link")
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text(text).fxFont(11.5).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                vm.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss model-folder error")
            .accessibilityIdentifier("models.error.dismiss")
            .help("Dismiss this model-folder error. The active model source is unchanged.")
        }
        .foregroundStyle(Color.fxDanger)
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(Color.fxDangerSoft, in: RoundedRectangle(cornerRadius: FxRadius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FxRadius.field, style: .continuous)
            .strokeBorder(Color.fxDanger.opacity(0.35), lineWidth: 1))
    }

    // MARK: Model schema

    private var turboDescriptors: [ModelDescriptor] {
        ModelCatalog.knownModelDescriptors.filter { $0.checkpointFamily == .turbo }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quantization tiers · Turbo checkpoint")
                .fxFont(11, weight: .semibold).tracking(0.4).textCase(.uppercase)
                .foregroundStyle(tertiaryText)
                .padding(.bottom, 11)
            HStack(alignment: .top, spacing: 12) {
                ForEach(turboDescriptors) { descriptor in
                    qualityCard(
                        descriptor,
                        downloaded: vm.isReady(descriptor))
                }
            }
            Text(qualitySummary)
                .fxFont(11).foregroundStyle(tertiaryText)
                .padding(.top, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.active-model")
    }

    private var qualitySummary: String {
        let current = vm.selectedDescriptor.displayName
        if vm.isRefreshing {
            return "Verifying \(current) against its pinned manifest."
        }
        if vm.selectedModelReady {
            let source = vm.isLinkedReadOnly ? "linked, verified, and ready" : "installed, verified, and ready"
            return "Current render: \(current), \(source)."
        }
        return "Current render: \(current), missing required weights."
    }

    private func qualityCard(_ descriptor: ModelDescriptor, downloaded: Bool) -> some View {
        let selected = descriptor.quantizationTier == vm.selectedQuantizationTier
        let titleColor: Color = selected
            ? primaryText
            : (theme == .glass ? FxGlassPalette.text2 : Color(hex: 0xDDE2E6))
        let tagColor: Color = selected ? .fxAccent : tertiaryText
        let labelColor: Color = selected ? .fxAccent : tertiaryText
        let valueColor: Color = selected
            ? (theme == .glass ? FxGlassPalette.ember : .fxEmberHi)
            : secondaryText

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(descriptor.quantizationTier.qualityName)
                    .fxFont(14, weight: .semibold).foregroundStyle(titleColor)
                Text(selected ? "Selected" : (descriptor.isDefault ? "Default" : "Available"))
                    .fxMonoFont(10.5, weight: .medium).foregroundStyle(tagColor)
                Spacer(minLength: 0)
            }
            VStack(spacing: 6) {
                metricRow(
                    "Checkpoint",
                    descriptor.checkpointFamily.displayName,
                    labelColor: labelColor,
                    valueColor: valueColor)
                metricRow(
                    "Quantization",
                    descriptor.quantizationTier.displayName,
                    labelColor: labelColor,
                    valueColor: valueColor)
                metricRow(
                    "Weights",
                    vm.isLinkedReadOnly ? "External · read-only" : descriptor.weightAccess.displayName,
                    labelColor: labelColor,
                    valueColor: valueColor)
            }
            .padding(.top, 12)

            Divider().overlay(Color.fxBorder).padding(.vertical, 10)

            HStack(spacing: 8) {
                Text(descriptor.isDefault
                     ? "Balanced 9.8 GB backbone"
                     : "Near-lossless 14.2 GB backbone")
                    .fxFont(10.5)
                    .foregroundStyle(tertiaryText)
                Spacer(minLength: 8)
                if selected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .fxFont(10.5, weight: .semibold)
                        .foregroundStyle(Color.fxOk)
                } else {
                    Button("Use") { vm.selectQuality(descriptor) }
                        .buttonStyle(FxSecondaryButtonStyle(height: 28))
                        .disabled(!downloaded || !vm.canSelectQuality)
                        .help(!downloaded
                              ? "Download this tier's required components first."
                              : vm.selectQualityUnavailableReason
                                  ?? "Use \(descriptor.displayName) for new renders.")
                        .accessibilityIdentifier(descriptor.isDefault
                            ? "models.quality.default"
                            : "models.quality.best-fidelity")
                }
            }
            .frame(minHeight: ModelsQualityCardLayout.actionRowMinimumHeight)
        }
        .padding(15)
        .frame(
            maxWidth: .infinity,
            minHeight: ModelsQualityCardLayout.minimumHeight,
            alignment: .topLeading)
        .modifier(ModelsQualitySurfaceModifier(active: selected))
        .overlay(alignment: .topTrailing) {
            if downloaded {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(hex: 0xC3CCD4), Color(hex: 0x93A1AD)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.fxOnEmber)
                }
                .frame(width: 18, height: 18).padding(13)
            } else if selected {
                Text(vm.isLinkedReadOnly ? "Linked files missing" : "Not installed")
                    .fxMonoFont(9, weight: .semibold).foregroundStyle(tertiaryText)
                    .padding(.vertical, 3).padding(.horizontal, 7)
                    .fxThemedSurface(.inset, radius: 6)
                    .padding(11)
            } else if !downloaded {
                Text(vm.isLinkedReadOnly ? "Optional linked file missing" : "Optional install")
                    .fxMonoFont(9, weight: .semibold).foregroundStyle(tertiaryText)
                    .padding(.vertical, 3).padding(.horizontal, 7)
                    .fxThemedSurface(.inset, radius: 6)
                    .padding(11)
            }
        }
        .help(downloaded
              ? "\(vm.isLinkedReadOnly ? "Linked files verified." : "Installed files verified.") \(selected ? "Selected for new renders." : "Available to select.")"
              : "Download the required \(descriptor.displayName) component below.")
    }

    private func metricRow(_ label: String, _ value: String, labelColor: Color, valueColor: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(labelColor)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(valueColor)
        }
        .fxMonoFont(11, weight: .medium)
    }

    // MARK: Component rows (LIVE)

    private var componentRows: some View {
        VStack(spacing: 12) {
            if vm.components.isEmpty && vm.isRefreshing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking file sizes and checksums…")
                        .fxFont(12).foregroundStyle(secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(15)
                .fxThemedSurface(.card, radius: FxRadius.card)
            } else {
                ForEach(vm.components) { comp in
                    componentRow(comp)
                }
            }
        }
    }

    @ViewBuilder
    private func componentRow(_ comp: ComponentStatus) -> some View {
        let downloading = vm.downloadingIDs.contains(comp.id)
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                iconTile(for: comp.id)

                VStack(alignment: .leading, spacing: 2) {
                    Text(comp.title).fxFont(13.5, weight: .semibold).foregroundStyle(primaryText)
                    Text(subtitle(for: comp)).fxMonoFont(11, weight: .medium).foregroundStyle(tertiaryText)
                    Text(ModelComponentStatusPresentation.ownershipDetail(
                        for: comp.state,
                        linkedReadOnly: vm.isLinkedReadOnly))
                        .fxFont(10.5)
                        .foregroundStyle(tertiaryText)
                }

                Spacer(minLength: 0)

                if !downloading {
                    statusBadge(comp.state, linkedReadOnly: vm.isLinkedReadOnly)
                    trailingAction(comp)
                }
            }
            if downloading { downloadingRow(comp.id) }
        }
        .padding(15)
        .fxThemedSurface(.card, radius: FxRadius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.component.\(comp.id).row")
    }

    // Maket icons by component (SF has no serif "T", so draw it).
    @ViewBuilder
    private func iconTile(for id: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: FxRadius.field, style: .continuous).fill(Color.fxAccent.opacity(0.16))
            switch id {
            case "text-encoder":
                Text("T").font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(Color.fxAccent)
            case "vae":
                Image(systemName: "square.3.stack.3d").font(.system(size: 19)).foregroundStyle(Color.fxAccent)
            default:
                Image(systemName: "cube").font(.system(size: 19)).foregroundStyle(Color.fxAccent)
            }
        }
        .frame(width: 40, height: 40)
    }

    private func subtitle(for comp: ComponentStatus) -> String {
        let size = ByteFormat.string(comp.onDiskBytes > 0 ? comp.onDiskBytes : comp.expectedBytes)
        switch comp.id {
        case "text-encoder":   return "Qwen3-VL-4B · bf16 · \(size)"
        case "vae":            return "Qwen-Image · \(size)"
        case "dit-transformer":
            return "MMDiT 12.9B · Default mixed-4/8 · \(size)"
        case "dit-transformer-q8":
            return "MMDiT 12.9B · Best Fidelity q8 · \(size)"
        default:               return "\(comp.subtitle) · \(size)"
        }
    }

    @ViewBuilder
    private func statusBadge(_ state: ComponentState, linkedReadOnly: Bool) -> some View {
        let title = ModelComponentStatusPresentation.title(
            for: state,
            linkedReadOnly: linkedReadOnly)
        switch state {
        case .downloaded: badge(title, fg: .fxOk, bg: .fxOkSoft, border: Color.fxOk.opacity(0.30))
        case .partial:    badge(title, fg: .fxAccent, bg: .fxAccentSoft, border: .fxAccentLine)
        case .corrupted:  badge(title, fg: .fxDanger, bg: .fxDangerSoft, border: Color.fxDanger.opacity(0.35))
        case .missing:    badge(title, fg: .fxText3, bg: .fxInset, border: .fxBorder)
        }
    }

    private func badge(_ text: String, fg: Color, bg: Color, border: Color) -> some View {
        Text(text)
            .fxMonoFont(10.5, weight: .semibold).foregroundStyle(fg)
            .padding(.vertical, 3).padding(.horizontal, 9)
            .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(border, lineWidth: 1))
    }

    @ViewBuilder
    private func trailingAction(_ comp: ComponentStatus) -> some View {
        if vm.isLinkedReadOnly {
            Button { vm.revealComponent(id: comp.id) } label: {
                Label("Show source", systemImage: "folder")
                    .fxFont(11.5, weight: .semibold)
            }
            .buttonStyle(FxSecondaryButtonStyle(height: 32))
            .accessibilityIdentifier("models.component.\(comp.id).reveal")
            .help("Show this external read-only component in Finder. Twisterminigen will not delete linked files.")
        } else {
        switch comp.state {
        case .downloaded:
            Button { vm.requestDelete(id: comp.id) } label: {
                Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(tertiaryText)
                    .frame(width: 32, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!vm.canModifyModels)
            .accessibilityIdentifier("models.component.\(comp.id).delete")
            .help(vm.modifyModelsUnavailableReason
                  ?? "Remove this component's files from disk.")
        case .partial, .corrupted, .missing:
            // Every component can download at once (no cross-component disable) — the row
            // itself is only shown for components that AREN'T currently downloading.
            Button { vm.requestDownload(id: comp.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 12, weight: .semibold))
                    Text(actionTitle(for: comp.state)).fxFont(11.5, weight: .semibold)
                }
            }
            .buttonStyle(FxSecondaryButtonStyle(height: 32))
            .disabled(!vm.canModifyModels)
            .accessibilityIdentifier("models.component.\(comp.id).download")
            .help(vm.modifyModelsUnavailableReason
                  ?? "Download this component into the weights store — runs alongside any other downloads in progress.")
        }
        }
    }

    private func actionTitle(for state: ComponentState) -> String {
        switch state {
        case .downloaded: "Downloaded"
        case .partial: "Resume"
        case .corrupted: "Repair"
        case .missing: "Download"
        }
    }

    private func downloadingRow(_ id: String) -> some View {
        let frac = vm.progress[id] ?? 0
        let label = vm.progressLabel[id] ?? ""
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                FxDot(tone: .amber, live: true, size: 7)
                Text(label.isEmpty ? "downloading…" : label)
                    .fxMonoFont(11).foregroundStyle(secondaryText).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int((frac * 100).rounded()))%")
                    .fxMonoFont(11, weight: .bold).foregroundStyle(primaryText)
                Button("Cancel") { vm.cancelDownload(id: id) }
                    .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
                    .accessibilityIdentifier("models.component.\(id).cancel")
                    .help("Cancel this component download and preserve any resumable verified partial data.")
            }
            Meter(value: frac)
        }
    }
}

/// The current model tier has an accent shell in the original Dark appearance.
/// Glass keeps that state cue as a light accent over the shared material card.
private struct ModelsQualitySurfaceModifier: ViewModifier {
    let active: Bool

    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: FxRadius.card, style: .continuous)
        if theme == .dark, active {
            content
                .background(Color.fxAccent.opacity(0.10), in: shape)
                .overlay(shape.strokeBorder(Color.fxAccent.opacity(0.40), lineWidth: 1))
        } else {
            content
                .fxThemedSurface(.card, radius: FxRadius.card)
                .overlay(shape.fill(active ? Color.fxAccent.opacity(0.055) : Color.clear)
                    .allowsHitTesting(false))
                .overlay(shape.strokeBorder(
                    active ? Color.fxAccent.opacity(0.40) : Color.clear,
                    lineWidth: active ? 1 : 0))
        }
    }
}

private struct KreaLicenseReviewSheet: View {
    let onCancel: () -> Void
    let onAccept: () -> Void

    @State private var confirmsTerms = false
    @Environment(\.fxTheme) private var theme

    private var licenseText: String {
        guard let url = KreaLegal.bundledLicenseURL(),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return """
            The complete Krea 2 Community License is included in every release bundle and is also
            available from Krea at the link below. This development build could not locate its
            bundled copy.

            Key requirements include the Acceptable Use Policy, reasonable content filtering,
            content provenance where required, and a separate enterprise license for commercial
            use at or above the agreement's revenue threshold.
            """
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Krea 2 Community License")
                    .fxFont(22, weight: .bold)
                Text(KreaLegal.licenseIdentifier)
                    .fxMonoFont(11)
                    .foregroundStyle(theme == .glass ? FxGlassPalette.text3 : Color.fxText3)
            }

            Text(KreaLegal.localImplementationNotice)
                .fxFont(12)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(licenseText)
                    .fxMonoFont(11.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .accessibilityIdentifier("models.license-review.terms-scroll")
            .help("Scroll through the complete bundled Krea 2 Community License text.")
            .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.fxBorder, lineWidth: 1))

            HStack(spacing: 14) {
                Button("Official license") { NSWorkspace.shared.open(KreaLegal.licenseURL) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("models.license-review.official-license")
                    .help("Open the authoritative Krea 2 Community License source in the browser.")
                Button("Acceptable Use Policy") {
                    NSWorkspace.shared.open(KreaLegal.acceptableUsePolicyURL)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("models.license-review.acceptable-use-policy")
                .help("Open the authoritative Krea 2 Acceptable Use Policy in the browser.")
                Spacer()
            }

            Toggle(isOn: $confirmsTerms) {
                Text("I have read and agree to the Krea 2 Community License and Acceptable Use Policy, and I will review generated outputs before export or distribution.")
                    .fxFont(12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("models.license-review.agreement")
            .help("Confirm that you reviewed both Krea documents; this checkbox alone records no acceptance.")

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("models.license-review.cancel")
                    .help("Close without accepting the Krea 2 terms.")
                Button("Accept terms", action: onAccept)
                    .buttonStyle(FxPrimaryButtonStyle(height: 34))
                    .disabled(!confirmsTerms)
                    .help(confirmsTerms
                          ? "Record this exact local license acceptance."
                          : "Select the agreement checkbox before accepting the terms.")
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("models.license-review.accept")
            }
        }
        .padding(22)
        .frame(width: 760, height: 680)
        .fxPageBackground()
        .accessibilityIdentifier("models.license-review.sheet")
    }
}
