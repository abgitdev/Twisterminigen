import SwiftUI
import AppKit

// Gallery grid and detail sheet backed by the managed generation library.

enum GalleryToolbarLayout {
    /// Cyclonminigen's Gallery uses one compact 30 pt control rhythm throughout the header.
    static let controlHeight: CGFloat = 30
    static let controlSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 7
    static let searchMaximumWidth: CGFloat = 300
    static let previewSliderWidth: CGFloat = 72

    enum SelectionMode: Equatable {
        case entry
        case actions
    }

    enum ContextDeleteMode: Equatable {
        case single
        case selection(count: Int)
    }

    static func selectionMode(selectedCount: Int, isSelecting: Bool) -> SelectionMode {
        selectedCount > 0 || isSelecting ? .actions : .entry
    }

    static func contextDeleteMode(
        isItemSelected: Bool,
        selectedCount: Int
    ) -> ContextDeleteMode {
        isItemSelected && selectedCount > 1
            ? .selection(count: selectedCount)
            : .single
    }
}

private struct GalleryToolbarControlSurface: ViewModifier {
    let isActive: Bool
    var interactive = true
    @Environment(\.fxTheme) private var theme

    func body(content: Content) -> some View {
        content
            .frame(height: GalleryToolbarLayout.controlHeight)
            .fxThemedSurface(
                .card,
                radius: GalleryToolbarLayout.cornerRadius,
                bordered: false,
                interactive: interactive)
            .overlay(RoundedRectangle(cornerRadius: GalleryToolbarLayout.cornerRadius)
                .stroke(
                    isActive
                        ? Color.fxAccentLine
                        : (theme == .glass
                            ? FxGlassPalette.borderStrong
                            : Color.fxBorderStrong),
                    lineWidth: 1))
    }
}

struct GalleryFaithfulView: View {
    @Bindable var vm: GalleryViewModel
    @Bindable var localUpscaleVM: LocalUpscaleViewModel
    let onUseRecipe: (Generation) -> Void
    let onRemix: (Generation) async -> Bool
    let onSavePreset: (Generation) -> Void
    let onOpenExperiment: (ExperimentContext) -> Void

    @Environment(\.fxTheme) private var theme

    @State private var search = ""
    @State private var previewSize: Double = 0.55
    @State private var totalBytes: Int64 = 0
    @State private var modelFilter: GalleryModelFilter?
    @State private var captureFilter: GalleryCaptureFilter = .all
    @State private var favoritesOnly = false
    @State private var loraFilter: GalleryLoRAFilter = .all
    @State private var remixFilter: GalleryFeatureFilter = .all
    @State private var textModeFilter: GalleryFeatureFilter = .all
    @State private var spatialFilter: GalleryFeatureFilter = .all
    @State private var resolutionFilter: GalleryResolutionFilter?
    @State private var dateFilter: GalleryDateFilter = .all
    @State private var groupRuns = true
    @State private var selectionMode = false
    @State private var confirmBulkDelete = false
    @State private var compareRequest: GalleryCompareRequest?

    private let metaText = Color(hex: 0xDDE2E6)

    private var neutralControlStroke: Color {
        theme == .glass ? FxGlassPalette.borderStrong : Color.fxBorderStrong
    }

    private var filtered: [Generation] {
        let filters = GalleryFilters(
            search: search,
            model: modelFilter,
            capture: captureFilter,
            favoritesOnly: favoritesOnly,
            lora: loraFilter,
            remix: remixFilter,
            textMode: textModeFilter,
            spatial: spatialFilter,
            resolution: resolutionFilter,
            date: dateFilter)
        return vm.generations.filter { generation in
            filters.includes(generation, isFavorite: vm.isFavorite(generation))
        }
    }

    private var selectedVisible: [Generation] {
        vm.selectedGenerations(in: displayedGenerations)
    }

    private var galleryGroups: [GalleryGenerationGroup] {
        vm.groups(for: filtered, enabled: groupRuns)
    }

    private var displayedGenerations: [Generation] {
        galleryGroups.flatMap(\.generations)
    }

    private var visibleOrdinals: [UUID: Int] {
        displayedGenerations.enumerated().reduce(into: [:]) { result, pair in
            result[pair.element.id] = pair.offset + 1
        }
    }

    private var modelOptions: [GalleryModelFilter] {
        Array(Set(vm.generations.map {
            GalleryModelFilter(
                modelID: $0.recipe.model.modelID,
                variantID: $0.recipe.model.variantID)
        })).sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var loraOptions: [GalleryLoRAOption] {
        var options: [UUID: GalleryLoRAOption] = [:]
        for reference in vm.generations.flatMap(\.recipe.loras) {
            options[reference.managedID] = GalleryLoRAOption(
                managedID: reference.managedID,
                sha256: reference.sha256)
        }
        return options.values.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private var resolutionOptions: [GalleryResolutionFilter] {
        Array(Set(vm.generations.map {
            GalleryResolutionFilter(width: $0.width, height: $0.height)
        })).sorted {
            let leftPixels = $0.width * $0.height
            let rightPixels = $1.width * $1.height
            return leftPixels == rightPixels
                ? ($0.width, $0.height) < ($1.width, $1.height)
                : leftPixels < rightPixels
        }
    }

    // Preview slider (0…1) → grid cell min width.
    private var cellMin: CGFloat { 118 + CGFloat(previewSize) * 104 }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellMin, maximum: cellMin * 1.9), spacing: 14)]
    }

    var body: some View {
        let itemOrdinals = visibleOrdinals
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 14)

            if vm.generations.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noMatchState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(galleryGroups) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                if let title = group.title, let summary = group.summary {
                                    groupHeader(
                                        title: title,
                                        summary: summary)
                                }
                                LazyVGrid(columns: columns, spacing: 14) {
                                    ForEach(group.generations) { generation in
                                        if let visibleOrdinal = itemOrdinals[generation.id] {
                                            GalleryThumb(
                                                gen: generation,
                                                visibleOrdinal: visibleOrdinal,
                                                visible: displayedGenerations,
                                                selectionMode: selectionMode,
                                                vm: vm,
                                                metaText: metaText,
                                                onRequestBulkDelete: {
                                                    confirmBulkDelete = true
                                                })
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fxPageBackground()
        .task {
            let generations = await vm.reloadAndWait()
            totalBytes = await vm.totalBytes(for: generations)
        }
        .onChange(of: vm.generations) { _, gens in
            Task { totalBytes = await vm.totalBytes(for: gens) }
            if let modelFilter, !modelOptions.contains(modelFilter) {
                self.modelFilter = nil
            }
            if case .specific(let id) = loraFilter,
               !loraOptions.contains(where: { $0.managedID == id }) {
                loraFilter = .all
            }
            if let resolutionFilter, !resolutionOptions.contains(resolutionFilter) {
                self.resolutionFilter = nil
            }
        }
        .sheet(item: $vm.selected) { gen in
            GalleryDetailSheet(
                gen: gen,
                vm: vm,
                localUpscaleVM: localUpscaleVM,
                onUseRecipe: onUseRecipe,
                onRemix: onRemix,
                onSavePreset: onSavePreset,
                onOpenExperiment: onOpenExperiment)
        }
        .sheet(item: $compareRequest) { request in
            GalleryCompareSheet(request: request, vm: vm)
        }
        .sheet(isPresented: publicationReportIsPresented) {
            if let report = vm.publicationReport {
                GalleryPublicationReportSheet(
                    report: report,
                    onDone: vm.dismissPublicationReport)
            }
        }
        .confirmationDialog(
            "Permanently delete \(selectedVisible.count) images?",
            isPresented: $confirmBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedVisible.count) images", role: .destructive) {
                let targets = selectedVisible
                Task { _ = await vm.deleteSelected(targets) }
            }
            .help("Permanently delete every selected managed image and its private metadata.")
            .accessibilityIdentifier("gallery.bulk-delete.confirm")
            Button("Cancel", role: .cancel) {}
                .help("Keep every selected image in Gallery.")
                .accessibilityIdentifier("gallery.bulk-delete.cancel")
        } message: {
            Text("Each managed PNG, its private recipe sidecar, and cached thumbnail will be removed permanently. This cannot be undone.")
        }
        .alert(noticeTitle, isPresented: noticeIsPresented) {
            Button("OK", role: .cancel) {
                vm.errorMessage = nil
                vm.operationMessage = nil
            }
            .help("Dismiss this Gallery notice.")
            .accessibilityIdentifier("gallery.notice.ok")
        } message: {
            Text(vm.errorMessage ?? vm.operationMessage ?? "Unknown gallery result.")
        }
    }

    // MARK: Header

    private var header: some View {
        ScrollView(.horizontal) {
            HStack(spacing: GalleryToolbarLayout.controlSpacing) {
                galleryTitle
                galleryCountControl
                previewControl
                searchField
                favoritesFilterControl
                groupingControl
                filtersMenuControl
                contextualSelectionControls
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gallery.filters")
    }

    private var galleryTitle: some View {
        Text("Gallery")
            .fxFont(18, weight: .bold)
            .foregroundStyle(Color.fxText)
            .frame(height: GalleryToolbarLayout.controlHeight)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var galleryCountControl: some View {
        toolbarControlShell(isActive: false, interactive: false) {
            Text("\(vm.generations.count) image\(vm.generations.count == 1 ? "" : "s") · \(ByteFormat.string(totalBytes)) · showing \(filtered.count)")
                .fxMonoFont(10.5, weight: .medium)
                .foregroundStyle(Color.fxText3)
                .padding(.horizontal, 10)
                .frame(height: GalleryToolbarLayout.controlHeight)
        }
        .accessibilityLabel("\(vm.generations.count) Gallery images, showing \(filtered.count)")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(Color.fxText3)
                .accessibilityHidden(true)
            TextField("Search prompt, seed, or LoRA…", text: $search)
                .textFieldStyle(.plain)
                .fxFont(11.5).foregroundStyle(Color.fxText)
                .accessibilityLabel("Search gallery")
                .accessibilityIdentifier("gallery.search")
                .help("Search visible Gallery metadata by prompt, seed, LoRA, or lineage.")
        }
        .padding(.horizontal, 10)
        .frame(
            minWidth: 190,
            idealWidth: GalleryToolbarLayout.searchMaximumWidth,
            maxWidth: GalleryToolbarLayout.searchMaximumWidth)
        .frame(height: GalleryToolbarLayout.controlHeight)
        .fxThemedSurface(
            .card,
            radius: GalleryToolbarLayout.cornerRadius,
            bordered: false,
            interactive: true)
        .overlay(RoundedRectangle(cornerRadius: GalleryToolbarLayout.cornerRadius)
            .stroke(neutralControlStroke, lineWidth: 1))
    }

    private var modelFilterControl: some View {
        toolbarControlShell(isActive: modelFilter != nil) {
            Menu {
                Button { modelFilter = nil } label: {
                    menuChoice("All models", selected: modelFilter == nil)
                }
                .help("Show images from every model and variant.")
                .accessibilityIdentifier("gallery.filter.model.option.all")
                Divider()
                ForEach(Array(modelOptions.enumerated()), id: \.element.id) { optionIndex, option in
                    Button { modelFilter = option } label: {
                        menuChoice(option.label, selected: modelFilter == option)
                    }
                    .help("Show only images generated with \(option.label).")
                    .accessibilityIdentifier("gallery.filter.model.option.\(optionIndex + 1)")
                }
            } label: {
                filterLabel(
                    title: "Model",
                    systemImage: "cube",
                    isActive: modelFilter != nil)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .accessibilityLabel("Filter by model")
        .accessibilityIdentifier("gallery.filter.model")
        .accessibilityValue(modelFilter?.label ?? "All models")
        .help(modelFilter.map { "Showing \($0.label)." } ?? "Show every model and variant.")
    }

    private var captureFilterControl: some View {
        toolbarControlShell(isActive: captureFilter != .all) {
            Menu {
                ForEach(Array(GalleryCaptureFilter.allCases.enumerated()), id: \.element.id) { optionIndex, option in
                    Button { captureFilter = option } label: {
                        menuChoice(option.menuTitle, selected: captureFilter == option)
                    }
                    .help("Filter Gallery to \(option.menuTitle.lowercased()).")
                    .accessibilityIdentifier("gallery.filter.capture.option.\(optionIndex + 1)")
                }
            } label: {
                filterLabel(
                    title: captureFilter.controlTitle,
                    systemImage: "checkmark.seal",
                    isActive: captureFilter != .all)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .accessibilityLabel("Filter by recipe capture")
        .accessibilityIdentifier("gallery.filter.capture")
        .accessibilityValue(captureFilter.menuTitle)
        .help("Filter exact recipe captures and legacy records with inferred fields.")
    }

    private var favoritesFilterControl: some View {
        toolbarControlShell(isActive: favoritesOnly) {
            Button { favoritesOnly.toggle() } label: {
                filterLabel(
                    title: "Favorites",
                    systemImage: favoritesOnly ? "star.fill" : "star",
                    isActive: favoritesOnly,
                    showsChevron: false)
            }
            .buttonStyle(.plain)
        }
        .accessibilityLabel("Show favorites only")
        .accessibilityIdentifier("gallery.filter.favorites")
        .accessibilityValue(favoritesOnly ? "On" : "Off")
        .help(favoritesOnly ? "Showing favorite images only." : "Show favorite images only.")
    }

    private var groupingControl: some View {
        toolbarControlShell(isActive: groupRuns) {
            Button { groupRuns.toggle() } label: {
                filterLabel(
                    title: "Groups",
                    systemImage: "rectangle.grid.2x2",
                    isActive: groupRuns,
                    showsChevron: false)
            }
            .buttonStyle(.plain)
        }
        .accessibilityLabel("Group Batch and Queue Lab runs")
        .accessibilityIdentifier("gallery.grouping")
        .accessibilityValue(groupRuns ? "On" : "Off")
        .help(groupRuns
            ? "Batch and Queue Lab results are shown as grouped contact sheets."
            : "Show every result in one chronological grid.")
    }

    private var filtersMenuControl: some View {
        toolbarControlShell(isActive: secondaryFiltersAreActive) {
            Menu {
                Menu("Model") {
                    Button { modelFilter = nil } label: {
                        menuChoice("All models", selected: modelFilter == nil)
                    }
                    ForEach(Array(modelOptions.enumerated()), id: \.element.id) { optionIndex, option in
                        Button { modelFilter = option } label: {
                            menuChoice(option.label, selected: modelFilter == option)
                        }
                        .accessibilityIdentifier("gallery.filter.model.option.\(optionIndex + 1)")
                    }
                }

                Menu("Capture") {
                    ForEach(Array(GalleryCaptureFilter.allCases.enumerated()), id: \.element.id) { optionIndex, option in
                        Button { captureFilter = option } label: {
                            menuChoice(option.menuTitle, selected: captureFilter == option)
                        }
                        .accessibilityIdentifier("gallery.filter.capture.option.\(optionIndex + 1)")
                    }
                }

                Menu("LoRA") {
                    Button { loraFilter = .all } label: {
                        menuChoice("All LoRAs", selected: loraFilter == .all)
                    }
                    Button { loraFilter = .any } label: {
                        menuChoice("With any LoRA", selected: loraFilter == .any)
                    }
                    Button { loraFilter = .none } label: {
                        menuChoice("Without LoRA", selected: loraFilter == .none)
                    }
                    if !loraOptions.isEmpty {
                        Divider()
                        ForEach(Array(loraOptions.enumerated()), id: \.element.id) { optionIndex, option in
                            Button { loraFilter = .specific(option.managedID) } label: {
                                menuChoice(
                                    option.label,
                                    selected: loraFilter == .specific(option.managedID))
                            }
                            .accessibilityIdentifier("gallery.filter.lora.option.\(optionIndex + 1)")
                        }
                    }
                }

                featureFilterMenu(
                    title: "Remix",
                    accessibilityID: "gallery.filter.remix",
                    selection: $remixFilter)
                featureFilterMenu(
                    title: "Lettering",
                    accessibilityID: "gallery.filter.lettering",
                    selection: $textModeFilter)
                featureFilterMenu(
                    title: "Regional prompts",
                    accessibilityID: "gallery.filter.regional-prompts",
                    selection: $spatialFilter)

                Menu("Resolution") {
                    Button { resolutionFilter = nil } label: {
                        menuChoice("All resolutions", selected: resolutionFilter == nil)
                    }
                    ForEach(Array(resolutionOptions.enumerated()), id: \.element.id) { optionIndex, option in
                        Button { resolutionFilter = option } label: {
                            menuChoice(option.label, selected: resolutionFilter == option)
                        }
                        .accessibilityIdentifier("gallery.filter.resolution.option.\(optionIndex + 1)")
                    }
                }

                Menu("Date") {
                    ForEach(Array(GalleryDateFilter.allCases.enumerated()), id: \.element.id) { optionIndex, option in
                        Button { dateFilter = option } label: {
                            menuChoice(option.title, selected: dateFilter == option)
                        }
                        .accessibilityIdentifier("gallery.filter.date.option.\(optionIndex + 1)")
                    }
                }

                Divider()
                Button("Clear all filters", systemImage: "xmark.circle") {
                    resetFilters()
                }
                .disabled(!filtersAreActive)
            } label: {
                filterLabel(
                    title: activeSecondaryFilterCount == 0
                        ? "Filters"
                        : "Filters · \(activeSecondaryFilterCount)",
                    systemImage: "line.3.horizontal.decrease.circle",
                    isActive: secondaryFiltersAreActive)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .accessibilityLabel("Gallery filters")
        .accessibilityIdentifier("gallery.filters.menu")
        .accessibilityValue(activeSecondaryFilterCount == 0
            ? "No advanced filters"
            : "\(activeSecondaryFilterCount) active")
        .help("Filter by model, capture, LoRA, Remix, lettering, regions, resolution, or date.")
    }

    private func featureFilterMenu(
        title: String,
        accessibilityID: String,
        selection: Binding<GalleryFeatureFilter>
    ) -> some View {
        Menu(title) {
            ForEach(Array(GalleryFeatureFilter.allCases.enumerated()), id: \.element.id) { optionIndex, option in
                Button { selection.wrappedValue = option } label: {
                    menuChoice(
                        featureMenuTitle(option, feature: title),
                        selected: selection.wrappedValue == option)
                }
                .accessibilityIdentifier("\(accessibilityID).option.\(optionIndex + 1)")
            }
        }
    }

    private var loraFilterControl: some View {
        toolbarControlShell(isActive: loraFilter.isActive) {
            Menu {
                Button { loraFilter = .all } label: {
                    menuChoice("All LoRAs", selected: loraFilter == .all)
                }
                .help("Show images with any LoRA state.")
                .accessibilityIdentifier("gallery.filter.lora.option.all")
                Button { loraFilter = .any } label: {
                    menuChoice("With any LoRA", selected: loraFilter == .any)
                }
                .help("Show only images using at least one LoRA.")
                .accessibilityIdentifier("gallery.filter.lora.option.any")
                Button { loraFilter = .none } label: {
                    menuChoice("Without LoRA", selected: loraFilter == .none)
                }
                .help("Show only images without a LoRA.")
                .accessibilityIdentifier("gallery.filter.lora.option.none")
                if !loraOptions.isEmpty {
                    Divider()
                    ForEach(Array(loraOptions.enumerated()), id: \.element.id) { optionIndex, option in
                        Button { loraFilter = .specific(option.managedID) } label: {
                            menuChoice(
                                option.label,
                                selected: loraFilter == .specific(option.managedID))
                        }
                        .help("SHA-256 \(option.sha256)")
                        .accessibilityIdentifier("gallery.filter.lora.option.\(optionIndex + 1)")
                    }
                }
            } label: {
                filterLabel(
                    title: loraFilterTitle,
                    systemImage: "slider.horizontal.3",
                    isActive: loraFilter.isActive)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .accessibilityLabel("Filter by LoRA")
        .accessibilityIdentifier("gallery.filter.lora")
        .accessibilityValue(loraFilterAccessibilityValue)
        .help("Filter images by any, no, or one exact persisted LoRA reference.")
    }

    private func featureFilterControl(
        title: String,
        accessibilityID: String,
        systemImage: String,
        selection: Binding<GalleryFeatureFilter>
    ) -> some View {
        toolbarControlShell(isActive: selection.wrappedValue != .all) {
            Menu {
                ForEach(Array(GalleryFeatureFilter.allCases.enumerated()), id: \.element.id) { optionIndex, option in
                    Button { selection.wrappedValue = option } label: {
                        menuChoice(
                            featureMenuTitle(option, feature: title),
                            selected: selection.wrappedValue == option)
                    }
                    .help(featureMenuTitle(option, feature: title))
                    .accessibilityIdentifier("\(accessibilityID).option.\(optionIndex + 1)")
                }
            } label: {
                filterLabel(
                    title: featureControlTitle(selection.wrappedValue, feature: title),
                    systemImage: systemImage,
                    isActive: selection.wrappedValue != .all)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .accessibilityLabel("Filter by \(title)")
        .accessibilityIdentifier(accessibilityID)
        .accessibilityValue(featureMenuTitle(selection.wrappedValue, feature: title))
        .help("Filter Gallery by persisted \(title.lowercased()) recipe metadata.")
    }

    private var resolutionFilterControl: some View {
        toolbarControlShell(isActive: resolutionFilter != nil) {
            Menu {
                Button { resolutionFilter = nil } label: {
                    menuChoice("All resolutions", selected: resolutionFilter == nil)
                }
                .help("Show images at every resolution.")
                .accessibilityIdentifier("gallery.filter.resolution.option.all")
                if !resolutionOptions.isEmpty {
                    Divider()
                    ForEach(Array(resolutionOptions.enumerated()), id: \.element.id) { optionIndex, option in
                        Button { resolutionFilter = option } label: {
                            menuChoice(option.label, selected: resolutionFilter == option)
                        }
                        .help("Show only \(option.label) images.")
                        .accessibilityIdentifier("gallery.filter.resolution.option.\(optionIndex + 1)")
                    }
                }
            } label: {
                filterLabel(
                    title: resolutionFilter?.label ?? "Resolution",
                    systemImage: "aspectratio",
                    isActive: resolutionFilter != nil)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .accessibilityLabel("Filter by resolution")
        .accessibilityIdentifier("gallery.filter.resolution")
        .accessibilityValue(resolutionFilter?.label ?? "All resolutions")
        .help("Filter Gallery by exact persisted pixel dimensions.")
    }

    private var dateFilterControl: some View {
        toolbarControlShell(isActive: dateFilter != .all) {
            Menu {
                ForEach(Array(GalleryDateFilter.allCases.enumerated()), id: \.element.id) { optionIndex, option in
                    Button { dateFilter = option } label: {
                        menuChoice(option.title, selected: dateFilter == option)
                    }
                    .help("Show images in the \(option.title.lowercased()) date range.")
                    .accessibilityIdentifier("gallery.filter.date.option.\(optionIndex + 1)")
                }
            } label: {
                filterLabel(
                    title: dateFilter == .all ? "Date" : dateFilter.title,
                    systemImage: "calendar",
                    isActive: dateFilter != .all)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .accessibilityLabel("Filter by creation date")
        .accessibilityIdentifier("gallery.filter.date")
        .accessibilityValue(dateFilter.title)
        .help("Filter Gallery by local creation date.")
    }

    private var clearFiltersControl: some View {
        toolbarControlShell(isActive: filtersAreActive) {
            Button { resetFilters() } label: {
                toolbarActionLabel(
                    "Clear",
                    systemImage: "xmark.circle",
                    tone: filtersAreActive ? Color.fxAccent : Color.fxText3)
            }
            .buttonStyle(.plain)
        }
        .disabled(!filtersAreActive)
        .opacity(filtersAreActive ? 1 : 0.48)
        .accessibilityLabel("Clear gallery filters")
        .accessibilityIdentifier("gallery.filter.clear")
        .help(filtersAreActive
            ? "Clear search and every Gallery filter."
            : "Clear is unavailable because no Gallery filter is active.")
    }

    private var loraFilterTitle: String {
        switch loraFilter {
        case .all: return "LoRA"
        case .any: return "Any LoRA"
        case .none: return "No LoRA"
        case .specific(let id):
            return loraOptions.first(where: { $0.managedID == id })?.label ?? "Exact LoRA"
        }
    }

    private var loraFilterAccessibilityValue: String {
        switch loraFilter {
        case .all: return "All LoRAs"
        case .any: return "With any LoRA"
        case .none: return "Without LoRA"
        case .specific: return loraFilterTitle
        }
    }

    private func featureMenuTitle(
        _ filter: GalleryFeatureFilter,
        feature: String
    ) -> String {
        switch filter {
        case .all: return "All \(feature) results"
        case .included: return "With \(feature)"
        case .excluded: return "Without \(feature)"
        }
    }

    private func featureControlTitle(
        _ filter: GalleryFeatureFilter,
        feature: String
    ) -> String {
        switch filter {
        case .all: return feature
        case .included: return "\(feature) only"
        case .excluded: return "No \(feature)"
        }
    }

    private var filtersAreActive: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || modelFilter != nil
            || captureFilter != .all
            || favoritesOnly
            || loraFilter != .all
            || remixFilter != .all
            || textModeFilter != .all
            || spatialFilter != .all
            || resolutionFilter != nil
            || dateFilter != .all
    }

    private var secondaryFiltersAreActive: Bool {
        modelFilter != nil
            || captureFilter != .all
            || loraFilter != .all
            || remixFilter != .all
            || textModeFilter != .all
            || spatialFilter != .all
            || resolutionFilter != nil
            || dateFilter != .all
    }

    private var activeSecondaryFilterCount: Int {
        [
            modelFilter != nil,
            captureFilter != .all,
            loraFilter != .all,
            remixFilter != .all,
            textModeFilter != .all,
            spatialFilter != .all,
            resolutionFilter != nil,
            dateFilter != .all
        ].filter { $0 }.count
    }

    private func resetFilters() {
        search = ""
        modelFilter = nil
        captureFilter = .all
        favoritesOnly = false
        loraFilter = .all
        remixFilter = .all
        textModeFilter = .all
        spatialFilter = .all
        resolutionFilter = nil
        dateFilter = .all
    }

    @ViewBuilder
    private var contextualSelectionControls: some View {
        switch GalleryToolbarLayout.selectionMode(
            selectedCount: selectedVisible.count,
            isSelecting: selectionMode
        ) {
        case .entry:
            selectionEntryControl
        case .actions:
            selectionControls
        }
    }

    private var selectionEntryControl: some View {
        HStack(spacing: GalleryToolbarLayout.controlSpacing) {
            toolbarControlShell(isActive: false) {
                Button { selectionMode = true } label: {
                    toolbarActionLabel("Select", systemImage: "checkmark.circle")
                }
                .buttonStyle(.plain)
            }
            .disabled(filtered.isEmpty)
            .opacity(filtered.isEmpty ? 0.48 : 1)
            .help("Enter selection mode and choose Gallery images.")
            .accessibilityIdentifier("gallery.selection.enter")

            toolbarControlShell(isActive: false) {
                Button { selectionMode = true } label: {
                    toolbarActionLabel("Compare", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.plain)
            }
            .disabled(displayedGenerations.count < 2)
            .opacity(displayedGenerations.count < 2 ? 0.48 : 1)
            .help("Enter selection mode; choose exactly two images to compare.")
            .accessibilityIdentifier("gallery.selection.enter-compare")

            toolbarControlShell(isActive: false) {
                Button {
                    Task { _ = await vm.revealFolder() }
                } label: {
                    toolbarActionLabel("Open folder", systemImage: "folder")
                }
                .buttonStyle(.plain)
            }
            .help("Open the managed Gallery folder in Finder.")
            .accessibilityIdentifier("gallery.open-folder")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var selectionControls: some View {
        HStack(spacing: GalleryToolbarLayout.controlSpacing) {
            toolbarControlShell(isActive: true, interactive: false) {
                toolbarActionLabel(
                    "\(selectedVisible.count) selected",
                    systemImage: "checkmark.circle.fill",
                    tone: Color.fxAccent)
            }

            toolbarControlShell(isActive: false) {
                Button { vm.selectAll(displayedGenerations) } label: {
                    toolbarActionLabel("Select all", systemImage: "checkmark.circle")
                }
                .buttonStyle(.plain)
            }
                .keyboardShortcut("a", modifiers: [.command])
                .help("Select every image matching the current filters.")
                .accessibilityIdentifier("gallery.selection.select-all")

            if selectedVisible.count == 2 {
                toolbarControlShell(isActive: true) {
                    Button {
                        compareRequest = GalleryCompareRequest(
                            left: selectedVisible[0],
                            right: selectedVisible[1])
                    } label: {
                        toolbarActionLabel(
                            "Compare",
                            systemImage: "rectangle.split.2x1",
                            tone: Color.fxAccent)
                    }
                    .buttonStyle(.plain)
                }
                .help(compareUnavailableHelp)
                .accessibilityIdentifier("gallery.selection.compare")
            }

            toolbarControlShell(isActive: false) {
                Button { vm.exportPNGs(selectedVisible) } label: {
                    toolbarActionLabel("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
            .disabled(selectedVisible.isEmpty)
            .opacity(selectedVisible.isEmpty ? 0.48 : 1)
            .help("Export verified clean PNG copies without recipe metadata or overwriting existing files.")
            .accessibilityIdentifier("gallery.selection.export")

            toolbarControlShell(isActive: false) {
                Button { confirmBulkDelete = true } label: {
                    toolbarActionLabel(
                        "Delete",
                        systemImage: "trash",
                        tone: Color.fxDanger)
                }
                .buttonStyle(.plain)
            }
            .disabled(selectedVisible.isEmpty)
            .opacity(selectedVisible.isEmpty ? 0.48 : 1)
            .help("Permanently delete the selected managed images after confirmation.")
            .accessibilityIdentifier("gallery.selection.delete")

            toolbarControlShell(isActive: false) {
                Button {
                    vm.clearSelection()
                    selectionMode = false
                } label: {
                    toolbarActionLabel("Done", systemImage: "checkmark")
                }
                .buttonStyle(.plain)
            }
            .help("Clear the gallery selection.")
            .accessibilityIdentifier("gallery.selection.clear")
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gallery.selection")
    }

    private var compareUnavailableHelp: String {
        switch selectedVisible.count {
        case 0: "Compare is unavailable because no visible Gallery image is selected."
        case 1: "Select one more visible Gallery image to compare exactly two."
        case 2: "Compare the two selected images and every persisted recipe field."
        default: "Deselect \(selectedVisible.count - 2) image\(selectedVisible.count - 2 == 1 ? "" : "s") to compare exactly two."
        }
    }

    private func toolbarControlShell<Content: View>(
        isActive: Bool,
        interactive: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            content()
        }
        .fixedSize(horizontal: true, vertical: false)
        .modifier(GalleryToolbarControlSurface(
            isActive: isActive,
            interactive: interactive))
    }

    private func toolbarActionLabel(
        _ title: String,
        systemImage: String,
        tone: Color = Color.fxText2
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .fxFont(11.5, weight: .semibold)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 10)
        .frame(height: GalleryToolbarLayout.controlHeight)
    }

    private func groupHeader(
        title: String,
        summary: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: title == "Queue Lab"
                  ? "square.grid.3x3"
                  : "square.stack.3d.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.fxAccent)
            Text(title)
                .fxFont(12, weight: .bold)
                .foregroundStyle(Color.fxText2)
            Text(summary)
                .fxMonoFont(10.5, weight: .medium)
                .foregroundStyle(Color.fxText3)
            Spacer(minLength: 0)
        }
    }

    private func filterLabel(
        title: String,
        systemImage: String,
        isActive: Bool,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.fxAccent : Color.fxText3)
            Text(title)
                .fxFont(11.5, weight: .semibold)
                .foregroundStyle(isActive ? Color.fxAccent : Color.fxText2)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.fxText3)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: GalleryToolbarLayout.controlHeight)
    }

    @ViewBuilder
    private func menuChoice(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var previewControl: some View {
        toolbarControlShell(isActive: false) {
            HStack(spacing: 9) {
                Image(systemName: "photo")
                    .font(.system(size: 10)).foregroundStyle(Color.fxText3)
                    .accessibilityHidden(true)
                FxSlider(
                    value: $previewSize,
                    range: 0...1,
                    step: 0.05,
                    knob: 11,
                    track: 3,
                    accessibilityLabel: "Gallery thumbnail size",
                    accessibilityValue: "\(Int((previewSize * 100).rounded())) percent",
                    accessibilityID: "gallery.preview-size")
                    .frame(width: GalleryToolbarLayout.previewSliderWidth)
                    .help("Adjust gallery thumbnail size.")
                Image(systemName: "photo")
                    .font(.system(size: 14)).foregroundStyle(Color.fxText3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
        }
        .help("Adjust gallery thumbnail size.")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40)).foregroundStyle(Color.fxText3.opacity(0.7))
            Text("Nothing yet").fxFont(14, weight: .semibold).foregroundStyle(Color.fxText2)
            Text("Generate your first image on the Generate tab.")
                .fxFont(12).foregroundStyle(Color.fxText3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 8) {
            Text("No matches").fxFont(14, weight: .semibold).foregroundStyle(Color.fxText2)
            Text("No images match the current search and filters.")
                .fxFont(12).foregroundStyle(Color.fxText3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: {
                vm.publicationReport == nil
                    && (vm.errorMessage != nil || vm.operationMessage != nil)
            },
            set: {
                if !$0 {
                    vm.errorMessage = nil
                    vm.operationMessage = nil
                }
            })
    }

    private var publicationReportIsPresented: Binding<Bool> {
        Binding(
            get: { vm.selected == nil && vm.publicationReport != nil },
            set: { if !$0 { vm.dismissPublicationReport() } })
    }

    private var noticeTitle: String {
        vm.errorMessage == nil ? "Gallery" : "Gallery operation failed"
    }
}

struct GalleryPublicationReportSheet: View {
    let report: GalleryPublicationReport
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.title)
                        .fxFont(20, weight: .bold)
                        .foregroundStyle(Color.fxText)
                    Text(report.summary)
                        .fxFont(12)
                        .foregroundStyle(Color.fxText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .help("Close this destination-by-destination publication report.")
                    .accessibilityIdentifier("gallery.publication-report.done")
            }
            .padding(20)

            Divider().overlay(Color.fxBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(report.items) { item in
                        publicationRow(item)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 420, idealHeight: 560)
        .fxThemedSurface(.sheet, radius: FxRadius.sheet, bordered: false)
        .accessibilityIdentifier("gallery.publication-report")
    }

    private func publicationRow(_ item: GalleryPublicationReport.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(for: item.state))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tone(for: item.state))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(item.ordinal). \(item.role)")
                        .fxFont(12.5, weight: .semibold)
                        .foregroundStyle(Color.fxText)
                    Spacer(minLength: 8)
                    Text(item.state.headline)
                        .fxMonoFont(10.5, weight: .semibold)
                        .foregroundStyle(tone(for: item.state))
                }
                Text(item.destination.path)
                    .fxMonoFont(10.5)
                    .foregroundStyle(Color.fxText2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.state.detail)
                    .fxFont(11.5)
                    .foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .fxThemedSurface(.card, radius: 9, bordered: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gallery.publication-report.item.\(item.ordinal)")
    }

    private func symbol(for state: GalleryPublicationReport.State) -> String {
        switch state {
        case .publishedDurable: "checkmark.seal.fill"
        case .publishedDurabilityWarning: "exclamationmark.triangle.fill"
        case .failedBeforeVisibility: "xmark.octagon.fill"
        case .notConfirmed: "questionmark.diamond.fill"
        case .unattempted: "pause.circle.fill"
        }
    }

    private func tone(for state: GalleryPublicationReport.State) -> Color {
        switch state {
        case .publishedDurable: .fxOk
        case .publishedDurabilityWarning, .notConfirmed: .orange
        case .failedBeforeVisibility: .fxDanger
        case .unattempted: .fxText3
        }
    }
}

// MARK: - Grid cell (real thumbnail, hover meta)

private struct GalleryThumb: View {
    let gen: Generation
    let visibleOrdinal: Int
    let visible: [Generation]
    let selectionMode: Bool
    @Bindable var vm: GalleryViewModel
    let metaText: Color
    let onRequestBulkDelete: () -> Void
    @Environment(\.fxTheme) private var theme
    @State private var thumb: NSImage?
    @State private var failed = false
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .top) {
            Button { activate() } label: {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let thumb {
                            Image(nsImage: thumb).resizable().scaledToFill()
                        } else if failed {
                            Color.clear
                                .fxThemedSurface(.inset, radius: 0, bordered: false)
                                .overlay(Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(Color.fxText2))
                        } else {
                            Color.clear
                                .fxThemedSurface(.inset, radius: 0, bordered: false)
                                .overlay(ProgressView().controlSize(.small))
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if hover {
                            ZStack(alignment: .bottomLeading) {
                                LinearGradient(stops: [
                                    .init(color: Color(hex: 0x080A0D, alpha: 0.82), location: 0),
                                    .init(color: .clear, location: 0.5)
                                ], startPoint: .bottom, endPoint: .top)
                                Text(metadataLine)
                                    .fxMonoFont(9.5, weight: .medium).foregroundStyle(metaText)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.78)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 10).padding(.bottom, 9)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.fxAccent : neutralThumbStroke,
                            lineWidth: isSelected ? 2 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Gallery image \(visibleOrdinal)")
            .accessibilityIdentifier("gallery.item.\(visibleOrdinal).open")
            .help("Open image \(visibleOrdinal) details.")

            HStack {
                if selectionMode || hover || isSelected {
                    Button {
                        vm.updateSelection(
                            of: gen,
                            visible: visible,
                            command: true,
                            shift: false)
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.fxAccent : Color.white.opacity(0.88))
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Deselect image" : "Select image")
                    .accessibilityIdentifier("gallery.item.\(visibleOrdinal).selection")
                    .help(isSelected ? "Remove from selection." : "Add to selection.")
                }

                Spacer(minLength: 0)

                if hover || isFavorite {
                    Button { vm.toggleFavorite(gen) } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? Color.fxAccent : Color.white.opacity(0.88))
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                    .accessibilityIdentifier("gallery.item.\(visibleOrdinal).favorite")
                    .help(isFavorite ? "Remove from favorites." : "Add to favorites.")
                }
            }
            .padding(8)
        }
        .onHover { hover = $0 }
        .help("Image \(visibleOrdinal): \(gen.prompt)")
        .accessibilityLabel(isSelected ? "Selected gallery image" : "Gallery image")
        .accessibilityValue("\(gen.prompt), seed \(gen.seed), \(gen.width) by \(gen.height)")
        .onDrag { vm.dragProvider(for: gen) }
        .task(id: gen.id) {
            if let t = await vm.thumbnail(for: gen) { thumb = t; failed = false }
            else { failed = true }
        }
        .contextMenu {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                vm.toggleFavorite(gen)
            }
            .help(isFavorite ? "Remove image \(visibleOrdinal) from favorites." : "Add image \(visibleOrdinal) to favorites.")
            .accessibilityIdentifier("gallery.item.\(visibleOrdinal).context.favorite")
            Button(isSelected ? "Deselect" : "Add to Selection") {
                vm.updateSelection(
                    of: gen,
                    visible: visible,
                    command: true,
                    shift: false)
            }
            .help(isSelected ? "Remove image \(visibleOrdinal) from the current selection." : "Add image \(visibleOrdinal) to the current selection.")
            .accessibilityIdentifier("gallery.item.\(visibleOrdinal).context.selection")
            Divider()
            Button("Export Clean PNG…") { vm.exportPNG(gen) }
                .help("Review and export a verified clean PNG copy of image \(visibleOrdinal).")
                .accessibilityIdentifier("gallery.item.\(visibleOrdinal).context.export-clean")
            Button("Export with Recipe…") { vm.exportPNGWithRecipe(gen) }
                .help("Review and export image \(visibleOrdinal) with its portable recipe sidecar.")
                .accessibilityIdentifier("gallery.item.\(visibleOrdinal).context.export-recipe")
            Button("Show in Finder") { vm.revealInFinder(gen) }
                .help("Reveal the original stored PNG for image \(visibleOrdinal), without exporting a copy.")
                .accessibilityIdentifier("gallery.item.\(visibleOrdinal).context.reveal")
            Divider()
            switch contextDeleteMode {
            case .single:
                Button("Delete", role: .destructive) { vm.delete(gen) }
                    .help("Permanently delete image \(visibleOrdinal) and its private metadata.")
                    .accessibilityIdentifier("gallery.item.\(visibleOrdinal).context.delete")
            case .selection(let count):
                Button("Delete \(count) Selected…", role: .destructive) {
                    onRequestBulkDelete()
                }
                .help("Permanently delete all \(count) selected managed images after confirmation.")
                .accessibilityIdentifier("gallery.item.\(visibleOrdinal).context.delete-selection")
            }
        }
    }

    private var isSelected: Bool { vm.selectedIDs.contains(gen.id) }
    private var isFavorite: Bool { vm.isFavorite(gen) }
    private var contextDeleteMode: GalleryToolbarLayout.ContextDeleteMode {
        GalleryToolbarLayout.contextDeleteMode(
            isItemSelected: isSelected,
            selectedCount: vm.selectedGenerations(in: visible).count)
    }

    private var neutralThumbStroke: Color {
        if theme == .glass {
            return Color.white.opacity(hover ? 0.26 : 0.14)
        }
        return Color.white.opacity(hover ? 0.18 : 0.09)
    }

    private var metadataLine: String {
        let qa = gen.typographyQA.map { " · \($0.label)" } ?? ""
        let base = "seed \(shortSeed(gen.seed)) · \(gen.width)×\(gen.height) · \(gen.durationText)"
            + qa
        guard let provenance = gen.provenance else { return base }
        if let grid = provenance.queueLabGrid {
            return "S\(grid.seedIndex + 1) X\(grid.xIndex + 1) Y\(grid.yIndex + 1) · \(base)"
        }
        return "\(provenance.itemIndex + 1)/\(provenance.itemCount) · \(base)"
    }

    private func activate() {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        if command || shift {
            vm.updateSelection(
                of: gen,
                visible: visible,
                command: command,
                shift: shift)
        } else {
            vm.selected = gen
        }
    }

    private func shortSeed(_ seed: UInt64) -> String {
        let s = String(seed)
        return s.count > 6 ? String(s.prefix(6)) : s
    }
}

private struct GalleryCompareRequest: Identifiable {
    let id = UUID()
    let left: Generation
    let right: Generation
}

private struct GalleryCompareSheet: View {
    let request: GalleryCompareRequest
    @Bindable var vm: GalleryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fxTheme) private var theme
    @State private var leftImage: NSImage?
    @State private var rightImage: NSImage?
    @State private var leftFinished = false
    @State private var rightFinished = false

    private var comparison: GalleryRecipeComparison {
        GalleryRecipeComparison(left: request.left.recipe, right: request.right.recipe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Compare")
                        .fxFont(20, weight: .bold)
                        .foregroundStyle(Color.fxText)
                    Text("\(comparison.differenceCount) recipe difference\(comparison.differenceCount == 1 ? "" : "s")")
                        .fxFont(11.5)
                        .foregroundStyle(Color.fxText3)
                }
                Spacer(minLength: 0)
                Button("Close") { dismiss() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
                    .help("Close recipe comparison.")
                    .accessibilityIdentifier("gallery.compare.close")
            }
            .padding(20)

            HStack(spacing: 12) {
                compareImage(
                    leftImage,
                    finished: leftFinished,
                    generation: request.left,
                    label: "A")
                compareImage(
                    rightImage,
                    finished: rightFinished,
                    generation: request.right,
                    label: "B")
            }
            .padding(.horizontal, 20)

            Divider().overlay(Color.fxBorder).padding(.top, 16)

            ScrollView([.vertical, .horizontal]) {
                Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Field")
                        Text("A")
                        Text("B")
                    }
                    .fxFont(10.5, weight: .bold)
                    .foregroundStyle(Color.fxText3)

                    ForEach(comparison.rows) { row in
                        GridRow(alignment: .top) {
                            comparisonCell(row.label, emphasized: row.isDifferent, width: 126)
                            comparisonCell(row.left, emphasized: row.isDifferent, width: 350)
                            comparisonCell(row.right, emphasized: row.isDifferent, width: 350)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 820, idealWidth: 980, maxWidth: 1_080,
               minHeight: 650, idealHeight: 780, maxHeight: 900)
        .background(theme == .dark ? Color.fxSheet : Color.clear)
        .fxStandalonePageBackground()
        .task(id: request.id) {
            async let left = vm.image(for: request.left)
            async let right = vm.image(for: request.right)
            let images = await (left, right)
            guard !Task.isCancelled else { return }
            leftImage = images.0
            rightImage = images.1
            leftFinished = true
            rightFinished = true
        }
    }

    private func compareImage(
        _ image: NSImage?,
        finished: Bool,
        generation: Generation,
        label: String
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.24)
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(8)
            } else if finished {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Image unavailable").fxFont(11, weight: .semibold)
                }
                .foregroundStyle(Color.fxText2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(label)
                .fxMonoFont(11, weight: .bold)
                .foregroundStyle(Color.fxText)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(.black.opacity(0.58), in: Capsule())
                .padding(10)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.fxBorderStrong, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image \(label)")
        .accessibilityValue("\(generation.prompt), seed \(generation.seed)")
    }

    @ViewBuilder
    private func comparisonCell(
        _ text: String,
        emphasized: Bool,
        width: CGFloat
    ) -> some View {
        let cell = Text(text)
            .fxMonoFont(10.5, weight: emphasized ? .semibold : .regular)
            .foregroundStyle(emphasized ? Color.fxText : Color.fxText2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .topLeading)
            .frame(minHeight: 30, alignment: .topLeading)
            .padding(7)

        if emphasized {
            cell
                .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.fxAccentLine, lineWidth: 1))
        } else {
            cell.fxThemedSurface(.inset, radius: 6)
        }
    }
}

// MARK: - Detail sheet

enum GalleryDetailDisplayMode: Equatable {
    case preview
    case details

    var toggled: Self {
        self == .preview ? .details : .preview
    }
}

enum GalleryDetailLayout {
    static let defaultDisplayMode = GalleryDetailDisplayMode.preview
    static let collapsedPromptLineLimit = 4
    static let standardActionColumnCount = 4
    static let accessibilityActionColumnCount = 3
    static let accessibilityTextScaleThreshold = 150
    static let promptExpansionCharacterThreshold = 220
    static let collapsedPromptViewportHeight: CGFloat = 76
    static let expandedPromptViewportHeight: CGFloat = 148
    static let accessibilityCollapsedPromptViewportHeight: CGFloat = 108
    static let accessibilityExpandedPromptViewportHeight: CGFloat = 196

    static func promptNeedsExpansion(_ prompt: String) -> Bool {
        prompt.count > promptExpansionCharacterThreshold
            || prompt.filter(\.isNewline).count >= collapsedPromptLineLimit
    }

    static func promptLineLimit(for prompt: String, expanded: Bool) -> Int? {
        guard !expanded, promptNeedsExpansion(prompt) else { return nil }
        return collapsedPromptLineLimit
    }

    static func promptUsesScroll(for prompt: String, expanded: Bool) -> Bool {
        expanded && promptNeedsExpansion(prompt)
    }

    static func promptViewportHeight(
        for prompt: String,
        expanded: Bool,
        usesAccessibilityLayout: Bool
    ) -> CGFloat? {
        guard promptNeedsExpansion(prompt) else { return nil }
        switch (expanded, usesAccessibilityLayout) {
        case (false, false): return collapsedPromptViewportHeight
        case (true, false): return expandedPromptViewportHeight
        case (false, true): return accessibilityCollapsedPromptViewportHeight
        case (true, true): return accessibilityExpandedPromptViewportHeight
        }
    }

    static func actionColumnCount(usesStackedLayout: Bool) -> Int {
        usesStackedLayout ? accessibilityActionColumnCount : standardActionColumnCount
    }

    static func usesAccessibilityLayout(
        textScalePercent: Int,
        dynamicTypeIsAccessibility: Bool
    ) -> Bool {
        dynamicTypeIsAccessibility
            || textScalePercent >= accessibilityTextScaleThreshold
    }

    static func actionRowCount(for itemCount: Int, usesStackedLayout: Bool) -> Int {
        guard itemCount > 0 else { return 0 }
        let columns = actionColumnCount(usesStackedLayout: usesStackedLayout)
        return (itemCount + columns - 1) / columns
    }

    static func imageMinimumHeight(
        mode: GalleryDetailDisplayMode,
        usesAccessibilityLayout: Bool
    ) -> CGFloat {
        switch mode {
        case .preview:
            usesAccessibilityLayout ? 620 : 680
        case .details:
            usesAccessibilityLayout ? 260 : 300
        }
    }

    static func sheetIdealHeight(mode: GalleryDetailDisplayMode) -> CGFloat {
        mode == .preview ? 860 : 780
    }

    static func sheetMaximumHeight(mode: GalleryDetailDisplayMode) -> CGFloat {
        mode == .preview ? 960 : 860
    }
}

private struct GalleryDetailSheet: View {
    let gen: Generation
    @Bindable var vm: GalleryViewModel
    @Bindable var localUpscaleVM: LocalUpscaleViewModel
    let onUseRecipe: (Generation) -> Void
    let onRemix: (Generation) async -> Bool
    let onSavePreset: (Generation) -> Void
    let onOpenExperiment: (ExperimentContext) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppAccessibilityPreferences.self) private var accessibilityPreferences
    @State private var full: NSImage?
    @State private var missing = false
    @State private var confirmDelete = false
    @State private var isPreparingRemix = false
    @State private var showImageTools = false
    @State private var promptExpanded = false
    @State private var displayMode = GalleryDetailLayout.defaultDisplayMode

    var body: some View {
        VStack(spacing: 0) {
            imageArea
            if displayMode == .details {
                ScrollView {
                    infoArea
                }
                .frame(
                    minHeight: usesAccessibilityLayout ? 130 : 160,
                    idealHeight: usesAccessibilityLayout ? 180 : 220,
                    maxHeight: usesAccessibilityLayout ? 240 : 300)
                .clipped()
            }
            actionArea
        }
        .frame(
            minWidth: 760,
            idealWidth: 920,
            maxWidth: 1_040,
            minHeight: 700,
            idealHeight: GalleryDetailLayout.sheetIdealHeight(mode: displayMode),
            maxHeight: GalleryDetailLayout.sheetMaximumHeight(mode: displayMode))
        .fxThemedSurface(.sheet, radius: FxRadius.sheet, bordered: false)
        .overlay(RoundedRectangle(cornerRadius: FxRadius.sheet, style: .continuous)
            .strokeBorder(Color.fxBorderStrong, lineWidth: 1))
        .onChange(of: gen.id) {
            full = nil
            missing = false
            promptExpanded = false
        }
        .task(id: gen.id) {
            let img = await vm.image(for: gen)
            guard !Task.isCancelled else { return }
            full = img; missing = (img == nil)
        }
        .confirmationDialog("Delete this image?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await vm.deleteAndWait(gen) { dismiss() }
                }
            }
            .help("Permanently delete this managed image and its private metadata.")
            .accessibilityIdentifier("gallery.detail.delete-confirm")
            Button("Cancel", role: .cancel) {}
                .help("Keep this image in Gallery.")
                .accessibilityIdentifier("gallery.detail.delete-cancel")
        } message: {
            Text("Removed from disk immediately and permanently (no Trash).")
        }
        .alert("Gallery operation failed", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { vm.errorMessage = nil }
                .help("Dismiss this Gallery error.")
                .accessibilityIdentifier("gallery.detail.error-ok")
        } message: {
            Text(vm.errorMessage ?? "Unknown gallery error.")
        }
        .sheet(isPresented: publicationReportIsPresented) {
            if let report = vm.publicationReport {
                GalleryPublicationReportSheet(
                    report: report,
                    onDone: vm.dismissPublicationReport)
            }
        }
        .sheet(isPresented: $showImageTools) {
            GalleryImageToolsSheet(
                basePrompt: gen.prompt,
                sourceSize: LocalUpscalePixelSize(width: gen.width, height: gen.height),
                sourceGeneration: gen,
                loadProtectedExportRoots: { await vm.currentProtectedExportRoots() },
                localUpscaleVM: localUpscaleVM,
                loadPNGData: { try await vm.pngDataForImageTools(gen) },
                onUsePrompt: { prompt in
                    let updated = try gen.replacingPositivePrompt(prompt)
                    showImageTools = false
                    dismiss()
                    onUseRecipe(updated)
                })
        }
    }

    private var imageArea: some View {
        ZStack {
            Color.black.opacity(0.22)
            if let full {
                Image(nsImage: full).resizable().scaledToFit()
                    .padding(10)
                    .onDrag { vm.dragProvider(for: gen) }
                    .help("Drag a verified PNG copy into Finder or another app.")
                    .accessibilityLabel("Generated image preview")
                    .accessibilityValue(gen.prompt)
            } else if missing {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 24))
                    Text("Image file missing").fxFont(12, weight: .semibold)
                }.foregroundStyle(Color.fxText2)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(
            minHeight: GalleryDetailLayout.imageMinimumHeight(
                mode: displayMode,
                usesAccessibilityLayout: usesAccessibilityLayout),
            idealHeight: imageIdealHeight,
            maxHeight: imageMaximumHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.fxBorder, lineWidth: 1))
        .overlay(alignment: .leading) { navArrow(next: false) }
        .overlay(alignment: .trailing) { navArrow(next: true) }
        .padding(.horizontal, 20).padding(.top, 20)
    }

    @ViewBuilder private func navArrow(next: Bool) -> some View {
        if next ? vm.canSelectNext : vm.canSelectPrevious {
            Button { next ? vm.selectNext() : vm.selectPrevious() } label: {
                Image(systemName: next ? "chevron.right" : "chevron.left")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(14)
            .keyboardShortcut(next ? .rightArrow : .leftArrow, modifiers: [])
            .accessibilityLabel(next ? "Next image" : "Previous image")
            .accessibilityIdentifier(
                next ? "gallery.detail.overlay.next" : "gallery.detail.overlay.previous")
            .help(next ? "Show the next image." : "Show the previous image.")
        }
    }

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            promptSummary

            if let negativePrompt {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Negative prompt")
                        .fxFont(10.5, weight: .semibold)
                        .foregroundStyle(Color.fxText3)
                    Text(negativePrompt)
                        .fxFont(12)
                        .foregroundStyle(Color.fxText2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let exactText {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Visible text")
                        .fxFont(10.5, weight: .semibold)
                        .foregroundStyle(Color.fxText3)
                    Text(exactText)
                        .fxFont(12)
                        .foregroundStyle(Color.fxText2)
                        .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let qa = gen.typographyQA {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Label(
                            qa.label,
                            systemImage: qa.exactMatch
                                ? "checkmark.seal.fill"
                                : "text.magnifyingglass")
                            .fxFont(11, weight: .semibold)
                            .foregroundStyle(qa.exactMatch ? Color.fxAccent : Color.orange)
                        Text(qa.exactMatch ? "Requested lettering found" : "Review spelling")
                            .fxFont(10.5)
                            .foregroundStyle(Color.fxText3)
                    }
                    Text(qa.recognizedText.isEmpty
                         ? "Vision did not recognize readable text."
                         : "Vision read: \(qa.recognizedText)")
                        .fxMonoFont(10.5)
                        .foregroundStyle(Color.fxText2)
                        .textSelection(.enabled)
                }
                .padding(9)
                .fxThemedSurface(.inset, radius: 8)
            }

            captureSummary

            if let provenance = gen.provenance {
                provenanceSummary(provenance)
            }

            if gen.parentGenerationID != nil || !vm.childGenerations(of: gen).isEmpty {
                lineageSummary
            }

            LazyVGrid(columns: identityColumns, alignment: .leading, spacing: 10) {
                recipeFact(label: "Model", value: gen.recipe.model.modelID)
                    .help("Manifest \(gen.recipe.model.manifestHash)")
                recipeFact(label: "Variant", value: gen.recipe.model.variantID)
            }

            LazyVGrid(columns: factColumns, alignment: .leading, spacing: 10) {
                recipeFact(label: "Dimensions", value: "\(gen.width) × \(gen.height)")
                recipeFact(label: "Steps", value: String(gen.steps))
                recipeFact(label: "Seed", value: seedText)
                recipeFact(label: "CFG", value: concise(gen.recipe.sampler.guidance))
                recipeFact(label: "Precision", value: gen.recipe.sampler.precision.rawValue)
            }

            if let performance = gen.performance {
                performanceSummary(performance)
            }

            if hasAdvancedIndicators {
                advancedIndicators
            }

            Text("Created \(gen.createdAt.formatted(date: .abbreviated, time: .shortened)) · generated in \(gen.durationText)")
                .fxMonoFont(11, weight: .medium)
                .foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var promptSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Prompt", systemImage: "text.quote")
                    .fxFont(10.5, weight: .semibold)
                    .foregroundStyle(Color.fxText3)

                Spacer(minLength: 8)

                Button { vm.toggleFavorite(gen) } label: {
                    Image(systemName: vm.isFavorite(gen) ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(vm.isFavorite(gen) ? Color.fxAccent : Color.fxText2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vm.isFavorite(gen) ? "Remove from favorites" : "Add to favorites")
                .accessibilityIdentifier("gallery.detail.favorite")
                .help(vm.isFavorite(gen) ? "Remove from favorites." : "Add to favorites.")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(gen.prompt, forType: .string)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.on.square").font(.system(size: 11))
                        Text("Copy prompt").fxFont(11.5)
                    }.foregroundStyle(Color.fxText2)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Copy the positive prompt.")
                .accessibilityIdentifier("gallery.detail.copy-prompt")
            }

            promptText

            if GalleryDetailLayout.promptNeedsExpansion(gen.prompt) {
                Button(promptExpanded ? "Show less" : "Show full prompt") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        promptExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .fxFont(10.5, weight: .semibold)
                .foregroundStyle(Color.fxAccent)
                .accessibilityIdentifier("gallery.detail.prompt-expansion")
                .help(promptExpanded ? "Collapse the prompt preview." : "Show the complete prompt.")
            }
        }
        .padding(11)
        .fxThemedSurface(.inset, radius: 8, bordered: false)
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.fxBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var promptText: some View {
        if GalleryDetailLayout.promptUsesScroll(
            for: gen.prompt,
            expanded: promptExpanded
        ) {
            ScrollView(.vertical) {
                promptTextLabel
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(
                height: GalleryDetailLayout.promptViewportHeight(
                    for: gen.prompt,
                    expanded: true,
                    usesAccessibilityLayout: usesAccessibilityLayout))
            .scrollIndicators(.visible)
            .clipped()
            .accessibilityIdentifier("gallery.detail.prompt-scroll")
        } else if let lineLimit = GalleryDetailLayout.promptLineLimit(
            for: gen.prompt,
            expanded: promptExpanded
        ) {
            promptTextLabel
                .lineLimit(lineLimit, reservesSpace: true)
                .frame(
                    height: GalleryDetailLayout.promptViewportHeight(
                        for: gen.prompt,
                        expanded: false,
                        usesAccessibilityLayout: usesAccessibilityLayout),
                    alignment: .topLeading)
                .clipped()
        } else {
            promptTextLabel
        }
    }

    private var promptTextLabel: some View {
        Text(gen.prompt)
            .fxFont(12.5, weight: .medium)
            .foregroundStyle(Color.fxText)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var captureSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(captureTitle, systemImage: captureIcon)
                .fxFont(10.5, weight: .semibold)
                .foregroundStyle(captureColor)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(captureFill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(captureStroke, lineWidth: 1))
                .help(captureHelp)

            if gen.recipeCapture == .legacy {
                Text("Prompt, dimensions, steps, and seed came from the original record. Model and advanced fields were inferred during migration.")
                    .fxFont(11)
                    .foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var advancedIndicators: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 138), spacing: 8, alignment: .topLeading)],
            alignment: .leading,
            spacing: 8
        ) {
            if negativePrompt != nil {
                recipeIndicator(systemImage: "minus.circle", text: "Negative prompt")
            }
            if exactText != nil {
                recipeIndicator(systemImage: "textformat", text: "Lettering")
            }
            if !gen.recipe.loras.isEmpty {
                let scales = gen.recipe.loras.map { concise($0.scale) }.joined(separator: ", ")
                recipeIndicator(
                    systemImage: "slider.horizontal.3",
                    text: "\(gen.recipe.loras.count) LoRA\(gen.recipe.loras.count == 1 ? "" : "s") · \(scales)")
            }
            if !gen.recipe.regions.isEmpty {
                recipeIndicator(
                    systemImage: "rectangle.3.group",
                    text: "\(gen.recipe.regions.count) region\(gen.recipe.regions.count == 1 ? "" : "s")")
            }
            if let input = gen.recipe.inputImage {
                recipeIndicator(
                    systemImage: "photo.on.rectangle",
                    text: "Input image · \(concise(input.strength * 100))% · \(input.resize.rawValue)")
            }
        }
    }

    private func provenanceSummary(_ provenance: GenerationProvenance) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: provenance.kind == .queueLab
                      ? "square.grid.3x3"
                      : "square.stack.3d.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.fxAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provenance.kind == .queueLab
                         ? "Queue Lab result"
                         : "Batch result")
                        .fxFont(10.5, weight: .semibold)
                        .foregroundStyle(Color.fxText2)
                    Text(provenanceDetail(provenance))
                        .fxMonoFont(10.5, weight: .medium)
                        .foregroundStyle(Color.fxText3)
                    if let context = provenance.experimentContext {
                        Text(context.summary)
                            .fxMonoFont(10, weight: .medium)
                            .foregroundStyle(Color.fxText3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            if let context = provenance.experimentContext {
                experimentTable(context)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .fxThemedSurface(.inset, radius: 7, bordered: false)
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.fxBorder, lineWidth: 1))
    }

    private var lineageSummary: some View {
        let parentID = gen.parentGenerationID
        let parent = vm.parentGeneration(of: gen)
        let children = vm.childGenerations(of: gen)

        return VStack(alignment: .leading, spacing: 8) {
            Label("Remix lineage", systemImage: "point.3.connected.trianglepath.dotted")
                .fxFont(10.5, weight: .semibold)
                .foregroundStyle(Color.fxAccent)

            if let parentID {
                if let parent {
                    lineageButton(
                        title: "Parent",
                        generation: parent,
                        systemImage: "arrow.up.left",
                        accessibilityID: "gallery.detail.lineage.parent")
                } else {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.fxAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Parent is no longer in this Gallery")
                                .fxFont(10.5, weight: .semibold)
                                .foregroundStyle(Color.fxText2)
                            Text(parentID.uuidString)
                                .fxMonoFont(9.5, weight: .medium)
                                .foregroundStyle(Color.fxText3)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if !children.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(children.enumerated()), id: \.element.id) { childIndex, child in
                            lineageButton(
                                title: "Child",
                                generation: child,
                                systemImage: "arrow.down.right",
                                accessibilityID: "gallery.detail.lineage.child.\(childIndex + 1)")
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("\(children.count) Remix child\(children.count == 1 ? "" : "ren")")
                        .fxFont(10.5, weight: .semibold)
                        .foregroundStyle(Color.fxText2)
                }
                .accessibilityHint("Expands links to every direct Remix child.")
                .accessibilityIdentifier("gallery.detail.lineage.children")
                .help("Expand or collapse links to every direct Remix child.")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .fxThemedSurface(.inset, radius: 7, bordered: false)
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.fxAccentLine, lineWidth: 1))
    }

    private func lineageButton(
        title: String,
        generation: Generation,
        systemImage: String,
        accessibilityID: String
    ) -> some View {
        Button { _ = vm.selectGeneration(id: generation.id) } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.fxAccent)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(title) · seed \(generation.seed)")
                        .fxMonoFont(10, weight: .semibold)
                        .foregroundStyle(Color.fxText2)
                    Text(generation.prompt)
                        .fxFont(10.5)
                        .foregroundStyle(Color.fxText3)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.fxText3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(title.lowercased()) generation")
        .accessibilityValue("\(generation.prompt), seed \(generation.seed)")
        .help("Open this related image in Gallery.")
        .accessibilityIdentifier(accessibilityID)
    }

    private func performanceSummary(_ metrics: GenerationPerformanceMetrics) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: factColumns, alignment: .leading, spacing: 9) {
                    performanceFact("Text encoder", metrics.textEncoderSeconds)
                    performanceFact("DiT load", metrics.transformerLoadSeconds)
                    performanceFact("DiT denoise", metrics.denoisingSeconds)
                    if metrics.imageEncoderSeconds > 0 {
                        performanceFact("VAE encode", metrics.imageEncoderSeconds)
                    }
                    performanceFact("VAE decode", metrics.vaeDecodeSeconds)
                    performanceFact("Prepare", metrics.preparationSeconds)
                    performanceFact("PNG encode", metrics.pngEncodingSeconds)
                    performanceFact("Measured phases", metrics.measuredPhaseSeconds)
                }

                Divider().overlay(Color.fxBorder)

                LazyVGrid(columns: factColumns, alignment: .leading, spacing: 9) {
                    recipeFact(label: "Process peak", value: ByteFormat.string(metrics.processPeakBytes))
                    recipeFact(label: "MLX peak", value: ByteFormat.string(metrics.mlxPeakBytes))
                    recipeFact(label: "MLX active", value: ByteFormat.string(metrics.mlxActiveBytes))
                    recipeFact(label: "MLX cache", value: ByteFormat.string(metrics.mlxCacheBytes))
                    recipeFact(label: "Swap peak", value: ByteFormat.string(metrics.swapPeakBytes))
                    recipeFact(label: "Swap increase", value: ByteFormat.string(metrics.swapIncreaseBytes))
                    recipeFact(label: "Memory pressure", value: metrics.worstMemoryPressure.title)
                    recipeFact(
                        label: "Thermal worst",
                        value: GenerationPerformanceMetrics.thermalStateTitle(
                            metrics.worstThermalState))
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 10, weight: .semibold))
                Text(performanceTitle(metrics))
                    .fxFont(10.5, weight: .semibold)
            }
            .foregroundStyle(Color.fxAccent)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .fxThemedSurface(.inset, radius: 7, bordered: false)
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.fxBorder, lineWidth: 1))
        .accessibilityLabel(performanceTitle(metrics))
        .accessibilityValue(MetricAccessibilitySummary.performance(metrics))
        .accessibilityHint("Expands measured text encoder, DiT, VAE, and memory statistics.")
        .accessibilityIdentifier("gallery.detail.performance")
        .help("Expand or collapse measured generation performance and memory statistics.")
    }

    private func performanceFact(_ label: String, _ seconds: Double) -> some View {
        recipeFact(label: label, value: GenerationPerformanceMetrics.durationText(seconds))
    }

    private func performanceTitle(_ metrics: GenerationPerformanceMetrics) -> String {
        if metrics.scope == .plannedSession {
            return "Performance · session totals for \(metrics.sessionItemCount) images"
        }
        return "Performance · single image"
    }

    private func experimentTable(_ context: ExperimentContext) -> some View {
        let preview = try? context.preview()
        return DisclosureGroup {
            if let preview {
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        experimentRow(
                            index: "#",
                            seed: "SEED",
                            x: QueueLab.axisLabel(
                                context.configuration.xAxis,
                                in: context.sourceRecipe)?.uppercased() ?? "X",
                            y: QueueLab.axisLabel(
                                context.configuration.yAxis,
                                in: context.sourceRecipe)?.uppercased() ?? "Y",
                            isHeader: true)
                        Divider().overlay(Color.fxBorder)
                        ForEach(preview.entries) { entry in
                            experimentRow(
                                index: String(entry.index + 1),
                                seed: String(entry.seed),
                                x: entry.xValue?.displayText ?? "–",
                                y: entry.yValue?.displayText ?? "–",
                                isHeader: false)
                            if entry.index < preview.entries.count - 1 {
                                Divider().overlay(Color.fxBorder.opacity(0.6))
                            }
                        }
                    }
                    .frame(minWidth: 500)
                }
                .frame(maxHeight: 180)
                .modifier(GalleryExperimentSurfaceModifier())
            } else {
                Text("This experiment context cannot be opened by this app version.")
                    .fxFont(10.5)
                    .foregroundStyle(Color.fxDanger)
            }
        } label: {
            Text("Original experiment table\(preview.map { " · \($0.jobCount) cells" } ?? "")")
                .fxFont(10.5, weight: .semibold)
                .foregroundStyle(Color.fxAccent)
        }
        .accessibilityHint("Expands the original Queue Lab seed and axis table.")
        .accessibilityIdentifier("gallery.detail.experiment-table")
        .help("Expand or collapse the original Queue Lab seed and axis table.")
    }

    private func experimentRow(
        index: String,
        seed: String,
        x: String,
        y: String,
        isHeader: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Text(index).frame(width: 28, alignment: .trailing)
            Text(seed).frame(width: 126, alignment: .leading)
            Text(x).frame(width: 156, alignment: .leading).lineLimit(1)
            Text(y).frame(width: 156, alignment: .leading).lineLimit(1)
        }
        .fxMonoFont(
            isHeader ? 9 : 9.5,
            weight: isHeader ? .semibold : .medium)
        .foregroundStyle(isHeader ? Color.fxText3 : Color.fxText2)
        .padding(.horizontal, 7)
        .frame(height: isHeader ? 25 : 27)
    }

    private func provenanceDetail(_ provenance: GenerationProvenance) -> String {
        guard let grid = provenance.queueLabGrid else {
            return "Image \(provenance.itemIndex + 1) of \(provenance.itemCount)"
        }
        var fields = [
            "Image \(provenance.itemIndex + 1) of \(provenance.itemCount)",
            "seed \(grid.seedIndex + 1)/\(grid.seedCount)",
        ]
        if grid.xCount > 1 { fields.append("X \(grid.xIndex + 1)/\(grid.xCount)") }
        if grid.yCount > 1 { fields.append("Y \(grid.yIndex + 1)/\(grid.yCount)") }
        return fields.joined(separator: " · ")
    }

    private func recipeFact(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .fxFont(9.5, weight: .semibold)
                .foregroundStyle(Color.fxText3)
            Text(value)
                .fxMonoFont(11, weight: .medium)
                .foregroundStyle(Color.fxText2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func recipeIndicator(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.fxAccent)
            Text(text)
                .fxMonoFont(10.5, weight: .medium)
                .foregroundStyle(Color.fxText2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        .fxThemedSurface(.inset, radius: 6, bordered: false)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.fxBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var actionArea: some View {
        VStack(spacing: 10) {
            Divider().overlay(Color.fxBorder)

            HStack(spacing: 10) {
                Button { vm.selectPrevious() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(FxSecondaryButtonStyle(height: 32))
                .disabled(!vm.canSelectPrevious)
                .accessibilityLabel("Previous image")
                .help(vm.canSelectPrevious
                    ? "Show the previous image."
                    : "Previous is unavailable because this is the first visible Gallery image.")
                .accessibilityIdentifier("gallery.detail.previous")

                if let pos = vm.positionText(of: gen) {
                    Text(pos)
                        .fxMonoFont(11)
                        .foregroundStyle(Color.fxText3)
                        .fixedSize()
                }

                Button { vm.selectNext() } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(FxSecondaryButtonStyle(height: 32))
                .disabled(!vm.canSelectNext)
                .accessibilityLabel("Next image")
                .help(vm.canSelectNext
                    ? "Show the next image."
                    : "Next is unavailable because this is the last visible Gallery image.")
                .accessibilityIdentifier("gallery.detail.next")

                Spacer(minLength: 0)

                Button { vm.revealInFinder(gen) } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .lineLimit(1)
                }
                .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
                .fixedSize()
                .disabled(missing)
                .accessibilityLabel("Show original image in Finder")
                .accessibilityIdentifier("gallery.detail.show-in-finder")
                .help(missing
                    ? "Show in Finder is unavailable because this image file is missing."
                    : "Reveal the original stored PNG without exporting or modifying it.")

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        displayMode = displayMode.toggled
                    }
                } label: {
                    Label(
                        displayMode == .preview ? "Details" : "Large preview",
                        systemImage: displayMode == .preview
                            ? "info.circle"
                            : "arrow.up.left.and.arrow.down.right")
                        .lineLimit(1)
                }
                .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
                .fixedSize()
                .accessibilityLabel(
                    displayMode == .preview ? "Show image details" : "Show large image preview")
                .accessibilityIdentifier("gallery.detail.display-mode")
                .help(displayMode == .preview
                    ? "Show the prompt, exact recipe, and image actions."
                    : "Hide the inspector and use the available space for a much larger image preview.")

                if let context = gen.provenance?.experimentContext {
                    Button {
                        dismiss()
                        Task { @MainActor in
                            // Let the detail sheet begin dismissing before the root presents the
                            // restored Queue Lab editor.
                            await Task.yield()
                            onOpenExperiment(context)
                        }
                    } label: {
                        Label("Table", systemImage: "square.grid.3x3")
                            .lineLimit(1)
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
                    .fixedSize()
                    .disabled(isPreparingRemix)
                    .help(isPreparingRemix
                        ? "Open table is unavailable while the Remix source is being prepared."
                        : "Reopen the complete original Queue Lab table with the same source recipe, seeds, and axis values.")
                    .accessibilityLabel("Open table")
                    .accessibilityIdentifier("gallery.detail.open-table")
                }

                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark")
                        .lineLimit(1)
                }
                .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
                .fixedSize()
                .keyboardShortcut(.cancelAction)
                .help("Close image details.")
                .accessibilityIdentifier("gallery.detail.close")
            }

            if displayMode == .details {
                LazyVGrid(columns: actionColumns, spacing: 8) {
                    detailActionButtons
                }
                .accessibilityIdentifier("gallery.detail.actions")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    @ViewBuilder private var detailActionButtons: some View {
        Button {
            dismiss()
            onUseRecipe(gen)
        } label: {
            actionLabel("Use", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(FxPrimaryButtonStyle(height: actionButtonHeight))
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel("Use settings")
        .help("Load this recipe into Generate.")
        .accessibilityIdentifier("gallery.detail.use-settings")

        Button {
            dismiss()
            onSavePreset(gen)
        } label: {
            actionLabel("Preset", systemImage: "rectangle.stack.badge.plus")
        }
        .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
        .disabled(missing)
        .accessibilityLabel("Save as Preset")
        .help(missing
            ? "Save as Preset is unavailable because this image file is missing."
            : "Create an editable personal preset with this exact recipe and image cover.")
        .accessibilityIdentifier("gallery.detail.save-preset")

        Button {
            showImageTools = true
        } label: {
            actionLabel("Tools", systemImage: "wand.and.rays")
        }
        .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
        .disabled(missing || isPreparingRemix)
        .accessibilityLabel("Image tools")
        .accessibilityIdentifier("gallery.image-tools")
        .help(missing
            ? "Image tools are unavailable because this image file is missing."
            : (isPreparingRemix
                ? "Image tools are unavailable while the Remix source is being prepared."
                : "Open offline palette and Apple Vision foreground tools. Nothing runs until you choose an action."))

        Button {
            Task {
                isPreparingRemix = true
                let prepared = await onRemix(gen)
                isPreparingRemix = false
                if prepared { dismiss() }
            }
        } label: {
            if isPreparingRemix {
                ProgressView().controlSize(.mini)
                    .frame(maxWidth: .infinity)
            } else {
                actionLabel("Remix", systemImage: "shuffle")
            }
        }
        .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
        .disabled(isPreparingRemix || missing)
        .help(missing
            ? "Remix is unavailable because this image file is missing."
            : (isPreparingRemix
                ? "The Remix source is already being prepared."
                : "Use this verified image as a managed Remix source."))
        .accessibilityIdentifier("gallery.detail.remix")

        Button { vm.exportPNG(gen) } label: {
            actionLabel("PNG…", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
        .accessibilityLabel("Clean PNG…")
        .accessibilityIdentifier("gallery.export-review")
        .help("Save a verified PNG copy outside the managed library.")

        Button { vm.exportPNGWithRecipe(gen) } label: {
            actionLabel("Recipe…", systemImage: "doc.badge.plus")
        }
        .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
        .accessibilityLabel("Export with Recipe…")
        .help("Save a verified clean PNG and a portable .twisterrecipe sidecar.")
        .accessibilityIdentifier("gallery.detail.export-recipe")

        Button { vm.revealInFinder(gen) } label: {
            actionLabel("Reveal", systemImage: "folder")
        }
        .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
        .accessibilityLabel("Reveal original image in Finder")
        .help("Reveal the original stored PNG without exporting or modifying it.")
        .accessibilityIdentifier("gallery.detail.reveal")

        Button { confirmDelete = true } label: {
            actionLabel("Delete", systemImage: "trash")
                .foregroundStyle(Color.fxDanger)
        }
        .buttonStyle(FxSecondaryButtonStyle(height: actionButtonHeight))
        .accessibilityLabel("Delete image")
        .help("Delete this image permanently.")
        .accessibilityIdentifier("gallery.detail.delete")
    }

    private var actionColumns: [GridItem] {
        let minimumWidth: CGFloat = usesAccessibilityLayout ? 150 : 130
        return Array(
            repeating: GridItem(.flexible(minimum: minimumWidth), spacing: 8),
            count: GalleryDetailLayout.actionColumnCount(
                usesStackedLayout: usesAccessibilityLayout))
    }

    private var identityColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 220), spacing: 14, alignment: .topLeading)]
    }

    private var factColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 12, alignment: .topLeading)]
    }

    private var actionButtonHeight: CGFloat {
        usesAccessibilityLayout ? 40 : 32
    }

    private var imageIdealHeight: CGFloat {
        if displayMode == .preview {
            return usesAccessibilityLayout ? 700 : 760
        }
        return usesAccessibilityLayout ? 300 : 360
    }

    private var imageMaximumHeight: CGFloat {
        if displayMode == .preview { return .infinity }
        return usesAccessibilityLayout ? 360 : 420
    }

    private var usesAccessibilityLayout: Bool {
        GalleryDetailLayout.usesAccessibilityLayout(
            textScalePercent: accessibilityPreferences.textScalePercent,
            dynamicTypeIsAccessibility: dynamicTypeSize.isAccessibilitySize)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }

    private var negativePrompt: String? {
        let value = gen.recipe.prompts.negative
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private var exactText: String? {
        guard let value = gen.recipe.prompts.exactText else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private var hasAdvancedIndicators: Bool {
        negativePrompt != nil
            || exactText != nil
            || !gen.recipe.loras.isEmpty
            || !gen.recipe.regions.isEmpty
            || gen.recipe.inputImage != nil
    }

    private var seedText: String {
        switch gen.recipe.sampler.seed {
        case .random: return "Random"
        case .fixed(let seed): return String(seed)
        }
    }

    private var captureTitle: String {
        gen.recipeCapture == .exact ? "Exact recipe capture" : "Legacy · inferred fields"
    }

    private var captureIcon: String {
        gen.recipeCapture == .exact ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var captureColor: Color {
        gen.recipeCapture == .exact ? Color.fxOk : Color.fxAccent
    }

    private var captureFill: Color {
        gen.recipeCapture == .exact ? Color.fxOkSoft : Color.fxAccentSoft
    }

    private var captureStroke: Color {
        gen.recipeCapture == .exact ? Color.fxOk.opacity(0.35) : Color.fxAccentLine
    }

    private var captureHelp: String {
        if gen.recipeCapture == .exact {
            return "Every recipe field was captured when this image was generated."
        }
        return "This older record preserved its scalar settings; missing recipe fields were inferred during migration."
    }

    private func concise(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { vm.publicationReport == nil && vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } })
    }

    private var publicationReportIsPresented: Binding<Bool> {
        Binding(
            get: { vm.publicationReport != nil },
            set: { if !$0 { vm.dismissPublicationReport() } })
    }
}

/// The experiment table used a one-off translucent workspace fill in Dark.
/// Keep that exact composition there while giving Glass a real log surface.
private struct GalleryExperimentSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .glass {
            content.fxThemedSurface(.log, radius: 5, bordered: false)
        } else {
            content.background(
                Color.fxBg.opacity(0.35),
                in: RoundedRectangle(cornerRadius: 5))
        }
    }
}
