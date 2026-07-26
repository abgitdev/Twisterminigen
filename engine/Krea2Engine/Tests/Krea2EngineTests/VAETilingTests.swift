// VAETilingTests.swift
//
// Pure tiling geometry and feather tests. These never construct an MLXArray or VAE module.

import Testing
@testable import Krea2VAE

private let exhaustiveLatentAxisLimit = 4_096

private func expectedWindowCount(total: Int) -> Int {
    guard total > Krea2VAE.tileMax else { return 1 }
    let stride = Krea2VAE.tileMax - Krea2VAE.tileFeather
    return 1 + (total - Krea2VAE.tileMax + stride - 1) / stride
}

private func axisWeightSums(total: Int, scale: Int) -> (sums: [Float], allPositive: Bool) {
    let windows = Krea2VAE.tileWindows(total: total)
    var sums = [Float](repeating: 0, count: total * scale)
    var allPositive = true

    for (index, window) in windows.enumerated() {
        let weights = Krea2VAE.ramp1D(
            length: window.count * scale,
            rampIn: index == 0 ? 0 : Krea2VAE.tileFeather * scale,
            rampOut: index == windows.count - 1 ? 0 : Krea2VAE.tileFeather * scale)
        allPositive = allPositive && weights.allSatisfy { $0 > 0 }
        let outputStart = window.lowerBound * scale
        for (offset, weight) in weights.enumerated() {
            sums[outputStart + offset] += weight
        }
    }
    return (sums, allPositive)
}

@Test func vaeBalancedTileWindowControls() {
    #expect(Krea2VAE.tileMax == 168)
    #expect(Krea2VAE.tileOverlap == 24)
    #expect(Krea2VAE.tileFeather == 48)

    #expect(Krea2VAE.tileWindows(total: 168) == [0 ..< 168])
    #expect(Krea2VAE.tileWindows(total: 169) == [0 ..< 109, 61 ..< 169])
    #expect(Krea2VAE.tileWindows(total: 176) == [0 ..< 112, 64 ..< 176])
    #expect(Krea2VAE.tileWindows(total: 192) == [0 ..< 120, 72 ..< 192])
    #expect(Krea2VAE.tileWindows(total: 256) == [0 ..< 152, 104 ..< 256])
}

@Test func vaeBalancedTileWindowsAreMinimalAndExhaustive() {
    for total in 1 ... exhaustiveLatentAxisLimit {
        let windows = Krea2VAE.tileWindows(total: total)
        let widths = windows.map(\.count)

        #expect(windows.count == expectedWindowCount(total: total))
        #expect(windows.first?.lowerBound == 0)
        #expect(windows.last?.upperBound == total)
        #expect(widths.allSatisfy { $0 > 0 && $0 <= Krea2VAE.tileMax })
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1)
        #expect(
            widths.reduce(0, +) - (windows.count - 1) * Krea2VAE.tileFeather == total)

        if windows.count == 1 {
            #expect(windows[0] == 0 ..< total)
        } else {
            let capacityWithOneFewer = (windows.count - 1) * Krea2VAE.tileMax
                - (windows.count - 2) * Krea2VAE.tileFeather
            #expect(capacityWithOneFewer < total)
        }

        for index in 1 ..< windows.count {
            #expect(
                windows[index - 1].upperBound - windows[index].lowerBound
                    == Krea2VAE.tileFeather)
            if index >= 2 {
                #expect(windows[index - 2].upperBound <= windows[index].lowerBound)
            }
        }
    }
}

@Test func vaeBalancedTileGridHandlesRectangularAxes() {
    let shapes = [
        (height: 168, width: 256, rows: 1, columns: 2),
        (height: 256, width: 168, rows: 2, columns: 1),
        (height: 169, width: 289, rows: 2, columns: 3),
        (height: 289, width: 192, rows: 3, columns: 2),
    ]

    for shape in shapes {
        let rows = Krea2VAE.tileWindows(total: shape.height).count
        let columns = Krea2VAE.tileWindows(total: shape.width).count
        #expect(rows == shape.rows)
        #expect(columns == shape.columns)
        #expect(rows * columns == shape.rows * shape.columns)
    }

    let latent2048 = 2_048 / Krea2VAE.spatialScale
    let windows = Krea2VAE.tileWindows(total: latent2048)
    #expect(latent2048 == 256)
    #expect(windows.count == 2)
    #expect(windows.count * windows.count == 4)
}

@Test func vaeFeatherPairsAreStrictlyPositiveAndPartitionUnity() {
    for scale in [1, Krea2VAE.spatialScale] {
        let feather = Krea2VAE.tileFeather * scale
        let outgoing = Krea2VAE.ramp1D(length: feather, rampIn: 0, rampOut: feather)
        let incoming = Krea2VAE.ramp1D(length: feather, rampIn: feather, rampOut: 0)

        #expect(outgoing.allSatisfy { $0 > 0 && $0 < 1 })
        #expect(incoming.allSatisfy { $0 > 0 && $0 < 1 })
        #expect(zip(outgoing, incoming).allSatisfy { $0 + $1 == 1 })
    }
}

@Test func vaeBalancedTileWeightsHaveNoGapsOrZeros() {
    for total in 1 ... exhaustiveLatentAxisLimit {
        let coverage = axisWeightSums(total: total, scale: 1)
        #expect(coverage.allPositive)
        #expect(coverage.sums.allSatisfy { $0 > 0 })
        #expect(coverage.sums.allSatisfy { abs($0 - 1) < 1e-6 })
    }

    for total in [168, 169, 176, 192, 256, 289] {
        let coverage = axisWeightSums(total: total, scale: Krea2VAE.spatialScale)
        #expect(coverage.allPositive)
        #expect(coverage.sums.allSatisfy { $0 > 0 })
        #expect(coverage.sums.allSatisfy { abs($0 - 1) < 1e-6 })
    }
}
