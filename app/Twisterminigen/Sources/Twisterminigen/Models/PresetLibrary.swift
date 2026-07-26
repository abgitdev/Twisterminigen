import Foundation

/// A visual recipe shown in the Presets library. Built-ins are recreated from the
/// current local model manifest; personal cards are kept in `PresetLibraryStore`.
struct PresetCard: Codable, Hashable, Identifiable, Sendable {
    enum Origin: String, Codable, Hashable, Sendable {
        case builtIn
        case personal
    }

    var id: String
    var origin: Origin
    var categoryID: String
    var title: String
    var summary: String
    var recipe: GenerationRecipe
    /// A canonical JPEG filename in the managed preset-cover directory. This is never
    /// an external URL or security-scoped bookmark.
    var coverFilename: String?
    var createdAt: Date
    var updatedAt: Date

    var isPersonal: Bool { origin == .personal }
    var prefersFullFrameCover: Bool {
        categoryID == BuiltinPresetCatalog.characterSheetCategoryID
    }
    var dimensionsText: String { "\(recipe.canvas.width) × \(recipe.canvas.height)" }
    var stepsText: String { "\(recipe.sampler.steps) steps" }
    var modelText: String {
        "\(recipe.model.checkpointFamily.displayName) · \(recipe.model.quantizationTier.displayName)"
    }
}

struct PresetCategory: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var systemImage: String
    var isPersonal: Bool

    init(id: String, title: String, systemImage: String, isPersonal: Bool) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isPersonal = isPersonal
    }
}

struct PresetLibrarySnapshot: Sendable, Equatable {
    var categories: [PresetCategory]
    var cards: [PresetCard]
    var favoritePresetIDs: Set<String>
    var removedBuiltinPresetIDs: Set<String>
    var removedBuiltinCategoryIDs: Set<String>
    var startupWarning: String?
}

/// The editable payload used by the editor. It deliberately carries the whole recipe,
/// not a reduced set of visible controls, so LoRA, Remix, and Regional prompts references
/// survive a save/update byte-for-byte.
struct PresetCardDraft: Sendable {
    var id: String?
    var categoryID: String
    var title: String
    var summary: String
    var recipe: GenerationRecipe

    init(
        id: String? = nil,
        categoryID: String,
        title: String,
        summary: String,
        recipe: GenerationRecipe
    ) {
        self.id = id
        self.categoryID = categoryID
        self.title = title
        self.summary = summary
        self.recipe = recipe
    }
}

enum BuiltinPresetCatalog {
    static let coverPixelSize = 256
    static let maximumCoverBytes = 128 * 1_024
    static let characterSheetCategoryID = "character-sheet"

    static let categories: [PresetCategory] = [
        .init(id: "interiors", title: "Interiors", systemImage: "lamp.desk", isPersonal: false),
        .init(id: "exteriors", title: "Exteriors", systemImage: "house", isPersonal: false),
        .init(id: "portrait", title: "Portrait", systemImage: "person.crop.rectangle", isPersonal: false),
        .init(
            id: characterSheetCategoryID,
            title: "Character Sheet",
            systemImage: "person.crop.rectangle.stack",
            isPersonal: false),
        .init(id: "anime", title: "Anime", systemImage: "sparkles", isPersonal: false),
        .init(id: "sci-fi", title: "Sci-Fi", systemImage: "fossil.shell", isPersonal: false),
        .init(id: "travel", title: "Travel", systemImage: "airplane", isPersonal: false),
        .init(id: "nature", title: "Nature", systemImage: "leaf", isPersonal: false),
        .init(id: "cinema", title: "Cinema", systemImage: "film", isPersonal: false),
        .init(id: "product", title: "Product", systemImage: "shippingbox", isPersonal: false),
        .init(id: "automotive", title: "Automotive", systemImage: "car", isPersonal: false),
        .init(id: "sports", title: "Sports", systemImage: "figure.run", isPersonal: false),
        .init(id: "fantasy", title: "Fantasy", systemImage: "wand.and.stars", isPersonal: false),
        .init(id: "selfie", title: "Selfie", systemImage: "camera", isPersonal: false),
        .init(id: "industry", title: "Industry", systemImage: "wrench.and.screwdriver", isPersonal: false),
        .init(id: "art", title: "Art", systemImage: "paintpalette", isPersonal: false),
        .init(id: "moments", title: "Moments", systemImage: "clock", isPersonal: false),
    ]

    private struct Definition: Sendable {
        let id: String
        let categoryID: String
        let title: String
        let summary: String
        let prompt: String
        let width: Int
        let height: Int
        let seed: UInt64
    }

    private struct SupplementalDocument: Decodable {
        let schema: String
        let version: Int
        let presets: [SupplementalDefinition]
    }

    private struct SupplementalDefinition: Decodable {
        let id: String
        let categoryID: String
        let title: String
        let summary: String
        let prompt: String
        let width: Int
        let height: Int
        let seed: String
    }

    /// These are original local-Turbo prompts. They use the current official Turbo defaults
    /// (8 steps, CFG 0, μ 1.15) and deliberately avoid artists, brands, franchises, LoRAs,
    /// cloud Style References, moodboards, and prompt-expander claims.
    private static let originalDefinitions: [Definition] = [
        .init(id: "builtin.rain-atrium", categoryID: "interiors", title: "Rain Atrium", summary: "Quiet concrete, wet light, living green.", prompt: "A calm rain-soaked residential atrium, pale cast concrete walls, a single olive tree rising from a shallow reflecting pool, two low linen chairs, droplets gathering on a skylight, straight-on architectural composition, restrained contemporary editorial photography, soft overcast daylight, tactile stone and brushed metal, muted olive, chalk, charcoal and silver palette, no people, no text.", width: 1024, height: 1024, seed: 814_220_631),
        .init(id: "builtin.cobalt-reading-room", categoryID: "interiors", title: "Cobalt Reading Room", summary: "Graphic color blocking for a focused room.", prompt: "An intimate reading room with a deep cobalt built-in bookcase, a terracotta lounge chair, a round travertine side table and one small lamp, eye-level corner composition, polished interior editorial photograph, late-afternoon sun casting long geometric shadows, matte lacquer, woven fabric and warm stone textures, cobalt blue, burnt orange, cream and umber palette, no people, no text.", width: 1024, height: 1024, seed: 572_904_118),
        .init(id: "builtin.desert-house", categoryID: "exteriors", title: "Geometric Dusk Villa", summary: "White cantilevers, warm interiors, and blue-hour calm.", prompt: "A futuristic modern villa with bold white geometric architecture, sharp angular rooflines, and large cantilevered sections. Floor-to-ceiling glass windows reveal warm minimalist interiors with recessed lighting. A wide illuminated staircase leads from the foreground to the main entrance, surrounded by manicured greenery and slender palm trees. A reflecting pool borders the house, mirroring the glowing steps and clean façade. The exterior features smooth white surfaces, open terraces, glass railings, and dramatic asymmetrical forms. The scene is set at dusk under a soft blue sky, creating a calm, elegant atmosphere.", width: 1024, height: 1024, seed: 5_115_011_706_942_581_160),
        .init(id: "builtin.gold-thread-macro", categoryID: "portrait", title: "Curtain Light Portrait", summary: "Soft sun and delicate curtain shadows across natural skin.", prompt: "A close beauty portrait of an adult with a calm direct gaze, centered head-and-shoulders composition, modern editorial photograph, soft warm morning sunlight filtered through sheer curtains, delicate feathered curtain shadows falling diagonally across the face and shoulders, natural skin texture and subtle freckles, dark hair loosely swept back, simple muted terracotta satin top, warm cream, deep brown, terracotta and soft gold palette, shallow depth of field, no facial jewelry, no thread, no face paint, no text.", width: 864, height: 1152, seed: 182_440_759),
        .init(id: "builtin.crimson-flower-portrait", categoryID: "portrait", title: "Crimson Flower Portrait", summary: "A high-fashion portrait with botanical tension.", prompt: "A studio portrait of an adult wearing a sculptural crimson flower collar, three-quarter pose looking beyond the camera, vertical high-fashion editorial composition, hard clean spotlight against a dove-gray backdrop, crisp facial anatomy, velvet petals, translucent organza and polished skin texture, crimson, gray, black and small amber highlights, controlled cinematic contrast, no text.", width: 864, height: 1152, seed: 649_351_082),
        .init(id: "builtin.blue-wind", categoryID: "anime", title: "Blue Wind", summary: "A precise animated frame full of weather.", prompt: "An original anime-style scene of a young adult cyclist pausing on a hill road as blue wind lifts a long coat and loose paper maps, low-angle wide composition with dramatic clouds and distant city lights, expressive hand-drawn cel animation, cool twilight rim light, clean linework, layered painted sky and textured asphalt, cobalt, pale cyan, slate and small coral palette, no logos, no text.", width: 1280, height: 720, seed: 734_910_266),
        .init(id: "builtin.summer-crowd", categoryID: "anime", title: "Summer Crowd", summary: "A bright crowd scene with one clear emotional beat.", prompt: "An original anime-style summer train platform, a young adult in a yellow raincoat standing still while a crowd moves around them, overhead view with a strong diagonal platform edge, vibrant hand-drawn animation frame, humid daylight after rain, glossy puddles, cotton fabric, paper tickets and painted metal textures, lemon yellow, teal, white and soft gray palette, readable faces, no logos, no text.", width: 1024, height: 1024, seed: 260_817_534),
        .init(id: "builtin.liquid-horizon", categoryID: "sci-fi", title: "Liquid Horizon", summary: "A strange clean future without visual noise.", prompt: "A solitary explorer in a matte white suit walking beside a mirror-smooth black liquid horizon beneath a huge pale moon, wide cinematic composition with the figure small in frame, original science-fiction concept art, cold backlight and a thin mist at ground level, ceramic suit panels, liquid reflections and fine dust, black, pearl, blue-gray and pale violet palette, no symbols, no text.", width: 1280, height: 720, seed: 497_301_688),
        .init(id: "builtin.chromed-orbital-relic", categoryID: "sci-fi", title: "Chromed Orbital Relic", summary: "A bold artifact study for a near future.", prompt: "A weathered chrome orbital relic suspended inside a vast industrial docking bay, close low-angle composition, original science-fiction product concept photograph, a narrow beam of warm light through high dust, scratched metal, braided cable, oxidized joints and matte black support frame, steel, graphite, tarnished gold and amber palette, crisp scale cues, no text.", width: 1024, height: 1024, seed: 916_773_405),
        .init(id: "builtin.dawn-window-journey", categoryID: "travel", title: "Dawn Window Journey", summary: "The first light of a long rail journey.", prompt: "A view through a train window at dawn, a passenger's hand resting on the lower frame while rice fields and low hills blur outside, horizontal travel photograph from the seat, delicate peach sunrise light, soft motion streaks, fogged glass and woven jacket textures, pale green, misty blue, peach and charcoal palette, intimate and observational, no text.", width: 1280, height: 720, seed: 351_902_774),
        .init(id: "builtin.harvest-mouse", categoryID: "nature", title: "Harvest Mouse", summary: "Small natural drama in a single grass stem.", prompt: "A harvest mouse balancing on a bending seed head after rain, close macro composition at eye level, refined wildlife photograph, early morning backlight shining through tiny water droplets, detailed fur, translucent grass and soft meadow bokeh, tawny brown, fresh green, cream and silver palette, anatomically believable, no text.", width: 1024, height: 1024, seed: 808_642_319),
        .init(id: "builtin.coastal-blue-hour", categoryID: "cinema", title: "Coastal Blue Hour", summary: "A still frame with a charged empty space.", prompt: "A lone adult standing beside a small coastal motel at blue hour, seen from far across an empty parking lot, wide cinematic frame with a glowing doorway and damp asphalt, understated film still, cool sodium and blue practical light, wind-blown coat, painted concrete and reflective puddles, navy, cyan, warm amber and black palette, quiet suspense, no readable signs or text.", width: 1280, height: 720, seed: 176_538_921),
        .init(id: "builtin.dusty-monument", categoryID: "cinema", title: "Dusty Monument", summary: "Sun, dust, and a monumental human scale.", prompt: "An adult in a dark coat crossing a sunlit hall beneath a monumental concrete stair, vertical cinematic frame with the person small against the architecture, dramatic film still, sharp afternoon shafts of light through dusty air, raw concrete, worn leather and polished stone, ochre, black, ivory and muted rust palette, strong silhouette, no text.", width: 864, height: 1152, seed: 692_174_508),
        .init(id: "builtin.vinyl-icon", categoryID: "product", title: "Vinyl Icon", summary: "Tactile record player styling with clean commercial light.", prompt: "A compact translucent amber music player resting on a black vinyl record, isolated three-quarter tabletop composition, premium product photograph, crisp studio side light with a controlled soft shadow, transparent resin, brushed aluminum, rubber and glossy vinyl materials, amber, black, graphite and warm cream palette, precise edges, no brand, no logo, no text.", width: 1024, height: 1024, seed: 421_865_097),
        .init(id: "builtin.sculptural-lamp", categoryID: "product", title: "Sculptural Lamp", summary: "A simple luminous object in a rich material study.", prompt: "A sculptural table lamp made from stacked milky glass discs and a dark walnut base, centered against a soft clay backdrop, high-end product editorial photograph, warm directional studio light and subtle reflected highlight, frosted glass, walnut grain and satin metal textures, cream, walnut, clay and muted brass palette, no brand, no logo, no text.", width: 1024, height: 1024, seed: 785_049_663),
        .init(id: "builtin.electric-night-drive", categoryID: "automotive", title: "Electric Night Drive", summary: "Fast lines and wet city light.", prompt: "An original low electric coupe moving through a rain-wet city street at night, rear three-quarter tracking composition, contemporary automotive editorial photograph, long blue reflections and warm storefront glow streaking across the bodywork, glossy paint, wet asphalt, glass and brushed alloy materials, midnight blue, silver, amber and black palette, no badges, no logos, no text.", width: 1280, height: 720, seed: 284_730_951),
        .init(id: "builtin.midair-serve", categoryID: "sports", title: "Midair Serve", summary: "A decisive athletic moment with clear form.", prompt: "An adult tennis player captured at the top of a serve, body fully airborne against an empty pale-blue court, low upward angle with generous negative space, premium sports photograph, bright clean afternoon sun and a crisp ground shadow, believable anatomy, textured performance fabric, racket strings and chalky court surface, sky blue, white, navy and small neon accent palette, no logos, no text.", width: 864, height: 1152, seed: 538_691_204),
        .init(id: "builtin.bronze-guardian", categoryID: "fantasy", title: "Bronze Guardian", summary: "A grounded fantasy portrait with tactile age.", prompt: "An original fantasy guardian in worn bronze armor standing at the mouth of a foggy cedar forest, waist-up three-quarter portrait, detailed cinematic fantasy illustration, pale dawn light catching etched metal and wet leaves, believable face and hands, patinated bronze, leather, moss and wool textures, forest green, oxidized teal, bronze and gray palette, no emblem, no text.", width: 864, height: 1152, seed: 904_126_377),
        .init(id: "builtin.flora-oracle", categoryID: "fantasy", title: "Flora Oracle", summary: "A luminous botanical ritual without borrowed lore.", prompt: "An original fantasy oracle seated inside a giant flower made of translucent petals, surrounded by floating pollen and fine roots, centered square composition, richly detailed storybook illustration, soft luminous dusk light from within the petals, velvet fabric, translucent plant veins, soil and gold thread textures, plum, moss, blush and warm gold palette, elegant hands and face, no text.", width: 1024, height: 1024, seed: 317_580_846),
        .init(id: "builtin.analog-mirror-moment", categoryID: "selfie", title: "Analog Mirror Moment", summary: "A natural self portrait with texture and restraint.", prompt: "A natural mirror selfie of an adult in a small sunlit apartment, phone partly outside the frame, relaxed seated pose and direct reflection, candid analog-inspired photograph, late morning window light, soft film grain, linen shirt, brushed steel mirror edge and houseplant texture, warm white, faded green, brown and soft blue palette, believable hands, no logo, no text.", width: 864, height: 1152, seed: 665_243_990),
        .init(id: "builtin.amber-assembly", categoryID: "industry", title: "Amber Assembly", summary: "Human-scale craft inside a clean industrial system.", prompt: "A technician in a dark work jacket assembling a precision glass valve at a long workbench, side-on industrial editorial composition, warm amber task lights against a deep shadowed workshop, crisp documentary photograph, polished steel, ribbed glass, black rubber and worn wood textures, amber, graphite, steel blue and brown palette, believable hands, no labels, no text.", width: 1280, height: 720, seed: 749_028_615),
        .init(id: "builtin.fragmented-alpine", categoryID: "art", title: "Fragmented Alpine", summary: "A mountain landscape rebuilt as luminous paper planes.", prompt: "An original abstract alpine landscape assembled from torn translucent paper planes, a winding river suggested by a single silver line, square gallery composition, contemporary mixed-media artwork, diffuse gallery light revealing paper fibers and layered edges, indigo, glacier blue, bone white, graphite and a small coral accent palette, intricate but calm, no letters, no text.", width: 1024, height: 1024, seed: 128_476_359),
        .init(id: "builtin.rooted-ink", categoryID: "art", title: "Rooted Ink", summary: "Organic ink and mineral color in a spare composition.", prompt: "An original abstract artwork of black ink roots spreading through a field of mineral blue and pale peach pigment, vertical composition with generous breathing room, tactile handmade paper and aqueous ink blooms, soft raking light emphasizing deckled fibers, black, lapis, peach, cream and muted copper palette, no calligraphy, no letters, no text.", width: 864, height: 1152, seed: 882_605_173),
        .init(id: "builtin.kitchen-sunbreak", categoryID: "moments", title: "Kitchen Sunbreak", summary: "An ordinary pause, observed with warmth.", prompt: "A candid morning kitchen moment: an adult laughing while slicing citrus beside an open window, medium-wide table-level composition, intimate lifestyle photograph, low warm sunlight breaking through cloud and catching steam from a mug, ceramic, cotton, wood and translucent fruit textures, lemon yellow, warm white, green and soft brown palette, believable hands, no labels, no text.", width: 1280, height: 720, seed: 451_319_728),
    ]

    private static let supplementalDefinitionCount = 219
    private static let supplementalSchema = "twisterminigen.supplemental-builtin-presets"
    private static let supplementalVersion = 2
    private static let supplementalDocumentKeys: Set<String> = ["schema", "version", "presets"]
    private static let supplementalDefinitionKeys: Set<String> = [
        "id",
        "categoryID",
        "title",
        "summary",
        "prompt",
        "width",
        "height",
        "seed",
    ]

    private static let definitions: [Definition] = {
        originalDefinitions + loadSupplementalDefinitions()
    }()

    private static func loadSupplementalDefinitions() -> [Definition] {
        guard let url = Bundle.module.url(
            forResource: "supplemental-builtin-presets",
            withExtension: "json",
            subdirectory: "PresetCovers")
            ?? Bundle.module.url(
                forResource: "supplemental-builtin-presets",
                withExtension: "json"),
              let data = try? Data(contentsOf: url),
              hasExactSupplementalPublicKeyShape(data),
              let document = try? JSONDecoder().decode(SupplementalDocument.self, from: data),
              document.schema == supplementalSchema,
              document.version == supplementalVersion,
              document.presets.count == supplementalDefinitionCount
        else {
            assertionFailure("The supplemental built-in preset catalog is missing or invalid.")
            return []
        }

        let validCategoryIDs = Set(categories.map(\.id))
        let originalIDs = Set(originalDefinitions.map(\.id))
        var seenIDs = Set<String>()
        var converted: [Definition] = []
        converted.reserveCapacity(document.presets.count)

        for preset in document.presets {
            guard preset.id.hasPrefix("builtin."),
                  !originalIDs.contains(preset.id),
                  seenIDs.insert(preset.id).inserted,
                  validCategoryIDs.contains(preset.categoryID),
                  !preset.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !preset.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  preset.width > 0,
                  preset.height > 0,
                  let seed = UInt64(preset.seed)
            else {
                assertionFailure("The supplemental built-in preset catalog has an invalid entry.")
                return []
            }
            converted.append(.init(
                id: preset.id,
                categoryID: preset.categoryID,
                title: preset.title,
                summary: preset.summary,
                prompt: preset.prompt,
                width: preset.width,
                height: preset.height,
                seed: seed))
        }
        return converted
    }

    /// Reject unknown keys because `Decodable` would otherwise accept a stale manifest that still
    /// embeds local Gallery provenance.
    private static func hasExactSupplementalPublicKeyShape(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == supplementalDocumentKeys,
              let presets = root["presets"] as? [[String: Any]]
        else {
            return false
        }
        return presets.allSatisfy { Set($0.keys) == supplementalDefinitionKeys }
    }

    /// Stable identities are also the persistence keys for favorites and locally removed examples.
    /// Keep them independent from the current model manifest so preferences can be validated
    /// without loading or probing model weights.
    static var stableIDs: Set<String> { Set(definitions.map(\.id)) }

    static var expectedCoverFilenames: Set<String> {
        Set(definitions.map { definition in
            "\(definition.id.dropFirst("builtin.".count)).jpg"
        })
    }

    static func stableIDs(in categoryID: String) -> Set<String> {
        Set(definitions.lazy.filter { $0.categoryID == categoryID }.map(\.id))
    }

    static func cards(catalog: ModelCatalog, date: Date = .distantPast) -> [PresetCard] {
        definitions.map { definition in
            let recipe = GenerationRecipeRuntime.currentTurboRecipe(
                prompt: definition.prompt,
                width: definition.width,
                height: definition.height,
                steps: 8,
                seed: .fixed(definition.seed),
                catalog: catalog)
            return PresetCard(
                id: definition.id,
                origin: .builtIn,
                categoryID: definition.categoryID,
                title: definition.title,
                summary: definition.summary,
                recipe: recipe,
                coverFilename: "\(definition.id.dropFirst("builtin.".count)).jpg",
                createdAt: date,
                updatedAt: date)
        }
    }
}
