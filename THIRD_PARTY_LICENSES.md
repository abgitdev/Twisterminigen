# Third-Party Licenses

Twisterminigen uses the open-source components listed below. Each component remains subject to its
own license. The release bundle includes this index and the complete LICENSE/NOTICE files for every
pinned Swift package in `Resources/Licenses/ThirdParty/`. Model weights are not included in this
repository or redistributed; users obtain them separately under the applicable model license,
including the Krea 2 Community License.

## Vendored code (adapted)

| Component | Author | License | Source | Location |
|---|---|---|---|---|
| flux-2-swift-mlx (`FluxTextEncoders`: Qwen3-VL language model, configuration, and hidden-state tap mechanics) | Vincent Gourbin | MIT | https://github.com/VincentGourbin/flux-2-swift-mlx | `engine/Krea2Engine/Sources/Krea2TextEncoder/Qwen3VL*.swift`, `Qwen3RMSNorm.swift` (adapted for rotate-half RoPE with θ=5e6 instead of interleaved MRoPE, f32 RMSNorm, and the Krea 2 tap/template/padding contract) |

### Complete flux-2-swift-mlx MIT license

Copyright (c) 2025 Vincent Gourbin

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Swift packages (linked dependencies)

| Component | Author | License | Source |
|---|---|---|---|
| mlx-swift (`MLX`, `MLXNN`, `MLXFast`, `MLXRandom`) | Apple / ml-explore | MIT | https://github.com/ml-explore/mlx-swift |
| swift-transformers (`Tokenizers`, `Hub`) | Hugging Face | Apache-2.0 | https://github.com/huggingface/swift-transformers |
| swift-argument-parser | Apple | Apache-2.0 | https://github.com/apple/swift-argument-parser |

Transitive dependencies, including swift-jinja, swift-huggingface, swift-nio, swift-crypto,
EventSource, and yyjson, are pinned in `Package.resolved`. The release bundler requires and embeds
their complete LICENSE and NOTICE files; the release fails closed if any required notice is absent.

## Porting references (not part of the product or public release)

| Project | License | Role |
|---|---|---|
| krea-2 (official PyTorch implementation) | Krea 2 Community License / repository code license | Mathematical reference |
| mflux | MIT | Primary MLX Python porting reference |
| krea2_alis_mlx | Repository-specific license | Secondary MLX Python porting reference |

## Models (downloaded by the user; not redistributed)

| Model | License | Notes |
|---|---|---|
| Krea 2 Turbo (transformer and VAE) | Krea 2 Community License | Commercial use below the license threshold; deployment requires content filtering |
| Qwen3-VL-4B text encoder (distributed with the Krea 2 weights) | Weight-repository license | Language component only |
