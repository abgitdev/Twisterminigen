// Krea2Patchify.swift
//



import Foundation
import MLX

public enum Krea2Patchify {

    public static func roundup(_ v: Int, _ m: Int) -> Int { ((v + m - 1) / m) * m }


    public static func patchify(_ x: MLXArray, patch p: Int) -> MLXArray {
        let b = x.dim(0), c = x.dim(1), h = x.dim(2) / p, w = x.dim(3) / p
        return x.reshaped([b, c, h, p, w, p])
            .transposed(0, 2, 4, 1, 3, 5)     // b h w c ph pw
            .reshaped([b, h * w, c * p * p])
    }


    public static func unpatchify(_ x: MLXArray, patch p: Int, h: Int, w: Int, channels c: Int) -> MLXArray {
        let b = x.dim(0)
        return x.reshaped([b, h, w, c, p, p])
            .transposed(0, 3, 1, 4, 2, 5)     // b c h ph w pw
            .reshaped([b, c, h * p, w * p])
    }


    public static func buildPositions(txtlen: Int, h: Int, w: Int) -> MLXArray {
        var flat = [Float](repeating: 0, count: (txtlen + h * w) * 3)

        var idx = txtlen * 3
        for r in 0 ..< h {
            for c in 0 ..< w {
                flat[idx + 1] = Float(r)
                flat[idx + 2] = Float(c)
                idx += 3
            }
        }
        return MLXArray(flat).reshaped([txtlen + h * w, 3])
    }
}
