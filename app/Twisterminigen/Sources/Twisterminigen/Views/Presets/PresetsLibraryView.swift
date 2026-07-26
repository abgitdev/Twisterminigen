import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PresetLibraryActionError: LocalizedError {
    case queueCallbackUnavailable

    var errorDescription: String? {
        switch self {
        case .queueCallbackUnavailable:
            return "Queue integration is unavailable in this window."
        }
    }
}

struct PresetCreationRequest: Identifiable, Sendable {
    let id: UUID
    let draft: PresetCardDraft
    let coverData: Data
}

struct PresetsLibraryView: View {
    let store: PresetLibraryStore
    let gallery: GalleryViewModel
    let makeNewDraft: () -> PresetCardDraft
    let onApply: (GenerationRecipe) async throws -> Void
    var onAddToQueue: (GenerationRecipe) async throws -> Void = { _ in
        throw PresetLibraryActionError.queueCallbackUnavailable
    }
    @Binding var creationRequest: PresetCreationRequest?

    @Environment(\.fxTheme) private var theme
    @State private var categories: [PresetCategory] = BuiltinPresetCatalog.categories
    @State private var cards: [PresetCard] = []
    @State private var selectedCategoryID: String?
    @State private var editor: PresetEditorInput?
    @State private var cardToDelete: PresetCard?
    @State private var categoryToDelete: PresetCategory?
    @State private var showCategoryCreator = false
    @State private var confirmDeleteEverything = false
    @State private var errorMessage: String?
    @State private var isApplyingID: String?
    @State private var isAddingToQueueID: String?
    @State private var favoriteIDs: Set<String> = []
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var didPresentStartupWarning = false

    private var filteredCards: [PresetCard] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = cards.filter { card in
            let matchesCategory = selectedCategoryID.map { card.categoryID == $0 } ?? true
            let matchesFavorite = !favoritesOnly || favoriteIDs.contains(card.id)
            let categoryTitle = categories.first(where: { $0.id == card.categoryID })?.title ?? ""
            let matchesSearch = query.isEmpty || [
                card.title,
                card.summary,
                card.recipe.prompts.positive,
                card.recipe.prompts.negative,
                categoryTitle,
                card.id,
            ].contains { $0.lowercased().contains(query) }
            return matchesCategory && matchesFavorite && matchesSearch
        }
        return filtered.sorted { lhs, rhs in
            let categoryOrder = categories.firstIndex(where: { $0.id == lhs.categoryID }) ?? .max
            let otherCategoryOrder = categories.firstIndex(where: { $0.id == rhs.categoryID }) ?? .max
            if categoryOrder != otherCategoryOrder { return categoryOrder < otherCategoryOrder }
            if lhs.origin != rhs.origin { return lhs.origin == .builtIn }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var grid: [GridItem] {
        [GridItem(.adaptive(minimum: 224, maximum: 316), spacing: 16, alignment: .top)]
    }

    private var selectedCategory: PresetCategory? {
        guard let selectedCategoryID else { return nil }
        return categories.first { $0.id == selectedCategoryID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            categoryStrip
                .padding(.top, 16)
                .padding(.bottom, 18)
            ScrollView {
                if filteredCards.isEmpty {
                    emptyCategory
                } else {
                    LazyVGrid(columns: grid, spacing: 16) {
                        ForEach(Array(filteredCards.enumerated()), id: \.element.id) { index, card in
                            PresetLibraryCard(
                                card: card,
                                accessibilityOrdinal: index + 1,
                                store: store,
                                isFavorite: favoriteIDs.contains(card.id),
                                isApplying: isApplyingID == card.id,
                                isAddingToQueue: isAddingToQueueID == card.id,
                                onApply: { apply(card) },
                                onAddToQueue: { addToQueue(card) },
                                onToggleFavorite: { toggleFavorite(card) },
                                onEdit: { editor = .fromCard(card) },
                                onDelete: { cardToDelete = card })
                        }
                    }
                    .padding(.bottom, 10)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("presets.cards-grid")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("presets.preset-list")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .fxPageBackground()
        .task { await reload() }
        .onChange(of: creationRequest?.id, initial: true) { _, _ in
            guard let request = creationRequest else { return }
            editor = PresetEditorInput(
                id: "gallery.\(request.id.uuidString)",
                draft: request.draft,
                initialCoverData: request.coverData,
                existingCard: nil)
            creationRequest = nil
        }
        .sheet(item: $editor) { input in
            PresetCardEditorSheet(
                input: input,
                categories: categories,
                store: store,
                gallery: gallery,
                onSaved: { await reload() })
        }
        .sheet(isPresented: $showCategoryCreator) {
            PresetCategoryCreatorSheet(store: store) { category in
                await reload()
                selectedCategoryID = category.id
            }
        }
        .confirmationDialog(
            "Delete this preset?",
            isPresented: Binding(
                get: { cardToDelete != nil },
                set: { if !$0 { cardToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let card = cardToDelete {
                Button("Delete \(card.title)", role: .destructive) { delete(card) }
                    .accessibilityIdentifier("presets.delete-confirm")
                    .help("Permanently remove this preset from the local library.")
            }
            Button("Cancel", role: .cancel) { cardToDelete = nil }
                .accessibilityIdentifier("presets.delete-cancel")
                .help("Keep this preset.")
        } message: {
            if cardToDelete?.origin == .builtIn {
                Text("This built-in preset will be permanently removed from your local library.")
            } else {
                Text("The recipe and its managed cover will be permanently removed.")
            }
        }
        .alert("Presets", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
                .accessibilityIdentifier("presets.error-dismiss")
                .help("Dismiss the visible preset error.")
        } message: {
            Text(errorMessage ?? "Unknown preset error.")
        }
        .confirmationDialog(
            "Delete this section?",
            isPresented: Binding(
                get: { categoryToDelete != nil },
                set: { if !$0 { categoryToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let category = categoryToDelete {
                Button("Delete \(category.title)", role: .destructive) { delete(category) }
                    .accessibilityIdentifier("presets.category-delete-confirm")
                    .help("Permanently delete this section and all affected presets.")
            }
            Button("Cancel", role: .cancel) { categoryToDelete = nil }
                .accessibilityIdentifier("presets.category-delete-cancel")
                .help("Keep this section and its presets.")
        } message: {
            if categoryToDelete?.isPersonal == true {
                Text("Every personal preset in this section and its managed cover will be permanently removed.")
            } else {
                Text("This built-in section, all of its built-in presets, and any personal presets stored inside it will be permanently removed from your local library.")
            }
        }
        .confirmationDialog(
            "Delete the entire Presets library?",
            isPresented: $confirmDeleteEverything,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { deleteEverything() }
                .accessibilityIdentifier("presets.delete-all-confirm")
                .help("Permanently remove all personal data and all built-in Presets content from this local library.")
            Button("Cancel", role: .cancel) { confirmDeleteEverything = false }
                .accessibilityIdentifier("presets.delete-all-cancel")
                .help("Keep the current Presets library.")
        } message: {
            Text("All personal cards, personal sections, and managed covers will be deleted. Every built-in card and section will also be removed from this local library. This cannot be undone in the app.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Presets")
                        .fxFont(24, weight: .bold)
                        .foregroundStyle(Color.fxText)
                    Text("Local visual recipes for Krea 2 Turbo. Apply a card or send its exact recipe straight to Queue.")
                        .fxFont(12)
                        .foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                if let selectedCategory {
                    Button { categoryToDelete = selectedCategory } label: {
                        Label("Delete section", systemImage: "trash")
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 34))
                    .accessibilityIdentifier("presets.delete-category")
                    .help("Permanently delete the selected \(selectedCategory.title) section and its contents.")
                }
                Button { showCategoryCreator = true } label: {
                    Label("New section", systemImage: "folder.badge.plus")
                }
                .buttonStyle(FxSecondaryButtonStyle(height: 34, accentText: true))
                .accessibilityIdentifier("presets.new-category")
                .help("Create a personal section for your own presets.")
                Menu {
                    Button("Delete everything…", role: .destructive) {
                        confirmDeleteEverything = true
                    }
                    .accessibilityIdentifier("presets.delete-all")
                    .help("Open a confirmation before permanently emptying the Presets library.")
                } label: {
                    Label("Manage library", systemImage: "slider.horizontal.3")
                }
                .menuStyle(.button)
                .buttonStyle(FxSecondaryButtonStyle(height: 34))
                .accessibilityLabel("Manage Presets library")
                .accessibilityIdentifier("presets.library-actions")
                .help("Manage the Presets library, including permanently removing all sections and cards.")
                Button {
                    var draft = makeNewDraft()
                    if let selectedCategoryID {
                        draft.categoryID = selectedCategoryID
                    } else if !categories.contains(where: { $0.id == draft.categoryID }),
                              let firstCategory = categories.first {
                        draft.categoryID = firstCategory.id
                    }
                    editor = PresetEditorInput(
                        id: "new.\(UUID().uuidString)",
                        draft: draft,
                        initialCoverData: nil,
                        existingCard: nil)
                } label: {
                    Label("New preset", systemImage: "plus")
                }
                .buttonStyle(FxPrimaryButtonStyle(height: 34))
                .disabled(categories.isEmpty)
                .accessibilityIdentifier("presets.new")
                .help(categories.isEmpty
                      ? "Create a personal section before adding a preset."
                      : "Create a reusable personal recipe and managed cover in the selected section.")
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.fxText3)
                        .accessibilityHidden(true)
                    TextField("Search title, prompt, category…", text: $searchText)
                        .textFieldStyle(.plain)
                        .fxFont(12.5)
                        .accessibilityLabel("Search presets")
                        .accessibilityIdentifier("presets.search")
                        .help("Filter presets by title, prompt, category, or recipe ID.")
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.fxText3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear preset search")
                        .accessibilityIdentifier("presets.search.clear")
                        .help("Clear the preset search and show the current category again.")
                    }
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: 420)
                .frame(height: 36)
                .modifier(PresetInsetBorderedSurfaceModifier(radius: 9))

                Button { favoritesOnly.toggle() } label: {
                    Label("Favorites", systemImage: favoritesOnly ? "star.fill" : "star")
                        .fxFont(11.5, weight: .semibold)
                        .foregroundStyle(favoritesOnly ? Color.fxOnAccent : Color.fxText2)
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .modifier(PresetSelectionSurfaceModifier(
                            selected: favoritesOnly,
                            radius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityValue(favoritesOnly ? "On" : "Off")
                .accessibilityIdentifier("presets.filter.favorites")
                .help("Show only favorite presets.")

                Spacer(minLength: 0)
                Text("\(filteredCards.count) shown")
                    .fxMonoFont(10.5)
                    .foregroundStyle(Color.fxText3)
            }
        }
    }

    private var categoryStrip: some View {
        PresetCategoryFlowLayout(spacing: 8, lineSpacing: 8) {
            categoryButton(id: nil, title: "All", image: "square.grid.2x2")
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                categoryButton(
                    id: category.id,
                    title: category.title,
                    image: category.systemImage,
                    accessibilityOrdinal: index + 1,
                    deletableCategory: category)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }

    private func categoryButton(
        id: String?,
        title: String,
        image: String,
        accessibilityOrdinal: Int? = nil,
        deletableCategory: PresetCategory? = nil
    ) -> some View {
        let selected = selectedCategoryID == id
        return Button { selectedCategoryID = id } label: {
            HStack(spacing: 6) {
                Image(systemName: image).font(.system(size: 11, weight: .medium))
                Text(title)
            }
            .fxFont(11.5, weight: .semibold)
            .foregroundStyle(selected ? Color.fxOnAccent : Color.fxText2)
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(
                selected
                    ? Color.fxAccent
                    : (theme == .glass ? FxGlassPalette.inset : Color.fxInset),
                in: Capsule())
            .overlay(Capsule().strokeBorder(
                selected
                    ? Color.clear
                    : (theme == .glass ? FxGlassPalette.border : Color.fxBorder),
                lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id == nil
            ? "presets.category.all"
            : "presets.category.\(accessibilityOrdinal ?? 0)")
        .accessibilityLabel("Show \(title) presets")
        .help(selected
              ? "The \(title) preset category is already selected."
              : "Filter the preset library to the \(title) category.")
        .contextMenu {
            if let deletableCategory {
                Button("Delete \(deletableCategory.title)", role: .destructive) {
                    categoryToDelete = deletableCategory
                }
                .accessibilityIdentifier("presets.category.\(accessibilityOrdinal ?? 0).delete")
                .help("Open a confirmation before permanently deleting this section and its contents.")
            }
        }
        .accessibilityLabel("Show \(title) presets")
    }

    private var emptyCategory: some View {
        VStack(spacing: 10) {
            Image(systemName: favoritesOnly ? "star" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(Color.fxText3)
            Text(emptyTitle)
                .fxFont(14, weight: .semibold)
                .foregroundStyle(Color.fxText2)
            Text(emptyMessage)
                .fxFont(12)
                .foregroundStyle(Color.fxText3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var emptyTitle: String {
        if favoritesOnly { return "No favorite presets match" }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matching presets" }
        return "No presets in this category"
    }

    private var emptyMessage: String {
        if favoritesOnly { return "Star a preset to keep it in this focused view." }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try a different title, prompt, category, or recipe ID."
        }
        return "Create one from a cover file, a Gallery result, or the current Generate settings."
    }

    private func apply(_ card: PresetCard) {
        guard isApplyingID == nil else { return }
        isApplyingID = card.id
        Task {
            defer { isApplyingID = nil }
            do {
                try await onApply(card.recipe)
            } catch {
                errorMessage = "Couldn’t apply \(card.title): \(error.localizedDescription)"
            }
        }
    }

    private func addToQueue(_ card: PresetCard) {
        guard isAddingToQueueID == nil else { return }
        isAddingToQueueID = card.id
        Task {
            defer { isAddingToQueueID = nil }
            do {
                try await onAddToQueue(card.recipe)
            } catch {
                errorMessage = "Couldn’t add \(card.title) to Queue: \(error.localizedDescription)"
            }
        }
    }

    private func toggleFavorite(_ card: PresetCard) {
        Task {
            do {
                _ = try await store.toggleFavorite(id: card.id)
                await reload()
            } catch {
                errorMessage = "Couldn’t update \(card.title): \(error.localizedDescription)"
            }
        }
    }

    private func delete(_ card: PresetCard) {
        cardToDelete = nil
        Task {
            do {
                if card.origin == .builtIn {
                    try await store.removeBuiltinCard(id: card.id)
                } else {
                    _ = try await store.removeCard(id: card.id)
                }
                await reload()
            } catch {
                errorMessage = "Couldn’t delete \(card.title): \(error.localizedDescription)"
            }
        }
    }

    private func delete(_ category: PresetCategory) {
        categoryToDelete = nil
        Task {
            do {
                _ = try await store.removeCategory(id: category.id)
                await reload()
            } catch {
                errorMessage = "Couldn’t delete \(category.title): \(error.localizedDescription)"
            }
        }
    }

    private func deleteEverything() {
        confirmDeleteEverything = false
        Task {
            do {
                try await store.removeEverything()
                selectedCategoryID = nil
                searchText = ""
                favoritesOnly = false
                await reload()
            } catch {
                errorMessage = "Couldn’t empty Presets: \(error.localizedDescription)"
            }
        }
    }

    @MainActor private func reload() async {
        let snapshot = await store.snapshot()
        let catalog = ModelCatalog(root: AppPaths.weightsRoot)
        categories = BuiltinPresetCatalog.categories
            .filter { !snapshot.removedBuiltinCategoryIDs.contains($0.id) }
            + snapshot.categories
        cards = BuiltinPresetCatalog.cards(catalog: catalog)
            .filter {
                !snapshot.removedBuiltinPresetIDs.contains($0.id)
                    && !snapshot.removedBuiltinCategoryIDs.contains($0.categoryID)
            }
            + snapshot.cards
        favoriteIDs = snapshot.favoritePresetIDs
        if let selectedCategoryID,
           !categories.contains(where: { $0.id == selectedCategoryID }) {
            self.selectedCategoryID = nil
        }
        if let warning = snapshot.startupWarning, !didPresentStartupWarning {
            didPresentStartupWarning = true
            errorMessage = warning
        }
    }
}

private struct PresetSelectionSurfaceModifier: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if selected {
            content
                .background(Color.fxAccent, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.clear, lineWidth: 1))
        } else if theme == .dark {
            content
                .background(Color.fxInset, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.fxBorder, lineWidth: 1))
        } else {
            content.fxThemedSurface(
                .inset,
                radius: radius,
                interactive: true)
        }
    }
}

private struct PresetInsetBorderedSurfaceModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .dark {
            content
                .background(Color.fxInset, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.fxBorder, lineWidth: 1))
        } else {
            content.fxThemedSurface(.inset, radius: radius)
        }
    }
}

private struct PresetEditorInput: Identifiable {
    let id: String
    let draft: PresetCardDraft
    let initialCoverData: Data?
    let existingCard: PresetCard?

    static func fromCard(_ card: PresetCard) -> PresetEditorInput {
        PresetEditorInput(
            id: card.id,
            draft: PresetCardDraft(
                id: card.id,
                categoryID: card.categoryID,
                title: card.title,
                summary: card.summary,
                recipe: card.recipe),
            initialCoverData: nil,
            existingCard: card)
    }
}

/// Natural-width category chips wrap inside the available pane. This keeps every built-in
/// categories discoverable without a hidden horizontal scroll affordance.
private struct PresetCategoryFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = rows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height }
                + lineSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = rows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var result: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty && proposedWidth > maxWidth {
                result.append(row)
                row = Row()
            }
            row.indices.append(index)
            row.width = row.indices.count == 1 ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { result.append(row) }
        return result
    }
}

private struct PresetLibraryCard: View {
    let card: PresetCard
    let accessibilityOrdinal: Int
    let store: PresetLibraryStore
    let isFavorite: Bool
    let isApplying: Bool
    let isAddingToQueue: Bool
    let onApply: () -> Void
    let onAddToQueue: () -> Void
    let onToggleFavorite: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onApply) {
                VStack(alignment: .leading, spacing: 10) {
                    Group {
                        if card.prefersFullFrameCover {
                            PresetCoverImage(card: card, store: store)
                                .aspectRatio(16 / 9, contentMode: .fit)
                        } else {
                            PresetCoverImage(card: card, store: store)
                                .frame(height: 176)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(card.title)
                            .fxFont(14, weight: .semibold)
                            .foregroundStyle(Color.fxText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if card.isPersonal {
                            Text("Yours")
                                .fxMonoFont(9.5, weight: .semibold)
                                .foregroundStyle(Color.fxOk)
                                .padding(.vertical, 3).padding(.horizontal, 5)
                                .background(Color.fxOkSoft, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Text(card.summary)
                        .fxFont(11.5)
                        .foregroundStyle(Color.fxText3)
                        .lineLimit(2)
                        .frame(minHeight: 30, alignment: .topLeading)

                    HStack(spacing: 5) {
                        badge(card.dimensionsText)
                        badge(card.stepsText)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 5) {
                        badge(card.modelText, accent: true)
                        Spacer(minLength: 0)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fxThemedSurface(
                    .card,
                    radius: FxRadius.card,
                    interactive: true)
            }
            .buttonStyle(PresetCardButtonStyle())
            .disabled(isApplying || isAddingToQueue)
            .accessibilityLabel("Apply \(card.title) preset")
            .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).apply")
            .accessibilityHint("Loads its recipe into Generate without starting a render.")
            .help(isApplying || isAddingToQueue
                  ? "This preset is unavailable while its current action is finishing."
                  : "Load this complete recipe into Generate without starting a render.")

            HStack(spacing: 6) {
                cardActionButton(
                    isFavorite ? "star.fill" : "star",
                    accessibilityID: "presets.card.\(accessibilityOrdinal).favorite",
                    help: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    tint: isFavorite ? Color.fxAccentHi : Color.fxText,
                    action: onToggleFavorite)

                Button(action: onAddToQueue) {
                    Group {
                        if isAddingToQueue {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "text.badge.plus")
                                .font(.system(size: 12, weight: .bold))
                        }
                    }
                    .foregroundStyle(Color.fxText)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isApplying || isAddingToQueue)
                .accessibilityLabel("Add \(card.title) to Queue")
                .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).add-to-queue")
                .help(isApplying || isAddingToQueue
                      ? "Queue is unavailable while this preset's current action is finishing."
                      : "Add this exact recipe to Queue without changing Generate.")

                Menu {
                    if card.isPersonal {
                        Button("Edit", action: onEdit)
                            .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).edit")
                            .help("Edit this personal preset and its managed cover.")
                        Divider()
                        Button("Delete", role: .destructive, action: onDelete)
                            .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).delete")
                            .help("Open a confirmation before deleting this personal preset.")
                    } else {
                        Button("Delete permanently", role: .destructive, action: onDelete)
                            .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).delete")
                            .help("Open a confirmation before permanently removing this built-in preset from the local library.")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.fxText)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Actions for \(card.title)")
                .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).actions")
                .help("Open actions for this preset, including its recipe metadata choices.")
            }
            .padding(16)
        }
        .contextMenu {
            Button("Apply to Generate", action: onApply)
                .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).context-apply")
                .help("Load this complete recipe into Generate without starting a render.")
            Button("Add to Queue", action: onAddToQueue)
                .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).context-add-to-queue")
                .help("Add this exact recipe to Queue without changing Generate.")
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
                .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).context-favorite")
                .help(isFavorite ? "Remove this preset from Favorites." : "Add this preset to Favorites.")
            Divider()
            if card.isPersonal {
                Button("Edit", action: onEdit)
                    .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).context-edit")
                    .help("Edit this personal preset and its managed cover.")
                Button("Delete", role: .destructive, action: onDelete)
                    .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).context-delete")
                    .help("Open a confirmation before deleting this personal preset.")
            } else {
                Button("Delete permanently", role: .destructive, action: onDelete)
                    .accessibilityIdentifier("presets.card.\(accessibilityOrdinal).context-delete")
                    .help("Open a confirmation before permanently removing this built-in preset from the local library.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("presets.card.\(accessibilityOrdinal)")
    }

    private func cardActionButton(
        _ symbol: String,
        accessibilityID: String,
        help: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(help) for \(card.title)")
        .accessibilityIdentifier(accessibilityID)
    }

    private func badge(_ value: String, accent: Bool = false) -> some View {
        Text(value)
            .fxMonoFont(9.5, weight: .medium)
            .foregroundStyle(accent ? Color.fxAccentHi : Color.fxText3)
            .lineLimit(1)
            .padding(.vertical, 4).padding(.horizontal, 6)
            .modifier(PresetBadgeSurfaceModifier(accent: accent))
    }
}

private struct PresetBadgeSurfaceModifier: ViewModifier {
    let accent: Bool
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if accent {
            content
                .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.fxAccentLine, lineWidth: 1))
        } else if theme == .dark {
            content
                .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.fxBorder, lineWidth: 1))
        } else {
            content.fxThemedSurface(.inset, radius: 5)
        }
    }
}

private struct PresetCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.78 : 1)
    }
}

@MainActor
private final class PresetCoverImageCache {
    static let shared = PresetCoverImageCache()
    private let images = NSCache<NSString, NSImage>()

    private init() { images.countLimit = 80 }

    func image(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

private struct PresetCoverImage: View {
    let card: PresetCard
    let store: PresetLibraryStore
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity)
        .fxThemedSurface(.panel, radius: 0, bordered: false)
        .task(id: card.coverFilename) {
            image = nil
            let url: URL?
            if card.origin == .builtIn {
                url = BuiltinPresetCover.url(for: card)
            } else {
                url = await store.coverURL(for: card)
            }
            if let url {
                image = PresetCoverImageCache.shared.image(at: url)
            }
        }
    }

    private var placeholder: some View {
        let colors = placeholderColors
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [.white.opacity(0.24), .clear],
                center: .topTrailing,
                startRadius: 4,
                endRadius: 180)
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: categoryIcon)
                    .font(.system(size: 24, weight: .light))
                Text(card.isPersonal ? "PERSONAL COVER" : "LOCAL COVER")
                    .fxMonoFont(9.5, weight: .semibold)
                Text(card.isPersonal ? "loading managed preview" : "production pending")
                    .fxMonoFont(9)
                    .foregroundStyle(Color.white.opacity(0.68))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(14)
        }
    }

    private var categoryIcon: String {
        BuiltinPresetCatalog.categories.first(where: { $0.id == card.categoryID })?.systemImage ?? "square.grid.2x2"
    }

    private var placeholderColors: [Color] {
        switch card.categoryID {
        case "portrait", "selfie": [.init(hex: 0x6D4A47), .init(hex: 0x1C2027)]
        case "anime", "art": [.init(hex: 0x4554A3), .init(hex: 0x24223D)]
        case "nature", "fantasy": [.init(hex: 0x375D4D), .init(hex: 0x17211E)]
        case "product", "industry": [.init(hex: 0x765C35), .init(hex: 0x25211B)]
        case "cinema", "sci-fi": [.init(hex: 0x314B69), .init(hex: 0x17202B)]
        default: [.init(hex: 0x56616D), .init(hex: 0x20252D)]
        }
    }
}

private enum BuiltinPresetCover {
    static func url(for card: PresetCard) -> URL? {
        BuiltinPresetCoverContract.url(for: card, bundle: .module)
    }
}

private struct PresetCardEditorSheet: View {
    let input: PresetEditorInput
    let initialCategories: [PresetCategory]
    let store: PresetLibraryStore
    let gallery: GalleryViewModel
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var summary: String
    @State private var categoryID: String
    @State private var prompt: String
    @State private var width: Int
    @State private var height: Int
    @State private var steps: Int
    @State private var seedText: String
    @State private var originalRecipe: GenerationRecipe
    @State private var categories: [PresetCategory]
    @State private var coverData: Data?
    @State private var coverPreview: NSImage?
    @State private var showImporter = false
    @State private var showGalleryPicker = false
    @State private var showNewCategory = false
    @State private var newCategoryName = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        input: PresetEditorInput,
        categories: [PresetCategory],
        store: PresetLibraryStore,
        gallery: GalleryViewModel,
        onSaved: @escaping () async -> Void
    ) {
        self.input = input
        self.initialCategories = categories
        self.store = store
        self.gallery = gallery
        self.onSaved = onSaved
        let recipe = input.draft.recipe
        _title = State(initialValue: input.draft.title)
        _summary = State(initialValue: input.draft.summary)
        _categoryID = State(initialValue: input.draft.categoryID)
        _prompt = State(initialValue: recipe.prompts.positive)
        _width = State(initialValue: recipe.canvas.width)
        _height = State(initialValue: recipe.canvas.height)
        _steps = State(initialValue: recipe.sampler.steps)
        _seedText = State(initialValue: recipe.sampler.seed.fixedValue.map(String.init) ?? "")
        _originalRecipe = State(initialValue: recipe)
        _categories = State(initialValue: categories)
        _coverData = State(initialValue: input.initialCoverData)
        _coverPreview = State(initialValue: input.initialCoverData.flatMap(NSImage.init(data:)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(input.existingCard == nil ? "New preset" : "Edit preset")
                        .fxFont(18, weight: .bold).foregroundStyle(Color.fxText)
                    Text("The complete recipe is retained; only the visible core values are edited here.")
                        .fxFont(11.5).foregroundStyle(Color.fxText3)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .accessibilityIdentifier("presets.editor.close")
                    .help("Close the preset editor without saving these changes.")
            }
            .padding(20)
            Divider().overlay(Color.fxBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identitySection
                    recipeSection
                    coverSection
                    advancedSummary
                }
                .padding(20)
            }
            .accessibilityIdentifier("presets.editor.content-scroll")
            .help("Scroll through every preset editor section.")

            Divider().overlay(Color.fxBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 34))
                    .accessibilityIdentifier("presets.editor.cancel")
                    .help("Close the preset editor without saving these changes.")
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView().controlSize(.small) }
                    else { Text(input.existingCard == nil ? "Create preset" : "Save changes") }
                }
                .buttonStyle(FxPrimaryButtonStyle(height: 34))
                .disabled(isSaving)
                .accessibilityIdentifier("presets.editor.save")
                .help(isSaving
                      ? "Saving is unavailable until the current atomic preset write finishes."
                      : "Validate and save this complete preset recipe and managed cover.")
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 700, maxWidth: 760, minHeight: 620, idealHeight: 720)
        .fxThemedSurface(.sheet, radius: 0, bordered: false)
        .fxStandalonePageBackground()
        .accessibilityIdentifier("presets.editor.sheet")
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.png, .jpeg, .heic],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let data = try PresetCoverCodec.data(from: url)
                    coverData = data
                    coverPreview = NSImage(data: data)
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = "Couldn’t open the cover: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showGalleryPicker) {
            PresetGalleryPickerSheet(gallery: gallery) { generation, data in
                coverData = data
                coverPreview = NSImage(data: data)
                showGalleryPicker = false
            }
        }
        .task(id: input.existingCard?.coverFilename) {
            guard coverPreview == nil,
                  let existingCard = input.existingCard,
                  let url = await store.coverURL(for: existingCard)
            else { return }
            coverPreview = PresetCoverImageCache.shared.image(at: url)
        }
        .alert("Preset", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
                .accessibilityIdentifier("presets.editor.error-dismiss")
                .help("Dismiss the visible preset editor error.")
        } message: {
            Text(errorMessage ?? "Unknown preset error.")
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorLabel("Identity")
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .padding(10).fxInsetField()
                .accessibilityIdentifier("presets.editor.title")
                .help("Enter the visible preset title.")
            TextField("Short promise", text: $summary)
                .textFieldStyle(.plain)
                .padding(10).fxInsetField()
                .accessibilityIdentifier("presets.editor.summary")
                .help("Enter a short description of what this preset produces.")
            HStack(spacing: 8) {
                Picker("Category", selection: $categoryID) {
                    ForEach(categories) { category in
                        Text(category.title).tag(category.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5).fxInsetField()
                .accessibilityIdentifier("presets.editor.category")
                .help("Choose the category that contains this preset.")
                Button { showNewCategory = true } label: {
                    Label("New category", systemImage: "plus")
                }
                .buttonStyle(FxSecondaryButtonStyle(height: 32))
                .accessibilityIdentifier("presets.editor.new-category")
                .help("Show controls for creating a personal preset category.")
            }
            if showNewCategory {
                HStack(spacing: 8) {
                    TextField("Category name", text: $newCategoryName)
                        .textFieldStyle(.plain)
                        .padding(9).fxInsetField()
                        .accessibilityIdentifier("presets.editor.new-category-name")
                        .help("Enter a name for the new personal category.")
                    Button("Add") { addCategory() }
                        .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                        .accessibilityIdentifier("presets.editor.new-category-add")
                        .help("Validate and add this personal category.")
                    Button("Cancel") { showNewCategory = false; newCategoryName = "" }
                        .buttonStyle(FxGhostButtonStyle(height: 32))
                        .accessibilityIdentifier("presets.editor.new-category-cancel")
                        .help("Discard the unsaved category name.")
                }
            }
        }
    }

    private var recipeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorLabel("Core recipe")
            TextEditor(text: $prompt)
                .fxFont(12.5).foregroundStyle(Color.fxText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 116)
                .padding(8).fxInsetField()
                .accessibilityLabel("Preset prompt")
                .accessibilityIdentifier("presets.editor.prompt")
                .help("Edit the positive prompt retained in this preset recipe.")
            HStack(spacing: 10) {
                numericField("Width", accessibilityID: "presets.editor.width", value: $width, range: 256...2048, step: 16)
                numericField("Height", accessibilityID: "presets.editor.height", value: $height, range: 256...2048, step: 16)
                numericField("Steps", accessibilityID: "presets.editor.steps", value: $steps, range: 1...100, step: 1)
            }
            TextField("Seed — leave empty for random", text: $seedText)
                .textFieldStyle(.plain)
                .fxMonoFont(12)
                .padding(10).fxInsetField()
                .accessibilityIdentifier("presets.editor.seed")
                .help("Enter a fixed unsigned 64-bit seed, or leave empty for a new seed per render.")
            Text("Turbo defaults are retained: CFG 0 · μ 1.15 · bfloat16 · mixed-4/8.")
                .fxMonoFont(10.5)
                .foregroundStyle(Color.fxText3)
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorLabel("Cover")
            HStack(alignment: .center, spacing: 14) {
                Group {
                    if let coverPreview {
                        Image(nsImage: coverPreview).resizable().scaledToFill()
                    } else if input.existingCard != nil {
                        ZStack {
                            Color.clear
                            Image(systemName: "photo").foregroundStyle(Color.fxText3)
                        }
                        .fxThemedSurface(.panel, radius: 0, bordered: false)
                    } else {
                        ZStack {
                            Color.clear
                            Text("Required").fxMonoFont(10).foregroundStyle(Color.fxText3)
                        }
                        .fxThemedSurface(.inset, radius: 0, bordered: false)
                    }
                }
                .frame(width: 116, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.fxBorder, lineWidth: 1))
                VStack(alignment: .leading, spacing: 7) {
                    Text(input.existingCard == nil
                         ? "Use a PNG, JPEG, HEIC, or a Gallery result. It will be copied as a bounded managed JPEG."
                         : "Replace the managed cover with a PNG, JPEG, HEIC, or keep the existing cover.")
                        .fxFont(11.5).foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Choose from Gallery…") { showGalleryPicker = true }
                            .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
                            .accessibilityIdentifier("presets.editor.choose-gallery-cover")
                            .help("Choose one of your ready Gallery images as this preset's managed cover.")
                        Button("Choose file…") { showImporter = true }
                            .buttonStyle(FxSecondaryButtonStyle(height: 30))
                            .accessibilityIdentifier("presets.editor.choose-cover")
                            .help("Choose a bounded PNG, JPEG, or HEIC image to copy as the managed preset cover.")
                    }
                }
            }
        }
    }

    private var advancedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            editorLabel("Advanced recipe retained")
            let recipe = originalRecipe
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                summaryBadge("Model: \(recipe.model.checkpointFamily.displayName) · \(recipe.model.quantizationTier.displayName)")
                summaryBadge("Negative prompt: \(recipe.prompts.negative.isEmpty ? "none" : "kept")")
                summaryBadge("Lettering: \(recipe.prompts.exactText == nil ? "off" : "kept")")
                summaryBadge("LoRA: \(recipe.loras.count)")
                summaryBadge("Regional prompts: \(recipe.regions.count) region\(recipe.regions.count == 1 ? "" : "s")")
                summaryBadge("Remix: \(recipe.inputImage == nil ? "off" : "managed source kept")")
            }
            Text("Changing this card never silently removes these settings. If an asset is missing later, applying the card stops with a clear error.")
                .fxFont(10.5).foregroundStyle(Color.fxText3)
        }
        .padding(12)
        .modifier(PresetInsetBorderedSurfaceModifier(radius: 10))
    }

    private func numericField(
        _ label: String,
        accessibilityID: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).fxFont(10.5, weight: .semibold).foregroundStyle(Color.fxText3)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)").fxMonoFont(11.5).foregroundStyle(Color.fxText)
            }
            .labelsHidden()
            .padding(.horizontal, 8).padding(.vertical, 6).fxInsetField()
            .accessibilityIdentifier(accessibilityID)
            .help("Set the preset \(label.lowercased()) within the validated recipe range.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryBadge(_ text: String) -> some View {
        Text(text)
            .fxMonoFont(10)
            .foregroundStyle(Color.fxText2)
            .padding(.vertical, 6).padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(PresetPanelSurfaceModifier(radius: 6))
    }

    private func editorLabel(_ text: String) -> some View {
        Text(text).fxFont(12, weight: .semibold).foregroundStyle(Color.fxTextLabel)
    }

    private func addCategory() {
        let name = newCategoryName
        Task {
            do {
                let category = try await store.createCategory(title: name)
                categories.append(category)
                categoryID = category.id
                newCategoryName = ""
                showNewCategory = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        var recipe = originalRecipe
        recipe.prompts.positive = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.canvas.width = max(256, min(2048, (width / 16) * 16))
        recipe.canvas.height = max(256, min(2048, (height / 16) * 16))
        recipe.sampler.steps = steps
        let trimmedSeed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSeed.isEmpty {
            recipe.sampler.seed = .random
        } else if let seed = UInt64(trimmedSeed) {
            recipe.sampler.seed = .fixed(seed)
        } else {
            errorMessage = "Seed must be a positive whole number, or empty for random."
            return
        }
        let draft = PresetCardDraft(
            id: input.existingCard?.id,
            categoryID: categoryID,
            title: title,
            summary: summary,
            recipe: recipe)
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                _ = try await store.save(draft: draft, coverData: coverData)
                await onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PresetCategoryCreatorSheet: View {
    let store: PresetLibraryStore
    let onCreated: (PresetCategory) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Presets section")
                    .fxFont(18, weight: .bold)
                    .foregroundStyle(Color.fxText)
                Text("Create an empty personal section, then add or move your own preset cards into it.")
                    .fxFont(11.5)
                    .foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Section name", text: $title)
                .textFieldStyle(.plain)
                .padding(10)
                .fxInsetField()
                .accessibilityIdentifier("presets.category-editor.title")
                .help("Enter a unique name between 2 and 48 characters.")

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 34))
                    .accessibilityIdentifier("presets.category-editor.cancel")
                    .help("Close without creating a section.")
                Button {
                    create()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create section")
                    }
                }
                .buttonStyle(FxPrimaryButtonStyle(height: 34))
                .disabled(isSaving)
                .accessibilityIdentifier("presets.category-editor.save")
                .help("Create this personal Presets section.")
            }
        }
        .padding(20)
        .frame(width: 460)
        .fxThemedSurface(.sheet, radius: 0, bordered: false)
        .fxStandalonePageBackground()
        .accessibilityIdentifier("presets.category-editor.sheet")
        .alert("Presets", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
                .accessibilityIdentifier("presets.category-editor.error-dismiss")
        } message: {
            Text(errorMessage ?? "Unknown section error.")
        }
    }

    private func create() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let category = try await store.createCategory(title: title)
                await onCreated(category)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PresetGalleryPickerSheet: View {
    let gallery: GalleryViewModel
    let onSelect: (Generation, Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var generations: [Generation] = []
    @State private var selectedID: UUID?
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var filteredGenerations: [Generation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return generations
            .filter { generation in
                query.isEmpty
                    || generation.prompt.lowercased().contains(query)
                    || generation.id.uuidString.lowercased().contains(query)
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private var selectedGeneration: Generation? {
        guard let selectedID else { return nil }
        return generations.first { $0.id == selectedID }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 154, maximum: 210), spacing: 12, alignment: .top)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose a Gallery cover")
                        .fxFont(18, weight: .bold)
                        .foregroundStyle(Color.fxText)
                    Text("The selected image is verified, copied, and resized into a managed preset cover. The card's recipe stays unchanged.")
                        .fxFont(11.5)
                        .foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .accessibilityIdentifier("presets.gallery-picker.close")
            }
            .padding(20)

            Divider().overlay(Color.fxBorder)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.fxText3)
                    .accessibilityHidden(true)
                TextField("Search Gallery prompts…", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("presets.gallery-picker.search")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.fxText3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Gallery search")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .modifier(PresetInsetBorderedSurfaceModifier(radius: 9))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Group {
                if isLoading {
                    ProgressView("Loading Gallery…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredGenerations.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.fxText3)
                        Text(generations.isEmpty ? "Gallery is empty" : "No matching Gallery images")
                            .fxFont(14, weight: .semibold)
                            .foregroundStyle(Color.fxText2)
                        Text(generations.isEmpty
                             ? "Render an image first, or use Choose file in the preset editor."
                             : "Try another prompt search.")
                            .fxFont(11.5)
                            .foregroundStyle(Color.fxText3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(filteredGenerations.enumerated()), id: \.element.id) { index, generation in
                                Button {
                                    selectedID = generation.id
                                } label: {
                                    PresetGalleryPickerCell(
                                        generation: generation,
                                        gallery: gallery,
                                        selected: selectedID == generation.id)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Select Gallery image \(index + 1)")
                                .accessibilityValue(selectedID == generation.id ? "Selected" : "Not selected")
                                .accessibilityIdentifier("presets.gallery-picker.image.\(index + 1)")
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                    .accessibilityIdentifier("presets.gallery-picker.grid")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Color.fxBorder)
            HStack {
                Text(selectedGeneration.map {
                    "\($0.width) × \($0.height) · seed \($0.seed)"
                } ?? "Select one ready Gallery image")
                    .fxMonoFont(10.5)
                    .foregroundStyle(Color.fxText3)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 34))
                    .accessibilityIdentifier("presets.gallery-picker.cancel")
                Button {
                    importSelected()
                } label: {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Use as cover")
                    }
                }
                .buttonStyle(FxPrimaryButtonStyle(height: 34))
                .disabled(selectedGeneration == nil || isImporting)
                .accessibilityIdentifier("presets.gallery-picker.use")
                .help("Verify and copy the selected Gallery PNG as this preset's cover.")
            }
            .padding(16)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 580, idealHeight: 680)
        .fxThemedSurface(.sheet, radius: 0, bordered: false)
        .fxStandalonePageBackground()
        .accessibilityIdentifier("presets.gallery-picker.sheet")
        .task {
            generations = await gallery.reloadAndWait()
            isLoading = false
        }
        .alert("Gallery cover", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
                .accessibilityIdentifier("presets.gallery-picker.error-dismiss")
        } message: {
            Text(errorMessage ?? "Unknown Gallery cover error.")
        }
    }

    private func importSelected() {
        guard let generation = selectedGeneration else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let data = try await gallery.pngDataForPreset(generation)
                onSelect(generation, data)
            } catch {
                errorMessage = "Couldn’t use this Gallery image: \(error.localizedDescription)"
            }
        }
    }
}

private struct PresetGalleryPickerCell: View {
    let generation: Generation
    let gallery: GalleryViewModel
    let selected: Bool

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color.fxInset
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 118)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(generation.prompt)
                .fxFont(10.5, weight: .medium)
                .foregroundStyle(Color.fxText2)
                .lineLimit(2)
                .frame(minHeight: 27, alignment: .topLeading)
            Text("\(generation.width) × \(generation.height)")
                .fxMonoFont(9.5)
                .foregroundStyle(Color.fxText3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.fxAccentSoft : Color.fxPanel,
            in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.fxAccent : Color.fxBorder, lineWidth: selected ? 2 : 1))
        .task(id: generation.id) {
            thumbnail = await gallery.thumbnail(for: generation, maxPixel: 300)
        }
    }
}

private struct PresetPanelSurfaceModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .dark {
            content.background(Color.fxPanel, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.fxThemedSurface(.panel, radius: radius, bordered: false)
        }
    }
}
