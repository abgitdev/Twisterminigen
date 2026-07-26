import Foundation

enum ExactTextPromptError: Error, Equatable, Sendable {
    case empty
    case tooLong(maximumUTF8Bytes: Int)
    case unsupportedControlCharacter
    case composedPromptTooLong(maximumUTF8Bytes: Int)
}

enum ExactTextPrompt {
    static let maximumUTF8Bytes = 4_096

    static func normalize(_ text: String) throws -> String {
        let normalizedLineEndings = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let value = normalizedLineEndings.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ExactTextPromptError.empty }
        guard value.utf8.count <= maximumUTF8Bytes else {
            throw ExactTextPromptError.tooLong(maximumUTF8Bytes: maximumUTF8Bytes)
        }
        let allowedControls = CharacterSet(charactersIn: "\n\t")
        guard value.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar) || allowedControls.contains(scalar)
        }) else {
            throw ExactTextPromptError.unsupportedControlCharacter
        }
        return value
    }

    static func compose(basePrompt: String, exactText: String?) throws -> String {
        guard let exactText else { return basePrompt }
        let value = try normalize(exactText)
        let base = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Krea receives ordinary prose with the user's literal line breaks. Do not emit Ideogram
        // JSON or any invented structured schema: the open Krea 2 pipeline has no such contract.
        let letteringInstruction =
            "Lettering to appear (exact spelling is not guaranteed):\n\(value)"
        let composed = base.isEmpty
            ? letteringInstruction
            : "\(base)\n\n\(letteringInstruction)"
        guard composed.utf8.count <= GenerationRecipe.maximumPromptUTF8Bytes else {
            throw ExactTextPromptError.composedPromptTooLong(
                maximumUTF8Bytes: GenerationRecipe.maximumPromptUTF8Bytes)
        }
        return composed
    }
}

extension ExactTextPromptError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .empty: "Lettering text is empty."
        case .tooLong(let maximum): "Lettering text is limited to \(maximum) UTF-8 bytes."
        case .unsupportedControlCharacter: "Lettering text contains an unsupported control character."
        case .composedPromptTooLong(let maximum):
            "Prompt and lettering text together exceed \(maximum) UTF-8 bytes."
        }
    }
}
