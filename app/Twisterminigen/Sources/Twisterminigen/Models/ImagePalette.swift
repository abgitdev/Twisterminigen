import Foundation

/// A deterministic, prompt-ready selection of sRGB colours.
struct ImagePalette: Codable, Hashable, Sendable {
    static let maximumColorCount = 16

    let colors: [String]

    init(colors: [String]) {
        var seen = Set<String>()
        self.colors = colors.compactMap(Self.normalizedHex)
            .filter { seen.insert($0).inserted }
            .prefix(Self.maximumColorCount)
            .map { $0 }
    }

    var isEmpty: Bool { colors.isEmpty }

    /// Text intended to be reviewed, copied, or explicitly appended by the user.
    var promptModifier: String {
        guard !colors.isEmpty else { return "" }
        return "Use this color palette: \(colors.joined(separator: ", "))."
    }

    /// Appends the modifier without altering existing prompt wording. Applying the exact same
    /// palette twice is idempotent, which protects repeated UI clicks from duplicating text.
    func applying(
        to prompt: String,
        maximumUTF8Bytes: Int = GenerationRecipe.maximumPromptUTF8Bytes
    ) throws -> String {
        guard !colors.isEmpty else { throw ImagePalettePromptError.emptyPalette }
        guard maximumUTF8Bytes > 0 else {
            throw ImagePalettePromptError.promptTooLong(maximumUTF8Bytes: maximumUTF8Bytes)
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: String
        if trimmed.hasSuffix(promptModifier) {
            result = prompt
        } else if trimmed.isEmpty {
            result = promptModifier
        } else {
            result = prompt + (prompt.last?.isWhitespace == true ? "" : "\n") + promptModifier
        }
        guard result.utf8.count <= maximumUTF8Bytes else {
            throw ImagePalettePromptError.promptTooLong(maximumUTF8Bytes: maximumUTF8Bytes)
        }
        return result
    }

    private static func normalizedHex(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.utf8.count == 7, value.first == "#" else { return nil }
        let digits = value.dropFirst()
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value
    }
}

enum ImagePalettePromptError: Error, Equatable, Sendable {
    case emptyPalette
    case promptTooLong(maximumUTF8Bytes: Int)
}

extension ImagePalettePromptError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyPalette:
            return "Select at least one palette colour."
        case .promptTooLong(let maximumUTF8Bytes):
            return "Adding this palette would exceed the \(maximumUTF8Bytes)-byte prompt limit."
        }
    }
}

extension Generation {
    /// Makes a transient Gallery handoff value while preserving every setting and provenance field.
    /// It does not persist a new generation or alter the managed image.
    func replacingPositivePrompt(_ positivePrompt: String) throws -> Generation {
        var updatedRecipe = recipe
        updatedRecipe.prompts.positive = positivePrompt
        try updatedRecipe.validate()
        return Generation(
            id: id,
            recipe: updatedRecipe,
            recipeCapture: recipeCapture,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            imageFileName: imageFileName,
            provenance: provenance,
            completionID: completionID,
            performance: performance)
    }
}
