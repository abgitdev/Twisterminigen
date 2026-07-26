import Foundation

struct TypographyQAResult: Codable, Sendable, Hashable {
    let expectedText: String
    let recognizedText: String
    let similarity: Double
    let exactMatch: Bool

    var label: String { "OCR \(Int((similarity * 100).rounded()))%" }

    func validate(expectedRecipeText: String?) throws {
        let expectedSimilarity = TypographyQAService.similarity(
            expected: expectedText,
            recognized: recognizedText)
        guard let expectedRecipeText,
              !expectedText.isEmpty,
              expectedText == expectedRecipeText,
              expectedText.utf8.count <= GenerationRecipe.maximumExactTextUTF8Bytes,
              recognizedText.utf8.count <= 65_536,
              similarity.isFinite,
              (0 ... 1).contains(similarity),
              abs(similarity - expectedSimilarity) < 1e-12,
              exactMatch == TypographyQAService.isExact(
                expected: expectedText,
                recognized: recognizedText) else {
            throw TypographyQAError.invalidResult
        }
    }
}

enum TypographyQAError: Error, Equatable, LocalizedError, Sendable {
    case unreadableImage
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The rendered PNG could not be read for OCR QA."
        case .invalidResult: return "The stored Typography OCR QA result is inconsistent."
        }
    }
}
