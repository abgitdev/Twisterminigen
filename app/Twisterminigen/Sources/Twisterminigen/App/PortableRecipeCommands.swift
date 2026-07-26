import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native File-menu actions for the portable recipe boundary. Import only loads settings after
/// dependency inspection; neither command starts a render.
struct PortableRecipeCommands: Commands {
    let generate: GenerateViewModel

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import Twister Recipe…") { chooseImport() }
                .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Export Current Recipe…") { chooseExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }

    @MainActor
    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Twister Recipe"
        panel.prompt = "Inspect & Import"
        panel.allowedContentTypes = [.twisterRecipe]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }

        Task { @MainActor in
            do {
                let report = try await generate.importPortableRecipe(from: source)
                if report.canApply {
                    Self.present(
                        title: "Recipe loaded",
                        message: report.summary + "\n\nNo render was started.",
                        style: .informational)
                } else {
                    Self.present(
                        title: "Recipe dependencies missing",
                        message: report.summary + "\n\nThe current Generate settings were not changed.",
                        style: .warning)
                }
            } catch {
                Self.present(
                    title: "Recipe import failed",
                    message: error.localizedDescription,
                    style: .critical)
            }
        }
    }

    @MainActor
    private func chooseExport() {
        let panel = NSSavePanel()
        panel.title = "Export Current Recipe"
        panel.prompt = "Export Recipe"
        panel.allowedContentTypes = [.twisterRecipe]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Twister-recipe.twisterrecipe"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task { @MainActor in
            do {
                let outcome = try await generate.exportPortableRecipe(to: destination)
                switch outcome {
                case .publishedDurable(let url):
                    Self.present(
                        title: "Recipe exported",
                        message: "Saved \(url.lastPathComponent). No image or private asset bytes were embedded.",
                        style: .informational)
                case .publishedDurabilityWarning(let url, let code):
                    Self.present(
                        title: "Recipe saved with a durability warning",
                        message: "\(url.lastPathComponent) is visible, but filesystem durability could not be confirmed (POSIX \(code)). Inspect the destination before retrying.",
                        style: .warning)
                case .failedBeforeVisibility(_, let error):
                    throw error
                case .stateUnknown(let url, let error):
                    throw ExternalPublicationStateError.stateUnknown(url, underlying: error)
                }
            } catch {
                Self.present(
                    title: "Recipe export failed",
                    message: error.localizedDescription,
                    style: .critical)
            }
        }
    }

    @MainActor
    private static func present(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
