// Krea2DiTLoRAMapping.swift
//






import Foundation

public enum Krea2DiTLoRAMapping {
    public struct Target {
        public let modulePath: String
        public let aliases: [String]
    }

    public static func targets(config: Krea2DiTConfig) -> [Target] {
        var result: [Target] = []
        result.append(contentsOf: globalTargets())
        for block in 0 ..< 2 {
            result.append(contentsOf: textFusionBlockTargets(group: "layerwise_blocks", block: block))
        }
        for block in 0 ..< 2 {
            result.append(contentsOf: textFusionBlockTargets(group: "refiner_blocks", block: block))
        }
        for block in 0 ..< config.layers {
            result.append(contentsOf: transformerBlockTargets(block: block))
        }
        return result
    }

    private static func globalTargets() -> [Target] {
        [
            Target(modulePath: "first", aliases: ["img_in"]),
            Target(modulePath: "tmlp.0", aliases: ["tmlp.linear_in", "time_embed.linear_1"]),
            Target(modulePath: "tmlp.2", aliases: ["tmlp.linear_out", "time_embed.linear_2"]),
            Target(modulePath: "tproj.1", aliases: ["tproj.linear", "time_mod_proj"]),
            Target(modulePath: "txtmlp.1", aliases: ["txtmlp.linear_in", "txt_in.linear_1"]),
            Target(modulePath: "txtmlp.3", aliases: ["txtmlp.linear_out", "txt_in.linear_2"]),
            Target(modulePath: "txtfusion.projector", aliases: ["text_fusion.projector"]),
            Target(modulePath: "last.linear", aliases: ["final_layer.linear"]),
        ]
    }

    private static func textFusionBlockTargets(group: String, block: Int) -> [Target] {
        attnAndMlpTargets(
            mlxPrefix: "txtfusion.\(group).\(block)",
            diffusersPrefix: "text_fusion.\(group).\(block)")
    }

    private static func transformerBlockTargets(block: Int) -> [Target] {
        attnAndMlpTargets(mlxPrefix: "blocks.\(block)", diffusersPrefix: "transformer_blocks.\(block)")
    }



    private static func attnAndMlpTargets(mlxPrefix: String, diffusersPrefix: String) -> [Target] {
        [
            Target(modulePath: "\(mlxPrefix).attn.wq", aliases: ["\(diffusersPrefix).attn.to_q"]),
            Target(modulePath: "\(mlxPrefix).attn.wk", aliases: ["\(diffusersPrefix).attn.to_k"]),
            Target(modulePath: "\(mlxPrefix).attn.wv", aliases: ["\(diffusersPrefix).attn.to_v"]),
            Target(modulePath: "\(mlxPrefix).attn.gate", aliases: ["\(diffusersPrefix).attn.to_gate"]),
            Target(
                modulePath: "\(mlxPrefix).attn.wo",
                aliases: ["\(diffusersPrefix).attn.to_out.0", "\(diffusersPrefix).attn.to_out"]),
            Target(modulePath: "\(mlxPrefix).mlp.gate", aliases: ["\(diffusersPrefix).ff.gate"]),
            Target(modulePath: "\(mlxPrefix).mlp.up", aliases: ["\(diffusersPrefix).ff.up"]),
            Target(modulePath: "\(mlxPrefix).mlp.down", aliases: ["\(diffusersPrefix).ff.down"]),
        ]
    }
}
