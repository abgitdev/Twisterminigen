import Foundation

struct InputImageAsset: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let managedFilename: String
    let sha256: String
    let byteCount: Int64
    let width: Int
    let height: Int
    let importedAt: Date
}

struct InputImageLibrarySnapshot: Sendable, Equatable {
    var assets: [InputImageAsset]

    static let empty = InputImageLibrarySnapshot(assets: [])
}

/// Host-resident RGB floats in contiguous CHW order: red plane, green plane, blue plane.
struct InputImagePlanarRGB: Sendable, Equatable {
    enum Channel: Int, Sendable {
        case red
        case green
        case blue
    }

    let width: Int
    let height: Int
    let values: [Float]

    var planeSize: Int { width * height }
    var tensorShape: [Int] { [1, 3, height, width] }

    subscript(channel: Channel, x: Int, y: Int) -> Float {
        values[channel.rawValue * planeSize + y * width + x]
    }
}
