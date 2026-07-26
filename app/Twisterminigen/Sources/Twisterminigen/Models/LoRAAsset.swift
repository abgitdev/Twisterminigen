import Foundation

struct LoRAOrigin: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case localImport
        case officialKreaStyle
    }

    let kind: Kind
    let repository: String?
    let revision: String?
    let weightFilename: String?

    static let localImport = LoRAOrigin(
        kind: .localImport,
        repository: nil,
        revision: nil,
        weightFilename: nil)

    static func officialKreaStyle(
        repository: String,
        revision: String,
        weightFilename: String
    ) -> Self {
        Self(
            kind: .officialKreaStyle,
            repository: repository,
            revision: revision,
            weightFilename: weightFilename)
    }
}

struct LoRAAsset: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    let managedFilename: String
    let sha256: String
    let byteCount: Int64
    let matchedTargets: Int
    let totalTargets: Int
    let matchedKeys: Int
    let totalKeys: Int
    let tensorBytes: Int64
    var triggers: [String]
    /// Explicit per-adapter opt-in. Enabling the adapter may append its saved trigger phrases to
    /// the current prompt only when this flag is true; legacy catalogs always default to false.
    var automaticallyInsertTriggers: Bool
    let origin: LoRAOrigin
    let importedAt: Date

    init(
        id: UUID,
        name: String,
        managedFilename: String,
        sha256: String,
        byteCount: Int64,
        matchedTargets: Int,
        totalTargets: Int,
        matchedKeys: Int,
        totalKeys: Int,
        tensorBytes: Int64,
        triggers: [String] = [],
        automaticallyInsertTriggers: Bool = false,
        origin: LoRAOrigin = .localImport,
        importedAt: Date
    ) {
        self.id = id
        self.name = name
        self.managedFilename = managedFilename
        self.sha256 = sha256
        self.byteCount = byteCount
        self.matchedTargets = matchedTargets
        self.totalTargets = totalTargets
        self.matchedKeys = matchedKeys
        self.totalKeys = totalKeys
        self.tensorBytes = tensorBytes
        self.triggers = triggers
        self.automaticallyInsertTriggers = automaticallyInsertTriggers
        self.origin = origin
        self.importedAt = importedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case managedFilename
        case sha256
        case byteCount
        case matchedTargets
        case totalTargets
        case matchedKeys
        case totalKeys
        case tensorBytes
        case triggers
        case automaticallyInsertTriggers
        case origin
        case importedAt
    }

    /// Early schema-1 catalogs predate trigger phrases. Keep them readable and let the next
    /// metadata edit persist an explicit empty array instead of rejecting the whole LoRA library.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        managedFilename = try container.decode(String.self, forKey: .managedFilename)
        sha256 = try container.decode(String.self, forKey: .sha256)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        matchedTargets = try container.decode(Int.self, forKey: .matchedTargets)
        totalTargets = try container.decode(Int.self, forKey: .totalTargets)
        matchedKeys = try container.decode(Int.self, forKey: .matchedKeys)
        totalKeys = try container.decode(Int.self, forKey: .totalKeys)
        tensorBytes = try container.decode(Int64.self, forKey: .tensorBytes)
        triggers = try container.decodeIfPresent([String].self, forKey: .triggers) ?? []
        automaticallyInsertTriggers = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticallyInsertTriggers) ?? false
        origin = try container.decodeIfPresent(LoRAOrigin.self, forKey: .origin) ?? .localImport
        importedAt = try container.decode(Date.self, forKey: .importedAt)
    }

    var coverage: Double {
        totalTargets > 0 ? Double(matchedTargets) / Double(totalTargets) : 0
    }
}

struct LoRASelection: Codable, Identifiable, Sendable, Equatable {
    var id: UUID { assetID }
    let assetID: UUID
    var scale: Double
}

struct LoRALibrarySnapshot: Sendable, Equatable {
    var assets: [LoRAAsset]
    var active: [LoRASelection]

    static let empty = LoRALibrarySnapshot(assets: [], active: [])
}
