// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Krea2Engine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Krea2Core", targets: ["Krea2Core"]),
        .library(name: "Krea2TextEncoder", targets: ["Krea2TextEncoder"]),
        .library(name: "Krea2DiT", targets: ["Krea2DiT"]),
        .library(name: "Krea2VAE", targets: ["Krea2VAE"]),
        .library(name: "Krea2Sampler", targets: ["Krea2Sampler"]),
        .library(name: "Krea2Pipeline", targets: ["Krea2Pipeline"]),
        .executable(name: "Krea2CLI", targets: ["Krea2CLI"]),
    ],
    dependencies: [
        // Exact pin: validated together with the quantized DiT, VAE, and app packages.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
    ],
    targets: [

        .target(
            name: "Krea2Core",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),


        .target(
            name: "Krea2TextEncoder",
            dependencies: [
                "Krea2Core",
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),


        .target(
            name: "Krea2DiT",
            dependencies: [
                "Krea2Core",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),


        .target(
            name: "Krea2VAE",
            dependencies: [
                "Krea2Core",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),

        .target(
            name: "Krea2Sampler",
            dependencies: [
                "Krea2Core",
                "Krea2DiT",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ]
        ),

        .target(
            name: "Krea2Pipeline",
            dependencies: [
                "Krea2Core",
                "Krea2TextEncoder",
                "Krea2DiT",
                "Krea2VAE",
                "Krea2Sampler",
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),

        .executableTarget(
            name: "Krea2CLI",
            dependencies: [
                "Krea2Core",
                "Krea2DiT",
                "Krea2Pipeline",
                "Krea2Sampler",
                "Krea2TextEncoder",
                "Krea2VAE",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),
        .testTarget(
            name: "Krea2EngineTests",
            dependencies: [
                "Krea2Core",
                "Krea2DiT",
                "Krea2Pipeline",
                "Krea2TextEncoder",
                "Krea2Sampler",
                "Krea2VAE",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),
    ]
)
