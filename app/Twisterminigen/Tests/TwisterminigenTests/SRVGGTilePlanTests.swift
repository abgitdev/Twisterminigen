import Testing
@testable import Twisterminigen

@Suite("SRVGG tile plan")
struct SRVGGTilePlanTests {
    @Test("Cores partition source and exact 4× destination once")
    func exactCoverage() throws {
        let plan = try SRVGGTilePlan.make(
            sourceWidth: 7,
            sourceHeight: 5,
            coreSize: 3,
            halo: SRVGGTilePlan.receptiveFieldRadius,
            scale: 4)

        #expect(plan.tiles.count == 6)
        #expect(plan.outputWidth == 28)
        #expect(plan.outputHeight == 20)
        var sourceHits = [Int](repeating: 0, count: 7 * 5)
        var outputHits = [Int](repeating: 0, count: 28 * 20)
        for tile in plan.tiles {
            for y in tile.core.y ..< tile.core.maxY {
                for x in tile.core.x ..< tile.core.maxX {
                    sourceHits[y * 7 + x] += 1
                }
            }
            for y in tile.outputCore.y ..< tile.outputCore.maxY {
                for x in tile.outputCore.x ..< tile.outputCore.maxX {
                    outputHits[y * 28 + x] += 1
                }
            }
        }
        #expect(sourceHits.allSatisfy { $0 == 1 })
        #expect(outputHits.allSatisfy { $0 == 1 })
    }

    @Test("Interior tiles carry the audited halo and exact crop offsets")
    func haloGeometry() throws {
        let plan = try SRVGGTilePlan.make(
            sourceWidth: 520,
            sourceHeight: 300,
            coreSize: 256,
            halo: 40,
            scale: 4)
        let tile = try #require(plan.tiles.first {
            $0.core.x == 256 && $0.core.y == 0
        })

        #expect(tile.core == SRVGGPixelRect(x: 256, y: 0, width: 256, height: 256))
        #expect(tile.context == SRVGGPixelRect(x: 216, y: 0, width: 304, height: 296))
        #expect(tile.outputCropX == 160)
        #expect(tile.outputCropY == 0)
        #expect(tile.outputCore == SRVGGPixelRect(
            x: 1_024,
            y: 0,
            width: 1_024,
            height: 1_024))
    }

    @Test("Insufficient halo, non-4× scale, overflow, and tile explosion fail closed")
    func safetyLimits() {
        #expect(throws: SRVGGTilePlanError.insufficientHalo(
            requiredAtLeast: 34,
            actual: 33)) {
            _ = try SRVGGTilePlan.make(
                sourceWidth: 64,
                sourceHeight: 64,
                coreSize: 32,
                halo: 33)
        }
        #expect(throws: SRVGGTilePlanError.unsupportedScale(2)) {
            _ = try SRVGGTilePlan.make(
                sourceWidth: 64,
                sourceHeight: 64,
                scale: 2)
        }
        #expect(throws: SRVGGTilePlanError.dimensionsOverflow) {
            _ = try SRVGGTilePlan.make(
                sourceWidth: Int.max,
                sourceHeight: 1)
        }
        #expect(throws: SRVGGTilePlanError.tooManyTiles(
            maximum: SRVGGTilePlan.maximumTileCount)) {
            _ = try SRVGGTilePlan.make(
                sourceWidth: SRVGGTilePlan.maximumTileCount + 1,
                sourceHeight: 1,
                coreSize: 1,
                halo: 34)
        }
    }
}
