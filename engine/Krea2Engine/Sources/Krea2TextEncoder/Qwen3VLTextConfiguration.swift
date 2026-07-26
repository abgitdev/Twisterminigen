// Qwen3VLTextConfiguration.swift
//


// Sources/FluxTextEncoders/Configuration/Qwen3VLConfiguration.swift.




import Foundation


public struct Krea2TextEncoderConfig: Decodable, Sendable {
    public let vocabSize: Int
    public let hiddenSize: Int
    public let intermediateSize: Int
    public let numHiddenLayers: Int
    public let numAttentionHeads: Int
    public let numKeyValueHeads: Int

    public let headDim: Int

    public let rmsNormEps: Float

    public let ropeTheta: Float
    public let tieWordEmbeddings: Bool

    enum CodingKeys: String, CodingKey {
        case vocabSize = "vocab_size"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case rmsNormEps = "rms_norm_eps"
        case ropeTheta = "rope_theta"
        case ropeParameters = "rope_parameters"
        case ropeScaling = "rope_scaling"
        case tieWordEmbeddings = "tie_word_embeddings"
    }



    private struct RopeParameters: Decodable {
        let ropeTheta: Float?
        enum CodingKeys: String, CodingKey {
            case ropeTheta = "rope_theta"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vocabSize = try c.decode(Int.self, forKey: .vocabSize)
        hiddenSize = try c.decode(Int.self, forKey: .hiddenSize)
        intermediateSize = try c.decode(Int.self, forKey: .intermediateSize)
        numHiddenLayers = try c.decode(Int.self, forKey: .numHiddenLayers)
        numAttentionHeads = try c.decode(Int.self, forKey: .numAttentionHeads)
        numKeyValueHeads = try c.decode(Int.self, forKey: .numKeyValueHeads)
        headDim = try c.decodeIfPresent(Int.self, forKey: .headDim) ?? 128
        rmsNormEps = try c.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        tieWordEmbeddings = try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true

        if let theta = try c.decodeIfPresent(Float.self, forKey: .ropeTheta) {
            ropeTheta = theta
        } else if let params = try c.decodeIfPresent(RopeParameters.self, forKey: .ropeParameters),
                  let theta = params.ropeTheta {
            ropeTheta = theta
        } else if let params = try c.decodeIfPresent(RopeParameters.self, forKey: .ropeScaling),
                  let theta = params.ropeTheta {
            ropeTheta = theta
        } else {
            ropeTheta = 5_000_000.0
        }
    }

    public init(
        vocabSize: Int = 151_936,
        hiddenSize: Int = 2560,
        intermediateSize: Int = 9728,
        numHiddenLayers: Int = 36,
        numAttentionHeads: Int = 32,
        numKeyValueHeads: Int = 8,
        headDim: Int = 128,
        rmsNormEps: Float = 1e-6,
        ropeTheta: Float = 5_000_000.0,
        tieWordEmbeddings: Bool = true
    ) {
        self.vocabSize = vocabSize
        self.hiddenSize = hiddenSize
        self.intermediateSize = intermediateSize
        self.numHiddenLayers = numHiddenLayers
        self.numAttentionHeads = numAttentionHeads
        self.numKeyValueHeads = numKeyValueHeads
        self.headDim = headDim
        self.rmsNormEps = rmsNormEps
        self.ropeTheta = ropeTheta
        self.tieWordEmbeddings = tieWordEmbeddings
    }


    public static let qwen3VL4B = Krea2TextEncoderConfig()



    public static func load(from url: URL) throws -> Krea2TextEncoderConfig {
        let data = try Data(contentsOf: url)

        struct Wrapper: Decodable {
            let textConfig: Krea2TextEncoderConfig
            enum CodingKeys: String, CodingKey {
                case textConfig = "text_config"
            }
        }

        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data) {
            return wrapped.textConfig
        }
        return try JSONDecoder().decode(Krea2TextEncoderConfig.self, from: data)
    }
}
