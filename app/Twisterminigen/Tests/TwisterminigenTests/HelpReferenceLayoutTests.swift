import Testing
@testable import Twisterminigen

@Suite("Help reference layout")
struct HelpReferenceLayoutTests {
    @Test("Wide Help is a complete five by three table")
    @MainActor
    func wideHelpGridIsBalanced() {
        #expect(HelpReferenceLayout.columnCount == 3)
        #expect(HelpReferenceLayout.rowCount == 5)
        #expect(HelpReferenceLayout.sectionCount == 15)
        #expect(HelpReferenceLayout.index(row: 0, column: 0) == 0)
        #expect(HelpReferenceLayout.index(row: 4, column: 2) == 14)
        #expect(HelpView.referenceSections.count == HelpReferenceLayout.sectionCount)
    }

    @Test("Help documents the license render gate and every primary workflow")
    @MainActor
    func contentIsCompleteAndHonest() {
        let sections = HelpView.referenceSections
        let titles = Set(sections.map(\.title))
        #expect(titles == [
            "LICENSE & FIRST RUN",
            "MODELS & QUALITY",
            "GENERATE BASICS",
            "CANVAS & RENDER",
            "REMIX / IMG2IMG",
            "REGIONAL PROMPTS",
            "LORA",
            "QUEUE",
            "QUEUE LAB",
            "PRESETS",
            "GALLERY",
            "IMAGE TOOLS & EXPORT",
            "SYSTEM & STORAGE",
            "PRIVACY & SAFETY",
            "SHORTCUTS",
        ])

        let text = sections
            .flatMap(\.rows)
            .map { "\($0.term) \($0.desc)" }
            .joined(separator: " ")
        #expect(text.contains("before model download or any Krea render"))
        #expect(text.contains("select the agreement checkbox, then press Accept terms"))
        #expect(text.contains("intentionally does not train LoRAs"))
        #expect(text.contains("Clear canvas only hides it and keeps Gallery intact"))
        #expect(text.contains("Storage Manager"))
    }
}
