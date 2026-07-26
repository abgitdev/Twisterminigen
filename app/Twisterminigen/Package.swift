// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Twisterminigen",
    platforms: [
        .macOS(.v14) // floor matches the Krea2Engine / mlx-swift package
    ],
    dependencies: [
        // Local Krea 2 engine (already built + validated): text encoder → quant DiT → VAE.
        .package(path: "../../engine/Krea2Engine"),
        // Keep the app and engine on the same exact, regression-tested MLX release.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        // Local Describe Image assistant. 3.31.4 accepts mlx-swift 0.31.x and is pinned so the
        // separately managed Qwen3-VL cache has a reproducible loader/runtime contract.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        // The 3.x LM package is tokenizer-provider agnostic. Reuse the same implementation already
        // used by Krea2Engine instead of adding a second tokenizer stack.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
    ],
    targets: [
        .executableTarget(
            name: "Twisterminigen",
            dependencies: [
                .product(name: "Krea2Pipeline", package: "Krea2Engine"),
                .product(name: "Krea2DiT", package: "Krea2Engine"),
                .product(name: "Krea2Sampler", package: "Krea2Engine"),
                .product(name: "Krea2Core", package: "Krea2Engine"),
                .product(name: "Krea2TextEncoder", package: "Krea2Engine"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/Twisterminigen",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TwisterminigenTests",
            dependencies: [
                "Twisterminigen",
                .product(name: "Krea2DiT", package: "Krea2Engine"),
                .product(name: "Krea2Pipeline", package: "Krea2Engine"),
                .product(name: "Krea2Sampler", package: "Krea2Engine"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        )
    ]
)
