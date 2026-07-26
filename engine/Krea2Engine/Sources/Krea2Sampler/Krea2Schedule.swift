// Krea2Schedule.swift
//






import Foundation

public enum Krea2Schedule {




    public static func timesteps(
        seqLen: Int, steps: Int, x1: Int, x2: Int,
        y1: Double = 0.5, y2: Double = 1.15, sigma: Double = 1.0, mu: Double? = nil
    ) -> [Double] {
        let mu: Double = mu ?? {
            let slope = (y2 - y1) / Double(x2 - x1)
            return slope * Double(seqLen) + (y1 - slope * Double(x1))
        }()
        let emu = Foundation.exp(mu)


        let n = steps + 1
        return (0 ..< n).map { i -> Double in
            let t = 1.0 - Double(i) / Double(steps)   // i=0 → 1.0; i=steps → 0.0
            if t <= 0 { return 0.0 }                  // guard: 1/0=inf → σ=0 (§0.9)
            return emu / (emu + Foundation.pow(1.0 / t - 1.0, sigma))
        }
    }
}
