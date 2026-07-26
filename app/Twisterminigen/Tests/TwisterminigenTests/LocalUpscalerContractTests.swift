import Foundation
import Testing
@testable import Twisterminigen

@Suite("Local upscaler contract")
struct LocalUpscalerContractTests {
    private let model = LocalUpscaleModel(
        id: "test.srvgg.x4",
        displayName: "Test SRVGG ×4",
        nativeFactor: .fourX,
        revision: String(repeating: "a", count: 40))

    @Test("Unavailable service receives no filesystem capability")
    func unavailableIsHonest() async {
        let request = LocalUpscaleRequest(
            sourcePNGData: Self.onePixelPNG,
            sourceSize: .init(width: 1, height: 1),
            factor: .fourX,
            model: model)

        do {
            _ = try await UnavailableLocalUpscaler().upscale(request)
            Issue.record("An unavailable executor claimed a successful result")
        } catch let error as LocalUpscalerError {
            #expect(error == .unavailable(
                message: UnavailableLocalUpscaler.verificationRequiredMessage))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Request and result require exact native 4× dimensions")
    func strictShapeContract() throws {
        let request = LocalUpscaleRequest(
            sourcePNGData: Self.onePixelPNG,
            sourceSize: .init(width: 513, height: 257),
            factor: .fourX,
            model: model)

        try request.validate()
        #expect(try request.expectedOutputSize == .init(width: 2_052, height: 1_028))

        let exact = LocalUpscaleDataResult(
            pngData: Self.onePixelPNG,
            pixelSize: .init(width: 2_052, height: 1_028),
            model: model)
        try exact.validate(against: request)

        let interpolatedTwoX = LocalUpscaleDataResult(
            pngData: Self.onePixelPNG,
            pixelSize: .init(width: 1_026, height: 514),
            model: model)
        #expect(throws: LocalUpscalerError.resultDoesNotMatchRequest) {
            try interpolatedTwoX.validate(against: request)
        }
    }

    @Test("Empty source and dimension overflow fail before inference")
    func safetyValidation() {
        let empty = LocalUpscaleRequest(
            sourcePNGData: Data(),
            sourceSize: .init(width: 1, height: 1),
            factor: .fourX,
            model: model)
        #expect(throws: LocalUpscalerError.emptySourceData) {
            try empty.validate()
        }

        let overflow = LocalUpscalePixelSize(width: Int.max, height: 1)
        #expect(throws: LocalUpscalerError.outputDimensionsOverflow) {
            _ = try overflow.scaled(by: .fourX)
        }
    }

    @Test("Encoded output remains exact in memory until reviewed publication")
    func encodedOutputHasNoDestinationPath() throws {
        let request = LocalUpscaleRequest(
            sourcePNGData: Self.onePixelPNG,
            sourceSize: .init(width: 1, height: 1),
            factor: .fourX,
            model: model)
        let encoded = Data("complete encoded output".utf8)
        let result = LocalUpscaleDataResult(
            pngData: encoded,
            pixelSize: .init(width: 4, height: 4),
            model: model)

        try result.validate(against: request)
        #expect(result.pngData == encoded)
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}
