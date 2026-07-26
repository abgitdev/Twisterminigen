import Testing
@testable import Twisterminigen

@Suite("SRVGGNetCompact contract")
struct SRVGGNetCompactContractTests {
    @Test("Pinned model topology is the real general-x4v3 SRVGG configuration")
    func configuration() {
        let configuration = SRVGGNetCompact.Configuration.realESRGANGeneralX4V3

        #expect(configuration.inputChannels == 3)
        #expect(configuration.outputChannels == 3)
        #expect(configuration.features == 64)
        #expect(configuration.convolutionCount == 32)
        #expect(configuration.upscaleFactor == .fourX)
        // first conv/PReLU + 32 conv/PReLU pairs + terminal conv
        #expect(2 + configuration.convolutionCount * 2 + 1 == 67)
        // 34 3×3 convolutions imply the tile planner's exact receptive radius.
        #expect(1 + configuration.convolutionCount + 1 == SRVGGTilePlan.receptiveFieldRadius)
    }
}
