import CoreGraphics
import Foundation
import Vision

enum TypographyQAService {
    static func evaluate(pngData: Data, expectedText: String) throws -> TypographyQAResult {
        guard !pngData.isEmpty else { throw TypographyQAError.unreadableImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(data: pngData, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw TypographyQAError.unreadableImage
        }
        let recognized = (request.results ?? [])
            .compactMap { observation -> (String, CGRect)? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return (candidate.string, observation.boundingBox)
            }
            .sorted { lhs, rhs in
                let rowDelta = abs(lhs.1.midY - rhs.1.midY)
                return rowDelta > 0.04 ? lhs.1.midY > rhs.1.midY : lhs.1.minX < rhs.1.minX
            }
            .map(\.0)
            .joined(separator: " ")
        let result = TypographyQAResult(
            expectedText: expectedText,
            recognizedText: recognized,
            similarity: similarity(expected: expectedText, recognized: recognized),
            exactMatch: isExact(expected: expectedText, recognized: recognized))
        try result.validate(expectedRecipeText: expectedText)
        return result
    }

    static func isExact(expected: String, recognized: String) -> Bool {
        let expected = canonical(expected)
        let recognized = canonical(recognized)
        return !expected.isEmpty && recognized.contains(expected)
    }

    static func similarity(expected: String, recognized: String) -> Double {
        let expected = canonical(expected)
        let recognized = canonical(recognized)
        guard !expected.isEmpty, !recognized.isEmpty else { return 0 }
        if recognized.contains(expected) { return 1 }
        let distance = levenshtein(Array(expected), Array(recognized))
        return max(0, 1 - Double(distance) / Double(max(expected.count, recognized.count)))
    }

    static func canonical(_ value: String) -> String {
        String(value.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0 ... rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for row in 1 ... lhs.count {
            current[0] = row
            for column in 1 ... rhs.count {
                let substitution = lhs[row - 1] == rhs[column - 1] ? 0 : 1
                current[column] = min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1] + substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
