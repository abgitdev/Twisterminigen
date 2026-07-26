import Foundation

struct OfficialKreaStyleLoRA: Identifiable, Sendable, Equatable {
    let slug: String
    let title: String
    let repository: String
    let revision: String
    let weightFilename: String
    let byteCount: Int64
    let sha256: String
    let trigger: String

    var id: String { repository }
    var origin: LoRAOrigin {
        .officialKreaStyle(
            repository: repository,
            revision: revision,
            weightFilename: weightFilename)
    }
    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(weightFilename)")!
    }
    var modelCardURL: URL {
        URL(string: "https://huggingface.co/\(repository)")!
    }
}

enum OfficialKreaStyleLoRACatalog {
    /// Verified Krea organization releases. Revisions, sizes, and LFS SHA-256 values are pinned so
    /// a mutable repository head can never silently change an app import.
    static let styles: [OfficialKreaStyleLoRA] = [
        style("neondrip", "Neon Drip", "27b1c13a6feb68fe9abc71dc3dbc813fe6af408c", "a779c14435949eabae9ce0bface4320cad6672ef3547e8489107e3498d65e871", "Textured abstract style"),
        style("dotmatrix", "Dot Matrix", "47f962a5690534f99a8341d37f10ea6322a0c34a", "805aa30d863347222485b9d3ce81642dbc70a73cebc95ab57219d98b878fceec", "Monochrome stippling style"),
        style("darkbrush", "Dark Brush", "af7645f3502694cfc9fd69b9c2dca113344df33d", "f476ad1c0679bc6b14c815187e78a6ece43248f6d232faeccbfed0c4f37f36de", "monochrome ink wash style"),
        style("sunsetblur", "Sunset Blur", "bbc39e05cb5b59f60b00d9cca027495d91f2e10a", "194abdd531ca190d32799f26ab5bab634aa5ba3f07b7a60ffb282657db8bf3a0", "ethereal motion blur style"),
        style("rainywindow", "Rainy Window", "b071a8c4201655dcf175e9b5f8ab66db93525747", "7063a6f15ec6112ad3c06d79097b2a30a3ea7d9072821cb36021010d55989fe5", "rainy window style"),
        style("kidsdrawing", "Kids Drawing", "0103d1c5f33d5b6d1c7226c879d5debc6d136121", "8c1d45d204aeb4e34a7d9e16a7d473917592ba0048b03f4e03e037e3578ca500", "naive expressive sketch style"),
        style("vintagetarot", "Vintage Tarot", "5fb7c2f1d6b7a8a35aca940dbe8c5c02ba85fb3f", "8cca96c56658fb3ac5269f9ef2245bd07cbf1b7a189f517c8763470bb1385f9f", "vintage tarot style"),
        style("softwatercolor", "Soft Watercolor", "12ff680b14a869b0e72f225bbdb237ad244b6a94", "3805e8655f19fbcac116542685e3f78f3a642e8fbfb857b5352bb32a4b3d445a", "Art Deco watercolor style"),
        style("retroanime", "Retro Anime", "23336fcff3bac43028918a2df795fbb63fdc1ff3", "ca42107783d9e517c5d62cb9a9db9ab2ba4887d90e9dad97a9d1a7fe6ff14c56", "Purple retro anime style"),
    ]

    static func style(matchingSHA256 sha256: String) -> OfficialKreaStyleLoRA? {
        styles.first { $0.sha256.caseInsensitiveCompare(sha256) == .orderedSame }
    }

    private static func style(
        _ slug: String,
        _ title: String,
        _ revision: String,
        _ sha256: String,
        _ trigger: String
    ) -> OfficialKreaStyleLoRA {
        OfficialKreaStyleLoRA(
            slug: slug,
            title: title,
            repository: "krea/Krea-2-LoRA-\(slug)",
            revision: revision,
            weightFilename: "\(slug).safetensors",
            byteCount: 469_291_992,
            sha256: sha256,
            trigger: trigger)
    }
}
