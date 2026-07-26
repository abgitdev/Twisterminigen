import Foundation

/// One concrete model build exposed by the Gallery's dynamic model filter.
struct GalleryModelFilter: Hashable, Identifiable, Sendable {
    let modelID: String
    let variantID: String

    var id: Self { self }
    var label: String { "\(modelID) · \(variantID)" }
}

enum GalleryCaptureFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case exact
    case legacy

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .all: return "All captures"
        case .exact: return "Exact captures"
        case .legacy: return "Legacy inferred"
        }
    }

    var controlTitle: String {
        switch self {
        case .all: return "Capture"
        case .exact: return "Exact"
        case .legacy: return "Legacy"
        }
    }

    func includes(_ capture: GenerationRecipeCapture) -> Bool {
        switch self {
        case .all: return true
        case .exact: return capture == .exact
        case .legacy: return capture == .legacy
        }
    }
}

/// Reused by Remix, Lettering, and Regional prompts filters so every feature supports an explicit
/// "with" and "without" query instead of only a lossy on/off toggle.
enum GalleryFeatureFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case included
    case excluded

    var id: String { rawValue }

    func includes(_ isPresent: Bool) -> Bool {
        switch self {
        case .all: return true
        case .included: return isPresent
        case .excluded: return !isPresent
        }
    }
}

struct GalleryLoRAOption: Hashable, Identifiable, Sendable {
    let managedID: UUID
    let sha256: String

    var id: UUID { managedID }

    /// Recipes intentionally persist immutable IDs/hashes rather than mutable catalog names.
    /// A short stable ID therefore remains truthful even if the local LoRA was later removed.
    var label: String {
        "LoRA \(managedID.uuidString.prefix(8).uppercased())"
    }
}

enum GalleryLoRAFilter: Hashable, Sendable {
    case all
    case any
    case none
    case specific(UUID)

    var isActive: Bool { self != .all }

    func includes(_ references: [GenerationRecipe.LoRAReference]) -> Bool {
        switch self {
        case .all: return true
        case .any: return !references.isEmpty
        case .none: return references.isEmpty
        case .specific(let id): return references.contains { $0.managedID == id }
        }
    }
}

struct GalleryResolutionFilter: Hashable, Identifiable, Sendable {
    let width: Int
    let height: Int

    var id: Self { self }
    var label: String { "\(width) × \(height)" }
}

enum GalleryDateFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case today
    case last7Days
    case last30Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Any date"
        case .today: return "Today"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        }
    }

    func includes(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        if self == .all { return true }
        guard date <= now else { return false }
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .last7Days:
            guard let start = calendar.date(
                byAdding: .day,
                value: -6,
                to: calendar.startOfDay(for: now)) else { return false }
            return date >= start
        case .last30Days:
            guard let start = calendar.date(
                byAdding: .day,
                value: -29,
                to: calendar.startOfDay(for: now)) else { return false }
            return date >= start
        }
    }
}

/// Complete Gallery query state. Keeping matching outside SwiftUI makes filters deterministic,
/// testable, and shared by the grid, selection, and future export workflows.
struct GalleryFilters: Sendable {
    var search = ""
    var model: GalleryModelFilter?
    var capture: GalleryCaptureFilter = .all
    var favoritesOnly = false
    var lora: GalleryLoRAFilter = .all
    var remix: GalleryFeatureFilter = .all
    var textMode: GalleryFeatureFilter = .all
    var spatial: GalleryFeatureFilter = .all
    var resolution: GalleryResolutionFilter?
    var date: GalleryDateFilter = .all

    func includes(
        _ generation: Generation,
        isFavorite: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let recipe = generation.recipe
        guard model.map({
            $0.modelID == recipe.model.modelID && $0.variantID == recipe.model.variantID
        }) ?? true,
        capture.includes(generation.recipeCapture),
        !favoritesOnly || isFavorite,
        lora.includes(recipe.loras),
        remix.includes(generation.isRemix),
        textMode.includes(recipe.prompts.exactText != nil),
        spatial.includes(!recipe.regions.isEmpty),
        resolution.map({ $0.width == generation.width && $0.height == generation.height }) ?? true,
        date.includes(generation.createdAt, now: now, calendar: calendar)
        else { return false }

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return searchableFields(of: generation).contains {
            $0.lowercased().contains(query)
        }
    }

    private func searchableFields(of generation: Generation) -> [String] {
        let recipe = generation.recipe
        var fields = [
            recipe.prompts.positive,
            recipe.prompts.negative,
            recipe.prompts.exactText ?? "",
            recipe.model.modelID,
            recipe.model.variantID,
            String(generation.seed),
            "\(generation.width)x\(generation.height)",
            "\(generation.width)×\(generation.height)",
        ]
        fields.append(contentsOf: recipe.loras.flatMap {
            [$0.managedID.uuidString, $0.sha256]
        })
        fields.append(contentsOf: recipe.regions.map(\.prompt))
        if let input = recipe.inputImage {
            fields.append(input.managedID.uuidString)
            fields.append(input.sha256)
            if let parentID = input.sourceGenerationID {
                fields.append(parentID.uuidString)
            }
        }
        return fields
    }
}
