// Krea2DiTConfig.swift
//



import Foundation

public struct Krea2DiTConfig: Sendable, Codable {
    public var features: Int = 6144
    public var tdim: Int = 256             // timestep_embed_dim
    public var txtdim: Int = 2560          // text_hidden_dim (Qwen3-VL-4B)
    public var heads: Int = 48             // num_attention_heads
    public var kvheads: Int = 12           // num_key_value_heads (GQA rep=4)
    public var multiplier: Int = 4         // SwiGLU multiplier
    public var layers: Int = 28            // num_layers (SingleStreamBlock)
    public var patch: Int = 2              // patch size
    public var channels: Int = 16          // latent channels (in_channels/patch^2 = 64/4)
    public var theta: Float = 1000.0       // rope_theta
    public var txtheads: Int = 20          // text_num_attention_heads
    public var txtkvheads: Int = 20        // text_num_key_value_heads
    public var txtlayers: Int = 12
    public var normEps: Float = 1e-5

    public init() {}


    public static func load(from url: URL) throws -> Krea2DiTConfig {
        try JSONDecoder().decode(Krea2DiTConfig.self, from: Data(contentsOf: url))
    }

    /// headDim = features / heads = 128.
    public var headDim: Int { features / heads }



    public var ropeAxes: [Int] {
        let h = headDim
        let a0 = h - 12 * (h / 16)
        let a1 = 6 * (h / 16)
        return [a0, a1, a1]
    }


    public var inChannels: Int { channels * patch * patch }
}
