import Foundation
import Testing
@testable import Twisterminigen

@Suite("Grouping metadata decoding")
struct ProvenanceDecodingTests {
    @Test("Unsupported historical grouping is discarded without losing records or jobs")
    func unsupportedKindKeepsPayloads() throws {
        let generation = makeGeneration()
        let job = QueueJob(recipe: generation.recipe, provenance: generation.provenance)

        let decodedGeneration = try JSONDecoder().decode(
            Generation.self,
            from: try replacingKind(in: generation, with: "retired-grouping"))
        let decodedJob = try JSONDecoder().decode(
            QueueJob.self,
            from: try replacingKind(in: job, with: "retired-grouping"))

        #expect(decodedGeneration.id == generation.id)
        #expect(decodedGeneration.recipe == generation.recipe)
        #expect(decodedGeneration.imageFileName == generation.imageFileName)
        #expect(decodedGeneration.provenance == nil)
        #expect(decodedJob.id == job.id)
        #expect(decodedJob.recipe == job.recipe)
        #expect(decodedJob.provenance == nil)
    }

    @Test("Malformed supported grouping metadata still fails closed")
    func malformedSupportedKindFails() throws {
        let generation = makeGeneration()
        let job = QueueJob(recipe: generation.recipe, provenance: generation.provenance)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                Generation.self,
                from: try removingGroupID(from: generation))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                QueueJob.self,
                from: try removingGroupID(from: job))
        }
    }

    private func makeGeneration() -> Generation {
        let recipe = GenerationRecipe.turbo(
            prompt: "compatibility test",
            model: QueueJob.legacyModelReference,
            seed: .fixed(17))
        return Generation(
            recipe: recipe,
            durationSeconds: 1,
            imageFileName: "compatibility.png",
            provenance: .batch(groupID: UUID(), itemIndex: 0, itemCount: 2))
    }

    private func replacingKind<Value: Encodable>(
        in value: Value,
        with replacement: String
    ) throws -> Data {
        try editingProvenance(in: value) { provenance in
            provenance["kind"] = replacement
        }
    }

    private func removingGroupID<Value: Encodable>(from value: Value) throws -> Data {
        try editingProvenance(in: value) { provenance in
            provenance.removeValue(forKey: "groupID")
        }
    }

    private func editingProvenance<Value: Encodable>(
        in value: Value,
        edit: (inout [String: Any]) -> Void
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var provenance = try #require(object["provenance"] as? [String: Any])
        edit(&provenance)
        object["provenance"] = provenance
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
