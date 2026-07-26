import Foundation

struct SRVGGPixelRect: Equatable, Sendable, Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }
}

/// One non-overlapping destination core plus its larger source context. Only the core is stitched;
/// the halo gives every boundary convolution the same neighbours as a full-image forward pass.
struct SRVGGTile: Equatable, Sendable, Hashable {
    let core: SRVGGPixelRect
    let context: SRVGGPixelRect
    let scale: Int

    var outputCore: SRVGGPixelRect {
        SRVGGPixelRect(
            x: core.x * scale,
            y: core.y * scale,
            width: core.width * scale,
            height: core.height * scale)
    }

    var outputCropX: Int { (core.x - context.x) * scale }
    var outputCropY: Int { (core.y - context.y) * scale }
}

enum SRVGGTilePlanError: Error, LocalizedError, Equatable, Sendable {
    case invalidImageDimensions
    case invalidCoreSize
    case insufficientHalo(requiredAtLeast: Int, actual: Int)
    case unsupportedScale(Int)
    case dimensionsOverflow
    case tooManyTiles(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .invalidImageDimensions: "The source image dimensions are invalid for tiled upscaling."
        case .invalidCoreSize: "The SRVGG tile core size must be positive."
        case .insufficientHalo(let required, let actual):
            "The SRVGG tile halo is \(actual) px; at least \(required) px is required to avoid seams."
        case .unsupportedScale(let scale): "The SRVGG executor does not support a \(scale)× model."
        case .dimensionsOverflow: "The SRVGG tile or output dimensions overflow the supported range."
        case .tooManyTiles(let maximum): "The SRVGG plan exceeds its \(maximum)-tile safety limit."
        }
    }
}

/// The pinned network has 34 sequential 3×3 convolutions, hence a 34-pixel receptive-field radius.
/// A 40-pixel default keeps a small audited margin. Lower values fail closed before MLX starts.
struct SRVGGTilePlan: Equatable, Sendable {
    static let receptiveFieldRadius = 34
    static let defaultCoreSize = 256
    static let defaultHalo = 40
    static let maximumTileCount = 16_384

    let sourceWidth: Int
    let sourceHeight: Int
    let coreSize: Int
    let halo: Int
    let scale: Int
    let outputWidth: Int
    let outputHeight: Int
    let tiles: [SRVGGTile]

    static func make(
        sourceWidth: Int,
        sourceHeight: Int,
        coreSize: Int = defaultCoreSize,
        halo: Int = defaultHalo,
        scale: Int = LocalUpscaleFactor.fourX.rawValue
    ) throws -> Self {
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw SRVGGTilePlanError.invalidImageDimensions
        }
        guard coreSize > 0 else { throw SRVGGTilePlanError.invalidCoreSize }
        guard halo >= receptiveFieldRadius else {
            throw SRVGGTilePlanError.insufficientHalo(
                requiredAtLeast: receptiveFieldRadius,
                actual: halo)
        }
        guard scale == LocalUpscaleFactor.fourX.rawValue else {
            throw SRVGGTilePlanError.unsupportedScale(scale)
        }
        let (outputWidth, widthOverflow) = sourceWidth.multipliedReportingOverflow(by: scale)
        let (outputHeight, heightOverflow) = sourceHeight.multipliedReportingOverflow(by: scale)
        guard !widthOverflow, !heightOverflow, outputWidth > 0, outputHeight > 0 else {
            throw SRVGGTilePlanError.dimensionsOverflow
        }

        let horizontalCount = try ceilingDivision(sourceWidth, by: coreSize)
        let verticalCount = try ceilingDivision(sourceHeight, by: coreSize)
        let (tileCount, countOverflow) = horizontalCount.multipliedReportingOverflow(by: verticalCount)
        guard !countOverflow, tileCount <= maximumTileCount else {
            throw SRVGGTilePlanError.tooManyTiles(maximum: maximumTileCount)
        }

        var tiles: [SRVGGTile] = []
        tiles.reserveCapacity(tileCount)
        for row in 0 ..< verticalCount {
            let (y, yOverflow) = row.multipliedReportingOverflow(by: coreSize)
            guard !yOverflow else { throw SRVGGTilePlanError.dimensionsOverflow }
            let coreHeight = min(coreSize, sourceHeight - y)
            for column in 0 ..< horizontalCount {
                let (x, xOverflow) = column.multipliedReportingOverflow(by: coreSize)
                guard !xOverflow else { throw SRVGGTilePlanError.dimensionsOverflow }
                let coreWidth = min(coreSize, sourceWidth - x)
                let core = SRVGGPixelRect(
                    x: x,
                    y: y,
                    width: coreWidth,
                    height: coreHeight)
                let left = max(0, x - min(x, halo))
                let top = max(0, y - min(y, halo))
                let right = sourceWidth - core.maxX > halo
                    ? core.maxX + halo
                    : sourceWidth
                let bottom = sourceHeight - core.maxY > halo
                    ? core.maxY + halo
                    : sourceHeight
                let context = SRVGGPixelRect(
                    x: left,
                    y: top,
                    width: right - left,
                    height: bottom - top)
                tiles.append(SRVGGTile(core: core, context: context, scale: scale))
            }
        }

        return Self(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            coreSize: coreSize,
            halo: halo,
            scale: scale,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            tiles: tiles)
    }

    private static func ceilingDivision(_ value: Int, by divisor: Int) throws -> Int {
        let (adjusted, overflow) = value.addingReportingOverflow(divisor - 1)
        guard !overflow else { throw SRVGGTilePlanError.dimensionsOverflow }
        return adjusted / divisor
    }
}
