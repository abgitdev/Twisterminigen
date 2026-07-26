// Qwen3VLTextMLP.swift
//
// SwiGLU FFN Qwen3-VL (gate/up/down, intermediate 9728, SiLU) — PORT_MAP §2.

// Sources/FluxTextEncoders/Model/Qwen3VL/Qwen3VLMLP.swift.


import Foundation
import MLX
import MLXNN

public final class Qwen3VLTextMLP: Module {
    @ModuleInfo public var gate_proj: Linear
    @ModuleInfo public var up_proj: Linear
    @ModuleInfo public var down_proj: Linear

    public init(config: Krea2TextEncoderConfig) {
        self._gate_proj = ModuleInfo(wrappedValue: Linear(config.hiddenSize, config.intermediateSize, bias: false))
        self._up_proj = ModuleInfo(wrappedValue: Linear(config.hiddenSize, config.intermediateSize, bias: false))
        self._down_proj = ModuleInfo(wrappedValue: Linear(config.intermediateSize, config.hiddenSize, bias: false))
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        down_proj(silu(gate_proj(x)) * up_proj(x))
    }
}
