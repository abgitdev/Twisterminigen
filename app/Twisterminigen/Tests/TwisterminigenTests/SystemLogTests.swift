import Foundation
import Testing
@testable import Twisterminigen

@Suite("Persistent system log")
@MainActor
struct SystemLogTests {
    @Test("Entries survive a new log instance and stay bounded")
    func entriesPersistAndStayBounded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenSystemLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("system-log.json")

        let writer = SystemLog(fileURL: fileURL)
        for index in 0 ..< 205 {
            writer.log("entry \(index)")
        }

        let reader = SystemLog(fileURL: fileURL)
        #expect(reader.lines.count == 200)
        #expect(reader.lines.first?.contains("entry 5") == true)
        #expect(reader.lines.last?.contains("entry 204") == true)
    }

    @Test("Clear removes persistent entries but keeps the visible status")
    func clearPersistsEmptyState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenSystemLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("system-log.json")

        let writer = SystemLog(fileURL: fileURL)
        writer.log("before clear")
        writer.clear(status: "Logs cleared.")

        #expect(writer.lines.isEmpty)
        #expect(writer.lastStatus == "Logs cleared.")
        #expect(SystemLog(fileURL: fileURL).lines.isEmpty)
    }

    @Test("A malformed or oversized file cannot escape into the UI")
    func malformedFilesAreIgnored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwisterminigenSystemLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("system-log.json")
        try Data(repeating: 0x41, count: 1_048_577).write(to: fileURL)

        #expect(SystemLog(fileURL: fileURL).lines.isEmpty)
    }
}
