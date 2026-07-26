import Foundation
import Testing
@testable import Twisterminigen

@Suite("Generation recipe")
struct GenerationRecipeTests {
    @Test("A complete recipe round-trips without losing ordered references")
    func fullRoundTripPreservesOrder() throws {
        let firstLoRAID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let secondLoRAID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let firstRegionID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let secondRegionID = try #require(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let inputID = try #require(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        let recipe = GenerationRecipe(
            prompts: .init(
                positive: "a brass observatory",
                negative: "fog",
                exactText: "OPEN ALL NIGHT"),
            canvas: .init(width: 1_280, height: 720),
            sampler: .init(
                steps: 12,
                seed: .fixed(9_876_543_210),
                guidance: 3.5,
                schedule: .init(mu: 1.15, minres: 256, maxres: 2_048, y1: 0.5, y2: 1.15),
                precision: .float16),
            model: testModel,
            loras: [
                .init(managedID: firstLoRAID, sha256: hash("b"), scale: 0.75),
                .init(managedID: secondLoRAID, sha256: hash("c"), scale: 1.25),
            ],
            regions: [
                .init(
                    id: firstRegionID,
                    prompt: "brass telescope",
                    rect: .init(x0: 0.05, y0: 0.1, x1: 0.45, y1: 0.9)),
                .init(
                    id: secondRegionID,
                    prompt: "star chart",
                    rect: .init(x: 0.5, y: 0.2, width: 0.4, height: 0.6)),
            ],
            inputImage: .init(
                managedID: inputID,
                sha256: hash("d"),
                strength: 0.6,
                resize: .fill,
                crop: .init(x0: 0.1, y0: 0, x1: 0.9, y1: 1)))

        try recipe.validate(for: .persistedResult)
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(GenerationRecipe.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded == recipe)
        #expect(decoded.loras.map(\.managedID) == [firstLoRAID, secondLoRAID])
        #expect(decoded.regions.map(\.id) == [firstRegionID, secondRegionID])
        #expect(decoded.prompts.exactText == "OPEN ALL NIGHT")
        #expect(decoded.kind == .imageToImage)
        #expect(!json.contains("enabled"))
        #expect(!json.contains("bookmark"))
        #expect(!json.contains("/Users/"))
    }

    @Test("A fixed seed preserves the full UInt64 domain")
    func uint64MaxRoundTrip() throws {
        let recipe = GenerationRecipe.turbo(
            prompt: "maximum seed",
            model: testModel,
            seed: .fixed(UInt64.max))

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(GenerationRecipe.self, from: data)

        #expect(decoded.sampler.seed == .fixed(UInt64.max))
        #expect(decoded.sampler.seed.fixedValue == UInt64.max)
    }

    @Test("The Turbo factory materializes every current engine default")
    func turboDefaultsAreExplicit() throws {
        let recipe = GenerationRecipe.turbo(
            prompt: "city reflected in rain",
            negativePrompt: "text",
            model: testModel)

        #expect(recipe.schema == "twisterminigen.generation-recipe")
        #expect(recipe.version == 1)
        #expect(recipe.prompts == .init(positive: "city reflected in rain", negative: "text"))
        #expect(recipe.canvas == .init(width: 1_024, height: 1_024))
        #expect(recipe.sampler.steps == 8)
        #expect(recipe.sampler.seed == .random)
        #expect(recipe.sampler.guidance == 0)
        #expect(recipe.sampler.schedule == .init(
            mu: 1.15,
            minres: 256,
            maxres: 1_280,
            y1: 0.5,
            y2: 1.15))
        #expect(recipe.sampler.precision == .bfloat16)
        #expect(recipe.model == testModel)
        #expect(recipe.model.checkpointFamily == .turbo)
        #expect(recipe.model.quantizationTier == .mixed4And8)
        #expect(recipe.loras.isEmpty)
        #expect(recipe.regions.isEmpty)
        #expect(recipe.inputImage == nil)
        #expect(recipe.kind == .textToImage)
        try recipe.validate()
    }

    @Test("Model axes round-trip and old recipes receive current defaults")
    func modelAxesAreBackwardCompatible() throws {
        let explicit = GenerationRecipe.ModelReference(
            modelID: "krea-2-raw",
            variantID: "local-q8",
            manifestHash: hash("9"),
            checkpointFamily: .raw,
            quantizationTier: .q8)
        let recipe = GenerationRecipe.turbo(prompt: "typed model", model: explicit)
        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(GenerationRecipe.self, from: encoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedModel = try #require(object["model"] as? [String: Any])

        #expect(decoded.model == explicit)
        #expect(encodedModel["checkpointFamily"] as? String == "raw")
        #expect(encodedModel["quantizationTier"] as? String == "q8")

        var legacyObject = object
        var legacyModel = encodedModel
        legacyModel.removeValue(forKey: "checkpointFamily")
        legacyModel.removeValue(forKey: "quantizationTier")
        legacyObject["model"] = legacyModel
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(GenerationRecipe.self, from: legacyData)

        #expect(legacy.model.checkpointFamily == .turbo)
        #expect(legacy.model.quantizationTier == .mixed4And8)
        #expect(legacy.version == GenerationRecipe.currentVersion)
    }

    @Test("Resolving a seed fixes random requests once and preserves fixed requests")
    func seedResolution() throws {
        let random = GenerationRecipe.turbo(prompt: "seed me", model: testModel)
        var calls = 0
        let resolved = random.resolvingRandomSeed {
            calls += 1
            return UInt64.max
        }

        #expect(calls == 1)
        #expect(resolved.sampler.seed == .fixed(UInt64.max))
        #expect(random.sampler.seed == .random)
        try resolved.validate(for: .persistedResult)

        let fixed = GenerationRecipe.turbo(
            prompt: "already fixed",
            model: testModel,
            seed: .fixed(42))
        let unchanged = fixed.resolvingRandomSeed {
            calls += 1
            return 7
        }
        #expect(unchanged == fixed)
        #expect(calls == 1)
        #expect(random.resolvingRandomSeed(to: 123).sampler.seed == .fixed(123))
    }

    @Test("Session keys are deterministic and change only with resident compatibility")
    func deterministicSessionKeyChanges() throws {
        let loraID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let regionID = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        let inputID = try #require(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        let base = GenerationRecipe.turbo(
            prompt: "base",
            model: testModel,
            seed: .fixed(1))

        #expect(base.sessionKey == base.sessionKey)
        #expect(base.sessionKey.count == 64)

        var requestOnlyChange = base
        requestOnlyChange.prompts.positive = "different prompt"
        requestOnlyChange.canvas.width = 512
        requestOnlyChange.sampler.steps = 20
        requestOnlyChange.sampler.seed = .fixed(2)
        #expect(requestOnlyChange.sessionKey == base.sessionKey)

        var modelChange = base
        modelChange.model.manifestHash = hash("e")
        #expect(modelChange.sessionKey != base.sessionKey)

        var checkpointChange = base
        checkpointChange.model.checkpointFamily = .raw
        #expect(checkpointChange.sessionKey != base.sessionKey)

        var quantizationChange = base
        quantizationChange.model.quantizationTier = .q8
        #expect(quantizationChange.sessionKey != base.sessionKey)

        var loraChange = base
        loraChange.loras = [.init(managedID: loraID, sha256: hash("f"), scale: 1)]
        #expect(loraChange.sessionKey != base.sessionKey)
        var loraScaleChange = loraChange
        loraScaleChange.loras[0].scale = 0.5
        #expect(loraScaleChange.sessionKey != loraChange.sessionKey)

        var precisionChange = base
        precisionChange.sampler.precision = .float32
        #expect(precisionChange.sessionKey != base.sessionKey)

        var regionalChange = base
        regionalChange.regions = [.init(
            id: regionID,
            prompt: "left subject",
            rect: .init(x0: 0, y0: 0, x1: 0.5, y1: 1))]
        #expect(regionalChange.sessionKey != base.sessionKey)

        var imageChange = base
        imageChange.inputImage = .init(
            managedID: inputID,
            sha256: hash("1"),
            strength: 0.5,
            resize: .fit)
        #expect(imageChange.kind == .imageToImage)
        #expect(imageChange.sessionKey != base.sessionKey)
    }

    @Test("Schema and version compatibility is validation, not decoding")
    func incompatibleEnvelopeStillDecodes() throws {
        let recipe = GenerationRecipe.turbo(prompt: "future", model: testModel)
        let encoded = try JSONEncoder().encode(recipe)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = GenerationRecipe.currentVersion + 1
        object["futureField"] = ["new": true]
        object["prompts"] = ["positive": "   ", "negative": ""]
        let futureData = try JSONSerialization.data(withJSONObject: object)

        let future = try JSONDecoder().decode(GenerationRecipe.self, from: futureData)
        #expect(future.version == 2)
        #expect(validationError(future) == .incompatibleVersion(2))

        var wrongSchema = recipe
        wrongSchema.schema = "another.recipe"
        #expect(validationError(wrongSchema) == .incompatibleSchema("another.recipe"))
    }

    @Test("Prompts, dimensions, steps, hashes, and finite values are strict")
    func invalidCoreValues() {
        var recipe = validFixedRecipe()
        recipe.prompts.positive = " \n\t"
        #expect(validationError(recipe) == .emptyValue("prompts.positive"))

        recipe = validFixedRecipe()
        recipe.canvas.width = 255
        #expect(validationError(recipe) == .invalidDimension(field: "canvas.width", value: 255))
        recipe.canvas.width = 2_048
        recipe.canvas.height = 2_049
        #expect(validationError(recipe) == .invalidDimension(field: "canvas.height", value: 2_049))
        recipe.canvas.height = 257
        #expect(validationError(recipe) == .invalidDimension(field: "canvas.height", value: 257))

        recipe = validFixedRecipe()
        recipe.sampler.steps = 0
        #expect(validationError(recipe) == .invalidStepCount(0))
        recipe.sampler.steps = GenerationRecipe.maximumSteps + 1
        #expect(validationError(recipe) == .invalidStepCount(GenerationRecipe.maximumSteps + 1))

        recipe = validFixedRecipe()
        recipe.sampler.guidance = .nan
        #expect(validationError(recipe) == .nonFinite("sampler.guidance"))
        recipe.sampler.guidance = -0.01
        #expect(validationError(recipe) == .outOfBounds("sampler.guidance"))
        recipe.sampler.guidance = GenerationRecipe.maximumGuidance + 0.01
        #expect(validationError(recipe) == .outOfBounds("sampler.guidance"))
        recipe.sampler.guidance = 0
        recipe.sampler.schedule.mu = .infinity
        #expect(validationError(recipe) == .nonFinite("sampler.schedule.mu"))

        recipe = validFixedRecipe()
        recipe.prompts.negative = String(repeating: "x", count: GenerationRecipe.maximumPromptUTF8Bytes + 1)
        #expect(validationError(recipe) == .valueTooLong(
            field: "prompts.negative",
            maximumUTF8Bytes: GenerationRecipe.maximumPromptUTF8Bytes))

        recipe = validFixedRecipe()
        recipe.model.manifestHash = "not-a-hash"
        #expect(validationError(recipe) == .invalidHash("model.manifestHash"))
    }

    @Test("Schedule, adapter, image, and rectangle bounds are strict")
    func invalidBounds() {
        var recipe = validFixedRecipe()
        recipe.sampler.schedule.minres = 1_280
        recipe.sampler.schedule.maxres = 256
        #expect(validationError(recipe) == .invalidSchedule("sampler.schedule.resolutionRange"))

        let loraID = UUID()
        recipe = validFixedRecipe()
        recipe.loras = [.init(managedID: loraID, sha256: hash("b"), scale: 0)]
        #expect(validationError(recipe) == .outOfBounds("loras[0].scale"))
        recipe.loras[0].scale = GenerationRecipe.maximumLoRAScale + 0.01
        #expect(validationError(recipe) == .outOfBounds("loras[0].scale"))
        recipe.loras[0].scale = .nan
        #expect(validationError(recipe) == .nonFinite("loras[0].scale"))

        recipe = validFixedRecipe()
        recipe.inputImage = .init(
            managedID: UUID(),
            sha256: hash("c"),
            strength: -0.01,
            resize: .stretch)
        #expect(validationError(recipe) == .outOfBounds("inputImage.strength"))
        recipe.inputImage?.strength = 1.01
        #expect(validationError(recipe) == .outOfBounds("inputImage.strength"))
        recipe.inputImage?.strength = .infinity
        #expect(validationError(recipe) == .nonFinite("inputImage.strength"))

        recipe = validFixedRecipe()
        recipe.regions = [.init(
            id: UUID(),
            prompt: "outside",
            rect: .init(x0: -0.1, y0: 0, x1: 0.5, y1: 1))]
        #expect(validationError(recipe) == .invalidNormalizedRect("regions[0].rect"))
        recipe.regions[0].rect = .init(x0: 0.5, y0: 0, x1: 0.5, y1: 1)
        #expect(validationError(recipe) == .invalidNormalizedRect("regions[0].rect"))
        recipe.regions[0].rect = .init(x0: 0, y0: 0, x1: .nan, y1: 1)
        #expect(validationError(recipe) == .nonFinite("regions[0].rect"))
    }

    @Test("Adapter and region IDs are unique and counts are bounded")
    func duplicateIDsAndMaximumCounts() {
        let duplicateLoRAID = UUID()
        var recipe = validFixedRecipe()
        recipe.loras = [
            .init(managedID: duplicateLoRAID, sha256: hash("b"), scale: 1),
            .init(managedID: duplicateLoRAID, sha256: hash("c"), scale: 0.5),
        ]
        #expect(validationError(recipe) == .duplicateLoRAID(duplicateLoRAID))

        let duplicateRegionID = UUID()
        recipe = validFixedRecipe()
        recipe.regions = [
            .init(
                id: duplicateRegionID,
                prompt: "first",
                rect: .init(x0: 0, y0: 0, x1: 0.5, y1: 1)),
            .init(
                id: duplicateRegionID,
                prompt: "second",
                rect: .init(x0: 0.5, y0: 0, x1: 1, y1: 1)),
        ]
        #expect(validationError(recipe) == .duplicateRegionID(duplicateRegionID))

        recipe = validFixedRecipe()
        recipe.loras = (0 ... GenerationRecipe.maximumLoRACount).map { index in
            .init(managedID: UUID(), sha256: hash(String(index % 10)), scale: 1)
        }
        #expect(validationError(recipe) == .tooManyLoRAs(
            actual: GenerationRecipe.maximumLoRACount + 1,
            maximum: GenerationRecipe.maximumLoRACount))

        recipe = validFixedRecipe()
        recipe.regions = (0 ... GenerationRecipe.maximumRegionCount).map { index in
            .init(
                id: UUID(),
                prompt: "region \(index)",
                rect: .init(x0: 0, y0: 0, x1: 1, y1: 1))
        }
        #expect(validationError(recipe) == .tooManyRegions(
            actual: GenerationRecipe.maximumRegionCount + 1,
            maximum: GenerationRecipe.maximumRegionCount))
    }

    @Test("Persisted results require a resolved seed")
    func randomSeedCannotBePersisted() {
        let random = GenerationRecipe.turbo(prompt: "unresolved", model: testModel)
        #expect(validationError(random, for: .request) == nil)
        #expect(validationError(random, for: .persistedResult) == .randomSeedForPersistedResult)

        let fixed = random.resolvingRandomSeed(to: 0)
        #expect(validationError(fixed, for: .persistedResult) == nil)
    }
}

private let testModel = GenerationRecipe.ModelReference(
    modelID: "krea-2-turbo",
    variantID: "alis-mixed-4-8",
    manifestHash: hash("a"))

private func validFixedRecipe() -> GenerationRecipe {
    GenerationRecipe.turbo(prompt: "valid prompt", model: testModel, seed: .fixed(1))
}

private func hash(_ digit: String) -> String {
    String(repeating: digit, count: 64)
}

private func validationError(
    _ recipe: GenerationRecipe,
    for purpose: GenerationRecipe.ValidationPurpose = .request
) -> GenerationRecipe.ValidationError? {
    do {
        try recipe.validate(for: purpose)
        return nil
    } catch let error as GenerationRecipe.ValidationError {
        return error
    } catch {
        return nil
    }
}
