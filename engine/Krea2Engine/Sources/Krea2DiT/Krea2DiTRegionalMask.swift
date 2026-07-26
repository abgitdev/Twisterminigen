// Krea2DiTRegionalMask.swift
//





//








//



import Foundation
import MLX

public enum Krea2DiTRegionalMask {


    public static func masks(
        txtLabels: MLXArray, imgLabels: MLXArray, dtype: DType
    ) -> (txtMask: MLXArray, fullMask: MLXArray) {
        let txtlen = txtLabels.dim(0)
        let imglen = imgLabels.dim(0)

        let tlI = txtLabels.reshaped([txtlen, 1])
        let tlJ = txtLabels.reshaped([1, txtlen])
        let ilI = imgLabels.reshaped([imglen, 1])
        let ilJ = imgLabels.reshaped([1, imglen])


        let ttNotPad = (tlI .!= -1) .&& (tlJ .!= -1)
        let ttBridge = (tlI .== 0) .|| (tlJ .== 0) .|| (tlI .== tlJ)
        let tt = (ttNotPad .&& ttBridge).asType(.float32)                    // (txtlen, txtlen)




        let tiNotPad = tlI .!= -1
        let tiBridge = (tlI .== 0) .|| (tlI .== ilJ)
        let ti = (tiNotPad .&& tiBridge).asType(.float32)                    // (txtlen, imglen)


        let itNotPad = tlJ .!= -1
        let itBridge = (tlJ .== 0) .|| (ilI .== tlJ)
        let it = (itNotPad .&& itBridge).asType(.float32)                    // (imglen, txtlen)


        let ii = MLXArray.ones([imglen, imglen])                            // (imglen, imglen)

        let full = concatenated([
            concatenated([tt, ti], axis: 1),
            concatenated([it, ii], axis: 1),
        ], axis: 0)                                                          // (L, L)




        let txtMask = ((1.0 - tt) * Float(-1e9)).reshaped([1, 1, txtlen, txtlen]).asType(dtype)
        let fullMask = ((1.0 - full) * Float(-1e9))
            .reshaped([1, 1, txtlen + imglen, txtlen + imglen]).asType(dtype)
        return (txtMask, fullMask)
    }
}
