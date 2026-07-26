import Foundation

/// Exact normalized-coordinate editing for Regional prompts rectangles.
enum SpatialRegionGeometry {
    static let minimumExtent = 0.05

    static func clamped(
        _ rect: GenerationRecipe.NormalizedRect
    ) -> GenerationRecipe.NormalizedRect {
        RemixCropGeometry.clamped(rect, minimumExtent: minimumExtent)
    }

    static func moved(
        _ rect: GenerationRecipe.NormalizedRect,
        deltaX: Double,
        deltaY: Double
    ) -> GenerationRecipe.NormalizedRect {
        let source = clamped(rect)
        let dx = deltaX.isFinite ? deltaX : 0
        let dy = deltaY.isFinite ? deltaY : 0
        let x = min(1 - source.width, max(0, source.x + dx))
        let y = min(1 - source.height, max(0, source.y + dy))
        return .init(x: x, y: y, width: source.width, height: source.height)
    }

    static func resized(
        _ rect: GenerationRecipe.NormalizedRect,
        deltaX: Double,
        deltaY: Double
    ) -> GenerationRecipe.NormalizedRect {
        RemixCropGeometry.resized(
            rect,
            handle: .bottomRight,
            deltaX: deltaX,
            deltaY: deltaY,
            minimumExtent: minimumExtent)
    }

    static func replacing(
        _ rect: GenerationRecipe.NormalizedRect,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) -> GenerationRecipe.NormalizedRect {
        let source = clamped(rect)
        return RemixCropGeometry.replacing(
            source,
            x: x,
            y: y,
            // X/Y are positions, not edge coordinates: moving one must preserve the extent.
            width: width ?? (x == nil ? nil : source.width),
            height: height ?? (y == nil ? nil : source.height),
            minimumExtent: minimumExtent)
    }
}

/// Resolves Regional prompt pointer input in the canvas coordinate space. Keeping hit-testing and
/// translation outside each moving overlay prevents a later overlay from capturing points outside
/// its visible rectangle and avoids changing the gesture's coordinate system during a drag.
enum SpatialRegionCanvasInteraction {
    enum Kind: Equatable {
        case move
        case resize
    }

    struct Session: Equatable {
        let regionID: UUID
        let origin: GenerationRecipe.NormalizedRect
        let kind: Kind
    }

    static let resizeHandleExtent: CGFloat = 24

    static func begin(
        at point: CGPoint,
        regions: [GenerationRecipe.BBoxRegion],
        canvasSize: CGSize
    ) -> Session? {
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              point.x.isFinite,
              point.y.isFinite
        else { return nil }

        // Later regions are drawn above earlier regions, so overlap selection follows the same
        // visual stacking order. Outside overlap, every region keeps its own exact hit target.
        for region in regions.reversed() {
            let rect = pixelRect(region.rect, canvasSize: canvasSize)
            guard rect.contains(point) else { continue }
            let handleWidth = min(resizeHandleExtent, rect.width)
            let handleHeight = min(resizeHandleExtent, rect.height)
            let handle = CGRect(
                x: rect.maxX - handleWidth,
                y: rect.maxY - handleHeight,
                width: handleWidth,
                height: handleHeight)
            return Session(
                regionID: region.id,
                origin: region.rect,
                kind: handle.contains(point) ? .resize : .move)
        }
        return nil
    }

    static func updatedRect(
        for session: Session,
        translation: CGSize,
        canvasSize: CGSize
    ) -> GenerationRecipe.NormalizedRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return session.origin
        }
        let deltaX = Double(translation.width / canvasSize.width)
        let deltaY = Double(translation.height / canvasSize.height)
        switch session.kind {
        case .move:
            return SpatialRegionGeometry.moved(
                session.origin,
                deltaX: deltaX,
                deltaY: deltaY)
        case .resize:
            return SpatialRegionGeometry.resized(
                session.origin,
                deltaX: deltaX,
                deltaY: deltaY)
        }
    }

    private static func pixelRect(
        _ rect: GenerationRecipe.NormalizedRect,
        canvasSize: CGSize
    ) -> CGRect {
        let rect = SpatialRegionGeometry.clamped(rect)
        return CGRect(
            x: CGFloat(rect.x0) * canvasSize.width,
            y: CGFloat(rect.y0) * canvasSize.height,
            width: CGFloat(rect.width) * canvasSize.width,
            height: CGFloat(rect.height) * canvasSize.height)
    }
}

enum RegionalPromptPlacement {
    static let initialExtent = 0.45
    static let cascadeStep = 0.07
    static let leadingInset = 0.05

    static func initialRect(index: Int) -> GenerationRecipe.NormalizedRect {
        let safeIndex = max(0, index)
        let maximumOffset = 1 - leadingInset - initialExtent
        let offset = min(maximumOffset, Double(safeIndex) * cascadeStep)
        return .init(
            x: leadingInset + offset,
            y: leadingInset + offset,
            width: initialExtent,
            height: initialExtent)
    }
}

enum RegionalPromptsLayout {
    static let maximumSheetWidth: CGFloat = 1_720
    static let maximumSheetHeight: CGFloat = 1_080
    static let horizontalScreenInset: CGFloat = 48
    static let verticalScreenInset: CGFloat = 80

    static func preferredSheetSize(visibleScreenSize: CGSize) -> CGSize {
        let availableWidth = max(720, visibleScreenSize.width - horizontalScreenInset)
        let availableHeight = max(600, visibleScreenSize.height - verticalScreenInset)
        return CGSize(
            width: min(maximumSheetWidth, availableWidth),
            height: min(maximumSheetHeight, availableHeight))
    }
}
