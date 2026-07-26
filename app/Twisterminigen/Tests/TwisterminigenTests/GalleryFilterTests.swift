import Foundation
import Testing
@testable import Twisterminigen

@Suite("Gallery filters")
struct GalleryFilterTests {
    @Test("Advanced feature filters compose without replacing legacy filters")
    func advancedFiltersCompose() {
        let loraID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let parentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let now = Date(timeIntervalSince1970: 1_783_756_800) // 2026-07-11 00:00:00 UTC
        let generation = filteredGeneration(
            createdAt: now.addingTimeInterval(-2 * 86_400),
            loraID: loraID,
            parentID: parentID,
            textMode: true,
            spatial: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var filters = GalleryFilters(
            search: "NEON",
            model: GalleryModelFilter(modelID: "test-model", variantID: "q8"),
            capture: .exact,
            favoritesOnly: true,
            lora: .specific(loraID),
            remix: .included,
            textMode: .included,
            spatial: .included,
            resolution: GalleryResolutionFilter(width: 768, height: 512),
            date: .last7Days)

        #expect(filters.includes(
            generation,
            isFavorite: true,
            now: now,
            calendar: calendar))

        filters.model = GalleryModelFilter(modelID: "other", variantID: "q8")
        #expect(!filters.includes(generation, isFavorite: true, now: now, calendar: calendar))
        filters.model = GalleryModelFilter(modelID: "test-model", variantID: "q8")
        #expect(!filters.includes(generation, isFavorite: false, now: now, calendar: calendar))
        filters.favoritesOnly = false
        filters.capture = .legacy
        #expect(!filters.includes(generation, isFavorite: true, now: now, calendar: calendar))
    }

    @Test("LoRA filter distinguishes any, none, and one exact adapter")
    func loraModes() {
        let firstID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let secondID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let withLoRA = filteredGeneration(loraID: firstID)
        let withoutLoRA = filteredGeneration()

        #expect(GalleryLoRAFilter.any.includes(withLoRA.recipe.loras))
        #expect(!GalleryLoRAFilter.any.includes(withoutLoRA.recipe.loras))
        #expect(GalleryLoRAFilter.none.includes(withoutLoRA.recipe.loras))
        #expect(!GalleryLoRAFilter.none.includes(withLoRA.recipe.loras))
        #expect(GalleryLoRAFilter.specific(firstID).includes(withLoRA.recipe.loras))
        #expect(!GalleryLoRAFilter.specific(secondID).includes(withLoRA.recipe.loras))
    }

    @Test("Remix, Lettering, Regional prompts, and resolution support inclusive and exclusive queries")
    func featureModes() {
        let advanced = filteredGeneration(
            parentID: UUID(),
            textMode: true,
            spatial: true)
        let plain = filteredGeneration()

        var filters = GalleryFilters()
        filters.remix = .included
        filters.textMode = .included
        filters.spatial = .included
        filters.resolution = .init(width: 768, height: 512)
        #expect(filters.includes(advanced, isFavorite: false))
        #expect(!filters.includes(plain, isFavorite: false))

        filters.remix = .excluded
        filters.textMode = .excluded
        filters.spatial = .excluded
        #expect(filters.includes(plain, isFavorite: false))
        #expect(!filters.includes(advanced, isFavorite: false))
    }

    @Test("Date ranges use calendar-day boundaries")
    func dateRanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(2026, 7, 15, hour: 18, calendar: calendar)

        #expect(GalleryDateFilter.today.includes(
            date(2026, 7, 15, hour: 0, calendar: calendar),
            now: now,
            calendar: calendar))
        #expect(!GalleryDateFilter.today.includes(
            date(2026, 7, 14, hour: 23, calendar: calendar),
            now: now,
            calendar: calendar))
        #expect(GalleryDateFilter.last7Days.includes(
            date(2026, 7, 9, hour: 0, calendar: calendar),
            now: now,
            calendar: calendar))
        #expect(!GalleryDateFilter.last7Days.includes(
            date(2026, 7, 8, hour: 23, calendar: calendar),
            now: now,
            calendar: calendar))
        #expect(GalleryDateFilter.last30Days.includes(
            date(2026, 6, 16, hour: 0, calendar: calendar),
            now: now,
            calendar: calendar))
        #expect(!GalleryDateFilter.last30Days.includes(
            date(2026, 6, 15, hour: 23, calendar: calendar),
            now: now,
            calendar: calendar))
    }

    @Test("Search covers exact text, regions, LoRA identity, resolution, and parent lineage")
    func advancedSearchFields() {
        let loraID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let parentID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let generation = filteredGeneration(
            loraID: loraID,
            parentID: parentID,
            textMode: true,
            spatial: true)

        for query in [
            "VISIBLE COPY",
            "foreground subject",
            "55555555",
            String(repeating: "b", count: 64),
            "768×512",
            "66666666",
        ] {
            var filters = GalleryFilters()
            filters.search = query
            #expect(filters.includes(generation, isFavorite: false), "Missing query: \(query)")
        }
    }
}

private func filteredGeneration(
    createdAt: Date = Date(timeIntervalSince1970: 1_783_756_800),
    loraID: UUID? = nil,
    parentID: UUID? = nil,
    textMode: Bool = false,
    spatial: Bool = false
) -> Generation {
    var recipe = GenerationRecipe.turbo(
        prompt: "Neon city",
        model: .init(
            modelID: "test-model",
            variantID: "q8",
            manifestHash: String(repeating: "a", count: 64)),
        seed: .fixed(73))
    recipe.canvas = .init(width: 768, height: 512)
    if let loraID {
        recipe.loras = [.init(
            managedID: loraID,
            sha256: String(repeating: "b", count: 64),
            scale: 0.8)]
    }
    if textMode {
        recipe.prompts.exactText = "Visible Copy"
    }
    if spatial {
        recipe.regions = [.init(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            prompt: "foreground subject",
            rect: .init(x0: 0.1, y0: 0.1, x1: 0.8, y1: 0.9))]
    }
    if let parentID {
        recipe.inputImage = .init(
            managedID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            sha256: String(repeating: "c", count: 64),
            strength: 0.65,
            resize: .fill,
            sourceGenerationID: parentID)
    }
    return Generation(
        recipe: recipe,
        createdAt: createdAt,
        durationSeconds: 1,
        imageFileName: "filter.png")
}

private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int,
    calendar: Calendar
) -> Date {
    calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour))!
}
