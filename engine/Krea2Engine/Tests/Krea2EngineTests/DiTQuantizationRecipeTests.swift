import Krea2DiT
import MLXNN
import Testing

@Suite("DiT quantization recipes")
struct DiTQuantizationRecipeTests {
    @Test("q8 quantizes every block bulk Linear uniformly and leaves sensitive paths alone")
    func q8FilterIsExact() throws {
        let linear = Linear(8, 8, bias: false)

        let attention = try #require(Krea2DiTQuantRecipe.q8Filter(
            "blocks.0.attn.wq", linear))
        let mlp = try #require(Krea2DiTQuantRecipe.q8Filter(
            "blocks.27.mlp.down", linear))
        #expect(attention.groupSize == 64)
        #expect(attention.bits == 8)
        #expect(mlp.groupSize == 64)
        #expect(mlp.bits == 8)
        #expect(Krea2DiTQuantRecipe.q8Filter("first", linear) == nil)
        #expect(Krea2DiTQuantRecipe.q8Filter("tmlp.0", linear) == nil)
    }

    @Test("q8 differs from mixed-4/8 on ordinary bulk while preserving its endpoints")
    func q8IsNotMixedRecipeAlias() throws {
        let linear = Linear(8, 8, bias: false)
        let ordinaryMixed = try #require(Krea2DiTQuantRecipe.mixed48Filter(
            "blocks.12.attn.wq", linear))
        let ordinaryQ8 = try #require(Krea2DiTQuantRecipe.q8Filter(
            "blocks.12.attn.wq", linear))
        let downMixed = try #require(Krea2DiTQuantRecipe.mixed48Filter(
            "blocks.12.mlp.down", linear))

        #expect(ordinaryMixed.bits == 4)
        #expect(ordinaryQ8.bits == 8)
        #expect(downMixed.bits == 8)
    }
}
