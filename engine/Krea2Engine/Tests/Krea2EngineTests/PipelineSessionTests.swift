import Foundation
import Krea2Core
import Krea2Sampler
import MLX
import Testing
@testable import Krea2Pipeline
@testable import Krea2TextEncoder

@Suite struct PipelineSessionTests {
    private enum LoadBoundaryFailure: Error {
        case blocked
    }

    @Test func stateMachinePermitsOnlyOneResidentModel() throws {
        var state = Krea2PipelineSessionStateMachine()
        #expect(state.stage == .idle)

        try state.beginLoading(.textEncoder)
        #expect(state.stage == .loadingTextEncoder)
        try state.markResident(.textEncoder)
        #expect(state.stage == .textEncoderResident)

        let conflict = captureSessionError {
            try state.beginLoading(.transformer)
        }
        #expect(conflict == .stageConflict(
            active: .textEncoderResident,
            requested: .loadingTransformer
        ))
        #expect(state.stage == .textEncoderResident)

        try state.release(.textEncoder)
        try state.beginLoading(.encoder)
        try state.markResident(.encoder)
        #expect(state.stage == .encoderResident)
        try state.release(.encoder)
        try state.beginLoading(.transformer)
        try state.markResident(.transformer)
        #expect(state.stage == .transformerResident)
        try state.release(.transformer)

        try state.beginLoading(.decoder)
        try state.markResident(.decoder)
        #expect(state.stage == .decoderResident)
        try state.release(.decoder)
        #expect(state.stage == .idle)
    }

    @Test func failedLoadCanResetSessionToIdle() throws {
        var state = Krea2PipelineSessionStateMachine()
        try state.beginLoading(.transformer)
        #expect(state.stage == .loadingTransformer)

        state.reset()
        #expect(state.stage == .idle)

        try state.beginLoading(.decoder)
        try state.markResident(.decoder)
        state.reset()
        #expect(state.stage == .idle)
    }

    @Test func loadVerificationRunsBeforeTextEncoderOpensAnyWeightPath() async {
        let recorder = ModelLoadVerificationRecorder()
        let session = Krea2PipelineSession(loadVerification: { component in
            recorder.record(component)
            throw LoadBoundaryFailure.blocked
        })
        do {
            _ = try await session.withTextEncoder(
                officialDirectory: URL(fileURLWithPath: "/must-not-be-opened")) { _ in
                    Issue.record("verification failure must prevent a resident text encoder")
                }
            Issue.record("Expected load verification to stop the model load")
        } catch is LoadBoundaryFailure {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(recorder.components == [.textEncoder])
        #expect(session.stage == .idle)
    }

    @Test func stateMachineRejectsOutOfOrderTransitions() {
        var state = Krea2PipelineSessionStateMachine()

        let markWithoutLoad = captureSessionError {
            try state.markResident(.transformer)
        }
        #expect(markWithoutLoad == .stageConflict(
            active: .idle,
            requested: .transformerResident
        ))

        let releaseWithoutResident = captureSessionError {
            try state.release(.decoder)
        }
        #expect(releaseWithoutResident == .stageConflict(
            active: .idle,
            requested: .idle
        ))
    }

    @Test func singletonTensorContractsAcceptOneJob() throws {
        try Krea2PipelineTensorContract.validateConditioning(
            embeddings: [1, 512, 12, 2_560],
            mask: [1, 512],
            validTokenCount: 123,
            branch: "positive"
        )
        try Krea2PipelineTensorContract.validateMatchingConditioning(
            positive: [1, 512, 12, 2_560],
            negative: [1, 512, 12, 2_560]
        )
        try Krea2PipelineTensorContract.validateLatent([1, 16, 128, 128])
        try Krea2PipelineTensorContract.validateImage([1, 3, 1_024, 1_024])
    }

    @Test func tensorContractsRejectTrueBatchDimensions() {
        let conditioningError = captureSessionError {
            try Krea2PipelineTensorContract.validateConditioning(
                embeddings: [2, 512, 12, 2_560],
                mask: [2, 512],
                validTokenCount: 123,
                branch: "positive"
            )
        }
        #expect(conditioningError == .invalidTensorShape(
            tensor: "positive embeddings",
            expected: Krea2PipelineTensorContract.conditioningShapeDescription,
            actual: [2, 512, 12, 2_560]
        ))

        let latentError = captureSessionError {
            try Krea2PipelineTensorContract.validateLatent([2, 16, 128, 128])
        }
        #expect(latentError == .invalidTensorShape(
            tensor: "latent",
            expected: Krea2PipelineTensorContract.latentShapeDescription,
            actual: [2, 16, 128, 128]
        ))

        let imageError = captureSessionError {
            try Krea2PipelineTensorContract.validateImage([2, 3, 1_024, 1_024])
        }
        #expect(imageError == .invalidTensorShape(
            tensor: "decoded image",
            expected: Krea2PipelineTensorContract.imageShapeDescription,
            actual: [2, 3, 1_024, 1_024]
        ))
    }

    @Test func conditioningBranchesMustMatch() {
        let error = captureSessionError {
            try Krea2PipelineTensorContract.validateMatchingConditioning(
                positive: [1, 512, 12, 2_560],
                negative: [1, 256, 12, 2_560]
            )
        }
        #expect(error == .incompatibleConditioningBranches(
            positive: [1, 512, 12, 2_560],
            negative: [1, 256, 12, 2_560]
        ))
    }

    @Test func regionalConditioningRequiresValidBoxesAndTokensForEveryRegion() throws {
        let embeddings = MLXArray.zeros([1, 4, 1, 2])
        let region = Krea2RegionBBox(x0: 0, y0: 0, x1: 0.5, y1: 1)
        _ = try Krea2MaterializedRegionalConditioning(
            materializing: .init(
                embeddings: embeddings,
                txtLabels: MLXArray([Int32(0), 1, 0, -1]),
                regionCount: 1),
            regions: [region])

        let missing = captureSessionError {
            _ = try Krea2MaterializedRegionalConditioning(
                materializing: .init(
                    embeddings: embeddings,
                    txtLabels: MLXArray([Int32(0), 0, 0, -1]),
                    regionCount: 1),
                regions: [region])
        }
        #expect(missing == .regionPromptHasNoTokens(0))

        let invalidBox = captureSessionError {
            _ = try Krea2MaterializedRegionalConditioning(
                materializing: .init(
                    embeddings: embeddings,
                    txtLabels: MLXArray([Int32(0), 1, 0, -1]),
                    regionCount: 1),
                regions: [.init(x0: 0.5, y0: 0, x1: 0.5, y1: 1)])
        }
        #expect(invalidBox == .invalidRegionBBox(0))
    }

    @Test func plannedGenerationRejectsUnboundedGroupsBeforeLoadingModels() async {
        let weights = Krea2Pipeline.Weights(
            officialDir: URL(fileURLWithPath: "/does-not-exist/official"),
            ditQuantFile: URL(fileURLWithPath: "/does-not-exist/dit"),
            vaeFile: URL(fileURLWithPath: "/does-not-exist/vae"))
        var params = Krea2Sampler.Params()
        params.width = 512
        params.height = 512
        let request = Krea2Pipeline.PlannedRequest(prompt: "test", params: params)

        await expectPlanError(.invalidRequestCount(actual: 0, maximum: 4)) {
            _ = try await Krea2Pipeline.generatePlanned(requests: [], weights: weights)
        }
        await expectPlanError(.invalidRequestCount(actual: 5, maximum: 4)) {
            _ = try await Krea2Pipeline.generatePlanned(
                requests: Array(repeating: request, count: 5),
                weights: weights)
        }
    }

    @Test func imageInputRejectsMalformedHostBuffers() throws {
        #expect(throws: Krea2Pipeline.ImageInputError.invalidDimensions(width: 510, height: 512)) {
            _ = try Krea2Pipeline.ImageInput(
                width: 510,
                height: 512,
                planarRGB: [])
        }
        #expect(throws: Krea2Pipeline.ImageInputError.invalidPixelCount(
            expected: 3 * 8 * 8,
            actual: 1)
        ) {
            _ = try Krea2Pipeline.ImageInput(width: 8, height: 8, planarRGB: [0])
        }
        var nonFinite = [Float](repeating: 0, count: 3 * 8 * 8)
        nonFinite[17] = .nan
        #expect(throws: Krea2Pipeline.ImageInputError.nonFinitePixel(17)) {
            _ = try Krea2Pipeline.ImageInput(width: 8, height: 8, planarRGB: nonFinite)
        }
    }

    @Test func plannedGenerationRejectsInvalidImageParametersBeforeLoadingModels() async throws {
        let weights = Krea2Pipeline.Weights(
            officialDir: URL(fileURLWithPath: "/does-not-exist/official"),
            ditQuantFile: URL(fileURLWithPath: "/does-not-exist/dit"),
            vaeFile: URL(fileURLWithPath: "/does-not-exist/vae"))
        var params = Krea2Sampler.Params()
        params.width = 16
        params.height = 16
        let image = try Krea2Pipeline.ImageInput(
            width: 8,
            height: 8,
            planarRGB: [Float](repeating: 0, count: 3 * 8 * 8))

        await expectPlanError(.invalidImageStrength(0)) {
            _ = try await Krea2Pipeline.generatePlanned(
                requests: [.init(
                    prompt: "test",
                    params: params,
                    inputImage: image,
                    imageStrength: 0)],
                weights: weights)
        }
        await expectPlanError(.inputImageSizeMismatch(
            index: 0,
            expectedWidth: 16,
            expectedHeight: 16,
            actualWidth: 8,
            actualHeight: 8)
        ) {
            _ = try await Krea2Pipeline.generatePlanned(
                requests: [.init(
                    prompt: "test",
                    params: params,
                    inputImage: image,
                    imageStrength: 0.5)],
                weights: weights)
        }
    }

    private func captureSessionError(
        _ operation: () throws -> Void
    ) -> Krea2PipelineSessionError? {
        do {
            try operation()
            Issue.record("Expected Krea2PipelineSessionError")
            return nil
        } catch let error as Krea2PipelineSessionError {
            return error
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }

    private func expectPlanError(
        _ expected: Krea2Pipeline.PlannedGenerationError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected planned generation to fail")
        } catch let error as Krea2Pipeline.PlannedGenerationError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private final class ModelLoadVerificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Krea2Pipeline.ModelLoadComponent] = []

    var components: [Krea2Pipeline.ModelLoadComponent] {
        lock.withLock { stored }
    }

    func record(_ component: Krea2Pipeline.ModelLoadComponent) {
        lock.withLock { stored.append(component) }
    }
}
