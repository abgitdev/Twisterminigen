import Foundation

/// The optional assistant is deliberately separate from Krea's text encoder. Krea ships the
/// Qwen3-VL language/vision backbone for conditioning, but its app-facing encoder intentionally
/// does not expose a production image-to-text path. Describe therefore owns one independently
/// quantized, pinned VLM that can be installed or removed without touching render weights.
enum DescribeImageModel {
    static let componentID = "describe-qwen3-vl-4b-8bit"
    static let repositoryID = "mlx-community/Qwen3-VL-4B-Instruct-8bit"
    static let revision = "0943db6e15185b86be368d3cf0704aec740b142b"
    static let title = "Qwen3-VL 4B · 8-bit"

    /// Optional weights are app-owned and durable. They do not live in Caches, where macOS may
    /// purge a multi-gigabyte verified install without an explicit user action.
    static var defaultRoot: URL {
        AppPaths.optionalModels
            .appendingPathComponent("DescribeImage", isDirectory: true)
            .appendingPathComponent("Qwen3VL4B8bit", isDirectory: true)
    }

    static func catalog(root: URL = defaultRoot) -> ModelCatalog {
        let root = root.standardizedFileURL
        func file(_ path: String, bytes: Int64, sha256: String, main: Bool = false) -> ModelFile {
            ModelFile(
                remotePath: path,
                localURL: root.appendingPathComponent(path),
                isMain: main,
                expectedBytes: bytes,
                sha256: sha256)
        }

        let component = ModelComponent(
            id: componentID,
            title: title,
            subtitle: "Local image → prompt assistant · optional",
            icon: "text.viewfinder",
            repo: repositoryID,
            revision: revision,
            files: [
                file("added_tokens.json", bytes: 707,
                     sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
                file("chat_template.jinja", bytes: 5_292,
                     sha256: "3636d0f0bd6bef02654cdffdc447b79cb2cef8ab02cc75267345946291a489e4"),
                file("chat_template.json", bytes: 5_502,
                     sha256: "6f8a6a55027e3da5160105556cda5dd69f6423f1c32645f6730d32de7773d0c4"),
                file("config.json", bytes: 7_137,
                     sha256: "abe3e847cdd84379a4754e5821ceda19226fda74fcf0b4436a966d3c2fbb68e7"),
                file("generation_config.json", bytes: 269,
                     sha256: "8469742d1fce0de951c8909b26a2c0c0d8490837ce476efb114da9e0cefc4d44"),
                file("model.safetensors", bytes: 5_104_903_807,
                     sha256: "49313ba7eb04191cb38fff8486ff87436d5fb6dcbb3eb9a32df250b0bef7f60d",
                     main: true),
                file("model.safetensors.index.json", bytes: 64_742,
                     sha256: "58a7841d7bff2548dd91577d216274a83cf1b500bc6a534b809d6c1b1707cf2b"),
                file("preprocessor_config.json", bytes: 782,
                     sha256: "93585062a80db5e8ca038efc7726a3e6411d9db948472d81d63c6303993be8c5"),
                file("special_tokens_map.json", bytes: 613,
                     sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
                file("tokenizer.json", bytes: 11_422_654,
                     sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
                file("tokenizer_config.json", bytes: 5_445,
                     sha256: "81ec7bb9530159b326c0bef1d0b6c33d392090524014ea3f0123a3c1eb9c2af5"),
                file("video_preprocessor_config.json", bytes: 817,
                     sha256: "59c5c9eb52182eb14c06ffb10ca9effd29adce5f238a95de23ca14a38dbd2cb1"),
            ])

        // The downloader's durable metadata format is shared with the main model catalog. Exact
        // file hashes plus the pinned source revision keep the independent component reproducible.
        return ModelCatalog(root: root, manifest: .current, components: [component])
    }
}
