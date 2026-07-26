import Foundation
import Darwin

enum QueueStoreError: Error, LocalizedError, Sendable {
    case unsupportedSchema(expected: String, found: String)
    case unsupportedVersion(expected: Int, found: Int)
    case corruptFiles(
        originalURLs: [URL],
        quarantineURLs: [URL],
        reason: String)
    case unreadableFile(URL, reason: String)
    case quarantineFailed(URL, reason: String)
    case invalidDocument(String)
    case invalidJob(UUID, reason: String)
    case duplicateJobID(UUID)
    case bulkEnqueueLimitExceeded(actual: Int, maximum: Int)
    case jobNotFound(UUID)
    case invalidDestination(Int)
    case claimAlreadyRunning(UUID)
    case noRunningClaim
    case staleClaim(expected: UUID, received: UUID)
    case revisionOverflow

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(expected, found):
            return "Queue data uses schema \(found); this app supports \(expected)."
        case let .unsupportedVersion(expected, found):
            return "Queue data is version \(found); this app supports version \(expected)."
        case let .corruptFiles(_, quarantineURLs, reason):
            let names = quarantineURLs.map(\.lastPathComponent).joined(separator: ", ")
            return "Queue data was invalid and moved to \(names): \(reason)"
        case let .unreadableFile(url, reason):
            return "Could not read \(url.lastPathComponent): \(reason)"
        case let .quarantineFailed(url, reason):
            return "Could not quarantine \(url.lastPathComponent): \(reason)"
        case let .invalidDocument(reason):
            return "Queue data is invalid: \(reason)"
        case let .invalidJob(id, reason):
            return "Queue job \(id.uuidString) is invalid: \(reason)"
        case let .duplicateJobID(id):
            return "Queue job \(id.uuidString) already exists."
        case let .bulkEnqueueLimitExceeded(actual, maximum):
            return "A bulk enqueue can contain at most \(maximum) jobs; received \(actual)."
        case let .jobNotFound(id):
            return "Queue job \(id.uuidString) was not found."
        case let .invalidDestination(index):
            return "Queue destination \(index) is out of bounds."
        case let .claimAlreadyRunning(id):
            return "Queue claim \(id.uuidString) is already running."
        case .noRunningClaim:
            return "The queue has no running claim."
        case let .staleClaim(expected, received):
            return "Queue claim \(received.uuidString) is stale; \(expected.uuidString) is running."
        case .revisionOverflow:
            return "The queue revision cannot be advanced."
        }
    }
}

/// Serializes queue ordering and owns the durable transition between pending and running work.
actor QueueStore {
    static let schema = "twisterminigen.queue"
    static let version = 3
    static let maximumClaimGroupSize = 4
    static let maximumBulkEnqueueCount = QueueLab.maximumJobCount

    private static let legacyVersion1 = 1
    private static let legacyVersion2 = 2
    private static let privateFilePermissions = 0o600
    private static let privateDirectoryPermissions = 0o700
    private static let maximumDocumentBytes = 64 * 1_024 * 1_024

    struct Claim: Codable, Identifiable, Sendable, Equatable {
        let id: UUID
        let job: QueueJob

        var recipe: GenerationRecipe { job.recipe }

        var resolvedSeed: UInt64 {
            guard case .fixed(let seed) = recipe.sampler.seed else {
                preconditionFailure("A queue claim must contain a fixed seed")
            }
            return seed
        }

        init(id: UUID, job: QueueJob) {
            precondition(job.recipe.sampler.seed.fixedValue != nil)
            self.id = id
            self.job = job
        }

        /// Compatibility initializer for the former scalar claim API.
        init(id: UUID, job: QueueJob, resolvedSeed: UInt64) {
            var recipe = job.recipe
            recipe.sampler.seed = .fixed(resolvedSeed)
            self.init(
                id: id,
                job: QueueJob(
                    id: job.id,
                    recipe: recipe,
                    provenance: job.provenance))
        }
    }

    struct Snapshot: Sendable, Equatable {
        let pending: [QueueJob]
        let runningClaims: [Claim]

        var running: Claim? { runningClaims.first }

        init(pending: [QueueJob], running: Claim?) {
            self.pending = pending
            self.runningClaims = running.map { [$0] } ?? []
        }

        init(pending: [QueueJob], runningClaims: [Claim]) {
            self.pending = pending
            self.runningClaims = runningClaims
        }

        var isEmpty: Bool { pending.isEmpty && runningClaims.isEmpty }
    }

    struct StartupReport: Sendable, Equatable {
        let recoveredAtomicWrite: Bool
        let restoredInterruptedClaims: [Claim]
        let quarantinedFiles: [URL]

        var restoredInterruptedClaim: Claim? { restoredInterruptedClaims.first }

        init(
            recoveredAtomicWrite: Bool,
            restoredInterruptedClaim: Claim?,
            quarantinedFiles: [URL]
        ) {
            self.recoveredAtomicWrite = recoveredAtomicWrite
            self.restoredInterruptedClaims = restoredInterruptedClaim.map { [$0] } ?? []
            self.quarantinedFiles = quarantinedFiles
        }

        init(
            recoveredAtomicWrite: Bool,
            restoredInterruptedClaims: [Claim],
            quarantinedFiles: [URL]
        ) {
            self.recoveredAtomicWrite = recoveredAtomicWrite
            self.restoredInterruptedClaims = restoredInterruptedClaims
            self.quarantinedFiles = quarantinedFiles
        }

        var hasRecovery: Bool {
            recoveredAtomicWrite
                || !restoredInterruptedClaims.isEmpty
                || !quarantinedFiles.isEmpty
        }
    }

    nonisolated let fileURL: URL
    nonisolated let startupReport: StartupReport

    private let stagingURL: URL
    private var document: Document

    init(
        fileURL: URL = AppPaths.appSupport.appendingPathComponent("queue.json"),
        quarantineID: @Sendable () -> UUID = { UUID() }
    ) throws {
        let fileURL = fileURL.standardizedFileURL
        let stagingURL = Self.stagingURL(for: fileURL)
        let loaded = try Self.load(
            fileURL: fileURL,
            stagingURL: stagingURL,
            quarantineID: quarantineID)
        var document = loaded.document
        let interruptedClaims = document.running

        if !interruptedClaims.isEmpty {
            document.pending.insert(
                contentsOf: Self.retryJobs(for: interruptedClaims),
                at: 0)
            document.running.removeAll()
        }
        if loaded.requiresMigration || !interruptedClaims.isEmpty {
            document.revision = try Self.nextRevision(after: document.revision)
            try Self.validate(document)
            try Self.persist(document, fileURL: fileURL, stagingURL: stagingURL)
        }

        self.fileURL = fileURL
        self.stagingURL = stagingURL
        self.document = document
        self.startupReport = StartupReport(
            recoveredAtomicWrite: loaded.recoveredAtomicWrite,
            restoredInterruptedClaims: interruptedClaims,
            quarantinedFiles: loaded.quarantinedFiles)
    }

    func snapshot() -> Snapshot {
        Snapshot(pending: document.pending, runningClaims: document.running)
    }

    @discardableResult
    func enqueue(_ job: QueueJob) throws -> QueueJob {
        try Self.validate(job)
        guard !Self.contains(job.id, in: document) else {
            throw QueueStoreError.duplicateJobID(job.id)
        }
        return try commit { candidate in
            candidate.pending.append(job)
            return job
        }
    }

    /// Validates and persists the complete batch as one queue revision.
    @discardableResult
    func enqueue(_ jobs: [QueueJob]) throws -> [QueueJob] {
        guard jobs.count <= Self.maximumBulkEnqueueCount else {
            throw QueueStoreError.bulkEnqueueLimitExceeded(
                actual: jobs.count,
                maximum: Self.maximumBulkEnqueueCount)
        }
        guard !jobs.isEmpty else { return [] }

        var ids = Set(document.pending.map(\.id))
        ids.formUnion(document.running.map(\.job.id))
        for job in jobs {
            try Self.validate(job)
            guard ids.insert(job.id).inserted else {
                throw QueueStoreError.duplicateJobID(job.id)
            }
        }

        return try commit { candidate in
            candidate.pending.append(contentsOf: jobs)
            return jobs
        }
    }

    @discardableResult
    func remove(id: UUID) throws -> QueueJob {
        guard let index = document.pending.firstIndex(where: { $0.id == id }) else {
            throw QueueStoreError.jobNotFound(id)
        }
        return try commit { candidate in
            candidate.pending.remove(at: index)
        }
    }

    /// Atomically replaces one pending recipe in place. Running claims cannot be edited because
    /// they have already crossed the durable execution boundary.
    @discardableResult
    func update(id: UUID, recipe: GenerationRecipe) throws -> QueueJob {
        guard let index = document.pending.firstIndex(where: { $0.id == id }) else {
            throw QueueStoreError.jobNotFound(id)
        }
        let updated = document.pending[index].replacingRecipe(recipe)
        try Self.validate(updated)

        return try commit { candidate in
            candidate.pending[index] = updated
            return updated
        }
    }

    func move(id: UUID, to destination: Int) throws {
        guard let source = document.pending.firstIndex(where: { $0.id == id }) else {
            throw QueueStoreError.jobNotFound(id)
        }
        guard document.pending.indices.contains(destination) else {
            throw QueueStoreError.invalidDestination(destination)
        }
        guard source != destination else { return }

        try commit { candidate in
            let job = candidate.pending.remove(at: source)
            candidate.pending.insert(job, at: destination)
        }
    }

    /// Moves a pending job relative to its current durable position. Computing the destination
    /// inside the actor keeps an in-flight UI action correct if the active renderer claims the
    /// previous first job before this mutation reaches QueueStore.
    func move(id: UUID, offset: Int) throws {
        guard let source = document.pending.firstIndex(where: { $0.id == id }) else {
            throw QueueStoreError.jobNotFound(id)
        }
        let (destination, overflow) = source.addingReportingOverflow(offset)
        guard !overflow, document.pending.indices.contains(destination) else {
            throw QueueStoreError.invalidDestination(destination)
        }
        guard source != destination else { return }

        try commit { candidate in
            let job = candidate.pending.remove(at: source)
            candidate.pending.insert(job, at: destination)
        }
    }

    @discardableResult
    func duplicate(
        id: UUID,
        newID: UUID = UUID(),
        seedMode: QueueDuplicateSeedMode = .same
    ) throws -> QueueJob {
        guard let index = document.pending.firstIndex(where: { $0.id == id }) else {
            throw QueueStoreError.jobNotFound(id)
        }
        guard !Self.contains(newID, in: document) else {
            throw QueueStoreError.duplicateJobID(newID)
        }
        let source = document.pending[index]
        let copy = try source.duplicate(id: newID, seedMode: seedMode)

        return try commit { candidate in
            candidate.pending.insert(copy, at: index + 1)
            return copy
        }
    }

    /// Inserts all Generate Again copies in one durable revision so a crash can never leave a
    /// half-created repetition. Sequential mode advances from the source by 1, 2, ... count.
    @discardableResult
    func duplicate(
        id: UUID,
        count: Int,
        seedMode: QueueDuplicateSeedMode,
        newID: @Sendable (Int) -> UUID = { _ in UUID() }
    ) throws -> [QueueJob] {
        guard (1 ... Self.maximumBulkEnqueueCount).contains(count) else {
            throw QueueJobDuplicationError.invalidCopyCount(count)
        }
        guard let index = document.pending.firstIndex(where: { $0.id == id }) else {
            throw QueueStoreError.jobNotFound(id)
        }
        let source = document.pending[index]
        var occupiedIDs = Set(document.pending.map(\.id))
        occupiedIDs.formUnion(document.running.map(\.job.id))
        var copies: [QueueJob] = []
        copies.reserveCapacity(count)
        for offset in 1 ... count {
            let copyID = newID(offset - 1)
            guard occupiedIDs.insert(copyID).inserted else {
                throw QueueStoreError.duplicateJobID(copyID)
            }
            let copy = try source.duplicate(
                id: copyID,
                seedMode: seedMode,
                sequenceOffset: offset)
            try Self.validate(copy)
            copies.append(copy)
        }

        return try commit { candidate in
            candidate.pending.insert(contentsOf: copies, at: index + 1)
            return copies
        }
    }

    /// Removes one pending job and persists its exact execution seed before returning it.
    @discardableResult
    func claimNext(
        randomSeed: UInt64 = UInt64.random(in: UInt64.min ... UInt64.max),
        claimID: UUID = UUID()
    ) throws -> Claim? {
        try claimNextGroup(
            maximumCount: 1,
            randomSeed: { _ in randomSeed },
            claimID: { _ in claimID })
            .first
    }

    /// Atomically claims a contiguous pending prefix, resolving every seed before returning.
    @discardableResult
    func claimNextGroup(
        maximumCount: Int = QueueStore.maximumClaimGroupSize,
        randomSeed: @Sendable (Int) -> UInt64 = {
            _ in UInt64.random(in: UInt64.min ... UInt64.max)
        },
        claimID: @Sendable (Int) -> UUID = { _ in UUID() }
    ) throws -> [Claim] {
        if let running = document.running.first {
            throw QueueStoreError.claimAlreadyRunning(running.id)
        }
        guard maximumCount > 0, !document.pending.isEmpty else { return [] }

        let maximum = min(
            document.pending.count,
            min(maximumCount, Self.maximumClaimGroupSize))
        let sessionKey = document.pending[0].recipe.sessionKey
        let jobs = document.pending.prefix(maximum).prefix {
            $0.recipe.sessionKey == sessionKey
        }
        let claims = jobs.enumerated().map { index, job in
            let resolvedRecipe = job.recipe.resolvingRandomSeed {
                randomSeed(index)
            }
            return Claim(
                id: claimID(index),
                job: QueueJob(
                    id: job.id,
                    recipe: resolvedRecipe,
                    provenance: job.provenance))
        }

        return try commit { candidate in
            candidate.pending.removeFirst(claims.count)
            candidate.running = claims
            return claims
        }
    }

    /// Acknowledges a result only when it belongs to the currently persisted claim.
    func completeClaim(_ claimID: UUID) throws {
        _ = try requireCurrentClaim(claimID)
        try commit { candidate in
            candidate.running.removeFirst()
        }
    }

    /// Returns the current and remaining claims to the head with their resolved seeds and order.
    func retryClaim(_ claimID: UUID) throws {
        _ = try requireCurrentClaim(claimID)
        let retryJobs = Self.retryJobs(for: document.running)

        try commit { candidate in
            candidate.pending.insert(contentsOf: retryJobs, at: 0)
            candidate.running.removeAll()
        }
    }

    /// Cancellation has the same durable rollback semantics as retry.
    func cancelClaim(_ claimID: UUID) throws {
        try retryClaim(claimID)
    }

    private func requireCurrentClaim(_ claimID: UUID) throws -> Claim {
        guard let running = document.running.first else {
            throw QueueStoreError.noRunningClaim
        }
        guard running.id == claimID else {
            throw QueueStoreError.staleClaim(expected: running.id, received: claimID)
        }
        return running
    }

    @discardableResult
    private func commit<Result>(
        _ mutation: (inout Document) throws -> Result
    ) throws -> Result {
        var candidate = document
        let result = try mutation(&candidate)
        candidate.revision = try Self.nextRevision(after: document.revision)
        try Self.validate(candidate)
        try Self.persist(candidate, fileURL: fileURL, stagingURL: stagingURL)
        document = candidate
        return result
    }
}

private extension QueueStore {
    struct Document: Codable, Sendable, Equatable {
        var schema: String
        var version: Int
        var revision: UInt64
        var pending: [QueueJob]
        var running: [Claim]

        static var empty: Document {
            Document(
                schema: QueueStore.schema,
                version: QueueStore.version,
                revision: 0,
                pending: [],
                running: [])
        }
    }

    struct LegacyScalarJob: Decodable {
        let id: UUID
        let prompt: String
        let width: Int
        let height: Int
        let steps: Int
        let seedText: String
    }

    struct LegacyClaim: Decodable {
        let id: UUID
        let job: LegacyScalarJob
        let resolvedSeed: UInt64
    }

    struct LegacyVersion1Document: Decodable {
        let schema: String
        let version: Int
        let revision: UInt64
        let pending: [LegacyScalarJob]
        let running: LegacyClaim?
    }

    struct LegacyVersion2Document: Decodable {
        let schema: String
        let version: Int
        let revision: UInt64
        let pending: [LegacyScalarJob]
        let running: [LegacyClaim]
    }

    struct DocumentHeader: Decodable {
        let schema: String
        let version: Int
    }

    struct DecodedDocument {
        let document: Document
        let requiresMigration: Bool
    }

    struct LoadResult {
        let document: Document
        let recoveredAtomicWrite: Bool
        let quarantinedFiles: [URL]
        let requiresMigration: Bool
    }

    enum Candidate {
        case missing
        case valid(DecodedDocument)
        case corrupt(String)
        case incompatible(QueueStoreError)
        case unreadable(QueueStoreError)
    }

    static func stagingURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("pending")
    }

    static func load(
        fileURL: URL,
        stagingURL: URL,
        quarantineID: @Sendable () -> UUID
    ) throws -> LoadResult {
        let parent = fileURL.deletingLastPathComponent()
        guard stagingURL.deletingLastPathComponent().standardizedFileURL
                == parent.standardizedFileURL else {
            throw QueueStoreError.unreadableFile(
                stagingURL,
                reason: "staging must remain beside the queue file")
        }
        try ensurePrivateDirectory(parent)
        let main = readCandidate(at: fileURL)
        let staged = readCandidate(at: stagingURL)

        for candidate in [main, staged] {
            switch candidate {
            case let .incompatible(error), let .unreadable(error):
                throw error
            case .missing, .valid, .corrupt:
                break
            }
        }

        var mainDocument: DecodedDocument?
        var stagedDocument: DecodedDocument?
        var corruptCandidates: [(url: URL, reason: String)] = []

        switch main {
        case let .valid(value): mainDocument = value
        case let .corrupt(reason): corruptCandidates.append((fileURL, reason))
        case .missing, .incompatible, .unreadable: break
        }
        switch staged {
        case let .valid(value): stagedDocument = value
        case let .corrupt(reason): corruptCandidates.append((stagingURL, reason))
        case .missing, .incompatible, .unreadable: break
        }

        let quarantined = try quarantine(
            corruptCandidates.map(\.url),
            relativeTo: fileURL,
            quarantineID: quarantineID)
        if mainDocument == nil && stagedDocument == nil {
            guard !corruptCandidates.isEmpty else {
                return LoadResult(
                    document: .empty,
                    recoveredAtomicWrite: false,
                    quarantinedFiles: [],
                    requiresMigration: false)
            }
            throw QueueStoreError.corruptFiles(
                originalURLs: corruptCandidates.map(\.url),
                quarantineURLs: quarantined,
                reason: corruptCandidates.map(\.reason).joined(separator: "; "))
        }

        if let mainDocument, let stagedDocument,
           stagedDocument.document.revision == mainDocument.document.revision,
           stagedDocument.document != mainDocument.document {
            throw QueueStoreError.invalidDocument(
                "main and staged files disagree at revision \(mainDocument.document.revision)")
        }
        let shouldInstallStaged = stagedDocument.map { stagedDocument in
            guard let mainDocument else { return true }
            return stagedDocument.document.revision > mainDocument.document.revision
        } ?? false
        if let stagedDocument, shouldInstallStaged {
            try installStaging(stagingURL, at: fileURL)
            return LoadResult(
                document: stagedDocument.document,
                recoveredAtomicWrite: true,
                quarantinedFiles: quarantined,
                requiresMigration: stagedDocument.requiresMigration)
        }

        if case .valid = staged {
            try FileManager.default.removeItem(at: stagingURL)
        }
        guard let mainDocument else {
            throw QueueStoreError.invalidDocument(
                "no valid queue document remained after recovery")
        }
        return LoadResult(
            document: mainDocument.document,
            recoveredAtomicWrite: false,
            quarantinedFiles: quarantined,
            requiresMigration: mainDocument.requiresMigration)
    }

    static func readCandidate(at url: URL) -> Candidate {
        switch itemKind(at: url) {
        case .missing:
            return .missing
        case .regular:
            break
        case .directory, .symbolicLink, .other:
            return .unreadable(.unreadableFile(
                url,
                reason: "expected a regular file and refused to follow an unsafe filesystem item"))
        }

        guard let byteCount = fileSize(at: url),
              byteCount > 0,
              byteCount <= maximumDocumentBytes else {
            return .unreadable(.unreadableFile(
                url,
                reason: "file size is outside the supported 1...\(maximumDocumentBytes)-byte range"))
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return .unreadable(.unreadableFile(url, reason: error.localizedDescription))
        }
        guard !data.isEmpty else { return .corrupt("\(url.lastPathComponent) is empty") }

        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(DocumentHeader.self, from: data)
            guard header.schema == schema else {
                return .incompatible(.unsupportedSchema(
                    expected: schema,
                    found: header.schema))
            }

            let decoded: DecodedDocument
            switch header.version {
            case version:
                decoded = DecodedDocument(
                    document: try decoder.decode(Document.self, from: data),
                    requiresMigration: false)
            case legacyVersion1:
                let legacy = try decoder.decode(LegacyVersion1Document.self, from: data)
                decoded = DecodedDocument(
                    document: try migrateLegacyDocument(
                        revision: legacy.revision,
                        pending: legacy.pending,
                        running: legacy.running.map { [$0] } ?? []),
                    requiresMigration: true)
            case legacyVersion2:
                let legacy = try decoder.decode(LegacyVersion2Document.self, from: data)
                decoded = DecodedDocument(
                    document: try migrateLegacyDocument(
                        revision: legacy.revision,
                        pending: legacy.pending,
                        running: legacy.running),
                    requiresMigration: true)
            default:
                return .incompatible(.unsupportedVersion(
                    expected: version,
                    found: header.version))
            }

            try validate(decoded.document)
            return .valid(decoded)
        } catch let error as QueueStoreError {
            switch error {
            case .unsupportedSchema, .unsupportedVersion:
                return .incompatible(error)
            default:
                return .corrupt(error.localizedDescription)
            }
        } catch {
            return .corrupt(error.localizedDescription)
        }
    }

    static func migrateLegacyDocument(
        revision: UInt64,
        pending: [LegacyScalarJob],
        running: [LegacyClaim]
    ) throws -> Document {
        Document(
            schema: schema,
            version: version,
            revision: revision,
            pending: try pending.map(migrateLegacyJob),
            running: try running.map(migrateLegacyClaim))
    }

    static func migrateLegacyJob(_ legacy: LegacyScalarJob) throws -> QueueJob {
        try validate(legacy)
        return QueueJob(
            id: legacy.id,
            prompt: legacy.prompt,
            width: legacy.width,
            height: legacy.height,
            steps: legacy.steps,
            seedText: legacy.seedText)
    }

    static func migrateLegacyClaim(_ legacy: LegacyClaim) throws -> Claim {
        let requested = legacy.job.seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitSeed = UInt64(requested), explicitSeed != legacy.resolvedSeed {
            throw QueueStoreError.invalidDocument(
                "running job seed does not match its resolved seed")
        }
        return Claim(
            id: legacy.id,
            job: try migrateLegacyJob(legacy.job),
            resolvedSeed: legacy.resolvedSeed)
    }

    static func validate(_ document: Document) throws {
        guard document.schema == schema else {
            throw QueueStoreError.invalidDocument("unexpected schema \(document.schema)")
        }
        guard document.version == version else {
            throw QueueStoreError.invalidDocument("unexpected version \(document.version)")
        }

        var ids = Set<UUID>()
        for job in document.pending {
            try validate(job)
            guard ids.insert(job.id).inserted else {
                throw QueueStoreError.invalidDocument(
                    "duplicate job id \(job.id.uuidString)")
            }
        }
        guard document.running.count <= maximumClaimGroupSize else {
            throw QueueStoreError.invalidDocument(
                "running claim group exceeds \(maximumClaimGroupSize) jobs")
        }
        var claimIDs = Set<UUID>()
        let runningSessionKey = document.running.first?.recipe.sessionKey
        for running in document.running {
            try validate(running.job, requiringFixedSeed: true)
            guard claimIDs.insert(running.id).inserted else {
                throw QueueStoreError.invalidDocument(
                    "duplicate running claim id \(running.id.uuidString)")
            }
            guard ids.insert(running.job.id).inserted else {
                throw QueueStoreError.invalidDocument(
                    "running job id \(running.job.id.uuidString) is also pending")
            }
            if running.recipe.sessionKey != runningSessionKey {
                throw QueueStoreError.invalidDocument(
                    "running claims require different engine sessions")
            }
        }
    }

    static func validate(_ job: QueueJob, requiringFixedSeed: Bool = false) throws {
        do {
            try job.recipe.validate(for: requiringFixedSeed ? .persistedResult : .request)
            try job.provenance?.validate(recipe: job.recipe)
        } catch GenerationRecipe.ValidationError.incompatibleSchema(let found) {
            throw QueueStoreError.unsupportedSchema(
                expected: GenerationRecipe.supportedSchema,
                found: found)
        } catch GenerationRecipe.ValidationError.incompatibleVersion(let found) {
            throw QueueStoreError.unsupportedVersion(
                expected: GenerationRecipe.currentVersion,
                found: found)
        } catch {
            throw QueueStoreError.invalidJob(job.id, reason: error.localizedDescription)
        }
    }

    static func validate(_ job: LegacyScalarJob) throws {
        guard !job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QueueStoreError.invalidJob(job.id, reason: "prompt is empty")
        }
        guard (256...2_048).contains(job.width), job.width.isMultiple(of: 16) else {
            throw QueueStoreError.invalidJob(
                job.id,
                reason: "width must be 256...2048 and divisible by 16")
        }
        guard (256...2_048).contains(job.height), job.height.isMultiple(of: 16) else {
            throw QueueStoreError.invalidJob(
                job.id,
                reason: "height must be 256...2048 and divisible by 16")
        }
        guard (4...12).contains(job.steps) else {
            throw QueueStoreError.invalidJob(job.id, reason: "steps must be 4...12")
        }
        let seed = job.seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard seed.isEmpty || UInt64(seed) != nil else {
            throw QueueStoreError.invalidJob(
                job.id,
                reason: "seed must be empty or an unsigned 64-bit integer")
        }
    }

    static func contains(_ id: UUID, in document: Document) -> Bool {
        document.pending.contains { $0.id == id }
            || document.running.contains { $0.job.id == id }
    }

    static func retryJobs(for claims: [Claim]) -> [QueueJob] {
        claims.map(\.job)
    }

    static func nextRevision(after revision: UInt64) throws -> UInt64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else { throw QueueStoreError.revisionOverflow }
        return next
    }

    static func persist(_ document: Document, fileURL: URL, stagingURL: URL) throws {
        let parent = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(parent)
        guard stagingURL.deletingLastPathComponent().standardizedFileURL
                == parent.standardizedFileURL else {
            throw QueueStoreError.unreadableFile(
                stagingURL,
                reason: "staging must remain beside the queue file")
        }
        switch itemKind(at: stagingURL) {
        case .missing, .regular:
            break
        case .directory, .symbolicLink, .other:
            throw QueueStoreError.unreadableFile(
                stagingURL,
                reason: "unsafe staging destination")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard !data.isEmpty, data.count <= maximumDocumentBytes else {
            throw QueueStoreError.invalidDocument(
                "encoded queue exceeds the \(maximumDocumentBytes)-byte limit")
        }
        try data.write(to: stagingURL, options: .atomic)
        try installStaging(stagingURL, at: fileURL)
    }

    static func installStaging(_ stagingURL: URL, at fileURL: URL) throws {
        guard itemKind(at: stagingURL) == .regular else {
            throw QueueStoreError.unreadableFile(stagingURL, reason: "staging file is not regular")
        }
        switch itemKind(at: fileURL) {
        case .missing, .regular:
            break
        case .directory, .symbolicLink, .other:
            throw QueueStoreError.unreadableFile(fileURL, reason: "queue destination is unsafe")
        }
        try setPrivatePermissions(at: stagingURL)
        guard rename(stagingURL.path, fileURL.path) == 0 else {
            throw QueueStoreError.unreadableFile(
                stagingURL,
                reason: String(cString: strerror(errno)))
        }
    }

    static func setPrivatePermissions(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: privateFilePermissions],
            ofItemAtPath: url.path)
        guard let permissions = try FileManager.default.attributesOfItem(
            atPath: url.path)[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == privateFilePermissions else {
            throw QueueStoreError.unreadableFile(
                url,
                reason: "private file permissions could not be verified")
        }
    }

    static func quarantine(
        _ urls: [URL],
        relativeTo fileURL: URL,
        quarantineID: @Sendable () -> UUID
    ) throws -> [URL] {
        var quarantined: [URL] = []
        let directory = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension

        for source in urls {
            let role = source == fileURL ? "" : ".pending"
            let token = quarantineID().uuidString.lowercased()
            var suffix = 0
            var destination: URL
            repeat {
                let collision = suffix == 0 ? "" : ".\(suffix)"
                destination = directory.appendingPathComponent(
                    "\(stem)\(role).corrupt.\(token)\(collision).\(ext)")
                suffix += 1
            } while FileManager.default.fileExists(atPath: destination.path)

            do {
                try setPrivatePermissions(at: source)
                guard rename(source.path, destination.path) == 0 else {
                    throw QueueStoreError.quarantineFailed(
                        source,
                        reason: String(cString: strerror(errno)))
                }
            } catch {
                if let error = error as? QueueStoreError { throw error }
                throw QueueStoreError.quarantineFailed(
                    source,
                    reason: error.localizedDescription)
            }
            quarantined.append(destination)
        }
        return quarantined
    }

    enum FilesystemItemKind: Equatable {
        case missing
        case regular
        case directory
        case symbolicLink
        case other
    }

    static func ensurePrivateDirectory(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let forbidden = Set([
            URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL,
            URL(fileURLWithPath: "/tmp", isDirectory: true).standardizedFileURL,
            URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL,
            FileManager.default.temporaryDirectory.standardizedFileURL,
            home,
            home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL,
            home.appendingPathComponent(
                "Library/Application Support",
                isDirectory: true).standardizedFileURL,
        ])
        guard !forbidden.contains(standardized) else {
            throw QueueStoreError.unreadableFile(
                url,
                reason: "refused to change permissions on a shared parent directory")
        }
        switch itemKind(at: url) {
        case .missing:
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: privateDirectoryPermissions])
        case .directory:
            break
        case .regular, .symbolicLink, .other:
            throw QueueStoreError.unreadableFile(url, reason: "queue parent is not a real directory")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: privateDirectoryPermissions],
            ofItemAtPath: url.path)
        guard let permissions = try FileManager.default.attributesOfItem(
            atPath: url.path)[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == privateDirectoryPermissions else {
            throw QueueStoreError.unreadableFile(
                url,
                reason: "private directory permissions could not be verified")
        }
    }

    static func itemKind(at url: URL) -> FilesystemItemKind {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return .symbolicLink
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return .other }
        switch type {
        case .typeRegular: return .regular
        case .typeDirectory: return .directory
        case .typeSymbolicLink: return .symbolicLink
        default: return .other
        }
    }

    static func fileSize(at url: URL) -> Int? {
        guard itemKind(at: url) == .regular,
              let size = (try? FileManager.default.attributesOfItem(
                atPath: url.path)[.size]) as? NSNumber else { return nil }
        return size.intValue
    }
}
