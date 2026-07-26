import Foundation
import Krea2Sampler
import MLX
import Testing
@testable import Krea2Pipeline
@testable import Krea2TextEncoder

@Suite struct ConditioningCacheTests {
    @Test func keyContainsEveryConditioningBoundaryAndNoRenderFields() {
        let firstRegion = Krea2ConditioningCacheKey.RegionIdentity(
            prompt: "left subject",
            x0: 0.0,
            y0: 0.0,
            x1: 0.5,
            y1: 1.0
        )
        let secondRegion = Krea2ConditioningCacheKey.RegionIdentity(
            prompt: "right subject",
            x0: 0.5,
            y0: 0.0,
            x1: 1.0,
            y1: 1.0
        )
        let base = Self.makeKey(regions: [firstRegion, secondRegion])

        let boundaryChanges = [
            Self.makeKey(schema: 2, regions: [firstRegion, secondRegion]),
            Self.makeKey(modelIdentity: "verified-model-b", regions: [firstRegion, secondRegion]),
            Self.makeKey(modelRoot: "/tmp/krea-model-b", regions: [firstRegion, secondRegion]),
            Self.makeKey(positivePrompt: "different positive", regions: [firstRegion, secondRegion]),
            Self.makeKey(negativePrompt: "", regions: [firstRegion, secondRegion]),
            Self.makeKey(cfgBranch: .positiveAndNegative, regions: [firstRegion, secondRegion]),
            Self.makeKey(guidanceMode: .classifierFree, regions: [firstRegion, secondRegion]),
            Self.makeKey(templateIdentity: "qwen-image-v2", regions: [firstRegion, secondRegion]),
            Self.makeKey(maxLength: 256, regions: [firstRegion, secondRegion]),
            Self.makeKey(selectLayers: [2, 5, 8], regions: [firstRegion, secondRegion]),
            Self.makeKey(dtypeIdentity: .float32, regions: [firstRegion, secondRegion]),
            Self.makeKey(orderedLoRAIdentity: "lora-b@0.5|lora-a@1.0", regions: [firstRegion, secondRegion]),
            Self.makeKey(regions: [secondRegion, firstRegion]),
            Self.makeKey(regions: [
                .init(prompt: "left subject", x0: 0.0, y0: 0.0, x1: 0.500_000_1, y1: 1.0),
                secondRegion,
            ]),
        ]

        #expect(boundaryChanges.allSatisfy { $0 != base })
        #expect(Set([base, Self.makeKey(regions: [firstRegion, secondRegion])]).count == 1)
        #expect(
            Self.makeKey(modelRoot: "/tmp/krea-model/../krea-model").canonicalModelRoot
                == "/tmp/krea-model"
        )

        let storedFields = Set(Mirror(reflecting: base).children.compactMap(\.label))
        let renderOnlyFields: Set<String> = ["seed", "resolution", "width", "height", "steps"]
        #expect(storedFields.isDisjoint(with: renderOnlyFields))

        let firstRender = (seed: UInt64(1), width: 512, height: 512, steps: 8)
        let secondRender = (seed: UInt64(999), width: 1536, height: 1024, steps: 24)
        #expect(firstRender.seed != secondRender.seed)
        #expect(firstRender.width != secondRender.width)
        #expect(firstRender.steps != secondRender.steps)
        #expect(base == Self.makeKey(regions: [firstRegion, secondRegion]))

        #expect(Krea2ConditioningCache.defaultByteBudget == 128 * 1_024 * 1_024)
        #expect(Krea2ConditioningCache.defaultMaxEntries == 4)
    }

    @Test func pipelineKeyExcludesRenderFieldsAndGuidanceScale() {
        let root = URL(fileURLWithPath: "/tmp/krea-cache-key")
        let weights = Krea2Pipeline.Weights(
            officialDir: root.appendingPathComponent("official"),
            ditQuantFile: root.appendingPathComponent("dit.safetensors"),
            vaeFile: root.appendingPathComponent("vae.safetensors"),
            verifiedModelIdentity: "verified-model-a")
        var first = Krea2Sampler.Params()
        first.seed = 1
        first.width = 512
        first.height = 512
        first.steps = 8
        first.guidance = 3.5
        var second = first
        second.seed = 999
        second.width = 1280
        second.height = 720
        second.steps = 12
        second.guidance = 7

        let firstKey = Krea2Pipeline.conditioningCacheKey(
            prompt: "positive",
            negativePrompt: "negative",
            weights: weights,
            params: first)
        let secondKey = Krea2Pipeline.conditioningCacheKey(
            prompt: "positive",
            negativePrompt: "negative",
            weights: weights,
            params: second)
        #expect(firstKey == secondKey)

        let changedNegative = Krea2Pipeline.conditioningCacheKey(
            prompt: "positive",
            negativePrompt: "different negative",
            weights: weights,
            params: first)
        #expect(changedNegative != firstKey)

        var turbo = first
        turbo.guidance = 0
        let turboA = Krea2Pipeline.conditioningCacheKey(
            prompt: "positive",
            negativePrompt: "ignored-a",
            weights: weights,
            params: turbo)
        let turboB = Krea2Pipeline.conditioningCacheKey(
            prompt: "positive",
            negativePrompt: "ignored-b",
            weights: weights,
            params: turbo)
        #expect(turboA == turboB)

        let unidentified = Krea2Pipeline.Weights(
            officialDir: weights.officialDir,
            ditQuantFile: weights.ditQuantFile,
            vaeFile: weights.vaeFile)
        #expect(Krea2Pipeline.conditioningCacheKey(
            prompt: "positive",
            negativePrompt: "negative",
            weights: unidentified,
            params: first) == nil)
    }

    @Test func hitMissAndCountBoundedLRU() async throws {
        let cache = Krea2ConditioningCache(byteBudget: 1_024, maxEntries: 2)
        let value = Self.makeConditioning(embeddingElements: 2)
        let a = Self.makeKey(positivePrompt: "a")
        let b = Self.makeKey(positivePrompt: "b")
        let c = Self.makeKey(positivePrompt: "c")

        #expect(await cache.value(for: a) == nil)
        #expect(try await cache.insert(value, for: a) == .inserted)
        #expect(try await cache.insert(value, for: b) == .inserted)
        #expect(await cache.value(for: a) == value)

        #expect(try await cache.insert(value, for: c) == .inserted)
        #expect(await cache.value(for: b) == nil)
        #expect(await cache.value(for: a) == value)
        #expect(await cache.value(for: c) == value)

        let snapshot = await cache.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.byteCount == 16)
    }

    @Test func byteBoundEvictsLRUAndRejectsOversizedEntry() async throws {
        let cache = Krea2ConditioningCache(byteBudget: 16, maxEntries: 4)
        let small = Self.makeConditioning(embeddingElements: 2) // 4 BF16 bytes + 4 mask bytes
        let a = Self.makeKey(positivePrompt: "a")
        let b = Self.makeKey(positivePrompt: "b")
        let c = Self.makeKey(positivePrompt: "c")
        let budgetFilling = Self.makeKey(positivePrompt: "budget-filling")

        #expect(try await cache.insert(small, for: a) == .inserted)
        #expect(try await cache.insert(small, for: b) == .inserted)
        #expect(try await cache.insert(small, for: c) == .inserted)
        #expect(await cache.value(for: a) == nil)
        #expect(await cache.snapshot().byteCount == 16)

        let oneLargeEntry = Self.makeConditioning(embeddingElements: 6) // exactly 16 bytes total
        #expect(try await cache.insert(oneLargeEntry, for: budgetFilling) == .inserted)
        #expect(await cache.snapshot().count == 1)
        #expect(await cache.snapshot().byteCount == 16)
        #expect(await cache.value(for: budgetFilling) == oneLargeEntry)

        let oversized = Self.makeConditioning(embeddingElements: 7) // 18 bytes total
        #expect(
            try await cache.insert(oversized, for: Self.makeKey(positivePrompt: "too-large"))
                == .exceedsByteBudget
        )
        #expect(await cache.snapshot().count == 1)
        #expect(await cache.value(for: budgetFilling) == oneLargeEntry)
    }

    @Test func replacementUpdatesAccountingWithoutDroppingPriorValueOnRejection() async throws {
        let cache = Krea2ConditioningCache(byteBudget: 16, maxEntries: 4)
        let key = Self.makeKey(positivePrompt: "replace")
        let small = Self.makeConditioning(embeddingElements: 2) // 8 bytes
        let replacement = Self.makeConditioning(embeddingElements: 4) // 12 bytes
        let oversized = Self.makeConditioning(embeddingElements: 7) // 18 bytes

        #expect(try await cache.insert(small, for: key) == .inserted)
        #expect(try await cache.insert(replacement, for: key) == .replaced)
        #expect(await cache.snapshot().count == 1)
        #expect(await cache.snapshot().byteCount == 12)
        #expect(await cache.value(for: key) == replacement)

        #expect(try await cache.insert(oversized, for: key) == .exceedsByteBudget)
        #expect(await cache.snapshot().count == 1)
        #expect(await cache.snapshot().byteCount == 12)
        #expect(await cache.value(for: key) == replacement)

        #expect(try await cache.insert(small, for: key) == .replaced)
        #expect(await cache.snapshot().byteCount == 8)
    }

    @Test func malformedValuesAreRejectedAndHostDataIsIndependent() async {
        var source = Data([1, 2, 3, 4])
        let copied = Krea2HostTensor(data: source, shape: [2], dtype: .bfloat16)
        source[0] = 99
        #expect(copied.data[0] == 1)

        let malformedEmbeddings = Krea2HostTensor(
            data: Data([0, 1, 2]),
            shape: [2],
            dtype: .bfloat16
        )
        let malformed = Krea2HostConditioning(
            positive: Krea2HostTextConditioning(
                embeddings: malformedEmbeddings,
                mask: Krea2HostTensor(data: Data(repeating: 0, count: 4), shape: [1], dtype: .int32),
                validTokenCount: 1
            )
        )
        let expectedError = Krea2ConditioningCacheError.byteCountMismatch(expected: 4, actual: 3)
        let cache = Krea2ConditioningCache(byteBudget: 100, maxEntries: 4)

        var insertionError: Krea2ConditioningCacheError?
        do {
            _ = try await cache.insert(malformed, for: Self.makeKey())
        } catch let error as Krea2ConditioningCacheError {
            insertionError = error
        } catch {
            Issue.record("Unexpected insertion error: \(error)")
        }
        #expect(insertionError == expectedError)
        #expect(await cache.snapshot().count == 0)

        var restoreError: Krea2ConditioningCacheError?
        do {
            _ = try Krea2ConditioningHostTransfer.restoreForInferenceTask(malformed.positive)
        } catch let error as Krea2ConditioningCacheError {
            restoreError = error
        } catch {
            Issue.record("Unexpected restore error: \(error)")
        }
        #expect(restoreError == expectedError)
    }

    @Test func pressureTransitionsTrimSuspendPurgeAndResume() async throws {
        let cache = Krea2ConditioningCache(byteBudget: 1_024, maxEntries: 4)
        let value = Self.makeConditioning(embeddingElements: 2)
        let a = Self.makeKey(positivePrompt: "a")
        let b = Self.makeKey(positivePrompt: "b")
        let c = Self.makeKey(positivePrompt: "c")
        let d = Self.makeKey(positivePrompt: "d")

        _ = try await cache.insert(value, for: a)
        _ = try await cache.insert(value, for: b)
        _ = try await cache.insert(value, for: c)
        _ = await cache.value(for: b) // B is most recent.

        await cache.setPressure(.amber)
        #expect(await cache.snapshot().pressure == .amber)
        #expect(await cache.snapshot().insertionSuspended)
        #expect(await cache.snapshot().count == 1)
        #expect(await cache.value(for: b) == value)
        #expect(await cache.value(for: a) == nil)
        #expect(await cache.value(for: c) == nil)
        #expect(try await cache.insert(value, for: d) == .insertionSuspended)

        await cache.setPressure(.normal)
        #expect(try await cache.insert(value, for: d) == .inserted)
        #expect(await cache.snapshot().count == 2)

        await cache.setPressure(.red)
        #expect(await cache.snapshot().pressure == .red)
        #expect(await cache.snapshot().insertionSuspended)
        #expect(await cache.snapshot().count == 0)
        #expect(try await cache.insert(value, for: a) == .insertionSuspended)

        await cache.setPressure(.normal)
        #expect(try await cache.insert(value, for: a) == .inserted)
        await cache.invalidateAll()
        let finalSnapshot = await cache.snapshot()
        #expect(finalSnapshot.count == 0)
        #expect(finalSnapshot.pressure == .normal)
        #expect(!finalSnapshot.insertionSuspended)
    }

    @Test func cancellationBeforeInsertNeverMutatesCache() async {
        let cache = Krea2ConditioningCache(byteBudget: 100, maxEntries: 4)
        let key = Self.makeKey()
        let value = Self.makeConditioning(embeddingElements: 2)

        let caughtCancellation = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await cache.insert(value, for: key)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(caughtCancellation)
        #expect(await cache.snapshot().count == 0)
        #expect(await cache.snapshot().byteCount == 0)
    }

    @Test func tinyBF16AndInt32HostValueIsExactAndIndependent() throws {
        let embeddingBytes = Data([0xC0, 0x3F, 0x10, 0xC0, 0x00, 0x3F, 0x00, 0x41])
        let maskBytes = [Int32(1), 0].withUnsafeBytes { Data($0) }
        let host = Krea2HostTextConditioning(
            embeddings: Krea2HostTensor(
                data: embeddingBytes,
                shape: [1, 2, 2],
                dtype: .bfloat16),
            mask: Krea2HostTensor(data: maskBytes, shape: [1, 2], dtype: .int32),
            validTokenCount: 1)
        #expect(host.embeddings.dtype == .bfloat16)
        #expect(host.mask.dtype == .int32)
        #expect(host.embeddings.shape == [1, 2, 2])
        #expect(host.mask.shape == [1, 2])
        #expect(try host.validatedByteCount() == 16)
        #expect(host.embeddings.data == embeddingBytes)
        #expect(host.mask.data == maskBytes)
    }

    @Test func mlxHostRoundTripIsByteExactWhenMetalResourcesAreAvailable() throws {
        guard ProcessInfo.processInfo.environment["TWISTER_RUN_METAL_TESTS"] == "1" else {
            return
        }

        let embeddings = MLXArray([Float(1.5), -2.25, 0.5, 8.0])
            .reshaped([1, 2, 2])
            .asType(.bfloat16)
        let mask = MLXArray([Int32(1), 0]).reshaped([1, 2])
        let original = Krea2TextConditioning(
            embeddings: embeddings,
            mask: mask,
            validTokenCount: 1)

        let host = try Krea2ConditioningHostTransfer.copyFromInferenceTask(original)
        let restored = try Krea2ConditioningHostTransfer.restoreForInferenceTask(host)
        eval(restored.embeddings, restored.mask)

        #expect(restored.embeddings.shape == embeddings.shape)
        #expect(restored.mask.shape == mask.shape)
        #expect(
            restored.embeddings.asData(access: .copy).data
                == embeddings.asData(access: .copy).data)
        #expect(restored.mask.asArray(Int32.self) == [1, 0])
    }

    private static func makeKey(
        schema: UInt32 = Krea2ConditioningCacheKey.currentSchema,
        modelIdentity: String = "verified-model-a",
        modelRoot: String = "/tmp/krea-model-a",
        positivePrompt: String = "positive",
        negativePrompt: String? = nil,
        cfgBranch: Krea2ConditioningCacheKey.CFGBranch = .positive,
        guidanceMode: Krea2ConditioningCacheKey.GuidanceMode = .disabled,
        templateIdentity: String = "qwen-image-v1",
        maxLength: Int = 512,
        selectLayers: [Int] = [2, 5, 8, 11],
        dtypeIdentity: Krea2HostTensorDType = .bfloat16,
        orderedLoRAIdentity: String = "lora-a@1.0|lora-b@0.5",
        regions: [Krea2ConditioningCacheKey.RegionIdentity] = []
    ) -> Krea2ConditioningCacheKey {
        Krea2ConditioningCacheKey(
            schema: schema,
            verifiedModelIdentity: modelIdentity,
            canonicalModelRoot: modelRoot,
            positivePrompt: positivePrompt,
            negativePrompt: negativePrompt,
            cfgBranch: cfgBranch,
            guidanceMode: guidanceMode,
            templateIdentity: templateIdentity,
            maxLength: maxLength,
            selectLayers: selectLayers,
            dtypeIdentity: dtypeIdentity,
            orderedLoRAIdentity: orderedLoRAIdentity,
            regionalPromptBBoxIdentity: regions
        )
    }

    private static func makeConditioning(embeddingElements: Int) -> Krea2HostConditioning {
        let embeddings = Krea2HostTensor(
            data: Data(repeating: UInt8(embeddingElements), count: embeddingElements * 2),
            shape: [embeddingElements],
            dtype: .bfloat16
        )
        let mask = Krea2HostTensor(
            data: Data(repeating: 0, count: 4),
            shape: [1],
            dtype: .int32
        )
        return Krea2HostConditioning(
            positive: Krea2HostTextConditioning(
                embeddings: embeddings,
                mask: mask,
                validTokenCount: 1
            )
        )
    }

}
