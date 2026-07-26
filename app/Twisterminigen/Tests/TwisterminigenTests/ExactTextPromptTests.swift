import Foundation
import Testing
@testable import Twisterminigen

@Suite struct ExactTextPromptTests {
    @Test func composesPlainLanguageLetteringWithoutLosingLinesOrQuotes() throws {
        let result = try ExactTextPrompt.compose(
            basePrompt: "poster on a wall",
            exactText: "First \"line\"\r\nSecond line")
        #expect(result == "poster on a wall\n\nLettering to appear (exact spelling is not guaranteed):\nFirst \"line\"\nSecond line")
    }

    @Test func absentTextLeavesPromptByteExact() throws {
        #expect(try ExactTextPrompt.compose(basePrompt: "  keep spacing  ", exactText: nil)
            == "  keep spacing  ")
    }

    @Test func rejectsEmptyOversizedAndControlText() {
        #expect(throws: ExactTextPromptError.empty) {
            _ = try ExactTextPrompt.normalize(" \n ")
        }
        #expect(throws: ExactTextPromptError.tooLong(
            maximumUTF8Bytes: ExactTextPrompt.maximumUTF8Bytes)
        ) {
            _ = try ExactTextPrompt.normalize(
                String(repeating: "a", count: ExactTextPrompt.maximumUTF8Bytes + 1))
        }
        #expect(throws: ExactTextPromptError.unsupportedControlCharacter) {
            _ = try ExactTextPrompt.normalize("bad\u{0000}text")
        }
    }
}
