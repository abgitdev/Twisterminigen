import AppIntents
import Foundation

/// One validated, local, UI-free render. Validation occurs before the runtime is consulted, so a
/// malformed Shortcut cannot touch weights, stores or MLX.
@available(macOS 14.0, *)
struct RenderRecipeIntent: AppIntent {
    static let title: LocalizedStringResource = "Render Twisterminigen Recipe"
    static let description = IntentDescription(
        "Render one validated Krea 2 image locally and save it to Twisterminigen Gallery."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Recipe JSON",
        default: #"{"prompt":"a small letterpress poster reading HELLO, cobalt ink on warm paper","width":1024,"height":1024,"steps":8,"seed":202}"#)
    var recipeJSON: String

    init() {}

    init(recipeJSON: String) {
        self.recipeJSON = recipeJSON
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recipe = try ShortcutRecipe.decode(json: recipeJSON)
        let generation = try await ShortcutRenderRuntime.render(recipe)
        return .result(dialog: "Saved \(generation.width) by \(generation.height) image to Gallery (seed \(generation.seed)).")
    }
}

@available(macOS 14.0, *)
struct TwisterminigenShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RenderRecipeIntent(),
            phrases: [
                "Render recipe in \(.applicationName)",
                "Make a local image with \(.applicationName)",
            ],
            shortTitle: "Render Recipe",
            systemImageName: "wand.and.stars")
    }
}
