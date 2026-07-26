import CryptoKit
import Foundation

enum GenerationStoreFailurePoint: String, CaseIterable, Equatable, Sendable {
    case saveAfterJournalWrite
    case saveAfterImageWrite
    case saveAfterSidecarWrite
    case saveAfterIndexWrite
    case deleteAfterJournalWrite
    case deleteAfterIndexWrite
    case deleteAfterSidecarRemoval
    case deleteAfterImageRemoval
    case deleteAllAfterJournalWrite
    case deleteAllAfterIndexWrite
    case deleteAllAfterSidecarRemoval
    case deleteAllAfterImageRemoval
}

typealias GenerationStoreFailureInjector =
    @Sendable (GenerationStoreFailurePoint) throws -> Void

struct LibraryDeletionResult: Equatable, Sendable {
    var count: Int = 0
    var bytes: Int64 = 0
}

enum LibraryQuarantineReason: String, Codable, Equatable, Sendable {
    case corruptIndex
    case incompatibleIndex
    case corruptJournal
    case rejectedRecords
    case orphanedImage
    case unsafeImage
    case corruptSidecar
    case incompatibleSidecar
    case orphanedSidecar
    case unsafeSidecar
    case sidecarMismatch
    case staleThumbnail
    case unsafeThumbnail
    case transactionConflict
}

struct LibraryQuarantinedItem: Equatable, Sendable {
    let originalURL: URL
    let quarantineURL: URL
    let reason: LibraryQuarantineReason
}

struct LibraryRepairReport: Equatable, Sendable {
    var recoveredTransactions = 0
    var orphanedImages: [String] = []
    var missingImages: [Generation] = []
    var unsafeRecords: [Generation] = []
    var duplicateRecords: [Generation] = []
    var unsafeImageEntries: [String] = []
    var orphanedSidecars: [String] = []
    var unsafeSidecarEntries: [String] = []
    var corruptSidecars: [String] = []
    var incompatibleEnvelopes: [String] = []
    var missingThumbnails: [String] = []
    var staleThumbnails: [String] = []
    var unsafeThumbnailEntries: [String] = []
    var quarantinedItems: [LibraryQuarantinedItem] = []
    var indexWasRewritten = false
    var errors: [String] = []

    var detectedIssueCount: Int {
        orphanedImages.count
            + missingImages.count
            + unsafeRecords.count
            + duplicateRecords.count
            + unsafeImageEntries.count
            + orphanedSidecars.count
            + unsafeSidecarEntries.count
            + corruptSidecars.count
            + incompatibleEnvelopes.count
            + missingThumbnails.count
            + staleThumbnails.count
            + unsafeThumbnailEntries.count
    }

    var isClean: Bool { detectedIssueCount == 0 && errors.isEmpty }

    mutating func merge(_ other: LibraryRepairReport) {
        recoveredTransactions += other.recoveredTransactions
        orphanedImages.append(contentsOf: other.orphanedImages)
        missingImages.append(contentsOf: other.missingImages)
        unsafeRecords.append(contentsOf: other.unsafeRecords)
        duplicateRecords.append(contentsOf: other.duplicateRecords)
        unsafeImageEntries.append(contentsOf: other.unsafeImageEntries)
        orphanedSidecars.append(contentsOf: other.orphanedSidecars)
        unsafeSidecarEntries.append(contentsOf: other.unsafeSidecarEntries)
        corruptSidecars.append(contentsOf: other.corruptSidecars)
        incompatibleEnvelopes.append(contentsOf: other.incompatibleEnvelopes)
        missingThumbnails.append(contentsOf: other.missingThumbnails)
        staleThumbnails.append(contentsOf: other.staleThumbnails)
        unsafeThumbnailEntries.append(contentsOf: other.unsafeThumbnailEntries)
        quarantinedItems.append(contentsOf: other.quarantinedItems)
        indexWasRewritten = indexWasRewritten || other.indexWasRewritten
        errors.append(contentsOf: other.errors)
    }
}

enum GenerationStoreError: Error, Equatable, LocalizedError {
    case invalidJournal(String)
    case managedFileAlreadyExists(URL)
    case unsafeFilesystemItem(URL)
    case completionIDConflict(UUID)
    case incompatibleLibrary(String)
    case invalidDuration(Double)
    case invalidProvenance(String)
    case invalidPerformance(String)
    case payloadTooLarge(URL, maximumBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidJournal(let reason):
            return "The gallery transaction journal is invalid: \(reason)"
        case .managedFileAlreadyExists(let url):
            return "A managed gallery file already exists at \(url.path)."
        case .unsafeFilesystemItem(let url):
            return "The gallery refused to follow an unsafe filesystem item at \(url.path)."
        case .completionIDConflict(let id):
            return "Completion \(id.uuidString) was already saved with a different recipe."
        case .incompatibleLibrary(let reason):
            return "The gallery contains data from a newer or incompatible app and is read-only: \(reason)"
        case .invalidDuration:
            return "Generation duration must be finite and between zero and one year."
        case .invalidProvenance(let reason):
            return "Generation provenance is invalid: \(reason)"
        case .invalidPerformance(let reason):
            return "Generation performance metrics are invalid: \(reason)"
        case .payloadTooLarge(let url, let maximumBytes):
            return "\(url.lastPathComponent) exceeds the \(maximumBytes)-byte safety limit."
        }
    }
}

/// Owns the gallery index, image files, recovery journal, and repair quarantine. The actor
/// serializes mutations; the write-ahead journal makes each mutation idempotent across restarts.
actor GenerationStore {
    private(set) var generations: [Generation]

    private let disk: GenerationLibraryDisk
    private let failureInjector: GenerationStoreFailureInjector
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let startupReportValue: LibraryRepairReport
    private let startupMutationBlockReason: String?

    init(
        paths: LibraryPaths = .application,
        failureInjector: @escaping GenerationStoreFailureInjector = { _ in },
        uuidGenerator: @escaping @Sendable () -> UUID = { UUID() },
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        let disk = GenerationLibraryDisk(
            paths: paths,
            fileManager: .default,
            makeUUID: uuidGenerator,
            now: dateProvider)
        let opened = disk.open()
        self.disk = disk
        self.failureInjector = failureInjector
        self.makeUUID = uuidGenerator
        self.now = dateProvider
        self.generations = opened.records
        self.startupReportValue = opened.report
        self.startupMutationBlockReason = opened.mutationBlockReason
    }

    // MARK: Read API

    func all() -> [Generation] { generations }

    func libraryPaths() -> LibraryPaths { disk.paths }

    func imageURL(for generation: Generation) throws -> URL {
        try disk.paths.imageURL(for: generation.imageFileName)
    }

    func thumbnailURL(for generation: Generation) throws -> URL {
        try disk.paths.thumbnailURL(for: generation.imageFileName)
    }

    func startupRecoveryReport() -> LibraryRepairReport { startupReportValue }

    // MARK: Mutations

    /// Reopens the durable library after Storage Manager has changed Gallery files. Normal Gallery
    /// mutations go through this actor; this explicit bridge prevents a confirmed whole-library
    /// deletion from leaving stale in-memory records in the running app.
    @discardableResult
    func reloadAfterExternalStorageChange() -> [Generation] {
        let opened = disk.open()
        generations = opened.records
        return generations
    }

    /// Once the journal is durable, recovery treats a matching durable image as committed. This
    /// means an interrupted save is either restored exactly once or removed from the index.
    @discardableResult
    func save(
        pngData: Data,
        prompt: String,
        width: Int,
        height: Int,
        steps: Int,
        seed: UInt64,
        duration: Double,
        performance: GenerationPerformanceMetrics? = nil,
        typographyQA: TypographyQAResult? = nil,
        completionID: UUID? = nil
    ) throws -> Generation {
        let recipe = Generation.compatibilityRecipe(
            prompt: prompt,
            width: width,
            height: height,
            steps: steps,
            seed: seed)
        return try save(
            pngData: pngData,
            recipe: recipe,
            recipeCapture: .legacy,
            duration: duration,
            provenance: nil,
            performance: performance,
            typographyQA: typographyQA,
            completionID: completionID)
    }

    /// Persists an exact, replayable recipe. Results must have resolved their random seed before
    /// they enter the gallery.
    @discardableResult
    func save(
        pngData: Data,
        recipe: GenerationRecipe,
        duration: Double,
        provenance: GenerationProvenance? = nil,
        performance: GenerationPerformanceMetrics? = nil,
        typographyQA: TypographyQAResult? = nil,
        completionID: UUID? = nil
    ) throws -> Generation {
        try recipe.validate(for: .persistedResult)
        return try save(
            pngData: pngData,
            recipe: recipe,
            recipeCapture: .exact,
            duration: duration,
            provenance: provenance,
            performance: performance,
            typographyQA: typographyQA,
            completionID: completionID)
    }

    private func save(
        pngData: Data,
        recipe: GenerationRecipe,
        recipeCapture: GenerationRecipeCapture,
        duration: Double,
        provenance: GenerationProvenance?,
        performance: GenerationPerformanceMetrics?,
        typographyQA: TypographyQAResult?,
        completionID: UUID?
    ) throws -> Generation {
        try recipe.validate(for: .persistedResult)
        try Self.validateDuration(duration)
        do {
            try provenance?.validate(recipe: recipe)
        } catch {
            throw GenerationStoreError.invalidProvenance(error.localizedDescription)
        }
        do {
            try performance?.validate()
        } catch {
            throw GenerationStoreError.invalidPerformance(error.localizedDescription)
        }
        try typographyQA?.validate(expectedRecipeText: recipe.prompts.exactText)
        if recipeCapture == .legacy {
            guard let seed = recipe.sampler.seed.fixedValue,
                  recipe == Generation.compatibilityRecipe(
                    prompt: recipe.prompts.positive,
                    width: recipe.canvas.width,
                    height: recipe.canvas.height,
                    steps: recipe.sampler.steps,
                    seed: seed) else {
                throw GenerationStoreError.invalidJournal(
                    "legacy capture is not the canonical compatibility recipe")
            }
        }
        guard let seed = recipe.sampler.seed.fixedValue else {
            throw GenerationRecipe.ValidationError.randomSeedForPersistedResult
        }

        try recoverBeforeMutation()
        if let completionID,
           let existing = generations.first(where: { $0.completionID == completionID })
        {
            guard existing.recipe == recipe else {
                throw GenerationStoreError.completionIDConflict(completionID)
            }
            return existing
        }

        let generationID = makeUUID()
        let fileName = ManagedGenerationFileName(identifier: generationID, seed: seed).rawValue
        let fileURL = try disk.paths.imageURL(for: fileName)
        try disk.requireMissingManagedDestination(fileURL)

        let generation = Generation(
            id: generationID,
            recipe: recipe,
            recipeCapture: recipeCapture,
            createdAt: now(),
            durationSeconds: duration,
            imageFileName: fileName,
            provenance: provenance,
            completionID: completionID,
            performance: performance,
            typographyQA: typographyQA)
        let journal = TransactionJournal.save(
            id: makeUUID(),
            createdAt: now(),
            generation: generation,
            imageData: pngData)

        var updated = generations.filter {
            $0.id != generation.id
                && $0.imageFileName.lowercased() != generation.imageFileName.lowercased()
        }
        updated.insert(generation, at: 0)
        updated = disk.sorted(updated)
        try disk.preflightSave(
            pngData: pngData,
            journal: journal,
            generation: generation,
            prospectiveRecords: updated)

        try disk.writeJournal(journal)
        try failureInjector(.saveAfterJournalWrite)
        try disk.writeImage(pngData, to: fileURL)
        try failureInjector(.saveAfterImageWrite)
        try disk.writeSidecar(for: generation, journal: journal)
        try failureInjector(.saveAfterSidecarWrite)

        try disk.persistIndex(updated)
        generations = updated
        try failureInjector(.saveAfterIndexWrite)
        try disk.clearJournal()
        return generation
    }

    /// Source-compatible wrapper for the existing UI. The labeled overload below exposes errors
    /// to later UI integration and to deterministic crash tests.
    func delete(_ id: UUID) {
        do {
            _ = try delete(id: id)
        } catch {
            _ = try? recover()
        }
    }

    @discardableResult
    func delete(id: UUID) throws -> Generation? {
        try recoverBeforeMutation()
        guard let generation = generations.first(where: { $0.id == id }) else { return nil }

        let journal = TransactionJournal.delete(
            id: makeUUID(), createdAt: now(), generation: generation)
        try disk.writeJournal(journal)
        try failureInjector(.deleteAfterJournalWrite)

        let normalizedName = generation.imageFileName.lowercased()
        let updated = generations.filter {
            $0.id != id && $0.imageFileName.lowercased() != normalizedName
        }
        try disk.persistIndex(updated)
        generations = updated
        try failureInjector(.deleteAfterIndexWrite)

        var report = LibraryRepairReport()
        try disk.removeManagedSidecar(generation.imageFileName, report: &report)
        try failureInjector(.deleteAfterSidecarRemoval)
        _ = try disk.removeManagedImage(generation.imageFileName, report: &report)
        try failureInjector(.deleteAfterImageRemoval)
        try disk.removeManagedThumbnail(generation.imageFileName, report: &report)
        try disk.clearJournal()
        return generation
    }

    /// Source-compatible result shape retained for GalleryViewModel.
    @discardableResult
    func deleteAll() -> (count: Int, bytes: Int64) {
        do {
            let result = try removeAll()
            return (result.count, result.bytes)
        } catch {
            _ = try? recover()
            return (0, 0)
        }
    }

    /// Throwing transactional variant for callers that need a truthful failure state.
    @discardableResult
    func removeAll() throws -> LibraryDeletionResult {
        try recoverBeforeMutation()

        var fileNames = try disk.managedImageFileNames()
        fileNames.formUnion(try disk.managedSidecarImageFileNames())
        fileNames.formUnion(generations.map(\.imageFileName))
        guard !generations.isEmpty || !fileNames.isEmpty else { return LibraryDeletionResult() }

        let snapshot = generations
        let journal = TransactionJournal.deleteAll(
            id: makeUUID(),
            createdAt: now(),
            generations: snapshot,
            fileNames: fileNames.sorted())
        try disk.writeJournal(journal)
        try failureInjector(.deleteAllAfterJournalWrite)

        try disk.persistIndex([])
        generations = []
        try failureInjector(.deleteAllAfterIndexWrite)

        var result = LibraryDeletionResult()
        var report = LibraryRepairReport()
        for fileName in fileNames.sorted() {
            try disk.removeManagedSidecar(fileName, report: &report)
            try failureInjector(.deleteAllAfterSidecarRemoval)
            let removed = try disk.removeManagedImage(fileName, report: &report)
            result.count += removed.count
            result.bytes += removed.bytes
            try failureInjector(.deleteAllAfterImageRemoval)
            try disk.removeManagedThumbnail(fileName, report: &report)
        }
        try disk.clearJournal()
        return result
    }

    // MARK: Recovery and repair

    /// Replays a pending operation, then reconciles the managed directories.
    @discardableResult
    func recover() throws -> LibraryRepairReport {
        try ensureCompatibleForMutation()
        try disk.bootstrap()
        try disk.preflightCompatibility()
        var report = LibraryRepairReport()
        var records = generations
        try disk.recoverPending(records: &records, report: &report)
        try disk.reconcile(records: &records, report: &report)
        generations = disk.sorted(records)
        return report
    }

    /// Re-reads the durable index, finishes any journal, sanitizes records, quarantines orphaned
    /// or unsafe managed files, and reports thumbnails that should be regenerated lazily.
    @discardableResult
    func reconcile() throws -> LibraryRepairReport {
        try ensureCompatibleForMutation()
        try disk.bootstrap()
        try disk.preflightCompatibility()
        var report = LibraryRepairReport()
        let loaded = try disk.loadIndex(report: &report)
        var records = loaded.records
        try disk.recoverPending(records: &records, report: &report)
        try disk.reconcile(
            records: &records,
            report: &report,
            rewriteIndex: loaded.requiresRewrite)
        generations = disk.sorted(records)
        return report
    }

    @discardableResult
    func repair() throws -> LibraryRepairReport { try reconcile() }

    private func recoverBeforeMutation() throws {
        try ensureCompatibleForMutation()
        try disk.bootstrap()
        try disk.preflightCompatibility()
        var report = LibraryRepairReport()
        var records = generations
        try disk.recoverPending(records: &records, report: &report)
        try disk.reconcile(records: &records, report: &report)
        generations = disk.sorted(records)
    }

    private func ensureCompatibleForMutation() throws {
        if let startupMutationBlockReason {
            throw GenerationStoreError.incompatibleLibrary(startupMutationBlockReason)
        }
    }

    private static func validateDuration(_ duration: Double) throws {
        guard duration.isFinite,
              duration >= 0,
              duration <= Generation.maximumDurationSeconds else {
            throw GenerationStoreError.invalidDuration(duration)
        }
    }
}

// MARK: - Journal

private struct TransactionJournal: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case save
        case delete
        case deleteAll
    }

    static let currentVersion = 2

    let version: Int
    let id: UUID
    let createdAt: Date
    let operation: Operation
    let records: [Generation]
    let fileNames: [String]
    let imageByteCount: Int64?
    let imageSHA256: String?

    static func save(
        id: UUID,
        createdAt: Date,
        generation: Generation,
        imageData: Data
    ) -> TransactionJournal {
        TransactionJournal(
            version: currentVersion,
            id: id,
            createdAt: createdAt,
            operation: .save,
            records: [generation],
            fileNames: [generation.imageFileName],
            imageByteCount: Int64(imageData.count),
            imageSHA256: Self.sha256(imageData))
    }

    static func delete(
        id: UUID,
        createdAt: Date,
        generation: Generation
    ) -> TransactionJournal {
        TransactionJournal(
            version: currentVersion,
            id: id,
            createdAt: createdAt,
            operation: .delete,
            records: [generation],
            fileNames: [generation.imageFileName],
            imageByteCount: nil,
            imageSHA256: nil)
    }

    static func deleteAll(
        id: UUID,
        createdAt: Date,
        generations: [Generation],
        fileNames: [String]
    ) -> TransactionJournal {
        TransactionJournal(
            version: currentVersion,
            id: id,
            createdAt: createdAt,
            operation: .deleteAll,
            records: generations,
            fileNames: fileNames,
            imageByteCount: nil,
            imageSHA256: nil)
    }

    func validate() throws {
        guard version == Self.currentVersion else {
            throw GenerationStoreError.invalidJournal("unsupported version \(version)")
        }

        let parsedNames = try fileNames.map { try ManagedGenerationFileName(validating: $0) }
        guard Set(parsedNames.map(\.normalizedKey)).count == parsedNames.count else {
            throw GenerationStoreError.invalidJournal("duplicate file names")
        }
        for record in records {
            let parsed = try ManagedGenerationFileName(validating: record.imageFileName)
            guard parsed.identifier == record.id,
                  parsed.seed == record.recipe.sampler.seed.fixedValue else {
                throw GenerationStoreError.invalidJournal(
                    "record identity does not match file name")
            }
        }

        switch operation {
        case .save:
            guard records.count == 1, fileNames.count == 1,
                  records[0].imageFileName.lowercased() == fileNames[0].lowercased(),
                  let imageByteCount, imageByteCount >= 0,
                  let imageSHA256, Self.isSHA256(imageSHA256) else {
                throw GenerationStoreError.invalidJournal("malformed save")
            }
        case .delete:
            guard records.count == 1, fileNames.count == 1,
                  records[0].imageFileName.lowercased() == fileNames[0].lowercased(),
                  imageByteCount == nil, imageSHA256 == nil else {
                throw GenerationStoreError.invalidJournal("malformed delete")
            }
        case .deleteAll:
            let journalNames = Set(parsedNames.map(\.normalizedKey))
            let recordNames = try Set(records.map {
                try ManagedGenerationFileName(validating: $0.imageFileName).normalizedKey
            })
            guard recordNames.isSubset(of: journalNames),
                  imageByteCount == nil, imageSHA256 == nil else {
                throw GenerationStoreError.invalidJournal("malformed delete-all")
            }
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var saveSidecar: GenerationSidecarEnvelope? {
        guard operation == .save,
              let generation = records.first,
              let imageByteCount,
              let imageSHA256 else { return nil }
        return GenerationSidecarEnvelope(
            generation: generation,
            pngByteCount: imageByteCount,
            pngSHA256: imageSHA256)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 70).contains(byte)
                || (97 ... 102).contains(byte)
        }
    }
}

/// Version 1 journals embedded the scalar generation record. They are migrated in memory before
/// replay so an app update cannot strand an already-durable operation.
private struct LegacyTransactionJournal: Decodable {
    let version: Int
    let id: UUID
    let createdAt: Date
    let operation: TransactionJournal.Operation
    let records: [LegacyGenerationRecord]
    let fileNames: [String]
    let imageByteCount: Int?
    let imageSHA256: String?

    var migrated: TransactionJournal {
        TransactionJournal(
            version: TransactionJournal.currentVersion,
            id: id,
            createdAt: createdAt,
            operation: operation,
            records: records.map(\.migrated),
            fileNames: fileNames,
            imageByteCount: imageByteCount.map(Int64.init),
            imageSHA256: imageSHA256)
    }
}

// MARK: - Filesystem implementation

private struct GenerationLibraryDisk {
    static let maximumIndexByteCount: Int64 = 64 * 1_024 * 1_024
    static let maximumSidecarByteCount: Int64 = 2 * 1_024 * 1_024
    static let maximumPNGByteCount: Int64 = 1_024 * 1_024 * 1_024

    enum ItemKind: Equatable {
        case missing
        case regular
        case directory
        case symbolicLink
        case other
    }

    enum ManagedState {
        case missing(URL)
        case regular(URL)
        case unsafe(URL)
    }

    struct OpenResult {
        let records: [Generation]
        let report: LibraryRepairReport
        let mutationBlockReason: String?
    }

    struct IndexLoadResult {
        let records: [Generation]
        let requiresRewrite: Bool
    }

    struct EnvelopeHeader: Decodable {
        let schema: String
        let version: Int
    }

    struct JournalHeader: Decodable {
        let version: Int
    }

    enum SidecarCandidate {
        case valid(GenerationSidecarEnvelope)
        case incompatible
        case corrupt
    }

    struct RejectedRecord: Codable {
        let reason: String
        let record: Generation
    }

    struct RejectedRecordEnvelope: Codable {
        let version: Int
        let createdAt: Date
        let records: [RejectedRecord]
    }

    let paths: LibraryPaths
    let fileManager: FileManager
    let makeUUID: @Sendable () -> UUID
    let now: @Sendable () -> Date

    func open() -> OpenResult {
        var report = LibraryRepairReport()
        var records: [Generation] = []
        var mutationBlockReason: String?
        do {
            try bootstrap()
            try preflightCompatibility()
            let loaded = try loadIndex(report: &report)
            records = loaded.records
            try recoverPending(records: &records, report: &report)
            try reconcile(
                records: &records,
                report: &report,
                rewriteIndex: loaded.requiresRewrite)
        } catch GenerationStoreError.incompatibleLibrary(let reason) {
            mutationBlockReason = reason
            report.incompatibleEnvelopes.append(reason)
            report.errors.append(
                GenerationStoreError.incompatibleLibrary(reason).localizedDescription)
            records = safelyReadableRecords(records)
        } catch {
            report.errors.append(error.localizedDescription)
            records = safelyReadableRecords(records)
        }
        return OpenResult(
            records: sorted(records),
            report: report,
            mutationBlockReason: mutationBlockReason)
    }

    func preflightCompatibility() throws {
        let decoder = JSONDecoder()

        if itemKind(at: paths.generationsIndex) == .regular,
           fileSize(at: paths.generationsIndex) <= Self.maximumIndexByteCount,
           let data = try? Data(contentsOf: paths.generationsIndex, options: .mappedIfSafe),
           let header = try? decoder.decode(EnvelopeHeader.self, from: data) {
            guard header.schema == GenerationIndexEnvelope.supportedSchema,
                  header.version == GenerationIndexEnvelope.currentVersion else {
                throw GenerationStoreError.incompatibleLibrary(
                    "\(paths.generationsIndex.lastPathComponent) uses \(header.schema) version \(header.version)")
            }
            if let envelope = try? decoder.decode(GenerationIndexEnvelope.self, from: data) {
                try envelope.generations.forEach { try requireSupportedRecipe($0.recipe, at: paths.generationsIndex) }
            }
        }

        if itemKind(at: paths.journal) == .regular,
           fileSize(at: paths.journal) <= Self.maximumIndexByteCount,
           let data = try? Data(contentsOf: paths.journal, options: .mappedIfSafe),
           let header = try? decoder.decode(JournalHeader.self, from: data) {
            guard header.version == TransactionJournal.currentVersion || header.version == 1 else {
                throw GenerationStoreError.incompatibleLibrary(
                    "\(paths.journal.lastPathComponent) uses version \(header.version)")
            }
            if header.version == TransactionJournal.currentVersion,
               let journal = try? decoder.decode(TransactionJournal.self, from: data) {
                try journal.records.forEach { try requireSupportedRecipe($0.recipe, at: paths.journal) }
            }
        }

        guard itemKind(at: paths.recipes) == .directory else { return }
        let sidecars = try fileManager.contentsOfDirectory(
            at: paths.recipes,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [])
        for url in sidecars where itemKind(at: url) == .regular {
            let byteCount = fileSize(at: url)
            guard byteCount > 0,
                  byteCount <= Self.maximumSidecarByteCount,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let header = try? decoder.decode(EnvelopeHeader.self, from: data) else {
                continue
            }
            guard header.schema == GenerationSidecarEnvelope.supportedSchema,
                  header.version == GenerationSidecarEnvelope.currentVersion else {
                throw GenerationStoreError.incompatibleLibrary(
                    "\(url.lastPathComponent) uses \(header.schema) version \(header.version)")
            }
            if let envelope = try? decoder.decode(GenerationSidecarEnvelope.self, from: data) {
                try requireSupportedRecipe(envelope.generation.recipe, at: url)
            }
        }
    }

    private func requireSupportedRecipe(_ recipe: GenerationRecipe, at url: URL) throws {
        guard recipe.schema == GenerationRecipe.supportedSchema,
              recipe.version == GenerationRecipe.currentVersion else {
            throw GenerationStoreError.incompatibleLibrary(
                "\(url.lastPathComponent) contains recipe \(recipe.schema) version \(recipe.version)")
        }
    }

    func bootstrap() throws {
        let protectedPaths = [
            paths.images,
            paths.recipes,
            paths.generationsIndex,
            paths.journal,
            paths.quarantine,
        ]
        guard protectedPaths.allSatisfy({ isLexicallyContained($0, in: paths.root) }) else {
            throw LibraryPathError.unsafePath(
                paths.root, reason: "managed paths must remain under the library root")
        }
        guard paths.generationsIndex != paths.journal,
              paths.generationsIndex != paths.root,
              paths.journal != paths.root,
              paths.images != paths.root,
              paths.recipes != paths.root,
              paths.quarantine != paths.root,
              paths.thumbnails != paths.root,
              paths.images != paths.quarantine,
              paths.images != paths.recipes,
              paths.images != paths.thumbnails,
              paths.recipes != paths.quarantine,
              paths.recipes != paths.thumbnails,
              paths.quarantine != paths.thumbnails,
              !isLexicallyContained(paths.images, in: paths.recipes),
              !isLexicallyContained(paths.recipes, in: paths.images),
              !isLexicallyContained(paths.images, in: paths.quarantine),
              !isLexicallyContained(paths.quarantine, in: paths.images),
              !isLexicallyContained(paths.images, in: paths.thumbnails),
              !isLexicallyContained(paths.thumbnails, in: paths.images),
              !isLexicallyContained(paths.recipes, in: paths.quarantine),
              !isLexicallyContained(paths.quarantine, in: paths.recipes),
              !isLexicallyContained(paths.recipes, in: paths.thumbnails),
              !isLexicallyContained(paths.thumbnails, in: paths.recipes),
              !isLexicallyContained(paths.quarantine, in: paths.thumbnails),
              !isLexicallyContained(paths.thumbnails, in: paths.quarantine),
              !isLexicallyContained(paths.generationsIndex, in: paths.images),
              !isLexicallyContained(paths.journal, in: paths.images),
              !isLexicallyContained(paths.generationsIndex, in: paths.recipes),
              !isLexicallyContained(paths.journal, in: paths.recipes),
              !isLexicallyContained(paths.generationsIndex, in: paths.quarantine),
              !isLexicallyContained(paths.journal, in: paths.quarantine),
              !isLexicallyContained(paths.generationsIndex, in: paths.thumbnails),
              !isLexicallyContained(paths.journal, in: paths.thumbnails) else {
            throw LibraryPathError.unsafePath(paths.root, reason: "managed paths overlap")
        }

        try ensureDirectory(paths.root)
        try requireResolvedContainment(paths.images, in: paths.root)
        try requireResolvedContainment(paths.recipes, in: paths.root)
        try requireResolvedContainment(paths.generationsIndex, in: paths.root)
        try requireResolvedContainment(paths.journal, in: paths.root)
        try requireResolvedContainment(paths.quarantine, in: paths.root)
        if isLexicallyContained(paths.thumbnails, in: paths.root) {
            try requireResolvedContainment(paths.thumbnails, in: paths.root)
        }

        try ensureDirectory(paths.generationsIndex.deletingLastPathComponent())
        try ensureDirectory(paths.journal.deletingLastPathComponent())
        try ensureDirectory(paths.images)
        try ensurePrivateDirectory(paths.recipes)
        try ensureDirectory(paths.quarantine)
        try ensureDirectory(paths.thumbnails)
    }

    func loadIndex(report: inout LibraryRepairReport) throws -> IndexLoadResult {
        switch itemKind(at: paths.generationsIndex) {
        case .missing:
            let rebuilt = try rebuildRecordsFromSidecars(report: &report)
            return IndexLoadResult(records: rebuilt, requiresRewrite: !rebuilt.isEmpty)
        case .regular:
            do {
                guard fileSize(at: paths.generationsIndex) <= Self.maximumIndexByteCount else {
                    throw GenerationStoreError.unsafeFilesystemItem(paths.generationsIndex)
                }
                let data = try Data(contentsOf: paths.generationsIndex, options: .mappedIfSafe)
                let decoder = JSONDecoder()

                if let header = try? decoder.decode(EnvelopeHeader.self, from: data) {
                    guard header.schema == GenerationIndexEnvelope.supportedSchema,
                          header.version == GenerationIndexEnvelope.currentVersion else {
                        throw GenerationStoreError.incompatibleLibrary(
                            "\(paths.generationsIndex.lastPathComponent) uses \(header.schema) version \(header.version)")
                    }
                    let envelope = try decoder.decode(GenerationIndexEnvelope.self, from: data)
                    try envelope.generations.forEach {
                        try requireSupportedRecipe($0.recipe, at: paths.generationsIndex)
                    }
                    return IndexLoadResult(
                        records: envelope.generations,
                        requiresRewrite: false)
                }

                if let currentArray = try? decoder.decode([Generation].self, from: data) {
                    try currentArray.forEach {
                        try requireSupportedRecipe($0.recipe, at: paths.generationsIndex)
                    }
                    return IndexLoadResult(records: currentArray, requiresRewrite: true)
                }
                let legacy = try decoder.decode([LegacyGenerationRecord].self, from: data)
                let migrated = legacy.map(\.migrated)
                return IndexLoadResult(records: migrated, requiresRewrite: true)
            } catch let error as GenerationStoreError {
                if case .incompatibleLibrary = error { throw error }
                let item = try quarantine(
                    paths.generationsIndex, reason: .corruptIndex, category: "Indexes")
                report.quarantinedItems.append(item)
                let rebuilt = try rebuildRecordsFromSidecars(report: &report)
                return IndexLoadResult(records: rebuilt, requiresRewrite: true)
            } catch {
                let item = try quarantine(
                    paths.generationsIndex, reason: .corruptIndex, category: "Indexes")
                report.quarantinedItems.append(item)
                let rebuilt = try rebuildRecordsFromSidecars(report: &report)
                return IndexLoadResult(records: rebuilt, requiresRewrite: true)
            }
        case .symbolicLink, .directory, .other:
            let item = try quarantine(
                paths.generationsIndex, reason: .corruptIndex, category: "Indexes")
            report.quarantinedItems.append(item)
            report.errors.append("The unsafe gallery index was quarantined.")
            let rebuilt = try rebuildRecordsFromSidecars(report: &report)
            return IndexLoadResult(records: rebuilt, requiresRewrite: true)
        }
    }

    func persistIndex(_ records: [Generation]) throws {
        try writeJSONAtomically(
            GenerationIndexEnvelope(generations: sorted(records)),
            to: paths.generationsIndex)
    }

    func preflightSave(
        pngData: Data,
        journal: TransactionJournal,
        generation: Generation,
        prospectiveRecords: [Generation]
    ) throws {
        guard !pngData.isEmpty,
              Int64(pngData.count) <= Self.maximumPNGByteCount else {
            throw GenerationStoreError.payloadTooLarge(
                try paths.imageURL(for: generation.imageFileName),
                maximumBytes: Self.maximumPNGByteCount)
        }
        try journal.validate()
        guard let sidecar = journal.saveSidecar,
              sidecar.generation == generation else {
            throw GenerationStoreError.invalidJournal(
                "save preflight could not construct its sidecar")
        }
        try validateSidecarMetadata(sidecar)
        try requireEncodedJSON(
            journal,
            maximumBytes: Self.maximumIndexByteCount,
            destination: paths.journal)
        try requireEncodedJSON(
            sidecar,
            maximumBytes: Self.maximumSidecarByteCount,
            destination: try paths.recipeURL(for: generation.imageFileName))
        try requireEncodedJSON(
            GenerationIndexEnvelope(generations: sorted(prospectiveRecords)),
            maximumBytes: Self.maximumIndexByteCount,
            destination: paths.generationsIndex)
    }

    func writeJournal(_ journal: TransactionJournal) throws {
        guard itemKind(at: paths.journal) == .missing else {
            throw GenerationStoreError.unsafeFilesystemItem(paths.journal)
        }
        try journal.validate()
        try writeJSONAtomically(journal, to: paths.journal)
    }

    func clearJournal() throws {
        switch itemKind(at: paths.journal) {
        case .missing:
            return
        case .regular:
            try fileManager.removeItem(at: paths.journal)
        case .symbolicLink, .directory, .other:
            throw GenerationStoreError.unsafeFilesystemItem(paths.journal)
        }
    }

    func recoverPending(
        records: inout [Generation],
        report: inout LibraryRepairReport
    ) throws {
        guard let journal = try readJournal(report: &report) else { return }
        try journal.validate()

        switch journal.operation {
        case .save:
            let generation = journal.records[0]
            let state = try inspectManagedImage(generation.imageFileName)
            let imageMatches: Bool
            switch state {
            case .regular(let url):
                imageMatches = try fileMatchesJournal(url, journal: journal)
            case .missing, .unsafe:
                imageMatches = false
            }

            let normalizedName = generation.imageFileName.lowercased()
            var updated = records.filter {
                $0.id != generation.id && $0.imageFileName.lowercased() != normalizedName
            }
            if imageMatches {
                guard let sidecar = journal.saveSidecar else {
                    throw GenerationStoreError.invalidJournal("save has no sidecar payload")
                }
                try ensureSidecar(sidecar)
                updated.insert(generation, at: 0)
            }
            updated = sorted(updated)
            if updated != sorted(records) {
                try persistIndex(updated)
                report.indexWasRewritten = true
            }
            records = updated

            if !imageMatches, case .unsafe(let url) = state {
                let item = try quarantine(
                    url, reason: .transactionConflict, category: "Transaction Conflicts")
                report.quarantinedItems.append(item)
                report.unsafeImageEntries.append(url.lastPathComponent)
            } else if !imageMatches, case .regular(let url) = state {
                let item = try quarantine(
                    url, reason: .transactionConflict, category: "Transaction Conflicts")
                report.quarantinedItems.append(item)
                report.unsafeImageEntries.append(url.lastPathComponent)
            }
            if !imageMatches {
                try removeManagedSidecar(generation.imageFileName, report: &report)
            }

        case .delete:
            let generation = journal.records[0]
            let normalizedName = generation.imageFileName.lowercased()
            let updated = records.filter {
                $0.id != generation.id && $0.imageFileName.lowercased() != normalizedName
            }
            if updated != records {
                try persistIndex(updated)
                report.indexWasRewritten = true
            }
            records = updated
            try removeManagedSidecar(generation.imageFileName, report: &report)
            _ = try removeManagedImage(generation.imageFileName, report: &report)
            try removeManagedThumbnail(generation.imageFileName, report: &report)

        case .deleteAll:
            let ids = Set(journal.records.map(\.id))
            let names = Set(journal.fileNames.map { $0.lowercased() })
            let updated = records.filter {
                !ids.contains($0.id) && !names.contains($0.imageFileName.lowercased())
            }
            if updated != records {
                try persistIndex(updated)
                report.indexWasRewritten = true
            }
            records = updated
            for fileName in journal.fileNames.sorted() {
                try removeManagedSidecar(fileName, report: &report)
                _ = try removeManagedImage(fileName, report: &report)
                try removeManagedThumbnail(fileName, report: &report)
            }
        }

        try clearJournal()
        report.recoveredTransactions += 1
    }

    func reconcile(
        records: inout [Generation],
        report: inout LibraryRepairReport,
        rewriteIndex: Bool = false
    ) throws {
        var kept: [Generation] = []
        var rejected: [RejectedRecord] = []
        var seenIDs = Set<UUID>()
        var seenNames = Set<String>()
        var seenCompletionIDs = Set<UUID>()
        var unsafeURLs = Set<URL>()

        for record in sorted(records) {
            let parsed: ManagedGenerationFileName
            do {
                parsed = try validateRecord(record)
            } catch {
                report.unsafeRecords.append(record)
                rejected.append(RejectedRecord(reason: "invalid record", record: record))
                continue
            }

            guard !seenIDs.contains(record.id), !seenNames.contains(parsed.normalizedKey) else {
                report.duplicateRecords.append(record)
                rejected.append(RejectedRecord(reason: "duplicate record", record: record))
                continue
            }
            if let completionID = record.completionID,
               seenCompletionIDs.contains(completionID)
            {
                report.duplicateRecords.append(record)
                rejected.append(RejectedRecord(reason: "duplicate completion id", record: record))
                continue
            }

            switch try inspectManagedImage(record.imageFileName) {
            case .missing:
                report.missingImages.append(record)
                rejected.append(RejectedRecord(reason: "missing image", record: record))
            case .unsafe(let url):
                report.unsafeRecords.append(record)
                report.unsafeImageEntries.append(url.lastPathComponent)
                rejected.append(RejectedRecord(reason: "unsafe image", record: record))
                unsafeURLs.insert(url)
            case .regular(let imageURL):
                guard try verifyOrBackfillSidecar(
                    for: record,
                    imageURL: imageURL,
                    report: &report) else {
                    report.unsafeRecords.append(record)
                    rejected.append(RejectedRecord(
                        reason: "sidecar integrity mismatch",
                        record: record))
                    continue
                }
                seenIDs.insert(record.id)
                seenNames.insert(parsed.normalizedKey)
                if let completionID = record.completionID {
                    seenCompletionIDs.insert(completionID)
                }
                kept.append(record)
            }
        }

        if !rejected.isEmpty {
            let item = try quarantineRejectedRecords(rejected)
            report.quarantinedItems.append(item)
        }
        if rewriteIndex || sorted(kept) != sorted(records) {
            try persistIndex(kept)
            report.indexWasRewritten = true
        }
        records = sorted(kept)

        for url in unsafeURLs.sorted(by: { $0.path < $1.path }) {
            guard itemKind(at: url) != .missing else { continue }
            let item = try quarantine(url, reason: .unsafeImage, category: "Unsafe Images")
            report.quarantinedItems.append(item)
        }

        let indexedFileNames = Dictionary(uniqueKeysWithValues: records.map {
            ($0.imageFileName.lowercased(), $0.imageFileName)
        })
        try reconcileSidecarDirectory(
            indexedFileNames: indexedFileNames,
            report: &report)
        try reconcileImageDirectory(
            indexedNames: indexedFileNames, report: &report)
        try reconcileThumbnails(indexedFileNames: indexedFileNames, report: &report)

        report.orphanedImages.sort()
        report.unsafeImageEntries = Array(Set(report.unsafeImageEntries)).sorted()
        report.orphanedSidecars = Array(Set(report.orphanedSidecars)).sorted()
        report.unsafeSidecarEntries = Array(Set(report.unsafeSidecarEntries)).sorted()
        report.corruptSidecars = Array(Set(report.corruptSidecars)).sorted()
        report.incompatibleEnvelopes = Array(Set(report.incompatibleEnvelopes)).sorted()
        report.missingThumbnails.sort()
        report.staleThumbnails.sort()
        report.unsafeThumbnailEntries = Array(Set(report.unsafeThumbnailEntries)).sorted()
    }

    func requireMissingManagedDestination(_ url: URL) throws {
        try requireResolvedContainment(url, in: paths.images)
        guard itemKind(at: url) == .missing else {
            throw GenerationStoreError.managedFileAlreadyExists(url)
        }
    }

    func writeImage(_ data: Data, to url: URL) throws {
        guard !data.isEmpty, Int64(data.count) <= Self.maximumPNGByteCount else {
            throw GenerationStoreError.payloadTooLarge(
                url,
                maximumBytes: Self.maximumPNGByteCount)
        }
        try requireMissingManagedDestination(url)
        try data.write(to: url, options: .atomic)
        guard case .regular(let writtenURL) = try inspectManagedImage(url.lastPathComponent),
              writtenURL == url.standardizedFileURL else {
            throw GenerationStoreError.unsafeFilesystemItem(url)
        }
    }

    func writeSidecar(for generation: Generation, journal: TransactionJournal) throws {
        guard let envelope = journal.saveSidecar,
              envelope.generation == generation else {
            throw GenerationStoreError.invalidJournal("save sidecar does not match generation")
        }
        try validateSidecarMetadata(envelope)
        guard case .regular(let imageURL) = try inspectManagedImage(generation.imageFileName),
              try fileMatchesSidecar(imageURL, envelope: envelope) else {
            throw GenerationStoreError.unsafeFilesystemItem(
                try paths.imageURL(for: generation.imageFileName))
        }

        let sidecarURL = try paths.recipeURL(for: generation.imageFileName)
        try requireResolvedContainment(sidecarURL, in: paths.recipes)
        guard itemKind(at: sidecarURL) == .missing else {
            throw GenerationStoreError.managedFileAlreadyExists(sidecarURL)
        }
        try writeJSONAtomically(envelope, to: sidecarURL, permissions: 0o600)
    }

    func managedImageFileNames() throws -> Set<String> {
        let entries = try fileManager.contentsOfDirectory(
            at: paths.images,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [])
        return Set(entries.compactMap { url in
            guard (try? ManagedGenerationFileName(validating: url.lastPathComponent)) != nil else {
                return nil
            }
            return url.lastPathComponent
        })
    }

    func managedSidecarImageFileNames() throws -> Set<String> {
        let entries = try fileManager.contentsOfDirectory(
            at: paths.recipes,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [])
        return Set(entries.compactMap { url in
            (try? ManagedGenerationRecipeFileName(validating: url.lastPathComponent))?
                .imageFileName.rawValue
        })
    }

    func removeManagedSidecar(
        _ imageFileName: String,
        report: inout LibraryRepairReport
    ) throws {
        switch try inspectManagedSidecar(imageFileName) {
        case .missing:
            return
        case .regular(let url):
            try fileManager.removeItem(at: url)
        case .unsafe(let url):
            let item = try quarantine(
                url, reason: .unsafeSidecar, category: "Unsafe Sidecars")
            report.unsafeSidecarEntries.append(url.lastPathComponent)
            report.quarantinedItems.append(item)
        }
    }

    func removeManagedImage(
        _ fileName: String,
        report: inout LibraryRepairReport
    ) throws -> LibraryDeletionResult {
        switch try inspectManagedImage(fileName) {
        case .missing:
            return LibraryDeletionResult()
        case .regular(let url):
            let bytes = fileSize(at: url)
            try fileManager.removeItem(at: url)
            return LibraryDeletionResult(count: 1, bytes: bytes)
        case .unsafe(let url):
            let item = try quarantine(url, reason: .unsafeImage, category: "Unsafe Images")
            report.unsafeImageEntries.append(url.lastPathComponent)
            report.quarantinedItems.append(item)
            return LibraryDeletionResult(count: 1, bytes: 0)
        }
    }

    func removeManagedThumbnail(
        _ fileName: String,
        report: inout LibraryRepairReport
    ) throws {
        switch try inspectManagedThumbnail(fileName) {
        case .missing:
            return
        case .regular(let url):
            try fileManager.removeItem(at: url)
        case .unsafe(let url):
            let item = try quarantine(url, reason: .unsafeThumbnail, category: "Unsafe Thumbnails")
            report.unsafeThumbnailEntries.append(url.lastPathComponent)
            report.quarantinedItems.append(item)
        }
    }

    func sorted(_ records: [Generation]) -> [Generation] {
        records.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func readJournal(report: inout LibraryRepairReport) throws -> TransactionJournal? {
        switch itemKind(at: paths.journal) {
        case .missing:
            return nil
        case .regular:
            do {
                guard fileSize(at: paths.journal) <= Self.maximumIndexByteCount else {
                    throw GenerationStoreError.unsafeFilesystemItem(paths.journal)
                }
                let data = try Data(contentsOf: paths.journal, options: .mappedIfSafe)
                let decoder = JSONDecoder()
                let header = try decoder.decode(JournalHeader.self, from: data)
                let journal: TransactionJournal
                switch header.version {
                case TransactionJournal.currentVersion:
                    journal = try decoder.decode(TransactionJournal.self, from: data)
                case 1:
                    journal = try decoder.decode(LegacyTransactionJournal.self, from: data)
                        .migrated
                default:
                    throw GenerationStoreError.incompatibleLibrary(
                        "\(paths.journal.lastPathComponent) uses version \(header.version)")
                }
                try journal.records.forEach {
                    try requireSupportedRecipe($0.recipe, at: paths.journal)
                }
                try journal.validate()
                return journal
            } catch let error as GenerationStoreError {
                if case .incompatibleLibrary = error { throw error }
                let item = try quarantine(
                    paths.journal, reason: .corruptJournal, category: "Journals")
                report.quarantinedItems.append(item)
                report.errors.append("A corrupt gallery transaction journal was quarantined.")
                return nil
            } catch {
                let item = try quarantine(
                    paths.journal, reason: .corruptJournal, category: "Journals")
                report.quarantinedItems.append(item)
                report.errors.append("A corrupt gallery transaction journal was quarantined.")
                return nil
            }
        case .symbolicLink, .directory, .other:
            let item = try quarantine(
                paths.journal, reason: .corruptJournal, category: "Journals")
            report.quarantinedItems.append(item)
            report.errors.append("An unsafe gallery transaction journal was quarantined.")
            return nil
        }
    }

    private func validateRecord(_ record: Generation) throws -> ManagedGenerationFileName {
        let parsed = try ManagedGenerationFileName(validating: record.imageFileName)
        guard parsed.identifier == record.id,
              let fixedSeed = record.recipe.sampler.seed.fixedValue,
              parsed.seed == fixedSeed,
              record.durationSeconds.isFinite,
              record.durationSeconds >= 0,
              record.durationSeconds <= Generation.maximumDurationSeconds,
              record.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryPathError.invalidManagedFileName(record.imageFileName)
        }

        try record.recipe.validate(for: .persistedResult)
        try record.provenance?.validate(recipe: record.recipe)
        try record.performance?.validate()
        try record.typographyQA?.validate(expectedRecipeText: record.recipe.prompts.exactText)
        switch record.recipeCapture {
        case .exact:
            break
        case .legacy:
            let canonical = Generation.compatibilityRecipe(
                prompt: record.prompt,
                width: record.width,
                height: record.height,
                steps: record.steps,
                seed: fixedSeed)
            guard record.recipe == canonical else {
                throw LibraryPathError.invalidManagedFileName(record.imageFileName)
            }
        }
        return parsed
    }

    private func validateSidecarMetadata(_ envelope: GenerationSidecarEnvelope) throws {
        guard envelope.schema == GenerationSidecarEnvelope.supportedSchema,
              envelope.version == GenerationSidecarEnvelope.currentVersion,
              (0 ... Self.maximumPNGByteCount).contains(envelope.pngByteCount),
              isSHA256(envelope.pngSHA256) else {
            throw GenerationStoreError.unsafeFilesystemItem(paths.recipes)
        }
        _ = try validateRecord(envelope.generation)
    }

    private func sidecarEnvelope(
        for generation: Generation,
        imageURL: URL
    ) throws -> GenerationSidecarEnvelope {
        let byteCount = fileSize(at: imageURL)
        guard (0 ... Self.maximumPNGByteCount).contains(byteCount) else {
            throw GenerationStoreError.unsafeFilesystemItem(imageURL)
        }
        return GenerationSidecarEnvelope(
            generation: generation,
            pngByteCount: byteCount,
            pngSHA256: try sha256(at: imageURL))
    }

    private func ensureSidecar(_ envelope: GenerationSidecarEnvelope) throws {
        try validateSidecarMetadata(envelope)
        let generation = envelope.generation
        guard case .regular(let imageURL) = try inspectManagedImage(generation.imageFileName),
              try fileMatchesSidecar(imageURL, envelope: envelope) else {
            throw GenerationStoreError.unsafeFilesystemItem(
                try paths.imageURL(for: generation.imageFileName))
        }

        let sidecarURL = try paths.recipeURL(for: generation.imageFileName)
        switch try inspectManagedSidecar(generation.imageFileName) {
        case .missing:
            break
        case .unsafe(let url):
            throw GenerationStoreError.unsafeFilesystemItem(url)
        case .regular(let url):
            switch readSidecarCandidate(at: url) {
            case .valid(let existing)
                where existing == envelope
                    && (try? fileMatchesSidecar(imageURL, envelope: existing)) == true:
                try setPermissions(0o600, at: url)
                return
            case .incompatible:
                throw GenerationStoreError.incompatibleLibrary(
                    "\(url.lastPathComponent) uses an unsupported sidecar or recipe version")
            case .valid, .corrupt:
                throw GenerationStoreError.unsafeFilesystemItem(url)
            }
        }

        guard itemKind(at: sidecarURL) == .missing else {
            throw GenerationStoreError.managedFileAlreadyExists(sidecarURL)
        }
        try writeJSONAtomically(envelope, to: sidecarURL, permissions: 0o600)
    }

    private func verifyOrBackfillSidecar(
        for record: Generation,
        imageURL: URL,
        report: inout LibraryRepairReport
    ) throws -> Bool {
        switch try inspectManagedSidecar(record.imageFileName) {
        case .missing:
            let envelope = try sidecarEnvelope(for: record, imageURL: imageURL)
            try ensureSidecar(envelope)
            return true
        case .unsafe(let url):
            try quarantineSidecar(url, reason: .unsafeSidecar, report: &report)
            return false
        case .regular(let url):
            switch readSidecarCandidate(at: url) {
            case .incompatible:
                throw GenerationStoreError.incompatibleLibrary(
                    "\(url.lastPathComponent) uses an unsupported sidecar or recipe version")
            case .corrupt:
                try quarantineSidecar(url, reason: .corruptSidecar, report: &report)
                return false
            case .valid(let existing):
                guard existing.generation == record,
                      try fileMatchesSidecar(imageURL, envelope: existing) else {
                    try quarantineSidecar(url, reason: .sidecarMismatch, report: &report)
                    return false
                }
                try setPermissions(0o600, at: url)
                return true
            }
        }
    }

    private func rebuildRecordsFromSidecars(
        report: inout LibraryRepairReport
    ) throws -> [Generation] {
        let entries = try fileManager.contentsOfDirectory(
            at: paths.recipes,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var records: [Generation] = []
        var seenIDs = Set<UUID>()
        var seenNames = Set<String>()
        var seenCompletionIDs = Set<UUID>()

        for url in entries {
            guard let sidecarName = try? ManagedGenerationRecipeFileName(
                validating: url.lastPathComponent) else {
                try quarantineSidecar(url, reason: .unsafeSidecar, report: &report)
                continue
            }
            guard itemKind(at: url) == .regular else {
                try quarantineSidecar(url, reason: .unsafeSidecar, report: &report)
                continue
            }

            let envelope: GenerationSidecarEnvelope
            switch readSidecarCandidate(at: url) {
            case .incompatible:
                throw GenerationStoreError.incompatibleLibrary(
                    "\(url.lastPathComponent) uses an unsupported sidecar or recipe version")
            case .corrupt:
                try quarantineSidecar(url, reason: .corruptSidecar, report: &report)
                continue
            case .valid(let value):
                envelope = value
            }

            let generation = envelope.generation
            guard sidecarName.imageFileName.rawValue == generation.imageFileName,
                  let expectedURL = try? paths.recipeURL(for: generation.imageFileName),
                  expectedURL.lastPathComponent == url.lastPathComponent else {
                try quarantineSidecar(url, reason: .sidecarMismatch, report: &report)
                continue
            }

            let imageURL: URL
            switch try inspectManagedImage(generation.imageFileName) {
            case .missing:
                try quarantineSidecar(url, reason: .orphanedSidecar, report: &report)
                continue
            case .unsafe:
                try quarantineSidecar(url, reason: .sidecarMismatch, report: &report)
                continue
            case .regular(let value):
                imageURL = value
            }
            guard try fileMatchesSidecar(imageURL, envelope: envelope) else {
                try quarantineSidecar(url, reason: .sidecarMismatch, report: &report)
                continue
            }

            let normalizedName = generation.imageFileName.lowercased()
            guard seenIDs.insert(generation.id).inserted,
                  seenNames.insert(normalizedName).inserted,
                  generation.completionID.map({ seenCompletionIDs.insert($0).inserted }) ?? true
            else {
                try quarantineSidecar(url, reason: .sidecarMismatch, report: &report)
                continue
            }
            try setPermissions(0o600, at: url)
            records.append(generation)
        }
        return sorted(records)
    }

    private func readSidecarCandidate(at url: URL) -> SidecarCandidate {
        guard itemKind(at: url) == .regular else { return .corrupt }
        let byteCount = fileSize(at: url)
        guard byteCount > 0, byteCount <= Self.maximumSidecarByteCount,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .corrupt
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(EnvelopeHeader.self, from: data) else {
            return .corrupt
        }
        guard header.schema == GenerationSidecarEnvelope.supportedSchema,
              header.version == GenerationSidecarEnvelope.currentVersion else {
            return .incompatible
        }
        guard let envelope = try? decoder.decode(GenerationSidecarEnvelope.self, from: data)
        else { return .corrupt }
        if envelope.generation.recipe.schema != GenerationRecipe.supportedSchema
            || envelope.generation.recipe.version != GenerationRecipe.currentVersion {
            return .incompatible
        }
        guard (try? validateSidecarMetadata(envelope)) != nil else { return .corrupt }
        return .valid(envelope)
    }

    private func reconcileSidecarDirectory(
        indexedFileNames: [String: String],
        report: inout LibraryRepairReport
    ) throws {
        let expected = try Dictionary(uniqueKeysWithValues: indexedFileNames.map { key, value in
            let url = try paths.recipeURL(for: value)
            return (key, url.lastPathComponent)
        })
        let entries = try fileManager.contentsOfDirectory(
            at: paths.recipes,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in entries {
            let fileName = url.lastPathComponent
            guard let parsed = try? ManagedGenerationRecipeFileName(validating: fileName) else {
                try quarantineSidecar(url, reason: .unsafeSidecar, report: &report)
                continue
            }
            if let expectedName = expected[parsed.imageFileName.normalizedKey] {
                if expectedName == fileName, itemKind(at: url) == .regular { continue }
                try quarantineSidecar(url, reason: .unsafeSidecar, report: &report)
                continue
            }

            if itemKind(at: url) != .regular {
                try quarantineSidecar(url, reason: .unsafeSidecar, report: &report)
                continue
            }
            switch readSidecarCandidate(at: url) {
            case .incompatible:
                throw GenerationStoreError.incompatibleLibrary(
                    "\(url.lastPathComponent) uses an unsupported sidecar or recipe version")
            case .corrupt:
                try quarantineSidecar(url, reason: .corruptSidecar, report: &report)
            case .valid:
                try quarantineSidecar(url, reason: .orphanedSidecar, report: &report)
            }
        }
    }

    private func quarantineSidecar(
        _ url: URL,
        reason: LibraryQuarantineReason,
        report: inout LibraryRepairReport
    ) throws {
        let category: String
        switch reason {
        case .incompatibleSidecar:
            category = "Incompatible Sidecars"
            report.incompatibleEnvelopes.append(url.lastPathComponent)
        case .corruptSidecar, .sidecarMismatch:
            category = reason == .corruptSidecar ? "Corrupt Sidecars" : "Mismatched Sidecars"
            report.corruptSidecars.append(url.lastPathComponent)
        case .orphanedSidecar:
            category = "Orphaned Sidecars"
            report.orphanedSidecars.append(url.lastPathComponent)
        default:
            category = "Unsafe Sidecars"
            report.unsafeSidecarEntries.append(url.lastPathComponent)
        }
        let item = try quarantine(url, reason: reason, category: category)
        report.quarantinedItems.append(item)
    }

    private func reconcileImageDirectory(
        indexedNames: [String: String],
        report: inout LibraryRepairReport
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: paths.images,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in entries {
            let fileName = url.lastPathComponent
            if let parsed = try? ManagedGenerationFileName(validating: fileName) {
                if let expectedName = indexedNames[parsed.normalizedKey] {
                    if expectedName != fileName || itemKind(at: url) != .regular {
                        report.unsafeImageEntries.append(fileName)
                        let item = try quarantine(
                            url, reason: .unsafeImage, category: "Unsafe Images")
                        report.quarantinedItems.append(item)
                    }
                    continue
                }

                report.orphanedImages.append(fileName)
                let reason: LibraryQuarantineReason = itemKind(at: url) == .regular
                    ? .orphanedImage
                    : .unsafeImage
                if reason == .unsafeImage { report.unsafeImageEntries.append(fileName) }
                let category = reason == .orphanedImage ? "Orphaned Images" : "Unsafe Images"
                let item = try quarantine(url, reason: reason, category: category)
                report.quarantinedItems.append(item)
            } else {
                report.unsafeImageEntries.append(fileName)
                let item = try quarantine(url, reason: .unsafeImage, category: "Unsafe Images")
                report.quarantinedItems.append(item)
            }
        }
    }

    private func reconcileThumbnails(
        indexedFileNames: [String: String],
        report: inout LibraryRepairReport
    ) throws {
        for fileName in indexedFileNames.values.sorted() {
            switch try inspectManagedThumbnail(fileName) {
            case .missing:
                report.missingThumbnails.append(fileName)
            case .regular:
                break
            case .unsafe(let url):
                report.unsafeThumbnailEntries.append(fileName)
                report.missingThumbnails.append(fileName)
                let item = try quarantine(
                    url, reason: .unsafeThumbnail, category: "Unsafe Thumbnails")
                report.quarantinedItems.append(item)
            }
        }

        let entries = try fileManager.contentsOfDirectory(
            at: paths.thumbnails,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in entries {
            let fileName = url.lastPathComponent
            if let parsed = try? ManagedGenerationFileName(validating: fileName) {
                guard indexedFileNames[parsed.normalizedKey] == nil else { continue }
                report.staleThumbnails.append(fileName)
                let item = try quarantine(
                    url, reason: .staleThumbnail, category: "Stale Thumbnails")
                report.quarantinedItems.append(item)
            } else {
                report.unsafeThumbnailEntries.append(fileName)
                let item = try quarantine(
                    url, reason: .unsafeThumbnail, category: "Unsafe Thumbnails")
                report.quarantinedItems.append(item)
            }
        }
    }

    private func inspectManagedImage(_ fileName: String) throws -> ManagedState {
        try inspectManagedURL(paths.imageURL(for: fileName), within: paths.images)
    }

    private func inspectManagedSidecar(_ imageFileName: String) throws -> ManagedState {
        try inspectManagedURL(
            paths.recipeURL(for: imageFileName),
            within: paths.recipes)
    }

    private func inspectManagedThumbnail(_ fileName: String) throws -> ManagedState {
        try inspectManagedURL(paths.thumbnailURL(for: fileName), within: paths.thumbnails)
    }

    private func inspectManagedURL(_ url: URL, within directory: URL) throws -> ManagedState {
        switch itemKind(at: url) {
        case .missing:
            try requireResolvedContainment(url, in: directory)
            return .missing(url)
        case .regular:
            try requireResolvedContainment(url, in: directory)
            guard hasExactEntry(url.lastPathComponent, in: directory) else {
                return .unsafe(url.standardizedFileURL)
            }
            return .regular(url.standardizedFileURL)
        case .symbolicLink, .directory, .other:
            return .unsafe(url.standardizedFileURL)
        }
    }

    private func safelyReadableRecords(_ records: [Generation]) -> [Generation] {
        sorted(records.filter { record in
            guard (try? validateRecord(record)) != nil,
                  let state = try? inspectManagedImage(record.imageFileName),
                  case .regular = state else {
                return false
            }
            return true
        })
    }

    private func fileMatchesJournal(_ url: URL, journal: TransactionJournal) throws -> Bool {
        guard let byteCount = journal.imageByteCount,
              let expectedSHA = journal.imageSHA256,
              (0 ... Self.maximumPNGByteCount).contains(byteCount),
              fileSize(at: url) == byteCount else { return false }
        return try sha256(at: url).caseInsensitiveCompare(expectedSHA) == .orderedSame
            && fileSize(at: url) == byteCount
    }

    private func fileMatchesSidecar(
        _ url: URL,
        envelope: GenerationSidecarEnvelope
    ) throws -> Bool {
        guard (0 ... Self.maximumPNGByteCount).contains(envelope.pngByteCount),
              fileSize(at: url) == envelope.pngByteCount else { return false }
        return try sha256(at: url).caseInsensitiveCompare(envelope.pngSHA256) == .orderedSame
            && fileSize(at: url) == envelope.pngByteCount
    }

    private func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 70).contains(byte)
                || (97 ... 102).contains(byte)
        }
    }

    private func hasExactEntry(_ name: String, in directory: URL) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return names.contains(name)
    }

    private func quarantineRejectedRecords(
        _ records: [RejectedRecord]
    ) throws -> LibraryQuarantinedItem {
        let directory = paths.quarantine.appendingPathComponent("Records", isDirectory: true)
        try ensureDirectory(directory)
        let destination = uniqueDestination(
            in: directory, preferredName: "records_\(makeUUID().uuidString).json")
        let envelope = RejectedRecordEnvelope(version: 1, createdAt: now(), records: records)
        try writeJSONAtomically(envelope, to: destination)
        return LibraryQuarantinedItem(
            originalURL: paths.generationsIndex,
            quarantineURL: destination,
            reason: .rejectedRecords)
    }

    private func quarantine(
        _ source: URL,
        reason: LibraryQuarantineReason,
        category: String
    ) throws -> LibraryQuarantinedItem {
        let directory = paths.quarantine.appendingPathComponent(category, isDirectory: true)
        try ensureDirectory(directory)
        let destination = uniqueDestination(
            in: directory,
            preferredName: "\(makeUUID().uuidString)_\(source.lastPathComponent)")
        try fileManager.moveItem(at: source, to: destination)
        return LibraryQuarantinedItem(
            originalURL: source,
            quarantineURL: destination,
            reason: reason)
    }

    private func uniqueDestination(in directory: URL, preferredName: String) -> URL {
        var candidate = directory.appendingPathComponent(preferredName)
        var suffix = 1
        while itemKind(at: candidate) != .missing {
            candidate = directory.appendingPathComponent("\(suffix)_\(preferredName)")
            suffix += 1
        }
        return candidate
    }

    private func writeJSONAtomically<T: Encodable>(
        _ value: T,
        to url: URL,
        permissions: Int? = nil
    ) throws {
        let parent = url.deletingLastPathComponent()
        try ensureDirectory(parent)
        try requireResolvedContainment(url, in: parent)
        switch itemKind(at: url) {
        case .missing, .regular:
            break
        case .symbolicLink, .directory, .other:
            throw GenerationStoreError.unsafeFilesystemItem(url)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let maximumBytes = isLexicallyContained(url, in: paths.recipes)
            ? Self.maximumSidecarByteCount
            : Self.maximumIndexByteCount
        guard !data.isEmpty, Int64(data.count) <= maximumBytes else {
            throw GenerationStoreError.payloadTooLarge(url, maximumBytes: maximumBytes)
        }
        try data.write(to: url, options: .atomic)
        guard itemKind(at: url) == .regular,
              hasExactEntry(url.lastPathComponent, in: parent) else {
            throw GenerationStoreError.unsafeFilesystemItem(url)
        }
        if let permissions {
            try setPermissions(permissions, at: url)
        }
    }

    private func requireEncodedJSON<T: Encodable>(
        _ value: T,
        maximumBytes: Int64,
        destination: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard !data.isEmpty, Int64(data.count) <= maximumBytes else {
            throw GenerationStoreError.payloadTooLarge(
                destination,
                maximumBytes: maximumBytes)
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        switch itemKind(at: url) {
        case .missing:
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        case .directory:
            break
        case .regular, .symbolicLink, .other:
            throw LibraryPathError.unsafePath(url, reason: "expected a real directory")
        }
        guard itemKind(at: url) == .directory else {
            throw LibraryPathError.unsafePath(url, reason: "directory creation failed")
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try ensureDirectory(url)
        try setPermissions(0o700, at: url)
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let actual = attributes[.posixPermissions] as? NSNumber,
              actual.intValue & 0o777 == permissions else {
            throw GenerationStoreError.unsafeFilesystemItem(url)
        }
    }

    private func itemKind(at url: URL) -> ItemKind {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return .symbolicLink
        }
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return .other }
        switch type {
        case .typeRegular:
            return .regular
        case .typeDirectory:
            return .directory
        case .typeSymbolicLink:
            return .symbolicLink
        default:
            return .other
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        guard itemKind(at: url) == .regular,
              let number = (try? fileManager.attributesOfItem(atPath: url.path))?[.size]
                as? NSNumber else { return 0 }
        return number.int64Value
    }

    private func requireResolvedContainment(_ url: URL, in directory: URL) throws {
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let directoryPath = resolvedDirectory.path
        let path = resolvedURL.path
        guard path.hasPrefix(directoryPath + "/") else {
            throw LibraryPathError.unsafePath(url, reason: "resolved path escapes its directory")
        }
    }

    private func isLexicallyContained(_ url: URL, in directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }
}
