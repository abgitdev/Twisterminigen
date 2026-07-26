import AppKit
import SwiftUI

struct StorageManagerView: View {
    let manager: StorageManager
    let deletionDisabled: Bool
    let onStorageChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fxTheme) private var theme

    @State private var snapshot: StorageSnapshot?
    @State private var plan: StorageDeletionPlan?
    @State private var selectedOption = StorageDeletionOption.clearCache
    @State private var preserveUserResults = true
    @State private var confirmedDuplicateRoots = Set<URL>()
    @State private var exportBeforeDeletion = true
    @State private var lastExport: StorageExportResult?
    @State private var isWorking = false
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var confirmsDeletion = false
    @AppStorage("storage.quarantine.maximumAgeDays")
    private var quarantineMaximumAgeDays = QuarantineRetentionPolicy.defaultMaximumAgeDays
    @AppStorage("storage.quarantine.maximumGB")
    private var quarantineMaximumGB =
        Double(QuarantineRetentionPolicy.defaultMaximumBytes) / 1_073_741_824

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let snapshot {
                        categoryGrid(snapshot)
                        duplicatePanel(snapshot)
                        expectedLocationsPanel(snapshot)
                        quarantinePanel
                        deletionWizard(snapshot)
                    } else {
                        ProgressView("Scanning app storage…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 650, idealHeight: 760)
        .background(theme == .glass ? Color.fxOpaqueBg : Color.fxBg)
        .task { await refresh() }
        .alert("Delete the exact dry-run selection?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await exportThenDelete() }
            }
        } message: {
            if let plan {
                Text(deletionConfirmationMessage(for: plan))
            }
        }
        .alert(
            "Storage Manager",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Storage Manager")
                    .fxFont(20, weight: .bold)
                Text("Inventory, exact dry-run, export, and complete removal")
                    .fxFont(11.5)
                    .foregroundStyle(Color.fxText3)
            }
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button("Rescan") { Task { await refresh() } }
                .disabled(isWorking)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
    }

    private func categoryGrid(_ snapshot: StorageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            storageCaps("Storage overview")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 205), spacing: 10)],
                spacing: 10
            ) {
                ForEach(snapshot.categories) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.category.title)
                                .fxFont(12, weight: .semibold)
                            Text("\(item.fileCount) files")
                                .fxMonoFont(10.5)
                                .foregroundStyle(Color.fxText3)
                        }
                        Spacer()
                        Text(ByteFormat.string(item.bytes))
                            .fxMonoFont(11.5, weight: .semibold)
                    }
                    .padding(11)
                    .fxThemedSurface(.card, radius: 9)
                }
            }
        }
    }

    @ViewBuilder
    private func duplicatePanel(_ snapshot: StorageSnapshot) -> some View {
        if !snapshot.possibleModelDuplicates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Possible duplicate models — review required", systemImage: "exclamationmark.triangle.fill")
                    .fxFont(12.5, weight: .bold)
                    .foregroundStyle(Color.fxDanger)
                Text(
                    "Matching file inventories are never deleted automatically. "
                    + "Review each path and explicitly allow a copy only if you want it included in the dry-run.")
                    .fxFont(11.5)
                    .foregroundStyle(Color.fxText2)

                ForEach(snapshot.possibleModelDuplicates) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "\(group.installations.count) possible copies · "
                            + "\(ByteFormat.string(group.bytesPerCopy)) each")
                            .fxMonoFont(11, weight: .semibold)
                        ForEach(group.installations) { installation in
                            Toggle(
                                isOn: duplicateConfirmationBinding(for: installation.root)
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(abbreviate(installation.root))
                                        .fxMonoFont(10.5)
                                        .textSelection(.enabled)
                                    Text(
                                        installation.isSelected
                                            ? "Selected model — keep recommended"
                                            : "Allow this possible duplicate to be included")
                                        .fxFont(10.5)
                                        .foregroundStyle(Color.fxText3)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(10)
                    .background(Color.fxDanger.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(13)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.fxDanger.opacity(0.45), lineWidth: 1))
        }
    }

    private func expectedLocationsPanel(_ snapshot: StorageSnapshot) -> some View {
        DisclosureGroup("Expected macOS locations") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(snapshot.expectedLocations) { location in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: location.exists ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(location.exists ? Color.fxOk : Color.fxText3)
                        Text(location.kind.title)
                            .fxFont(11, weight: .semibold)
                            .frame(width: 150, alignment: .leading)
                        Text(abbreviate(location.url))
                            .fxMonoFont(10)
                            .foregroundStyle(Color.fxText3)
                            .textSelection(.enabled)
                        Spacer()
                        if location.fileCount > 0 {
                            Text("\(location.fileCount) · \(ByteFormat.string(location.bytes))")
                                .fxMonoFont(10)
                        }
                    }
                }
            }
            .padding(.top, 9)
        }
        .fxFont(12, weight: .semibold)
        .padding(13)
        .fxThemedSurface(.card, radius: 10)
    }

    private var quarantinePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            storageCaps("Quarantine retention")
            HStack(spacing: 14) {
                Stepper(
                    "Keep up to \(quarantineMaximumAgeDays) days",
                    value: $quarantineMaximumAgeDays,
                    in: 0...365)
                HStack(spacing: 7) {
                    Text("Limit")
                    TextField(
                        "GB",
                        value: $quarantineMaximumGB,
                        format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 62)
                    Text("GB")
                }
                Spacer()
                Button("Apply now") { Task { await enforceRetention() } }
                    .disabled(isWorking)
            }
            .fxFont(11.5)
            Text("Oldest quarantine files are removed first after the age limit is applied.")
                .fxFont(10.5)
                .foregroundStyle(Color.fxText3)
        }
        .padding(13)
        .fxThemedSurface(.card, radius: 10)
    }

    private func deletionWizard(_ snapshot: StorageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            storageCaps("Deletion wizard")
            Picker("Action", selection: $selectedOption) {
                ForEach(StorageDeletionOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .onChange(of: selectedOption) { _, _ in invalidatePlan() }

            Text(selectedOption.detail)
                .fxFont(11.5)
                .foregroundStyle(Color.fxText2)

            if selectedOption == .fullReset {
                Toggle("Keep user Gallery results", isOn: $preserveUserResults)
                    .toggleStyle(.checkbox)
                    .onChange(of: preserveUserResults) { _, _ in invalidatePlan() }
                Text(
                    "When enabled, generated images, recipes, and Gallery annotations are excluded "
                    + "from the reset. Thumbnails can be regenerated and are still removed.")
                    .fxFont(10.5)
                    .foregroundStyle(Color.fxText3)
            }

            Toggle("Export selected files before deletion", isOn: $exportBeforeDeletion)
                .toggleStyle(.checkbox)

            if selectedOption == .deleteUnusedModels {
                Text(
                    "\(snapshot.unusedModels.count) unselected managed installation"
                    + (snapshot.unusedModels.count == 1 ? "" : "s")
                    + " currently eligible. Possible duplicates remain protected.")
                    .fxMonoFont(10.5)
                    .foregroundStyle(Color.fxText3)
            }

            HStack {
                Button("Calculate exact dry-run") { Task { await calculatePlan() } }
                    .disabled(isWorking)
                Spacer()
                if let plan {
                    Text("\(plan.fileCount) files · \(ByteFormat.string(plan.bytes))")
                        .fxMonoFont(12, weight: .bold)
                        .foregroundStyle(plan.fileCount == 0 ? Color.fxText3 : Color.fxAccent)
                }
            }

            if let plan {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plan.categoryCounts) { category in
                        HStack {
                            Text(category.category.title)
                            Spacer()
                            Text("\(category.fileCount) · \(ByteFormat.string(category.bytes))")
                                .fxMonoFont(10.5)
                        }
                    }
                    if !plan.protectedDuplicateRoots.isEmpty {
                        Label(
                            "\(plan.protectedDuplicateRoots.count) possible model duplicate"
                                + (plan.protectedDuplicateRoots.count == 1 ? "" : "s")
                                + " protected",
                            systemImage: "lock.shield")
                            .foregroundStyle(Color.fxDanger)
                    }
                    if !plan.refusedRoots.isEmpty {
                        Label(
                            "Deletion blocked: one or more roots are not proven app-owned.",
                            systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(Color.fxDanger)
                        ForEach(plan.refusedRoots, id: \.path) { root in
                            Text(root.path)
                                .fxMonoFont(9.5)
                                .textSelection(.enabled)
                        }
                    }
                }
                .fxFont(11)
                .padding(10)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                DisclosureGroup("Verified deletion roots") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(plan.cleanupRoots, id: \.path) { root in
                            Text(root.path)
                                .fxMonoFont(9.5)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .fxFont(11)

                DisclosureGroup("Exact file list (\(plan.fileCount))") {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(plan.files) { item in
                            Text(item.url.path)
                                .fxMonoFont(9.5)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .fxFont(11)

                Button("Continue to deletion…", role: .destructive) {
                    confirmsDeletion = true
                }
                .disabled(!plan.canExecute || deletionDisabled || isWorking)
                .help(
                    deletionDisabled
                        ? "Wait for the current model or render operation to finish."
                        : "Review and confirm the exact dry-run.")
            }
        }
        .padding(13)
        .fxThemedSurface(.card, radius: 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let status {
                Text(status)
                    .fxFont(11)
                    .foregroundStyle(Color.fxText2)
                    .lineLimit(2)
            } else {
                Text("No files are removed until an exact dry-run is confirmed.")
                    .fxFont(11)
                    .foregroundStyle(Color.fxText3)
            }
            Spacer()
            if let lastExport {
                Button("Show last export") {
                    NSWorkspace.shared.activateFileViewerSelecting([lastExport.root])
                }
            }
        }
        .padding(14)
    }

    private func deletionConfirmationMessage(for plan: StorageDeletionPlan) -> String {
        let recovery = exportBeforeDeletion
            ? "An export will be completed first."
            : "No recovery export will be created."
        let roots = plan.cleanupRoots.map(\.path).joined(separator: "\n")
        return "\(plan.fileCount) files · \(ByteFormat.string(plan.bytes)). "
            + "Verified roots:\n\(roots)\n\(recovery)"
    }

    private func refresh() async {
        isWorking = true
        defer { isWorking = false }
        snapshot = await manager.scan()
        plan = nil
    }

    private func calculatePlan() async {
        isWorking = true
        defer { isWorking = false }
        let request = StorageDeletionRequest(
            option: selectedOption,
            preserveUserResults: preserveUserResults,
            confirmedDuplicateRoots: confirmedDuplicateRoots)
        plan = await manager.dryRun(request)
        status = plan.map {
            if !$0.refusedRoots.isEmpty {
                return "Dry-run blocked: \($0.refusedRoots.count) root(s) are not proven app-owned."
            }
            return "Dry-run complete: \($0.fileCount) files, \(ByteFormat.string($0.bytes))."
        }
    }

    private func exportThenDelete() async {
        guard let plan, plan.canExecute else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if exportBeforeDeletion {
                guard let parent = chooseExportFolder() else {
                    status = "Deletion cancelled before export."
                    return
                }
                let exported = try await manager.export(plan: plan, to: parent)
                lastExport = exported
                status = "Exported \(exported.fileCount) files to \(exported.root.lastPathComponent)."
            }
            let result = await manager.execute(plan: plan)
            await onStorageChanged()
            snapshot = await manager.scan()
            self.plan = nil
            status = "Deleted \(result.deletedFiles) files · \(ByteFormat.string(result.deletedBytes))."
            if !result.failedPaths.isEmpty {
                errorMessage =
                    "\(result.failedPaths.count) files changed or could not be removed and were left in place."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func enforceRetention() async {
        isWorking = true
        defer { isWorking = false }
        let result = await manager.enforceQuarantineRetention(
            QuarantineRetentionPolicy(
                maximumBytes: Int64(max(0, quarantineMaximumGB) * 1_073_741_824),
                maximumAgeDays: quarantineMaximumAgeDays))
        snapshot = await manager.scan()
        plan = nil
        status =
            "Quarantine: removed \(result.deletedFiles) files · "
            + "\(ByteFormat.string(result.deletedBytes)); "
            + "\(ByteFormat.string(result.remainingBytes)) remains."
    }

    private func duplicateConfirmationBinding(for root: URL) -> Binding<Bool> {
        Binding(
            get: { confirmedDuplicateRoots.contains(root) },
            set: { allowed in
                if allowed {
                    confirmedDuplicateRoots.insert(root)
                } else {
                    confirmedDuplicateRoots.remove(root)
                }
                invalidatePlan()
            })
    }

    private func invalidatePlan() {
        plan = nil
        status = nil
        lastExport = nil
    }

    private func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the recovery export"
        panel.message = "Storage Manager creates a dated export folder here before deleting."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func storageCaps(_ value: String) -> some View {
        Text(value.uppercased())
            .fxFont(10.5, weight: .semibold)
            .tracking(0.5)
            .foregroundStyle(Color.fxText3)
    }
}
