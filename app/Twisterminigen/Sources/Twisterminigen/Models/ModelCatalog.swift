import CryptoKit
import Foundation

struct ModelManifest: Codable, Sendable, Hashable {
    static let current = ModelManifest(
        schema: "twisterminigen.model-catalog",
        version: 1)

    let schema: String
    let version: Int
}

/// One immutable file entry from the pinned model manifest.
struct ModelFile: Sendable, Hashable {
    let remotePath: String
    let localURL: URL
    let isMain: Bool
    let expectedBytes: Int64
    let sha256: String

    var partURL: URL { localURL.appendingPathExtension("part") }
    var metadataURL: URL { localURL.appendingPathExtension("meta") }
    var verificationURL: URL { localURL.appendingPathExtension("verified.json") }
}

/// One downloadable Krea 2 component (text encoder / VAE / DiT transformer).
struct ModelComponent: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let repo: String
    let revision: String
    let files: [ModelFile]

    var expectedBytes: Int64 { files.reduce(0) { $0 + $1.expectedBytes } }
    var mainFile: ModelFile { files.first(where: { $0.isMain }) ?? files[0] }

    func url(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.remotePath)")!
    }
}

/// A checkpoint/quantization combination known to the product schema.
///
/// Descriptors do not carry remote repositories or local import paths. Only `ModelComponent`
/// entries participate in managed downloads, so planned and local-only combinations cannot be
/// acquired or activated accidentally.
struct ModelDescriptor: Identifiable, Sendable, Hashable {
    enum Lifecycle: String, Sendable, Hashable {
        case active
        case planned
        case inactive

        var displayName: String {
            switch self {
            case .active: "Active"
            case .planned: "Planned"
            case .inactive: "Inactive"
            }
        }
    }

    enum WeightAccess: String, Sendable, Hashable {
        case managedDownload = "managed-download"
        case unavailable
        case localOnly = "local-only"

        var displayName: String {
            switch self {
            case .managedDownload: "Managed download"
            case .unavailable: "Not available"
            case .localOnly: "Local only"
            }
        }
    }

    let modelID: String
    let variantID: String
    let checkpointFamily: GenerationRecipe.CheckpointFamily
    let quantizationTier: GenerationRecipe.QuantizationTier
    let lifecycle: Lifecycle
    let weightAccess: WeightAccess
    let componentIDs: [String]

    var id: String { "\(modelID):\(variantID)" }
    var displayName: String {
        "\(checkpointFamily.displayName) · \(quantizationTier.qualityName) (\(quantizationTier.displayName))"
    }
    var isActive: Bool { lifecycle == .active }
    var isRenderable: Bool { isActive }
    var isDownloadable: Bool { isActive && weightAccess == .managedDownload }
    var isDefault: Bool { quantizationTier == .mixed4And8 }
}

/// A value snapshot of the complete pinned model manifest rooted at one local directory.
struct ModelCatalog: Sendable, Hashable {
    static let officialRevision = "1161245028ef398cd0a951101b2bbf486464f841"
    static let ditRevision = "8d078f9c163f301149289583ecb64a1d2cf404ca"
    static let q8Revision = "9fc879fe1d77d5d8abf0c916a968d3a40171d25b"

    static let licenseName = "Krea 2 Community License"
    static let licenseNote = "Weights require acceptance of the Krea 2 Community License and Acceptable Use Policy; local safety screening remains mandatory."

    static let defaultModelDescriptor = ModelDescriptor(
        modelID: "krea-2-turbo",
        variantID: "alis-mixed-4-8",
        checkpointFamily: .turbo,
        quantizationTier: .mixed4And8,
        lifecycle: .active,
        weightAccess: .managedDownload,
        componentIDs: ["text-encoder", "vae", "dit-transformer"])

    static let bestFidelityModelDescriptor = ModelDescriptor(
        modelID: "krea-2-turbo",
        variantID: "alis-q8",
        checkpointFamily: .turbo,
        quantizationTier: .q8,
        lifecycle: .active,
        weightAccess: .managedDownload,
        componentIDs: ["text-encoder", "vae", "dit-transformer-q8"])

    static let knownModelDescriptors: [ModelDescriptor] = [
        defaultModelDescriptor,
        bestFidelityModelDescriptor,
    ]

    /// Compatibility alias for code that means the product default, never the user's selection.
    static let activeModelDescriptor = defaultModelDescriptor

    // Raw is deliberately absent and outside the product scope. Twisterminigen remains a focused
    // Turbo inference application with import support for already-trained LoRA adapters.

    let root: URL
    let manifest: ModelManifest
    let components: [ModelComponent]

    var allFiles: [ModelFile] { components.flatMap(\.files) }
    /// Files required for the out-of-box Default tier. Optional q8 never blocks startup/import.
    var defaultFiles: [ModelFile] { files(for: Self.defaultModelDescriptor) }
    var descriptors: [ModelDescriptor] { Self.knownModelDescriptors }
    var officialDirectory: URL { root.appendingPathComponent("official", isDirectory: true) }
    var alisDirectory: URL { root.appendingPathComponent("alis-mixed-4-8", isDirectory: true) }
    var q8Directory: URL { root.appendingPathComponent("alis-q8", isDirectory: true) }
    /// Historical alias: the default mixed-4/8 identity stays stable when optional tiers appear.
    var pinnedIdentity: String { pinnedIdentity(for: Self.defaultModelDescriptor) }
    var generationReference: GenerationRecipe.ModelReference {
        generationReference(for: Self.defaultModelDescriptor)
    }

    func descriptor(for tier: GenerationRecipe.QuantizationTier) -> ModelDescriptor {
        switch tier {
        case .mixed4And8: Self.defaultModelDescriptor
        case .q8: Self.bestFidelityModelDescriptor
        }
    }

    func descriptor(matching reference: GenerationRecipe.ModelReference) -> ModelDescriptor? {
        Self.knownModelDescriptors.first { generationReference(for: $0) == reference }
    }

    func components(for descriptor: ModelDescriptor) -> [ModelComponent] {
        descriptor.componentIDs.compactMap(component(id:))
    }

    func files(for descriptor: ModelDescriptor) -> [ModelFile] {
        components(for: descriptor).flatMap(\.files)
    }

    func generationReference(
        for tier: GenerationRecipe.QuantizationTier
    ) -> GenerationRecipe.ModelReference {
        generationReference(for: descriptor(for: tier))
    }

    func generationReference(for descriptor: ModelDescriptor) -> GenerationRecipe.ModelReference {
        return GenerationRecipe.ModelReference(
            modelID: descriptor.modelID,
            variantID: descriptor.variantID,
            manifestHash: pinnedIdentity(for: descriptor),
            checkpointFamily: descriptor.checkpointFamily,
            quantizationTier: descriptor.quantizationTier)
    }

    func pinnedIdentity(for descriptor: ModelDescriptor) -> String {
        var fields = ["\(manifest.schema)@\(manifest.version)"]
        for component in components(for: descriptor).sorted(by: { $0.id < $1.id }) {
            fields.append("\(component.id):\(component.repo)@\(component.revision)")
            for file in component.files.sorted(by: { $0.remotePath < $1.remotePath }) {
                fields.append("\(file.remotePath):\(file.expectedBytes):\(file.sha256.lowercased())")
            }
        }
        let digest = SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    init(root: URL) {
        let root = root.standardizedFileURL
        let official = root.appendingPathComponent("official", isDirectory: true)
        let alis = root.appendingPathComponent("alis-mixed-4-8", isDirectory: true)

        self.init(
            root: root,
            manifest: .current,
            components: [
                ModelComponent(
                    id: "text-encoder",
                    title: "Text Encoder",
                    subtitle: "Qwen3-VL-4B · turns the prompt into conditioning",
                    icon: "character.cursor.ibeam",
                    repo: "krea/Krea-2-Turbo",
                    revision: Self.officialRevision,
                    files: [
                        ModelFile(
                            remotePath: "text_encoder/config.json",
                            localURL: official.appendingPathComponent("text_encoder/config.json"),
                            isMain: false,
                            expectedBytes: 1_559,
                            sha256: "1a1006851200920f53ab7e17ca14a8b3d1b91075dfbbff493307ba894cab0abb"),
                        ModelFile(
                            remotePath: "text_encoder/model.safetensors",
                            localURL: official.appendingPathComponent("text_encoder/model.safetensors"),
                            isMain: true,
                            expectedBytes: 8_875_715_136,
                            sha256: "8434db05292f95e0041589a7c82abeb39385be59c85b54ae11caa7b45e9f4f13"),
                        ModelFile(
                            remotePath: "tokenizer/tokenizer.json",
                            localURL: official.appendingPathComponent("tokenizer/tokenizer.json"),
                            isMain: false,
                            expectedBytes: 11_422_650,
                            sha256: "be75606093db2094d7cd20f3c2f385c212750648bd6ea4fb2bf507a6a4c55506"),
                        ModelFile(
                            remotePath: "tokenizer/tokenizer_config.json",
                            localURL: official.appendingPathComponent("tokenizer/tokenizer_config.json"),
                            isMain: false,
                            expectedBytes: 664,
                            sha256: "c871ed314285a377eccf509b906aa5fe015d5e79a3ddab2c198467329127ead6"),
                        ModelFile(
                            remotePath: "tokenizer/chat_template.jinja",
                            localURL: official.appendingPathComponent("tokenizer/chat_template.jinja"),
                            isMain: false,
                            expectedBytes: 5_292,
                            sha256: "3636d0f0bd6bef02654cdffdc447b79cb2cef8ab02cc75267345946291a489e4"),
                    ]),
                ModelComponent(
                    id: "vae",
                    title: "VAE",
                    subtitle: "Qwen-Image · decodes the latent into pixels",
                    icon: "photo.stack",
                    repo: "krea/Krea-2-Turbo",
                    revision: Self.officialRevision,
                    files: [
                        ModelFile(
                            remotePath: "vae/config.json",
                            localURL: official.appendingPathComponent("vae/config.json"),
                            isMain: false,
                            expectedBytes: 791,
                            sha256: "54949c79def0d1060353c3fbfd4d2d2c4815ae241da6d6d28c99634c4eac6e6e"),
                        ModelFile(
                            remotePath: "vae/diffusion_pytorch_model.safetensors",
                            localURL: official.appendingPathComponent("vae/diffusion_pytorch_model.safetensors"),
                            isMain: true,
                            expectedBytes: 507_591_892,
                            sha256: "ab1b61103959913d6c7e628cf793dbb2ca4726a40a3b3ae206c52b8e75bf6f08"),
                    ]),
                ModelComponent(
                    id: "dit-transformer",
                    title: "DiT Transformer",
                    subtitle: "mixed-4/8 quantized · the diffusion backbone",
                    icon: "cube.transparent",
                    repo: "avlp12/Krea-2-Turbo-Alis-MLX-mixed-4-8",
                    revision: Self.ditRevision,
                    files: [
                        ModelFile(
                            remotePath: "transformer_mixed_4_8.safetensors",
                            localURL: alis.appendingPathComponent("transformer_mixed_4_8.safetensors"),
                            isMain: true,
                            expectedBytes: 9_840_816_670,
                            sha256: "985d60722b339c3cd9df16a173f0cb504ae93d81ce9fbe2c3ab158cf5b60a5fb"),
                    ]),
                ModelComponent(
                    id: "dit-transformer-q8",
                    title: "DiT Transformer · Best Fidelity",
                    subtitle: "q8 near-lossless · optional diffusion backbone",
                    icon: "cube.transparent",
                    repo: "avlp12/Krea-2-Turbo-Alis-MLX-8bit",
                    revision: Self.q8Revision,
                    files: [
                        ModelFile(
                            remotePath: "transformer_8bit.safetensors",
                            localURL: root
                                .appendingPathComponent("alis-q8", isDirectory: true)
                                .appendingPathComponent("transformer_8bit.safetensors"),
                            isMain: true,
                            expectedBytes: 14_244_836_620,
                            sha256: "b10f33f0dcd91772990e7cecfc8003ba4d3f1ba27f03010b6d17a1f490f80a6c"),
                    ]),
            ])
    }

    /// Internal manifest injection keeps tests on tiny files while preserving snapshot semantics.
    init(root: URL, manifest: ModelManifest, components: [ModelComponent]) {
        self.root = root.standardizedFileURL
        self.manifest = manifest
        self.components = components
    }

    func component(id: String) -> ModelComponent? {
        components.first { $0.id == id }
    }

    // MARK: Compatibility for generation paths that still use the installed catalog

    private static var installed: ModelCatalog { ModelCatalog(root: AppPaths.weightsRoot) }

    static var officialDir: URL { installed.officialDirectory }
    static var alisDir: URL { installed.alisDirectory }
    static var ditQuantFile: URL { installed.component(id: "dit-transformer")!.mainFile.localURL }
    static var vaeFile: URL { installed.component(id: "vae")!.mainFile.localURL }

    /// Main-thread callers only consume the stat/stamp cache. ModelStore performs any needed hash.
    static func mainFilesPresent() -> Bool {
        let catalog = installed
        let verifier = ModelVerifier(
            manifest: catalog.manifest,
            stampDirectory: AppPaths.weightsSource.isReadOnly
                ? AppPaths.linkedModelVerification
                : nil)
        return catalog.defaultFiles.allSatisfy { verifier.isVerifiedFromCache($0) }
    }
}

enum FileProbe {
    static func size(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return nil }
        return n.int64Value
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
