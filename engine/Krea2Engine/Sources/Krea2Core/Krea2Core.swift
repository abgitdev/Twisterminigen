
public enum Krea2Constants {

    public static let resolutionMultiple = 16

    public static let defaultSteps = 8
}





public struct Krea2RegionBBox: Sendable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double
    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }
}
