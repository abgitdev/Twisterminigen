import SwiftUI
import Observation
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct GalleryPublicationReport: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case publishedDurable
        case publishedDurabilityWarning(code: Int32)
        case failedBeforeVisibility(message: String)
        case notConfirmed(message: String)
        case unattempted(message: String)

        var headline: String {
            switch self {
            case .publishedDurable: "Published · durable"
            case .publishedDurabilityWarning: "Published · durability not confirmed"
            case .failedBeforeVisibility: "Failed before visibility"
            case .notConfirmed: "Publication not confirmed"
            case .unattempted: "Not attempted"
            }
        }

        var detail: String {
            switch self {
            case .publishedDurable:
                "The exact reviewed bytes and parent-directory durability were confirmed."
            case .publishedDurabilityWarning(let code):
                "The exact reviewed bytes are visible, but filesystem durability was not confirmed (POSIX \(code)). Inspect this destination before retrying."
            case .failedBeforeVisibility(let message):
                message
            case .notConfirmed(let message):
                "The app cannot confirm whether its exact reviewed bytes are present. Inspect this destination before retrying. \(message)"
            case .unattempted(let message):
                message
            }
        }

        var isConfirmedVisible: Bool {
            switch self {
            case .publishedDurable, .publishedDurabilityWarning: true
            case .failedBeforeVisibility, .notConfirmed, .unattempted: false
            }
        }
    }

    struct Item: Identifiable, Equatable, Sendable {
        let ordinal: Int
        let role: String
        let destination: URL
        let state: State

        var id: String { "\(ordinal):\(destination.standardizedFileURL.path)" }
    }

    let title: String
    let items: [Item]

    var summary: String {
        let durable = items.filter {
            if case .publishedDurable = $0.state { true } else { false }
        }.count
        let warnings = items.filter {
            if case .publishedDurabilityWarning = $0.state { true } else { false }
        }.count
        let failed = items.filter {
            if case .failedBeforeVisibility = $0.state { true } else { false }
        }.count
        let unknown = items.filter {
            if case .notConfirmed = $0.state { true } else { false }
        }.count
        let unattempted = items.filter {
            if case .unattempted = $0.state { true } else { false }
        }.count
        return "\(items.count) destination\(items.count == 1 ? "" : "s"): \(durable) durable, \(warnings) visible with warning, \(failed) failed before visibility, \(unknown) not confirmed, \(unattempted) unattempted."
    }

    static func bulk(
        _ result: BulkGenerationExportResult,
        title: String = "Gallery publication report"
    ) -> Self {
        Self(
            title: title,
            items: result.items.enumerated().map { index, item in
                Item(
                    ordinal: index + 1,
                    role: "Generation \(item.generationID.uuidString)",
                    destination: item.destination.standardizedFileURL,
                    state: state(for: item.state))
            })
    }

    static func pngAndRecipe(
        _ result: PNGRecipeExportResult,
        recipeDestination: URL
    ) -> Self {
        var items = [Item(
            ordinal: 1,
            role: "Reviewed PNG",
            destination: result.pngOutcome.destination.standardizedFileURL,
            state: state(for: result.pngOutcome))]
        if let recipeOutcome = result.recipeOutcome {
            items.append(Item(
                ordinal: 2,
                role: "Portable recipe",
                destination: recipeOutcome.destination.standardizedFileURL,
                state: state(for: recipeOutcome)))
        } else {
            items.append(Item(
                ordinal: 2,
                role: "Portable recipe",
                destination: recipeDestination.standardizedFileURL,
                state: .unattempted(
                    message: "Not attempted because PNG publication was not confirmed.")))
        }
        return Self(title: "PNG + recipe publication report", items: items)
    }

    private static func state(for outcome: ExternalPublicationOutcome) -> State {
        switch outcome {
        case .publishedDurable:
            .publishedDurable
        case .publishedDurabilityWarning(_, let code):
            .publishedDurabilityWarning(code: code)
        case .failedBeforeVisibility(_, let error):
            .failedBeforeVisibility(message: error.localizedDescription)
        case .stateUnknown(_, let error):
            .notConfirmed(message: error.localizedDescription)
        }
    }

    private static func state(for state: BulkGenerationExportResult.State) -> State {
        switch state {
        case .publishedDurable:
            .publishedDurable
        case .publishedDurabilityWarning(let code):
            .publishedDurabilityWarning(code: code)
        case .failedBeforeVisibility(let error):
            .failedBeforeVisibility(message: error.localizedDescription)
        case .stateUnknown(let error):
            .notConfirmed(message: error.localizedDescription)
        case .unattemptedDueToEarlierFailure:
            .unattempted(message: "Not attempted because an earlier batch destination failed or was not confirmed.")
        }
    }
}

@MainActor
@Observable
final class GalleryViewModel {
    var generations: [Generation] = []
    var selected: Generation? = nil
    var selectedIDs: Set<UUID> = []
    var favoriteIDs: Set<UUID> = []
    var errorMessage: String? = nil
    var operationMessage: String? = nil
    private(set) var lastBulkExportResult: BulkGenerationExportResult?
    private(set) var lastPNGRecipeExportResult: PNGRecipeExportResult?
    private(set) var publicationReport: GalleryPublicationReport?

    @ObservationIgnored private nonisolated let store: GenerationStore
    @ObservationIgnored private nonisolated let annotations: GalleryAnnotationStore
    @ObservationIgnored private let revealFiles: ([URL]) -> Void
    @ObservationIgnored private let openFolder: (URL) -> Bool
    private var reloadTask: Task<Void, Never>?
    private var paths: LibraryPaths?
    private var consumedStartupRecoveryReport = false
    private var selectionAnchorID: UUID?
    private var reportedAnnotationFailure = false

    func currentProtectedExportRoots() async -> [URL] {
        (await store.libraryPaths()).protectedExportRoots
    }

    func dismissPublicationReport() {
        publicationReport = nil
        errorMessage = nil
        operationMessage = nil
    }

    init(
        store: GenerationStore,
        annotations: GalleryAnnotationStore,
        revealFiles: @escaping ([URL]) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting($0)
        },
        openFolder: @escaping (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        }
    ) {
        self.store = store
        self.annotations = annotations
        self.revealFiles = revealFiles
        self.openFolder = openFolder
    }

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let paths = await self.store.libraryPaths()
            let list = await self.store.all()
            guard !Task.isCancelled else { return }
            self.apply(list, paths: paths)
            await self.refreshAnnotations(for: list)
        }
    }

    func delete(_ gen: Generation) {
        Task { @MainActor [weak self] in
            _ = await self?.deleteAndWait(gen)
        }
    }

    @discardableResult
    func deleteAndWait(_ gen: Generation) async -> Bool {
        reloadTask?.cancel()
        reloadTask = nil
        do {
            _ = try await store.delete(id: gen.id)
            _ = await refreshFromStore()
            return true
        } catch {
            _ = await refreshFromStore()
            errorMessage = "Delete failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func reloadAndWait() async -> [Generation] {
        reloadTask?.cancel()
        reloadTask = nil
        return await refreshFromStore()
    }

    @discardableResult
    func reloadAfterStorageManagerChange() async -> [Generation] {
        reloadTask?.cancel()
        reloadTask = nil
        let list = await store.reloadAfterExternalStorageChange()
        await annotations.resetAfterExternalStorageChange()
        let paths = await store.libraryPaths()
        apply(list, paths: paths)
        favoriteIDs = []
        return list
    }

    @discardableResult
    func removeAll() async throws -> LibraryDeletionResult {
        reloadTask?.cancel()
        reloadTask = nil
        do {
            let result = try await store.removeAll()
            _ = await refreshFromStore()
            return result
        } catch {
            _ = await refreshFromStore()
            throw error
        }
    }

    @discardableResult
    func repairLibrary() async throws -> LibraryRepairReport {
        reloadTask?.cancel()
        reloadTask = nil
        do {
            let report = try await store.repair()
            _ = await refreshFromStore()
            return report
        } catch {
            _ = await refreshFromStore()
            throw error
        }
    }

    func consumeStartupRecoveryReport() async -> LibraryRepairReport? {
        guard !consumedStartupRecoveryReport else { return nil }
        consumedStartupRecoveryReport = true
        return await store.startupRecoveryReport()
    }

    func clearThumbnails() async throws -> LibraryDeletionResult {
        let paths = await store.libraryPaths()
        self.paths = paths
        return try await Self.removeContents(of: paths.thumbnails)
    }

    // MARK: User annotations

    func isFavorite(_ generation: Generation) -> Bool {
        favoriteIDs.contains(generation.id)
    }

    func toggleFavorite(_ generation: Generation) {
        Task { @MainActor [weak self] in
            _ = await self?.toggleFavoriteAndWait(generation)
        }
    }

    @discardableResult
    func toggleFavoriteAndWait(_ generation: Generation) async -> Bool {
        guard generations.contains(where: { $0.id == generation.id }) else { return false }
        do {
            let isFavorite = try await annotations.toggleFavorite(for: generation.id)
            if isFavorite {
                favoriteIDs.insert(generation.id)
            } else {
                favoriteIDs.remove(generation.id)
            }
            return isFavorite
        } catch {
            errorMessage = "Favorite update failed: \(error.localizedDescription)"
            return favoriteIDs.contains(generation.id)
        }
    }

    // MARK: Grid selection

    func updateSelection(
        of generation: Generation,
        visible: [Generation],
        command: Bool,
        shift: Bool
    ) {
        guard let targetIndex = visible.firstIndex(where: { $0.id == generation.id }) else {
            return
        }

        if shift {
            let anchorIndex = selectionAnchorID.flatMap { anchor in
                visible.firstIndex(where: { $0.id == anchor })
            } ?? targetIndex
            let range = min(anchorIndex, targetIndex) ... max(anchorIndex, targetIndex)
            let rangeIDs = Set(range.map { visible[$0].id })
            if command {
                selectedIDs.formUnion(rangeIDs)
            } else {
                selectedIDs = rangeIDs
            }
        } else if command {
            if !selectedIDs.insert(generation.id).inserted {
                selectedIDs.remove(generation.id)
            }
            selectionAnchorID = generation.id
        } else {
            selectedIDs = [generation.id]
            selectionAnchorID = generation.id
        }
    }

    func selectAll(_ visible: [Generation]) {
        selectedIDs = Set(visible.map(\.id))
        selectionAnchorID = visible.first?.id
    }

    func clearSelection() {
        selectedIDs.removeAll()
        selectionAnchorID = nil
    }

    func selectedGenerations(in visible: [Generation]) -> [Generation] {
        visible.filter { selectedIDs.contains($0.id) }
    }

    func groups(for visible: [Generation], enabled: Bool) -> [GalleryGenerationGroup] {
        guard enabled else {
            return visible.isEmpty ? [] : [GalleryGenerationGroup(
                id: .ungrouped(visible[0].id),
                generations: visible,
                provenance: nil)]
        }

        let grouped = Dictionary(grouping: visible) { $0.provenance?.groupID }
        var emittedGroupIDs = Set<UUID>()
        var sections: [GalleryGenerationGroup] = []
        var ungrouped: [Generation] = []

        func appendUngrouped() {
            guard let first = ungrouped.first else { return }
            sections.append(GalleryGenerationGroup(
                id: .ungrouped(first.id),
                generations: ungrouped,
                provenance: nil))
            ungrouped.removeAll(keepingCapacity: true)
        }

        for generation in visible {
            guard let provenance = generation.provenance else {
                ungrouped.append(generation)
                continue
            }
            appendUngrouped()
            guard emittedGroupIDs.insert(provenance.groupID).inserted else { continue }
            let members = (grouped[provenance.groupID] ?? [])
                .sorted { lhs, rhs in
                    let leftIndex = lhs.provenance?.itemIndex ?? .max
                    let rightIndex = rhs.provenance?.itemIndex ?? .max
                    return leftIndex == rightIndex
                        ? lhs.createdAt < rhs.createdAt
                        : leftIndex < rightIndex
                }
            sections.append(GalleryGenerationGroup(
                id: .provenance(provenance.groupID),
                generations: members,
                provenance: provenance))
        }
        appendUngrouped()
        return sections
    }

    // Detail-sheet navigation (newest first).
    var canSelectPrevious: Bool {
        guard let idx = selectedIndex else { return false }
        return idx > 0
    }
    var canSelectNext: Bool {
        guard let idx = selectedIndex else { return false }
        return idx < generations.count - 1
    }
    func selectPrevious() {
        guard let idx = selectedIndex, idx > 0 else { return }
        selected = generations[idx - 1]
    }
    func selectNext() {
        guard let idx = selectedIndex, idx < generations.count - 1 else { return }
        selected = generations[idx + 1]
    }
    func positionText(of gen: Generation) -> String? {
        guard let idx = generations.firstIndex(where: { $0.id == gen.id }) else { return nil }
        return "\(idx + 1) of \(generations.count)"
    }

    func parentGeneration(of generation: Generation) -> Generation? {
        guard let parentID = generation.parentGenerationID else { return nil }
        return generations.first { $0.id == parentID }
    }

    func childGenerations(of generation: Generation) -> [Generation] {
        generations.filter { $0.parentGenerationID == generation.id }
    }

    /// Lineage navigation always uses the full durable library, even when the destination is
    /// outside the grid's current filters.
    @discardableResult
    func selectGeneration(id: UUID) -> Bool {
        guard let generation = generations.first(where: { $0.id == id }) else { return false }
        selected = generation
        return true
    }

    private var selectedIndex: Int? {
        guard let cur = selected else { return nil }
        return generations.firstIndex { $0.id == cur.id }
    }

    func revealInFinder(_ gen: Generation) {
        Task { @MainActor [weak self] in
            _ = await self?.revealInFinderAndWait(gen)
        }
    }

    /// Reveals the exact managed PNG produced by generation. This is intentionally a read-only
    /// Finder action: it does not pass through export, review, metadata rewriting, or copying.
    @discardableResult
    func revealInFinderAndWait(_ gen: Generation) async -> Bool {
        do {
            let sourceURL = try await managedImageURL(for: gen)
            revealFiles([sourceURL])
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Reveal failed: \(error.localizedDescription)"
            return false
        }
    }

    func managedImageURL(for gen: Generation) async throws -> URL {
        let sourceURL = try await store.imageURL(for: gen)
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw GenerationStoreError.unsafeFilesystemItem(sourceURL)
        }
        return sourceURL.standardizedFileURL
    }

    func managedGalleryFolderURL() async -> URL {
        (await store.libraryPaths()).images.standardizedFileURL
    }

    func exportPNG(_ gen: Generation) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try await store.reviewablePNG(for: gen)
                let panel = NSSavePanel()
                panel.title = "Export Clean PNG"
                panel.prompt = "Export"
                panel.allowedContentTypes = [.png]
                panel.allowsOtherFileTypes = false
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                panel.nameFieldStringValue = exportFileName(for: gen)
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                guard let receipt = OutputReviewGate.reviewBeforeExport(
                    outputs: [output],
                    kind: .galleryImage) else { return }
                _ = await exportPNG(
                    output,
                    to: destination,
                    receipt: receipt,
                    kind: .galleryImage)
            } catch {
                errorMessage = "Export preparation failed: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func exportPNG(
        _ output: ReviewablePNG,
        to destination: URL,
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind
    ) async -> Bool {
        do {
            let roots = (await store.libraryPaths()).protectedExportRoots
            let outcome = try await ValidatedExternalPublisher.publishReviewedPNG(
                output,
                to: destination,
                receipt: receipt,
                kind: kind,
                protectedRoots: roots)
            _ = try outcome.requireVisibleURL()
            if let code = outcome.durabilityWarningCode {
                operationMessage = "The reviewed PNG is visible at the selected destination."
                errorMessage = "Filesystem durability could not be confirmed (POSIX \(code))."
            } else {
                errorMessage = nil
            }
            return true
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            return false
        }
    }

    func exportPNGWithRecipe(_ gen: Generation) {
        lastPNGRecipeExportResult = nil
        publicationReport = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try await store.reviewablePNG(for: gen)
                let panel = NSSavePanel()
                panel.title = "Export Clean PNG with Recipe"
                panel.prompt = "Export Both"
                panel.allowedContentTypes = [.png]
                panel.allowsOtherFileTypes = false
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                panel.nameFieldStringValue = exportFileName(for: gen)
                guard panel.runModal() == .OK, let pngDestination = panel.url else { return }
                guard let receipt = OutputReviewGate.reviewBeforeExport(
                    outputs: [output],
                    kind: .galleryWithRecipe) else { return }
                let recipeDestination = pngDestination.deletingPathExtension()
                    .appendingPathExtension("twisterrecipe")
                guard await exportPNGWithRecipe(
                    gen,
                    pngDestination: pngDestination,
                    recipeDestination: recipeDestination,
                    receipt: receipt) != nil else { return }
            } catch {
                errorMessage = "Export preparation failed: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func exportPNGWithRecipe(
        _ gen: Generation,
        pngDestination: URL,
        recipeDestination: URL,
        receipt: OutputReviewGate.ReviewReceipt
    ) async -> PNGRecipeExportResult? {
        lastPNGRecipeExportResult = nil
        publicationReport = nil
        do {
            let result = try await store.exportPNGWithRecipe(
                for: gen,
                pngDestination: pngDestination,
                recipeDestination: recipeDestination,
                receipt: receipt)
            lastPNGRecipeExportResult = result
            let report = GalleryPublicationReport.pngAndRecipe(
                result,
                recipeDestination: recipeDestination)
            publicationReport = report
            if let failure = result.failure {
                if let png = result.publishedPNG {
                    operationMessage = "Confirmed reviewed PNG: \(png.lastPathComponent)."
                    errorMessage = failure.stateUnknown
                        ? "The portable recipe publication was not confirmed. Inspect its exact destination before retrying."
                        : "The portable recipe failed before visibility."
                } else {
                    operationMessage = nil
                    errorMessage = failure.stateUnknown
                        ? "PNG publication was not confirmed. Inspect its exact destination before retrying."
                        : "PNG publication failed before visibility."
                }
            } else if !result.durabilityWarnings.isEmpty {
                operationMessage = "The reviewed PNG and portable recipe are visible."
                errorMessage = "One or more visible files have a durability warning. Review every destination state before retrying."
            } else {
                operationMessage = "Exported a verified clean PNG and portable recipe."
                errorMessage = nil
            }
            return result
        } catch {
            errorMessage = "Export with recipe failed: \(error.localizedDescription)"
            return nil
        }
    }

    func exportPNGs(_ generations: [Generation]) {
        guard !generations.isEmpty else { return }
        lastBulkExportResult = nil
        publicationReport = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var outputs: [ReviewablePNG] = []
                outputs.reserveCapacity(generations.count)
                for generation in generations {
                    outputs.append(try await store.reviewablePNG(for: generation))
                }
                let panel = NSOpenPanel()
                panel.title = "Export \(generations.count) PNGs"
                panel.prompt = "Export"
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let directory = panel.url else { return }
                guard let receipt = OutputReviewGate.reviewBeforeExport(
                    outputs: outputs,
                    kind: .galleryBulk) else { return }
                guard await exportPNGs(
                    generations,
                    toDirectory: directory,
                    receipt: receipt) != nil else { return }
            } catch {
                errorMessage = "Bulk export preparation failed: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func exportPNGs(
        _ generations: [Generation],
        toDirectory directory: URL,
        receipt: OutputReviewGate.ReviewReceipt
    ) async -> BulkGenerationExportResult? {
        lastBulkExportResult = nil
        publicationReport = nil
        do {
            let result = try await store.exportPNGs(
                for: generations,
                toDirectory: directory,
                receipt: receipt)
            lastBulkExportResult = result
            let report = GalleryPublicationReport.bulk(result)
            publicationReport = report
            if result.failures.isEmpty && result.durabilityWarnings.isEmpty {
                operationMessage = "Exported \(result.exported.count) verified clean PNG\(result.exported.count == 1 ? "" : "s")."
                errorMessage = nil
            } else if result.failures.isEmpty {
                operationMessage = "Confirmed \(result.exported.count) reviewed PNG\(result.exported.count == 1 ? "" : "s") visible."
                errorMessage = "\(result.durabilityWarnings.count) visible file\(result.durabilityWarnings.count == 1 ? " has" : "s have") a durability warning."
            } else {
                let unknown = result.failures.filter(\.stateUnknown).count
                let failedOrUnattempted = result.failures.count - unknown
                operationMessage = result.exported.isEmpty
                    ? nil
                    : "Confirmed \(result.exported.count) reviewed PNG\(result.exported.count == 1 ? "" : "s") visible."
                errorMessage = "\(unknown) destination\(unknown == 1 ? " was" : "s were") not confirmed; \(failedOrUnattempted) failed before visibility or were unattempted. Review every destination state."
            }
            return result
        } catch {
            errorMessage = "Bulk export failed: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func deleteSelected(_ targets: [Generation]) async -> GalleryBulkDeleteResult {
        reloadTask?.cancel()
        reloadTask = nil
        let uniqueTargets = targets.reduce(into: [UUID: Generation]()) { result, generation in
            result[generation.id] = generation
        }
        var attemptedErrors: [UUID: String] = [:]
        for generation in uniqueTargets.values {
            do {
                _ = try await store.delete(id: generation.id)
            } catch {
                attemptedErrors[generation.id] = error.localizedDescription
            }
        }

        let remaining = await refreshFromStore()
        let remainingIDs = Set(remaining.map(\.id))
        let deletedIDs = Set(uniqueTargets.keys).subtracting(remainingIDs)
        let failedIDs = Set(uniqueTargets.keys).intersection(remainingIDs)
        selectedIDs.formIntersection(failedIDs)
        let failures = failedIDs.sorted { $0.uuidString < $1.uuidString }.map { id in
            GalleryBulkDeleteResult.Failure(
                generationID: id,
                message: attemptedErrors[id] ?? "The image is still present in the managed library.")
        }
        let result = GalleryBulkDeleteResult(
            requestedCount: uniqueTargets.count,
            deletedCount: deletedIDs.count,
            failures: failures)
        if failures.isEmpty {
            operationMessage = "Permanently deleted \(deletedIDs.count) image\(deletedIDs.count == 1 ? "" : "s")."
        } else {
            errorMessage = "Deleted \(deletedIDs.count); \(failures.count) failed. \(failures[0].message)"
        }
        return result
    }

    /// Returns the verified managed PNG for a new personal preset cover. The caller must pass
    /// these bytes into `PresetLibraryStore`; it must not retain the Gallery file URL.
    func pngDataForPreset(_ gen: Generation) async throws -> Data {
        try await store.pngDataForExport(for: gen)
    }

    /// Returns verified managed bytes for read-only local analysis. Image tools never retain the
    /// private Gallery URL and never mutate the managed PNG.
    func pngDataForImageTools(_ gen: Generation) async throws -> Data {
        try await store.pngDataForExport(for: gen)
    }

    func reportUseSettingsError(_ error: Error) {
        errorMessage = "Use settings failed: \(error.localizedDescription)"
    }

    @discardableResult
    func revealFolder() async -> Bool {
        let directory = await managedGalleryFolderURL()
        guard openFolder(directory) else {
            errorMessage = "The managed Gallery folder could not be opened in Finder."
            return false
        }
        errorMessage = nil
        return true
    }

    func dragProvider(for gen: Generation) -> NSItemProvider {
        let store = self.store
        return CleanPNGItemProvider.make(suggestedName: exportFileName(for: gen)) {
            let output = try await store.reviewablePNG(for: gen)
            guard let receipt = await OutputReviewGate.reviewBeforeExport(
                outputs: [output],
                kind: .dragAndDrop) else {
                throw CancellationError()
            }
            try await OutputReviewGate.consume(
                receipt,
                outputs: [output],
                kind: .dragAndDrop)
            return output.data
        }
    }

    func totalBytes(for generations: [Generation]) async -> Int64 {
        let paths: LibraryPaths
        if let current = self.paths {
            paths = current
        } else {
            let current = await store.libraryPaths()
            self.paths = current
            paths = current
        }
        let imageURLs = generations.compactMap { try? paths.imageURL(for: $0.imageFileName) }
        return await Task.detached(priority: .utility) {
            imageURLs.reduce(Int64(0)) { $0 + (FileProbe.size($1) ?? 0) }
        }.value
    }

    /// Full image — only for the detail view. `nonisolated async` so the multi-MB PNG decode
    /// runs off the MainActor (arrow-key navigation re-decodes per step).
    nonisolated func image(for gen: Generation) async -> NSImage? {
        guard let imageURL = try? await store.imageURL(for: gen) else { return nil }
        return NSImage(contentsOf: imageURL)
    }

    /// Fast DOWNSAMPLED thumbnail for the grid — decodes to ~`maxPixel` px, backed by a disk
    /// cache keyed by the immutable PNG file name.
    nonisolated func thumbnail(for gen: Generation, maxPixel: Int = 340) async -> NSImage? {
        guard let imageURL = try? await store.imageURL(for: gen),
              let cacheURL = try? await store.thumbnailURL(for: gen) else { return nil }
        if let cached = NSImage(contentsOf: cacheURL) { return cached }
        guard let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // Cache to disk (best-effort).
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let dest = CGImageDestinationCreateWithURL(cacheURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func refreshFromStore() async -> [Generation] {
        let paths = await store.libraryPaths()
        let list = await store.all()
        apply(list, paths: paths)
        await refreshAnnotations(for: list)
        return list
    }

    private func refreshAnnotations(for list: [Generation]) async {
        do {
            let refreshed = try await annotations.reconcile(
                validGenerationIDs: Set(list.map(\.id)))
            guard !Task.isCancelled else { return }
            favoriteIDs = refreshed
        } catch {
            if !reportedAnnotationFailure {
                reportedAnnotationFailure = true
                errorMessage = "Favorites are unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func apply(_ list: [Generation], paths: LibraryPaths) {
        self.paths = paths
        generations = list
        if let selected, !list.contains(where: { $0.id == selected.id }) {
            self.selected = nil
        }
        let validIDs = Set(list.map(\.id))
        selectedIDs.formIntersection(validIDs)
        favoriteIDs.formIntersection(validIDs)
        if let selectionAnchorID, !validIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
    }

    private func exportFileName(for gen: Generation) -> String {
        "Twisterminigen-\(gen.seed).png"
    }

    private nonisolated static func removeContents(
        of directory: URL
    ) async throws -> LibraryDeletionResult {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: directory.path) else {
                return LibraryDeletionResult()
            }
            if (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) != nil {
                throw GenerationStoreError.unsafeFilesystemItem(directory)
            }

            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [])
            var result = LibraryDeletionResult()
            for file in files {
                let bytes = Int64(
                    (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                try fileManager.removeItem(at: file)
                result.count += 1
                result.bytes += bytes
            }
            return result
        }.value
    }
}

struct GalleryGenerationGroup: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case provenance(UUID)
        case ungrouped(UUID)
    }

    let id: ID
    let generations: [Generation]
    let provenance: GenerationProvenance?

    var title: String? {
        guard let provenance else { return nil }
        switch provenance.kind {
        case .batch: return "Batch"
        case .queueLab: return "Queue Lab"
        }
    }

    var summary: String? {
        guard let provenance else { return nil }
        let completed = generations.count == provenance.itemCount
            ? "\(provenance.itemCount) images"
            : "\(generations.count) of \(provenance.itemCount) images"
        guard let grid = provenance.queueLabGrid else { return completed }
        var details = [completed, "\(grid.seedCount) seed\(grid.seedCount == 1 ? "" : "s")"]
        if grid.xCount > 1 || grid.yCount > 1 {
            details.append("\(grid.xCount)×\(grid.yCount) grid")
        }
        let axes = [grid.xLabel, grid.yLabel].compactMap { $0 }
        if !axes.isEmpty { details.append(axes.joined(separator: " × ")) }
        return details.joined(separator: " · ")
    }

}

struct GalleryBulkDeleteResult: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        let generationID: UUID
        let message: String
    }

    let requestedCount: Int
    let deletedCount: Int
    let failures: [Failure]
}

extension LibraryRepairReport {
    var hasActivity: Bool {
        recoveredTransactions > 0
            || detectedIssueCount > 0
            || !quarantinedItems.isEmpty
            || indexWasRewritten
            || !errors.isEmpty
    }

    func conciseStatus(prefix: String) -> String {
        let unsafeFindings = unsafeRecords.count + unsafeImageEntries.count
        let thumbnailFindings = missingThumbnails.count
            + staleThumbnails.count
            + unsafeThumbnailEntries.count
        let rewrite = indexWasRewritten ? "; index rewritten" : ""
        return "\(prefix): recovered \(recoveredTransactions); orphaned \(orphanedImages.count); "
            + "missing \(missingImages.count); unsafe \(unsafeFindings); "
            + "duplicates \(duplicateRecords.count); thumbnails \(thumbnailFindings); "
            + "quarantined \(quarantinedItems.count); errors \(errors.count)\(rewrite)."
    }
}
