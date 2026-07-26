import CryptoKit
import Darwin
import Foundation

enum GenerationExportError: Error, Equatable, LocalizedError {
    case staleGeneration(UUID)
    case unsafeSource(URL)
    case missingSidecar(URL)
    case incompatibleSidecar(URL)
    case integrityMismatch(URL)
    case fileTooLarge(URL)
    case managedDestination(URL)
    case invalidDestinationDirectory(URL)
    case destinationExists(URL)
    case bulkNameExhausted(URL)
    case invalidPNGProvenance

    var errorDescription: String? {
        switch self {
        case .staleGeneration:
            return "This gallery item is no longer available."
        case .unsafeSource(let url):
            return "The gallery refused to export an unsafe file at \(url.path)."
        case .missingSidecar:
            return "The gallery could not verify this image because its recipe sidecar is missing."
        case .incompatibleSidecar:
            return "This image was written by a newer, incompatible gallery format."
        case .integrityMismatch:
            return "The image no longer matches its verified gallery record. Run Library Repair before exporting."
        case .fileTooLarge:
            return "The image is too large for a clean drag or export."
        case .managedDestination:
            return "Choose a destination outside Twisterminigen's managed library."
        case .invalidDestinationDirectory:
            return "Choose a regular, writable export folder."
        case .destinationExists(let url):
            return "A file already exists at \(url.lastPathComponent); no files were replaced."
        case .bulkNameExhausted:
            return "The gallery could not reserve a collision-free export name."
        case .invalidPNGProvenance:
            return "The verified image is not a structurally valid PNG, so AI provenance could not be attached."
        }
    }
}

struct BulkGenerationExportResult: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case publishedDurable
        case publishedDurabilityWarning(code: Int32)
        case failedBeforeVisibility(ExternalPublishError)
        case stateUnknown(ExternalPublishError)
        case unattemptedDueToEarlierFailure
    }

    struct Item: Equatable, Sendable {
        let generationID: UUID
        let destination: URL
        let state: State
    }

    struct Failure: Equatable, Sendable {
        let generationID: UUID
        let destination: URL
        let message: String
        let stateUnknown: Bool
    }

    let items: [Item]

    var exported: [URL] {
        items.compactMap { item in
            switch item.state {
            case .publishedDurable, .publishedDurabilityWarning: item.destination
            case .failedBeforeVisibility, .stateUnknown, .unattemptedDueToEarlierFailure: nil
            }
        }
    }

    var durabilityWarnings: [Item] {
        items.filter {
            if case .publishedDurabilityWarning = $0.state { true } else { false }
        }
    }

    var failures: [Failure] {
        items.compactMap { item in
            switch item.state {
            case .failedBeforeVisibility(let error):
                Failure(
                    generationID: item.generationID,
                    destination: item.destination,
                    message: error.localizedDescription,
                    stateUnknown: false)
            case .stateUnknown(let error):
                Failure(
                    generationID: item.generationID,
                    destination: item.destination,
                    message: "Publication state is unknown; inspect the destination. \(error.localizedDescription)",
                    stateUnknown: true)
            case .unattemptedDueToEarlierFailure:
                Failure(
                    generationID: item.generationID,
                    destination: item.destination,
                    message: "Not published because an earlier batch destination failed.",
                    stateUnknown: false)
            case .publishedDurable, .publishedDurabilityWarning:
                nil
            }
        }
    }
}

struct PNGRecipeExportResult: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        let destination: URL
        let message: String
        let stateUnknown: Bool
    }

    let pngOutcome: ExternalPublicationOutcome
    let recipeOutcome: ExternalPublicationOutcome?

    var publishedPNG: URL? { pngOutcome.confirmedVisibleURL }
    var publishedRecipe: URL? { recipeOutcome?.confirmedVisibleURL }

    var durabilityWarnings: [ExternalPublicationOutcome] {
        [pngOutcome, recipeOutcome].compactMap { outcome in
            guard let outcome, outcome.durabilityWarningCode != nil else { return nil }
            return outcome
        }
    }

    var failure: Failure? {
        for outcome in [pngOutcome, recipeOutcome].compactMap({ $0 }) {
            guard let error = outcome.failure else { continue }
            let unknown: Bool
            if case .stateUnknown = outcome { unknown = true } else { unknown = false }
            return Failure(
                destination: outcome.destination,
                message: unknown
                    ? "Publication state is unknown; inspect the destination. \(error.localizedDescription)"
                    : error.localizedDescription,
                stateUnknown: unknown)
        }
        return nil
    }

    var isComplete: Bool {
        publishedPNG != nil && publishedRecipe != nil && failure == nil
    }
}

extension GenerationStore {
    private static var maximumExportPNGBytes: Int { 256 * 1_024 * 1_024 }
    private static var maximumExportSidecarBytes: Int { 2 * 1_024 * 1_024 }

    /// Returns verified pixels with a small disclosure/provenance envelope. The private recipe is
    /// still not embedded; exports that request it receive a separate portable sidecar.
    func pngDataForExport(for generation: Generation) throws -> Data {
        try reviewablePNG(for: generation).data
    }

    /// Produces the exact final PNG bytes that must be bound into an OutputReviewGate receipt.
    func reviewablePNG(
        for generation: Generation,
        derivation: PNGOutputProvenance.Derivation = .generatedImage
    ) throws -> ReviewablePNG {
        guard all().contains(generation) else {
            throw GenerationExportError.staleGeneration(generation.id)
        }
        let paths = libraryPaths()
        let imageURL = try paths.imageURL(for: generation.imageFileName)
        let sidecarURL = try paths.recipeURL(for: generation.imageFileName)
        let imageData = try Self.readRegularExportFile(
            imageURL,
            maximumBytes: Self.maximumExportPNGBytes,
            missingError: .unsafeSource(imageURL))
        guard imageData.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw GenerationExportError.integrityMismatch(imageURL)
        }

        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            throw GenerationExportError.missingSidecar(sidecarURL)
        }
        let sidecarData = try Self.readRegularExportFile(
            sidecarURL,
            maximumBytes: Self.maximumExportSidecarBytes,
            missingError: .unsafeSource(sidecarURL))
        let envelope: GenerationSidecarEnvelope
        do {
            envelope = try JSONDecoder().decode(GenerationSidecarEnvelope.self, from: sidecarData)
        } catch {
            throw GenerationExportError.integrityMismatch(sidecarURL)
        }
        guard envelope.schema == GenerationSidecarEnvelope.supportedSchema,
              envelope.version == GenerationSidecarEnvelope.currentVersion,
              envelope.generation.recipe.schema == GenerationRecipe.supportedSchema,
              envelope.generation.recipe.version == GenerationRecipe.currentVersion else {
            throw GenerationExportError.incompatibleSidecar(sidecarURL)
        }

        let digest = SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard envelope.generation == generation,
              envelope.pngByteCount == Int64(imageData.count),
              envelope.pngSHA256.lowercased() == digest else {
            throw GenerationExportError.integrityMismatch(imageURL)
        }
        let tagged = try PNGOutputProvenance.embedding(
            in: imageData,
            generations: [generation],
            derivation: derivation)
        return try ReviewablePNG(provenancePNGData: tagged, derivation: derivation)
    }

    func exportPNG(
        for generation: Generation,
        to destination: URL,
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind,
        derivation: PNGOutputProvenance.Derivation = .generatedImage
    ) async throws -> ExternalPublicationOutcome {
        do {
            let paths = libraryPaths()
            let output = try reviewablePNG(for: generation, derivation: derivation)
            return try await ValidatedExternalPublisher.publishReviewedPNG(
                output,
                to: destination,
                receipt: receipt,
                kind: kind,
                protectedRoots: paths.protectedExportRoots)
        } catch {
            await OutputReviewGate.revoke(receipt)
            throw error
        }
    }

    /// Exports a verified clean PNG plus its portable recipe after both destinations preflight.
    /// Neither destination may already exist. A post-preflight external race can still make the
    /// second publication fail; in that case the reviewed PNG is left intact rather than deleting
    /// through a mutable user-controlled pathname that could have been swapped by another process.
    func exportPNGWithRecipe(
        for generation: Generation,
        pngDestination: URL,
        recipeDestination: URL,
        receipt: OutputReviewGate.ReviewReceipt
    ) async throws -> PNGRecipeExportResult {
        do {
            return try await exportPNGWithRecipe(
                for: generation,
                pngDestination: pngDestination,
                recipeDestination: recipeDestination,
                receipt: receipt,
                beforeRecipePublication: nil,
                pngFault: nil,
                recipeFault: nil)
        } catch {
            await OutputReviewGate.revoke(receipt)
            throw error
        }
    }

    #if DEBUG
    func exportPNGWithRecipeForTesting(
        for generation: Generation,
        pngDestination: URL,
        recipeDestination: URL,
        receipt: OutputReviewGate.ReviewReceipt,
        beforeRecipePublication: @escaping @Sendable () throws -> Void,
        pngFault: ValidatedExternalPublisher.PublicationFault? = nil,
        recipeFault: ValidatedExternalPublisher.PublicationFault? = nil
    ) async throws -> PNGRecipeExportResult {
        do {
            return try await exportPNGWithRecipe(
                for: generation,
                pngDestination: pngDestination,
                recipeDestination: recipeDestination,
                receipt: receipt,
                beforeRecipePublication: beforeRecipePublication,
                pngFault: pngFault,
                recipeFault: recipeFault)
        } catch {
            await OutputReviewGate.revoke(receipt)
            throw error
        }
    }
    #endif

    private func exportPNGWithRecipe(
        for generation: Generation,
        pngDestination: URL,
        recipeDestination: URL,
        receipt: OutputReviewGate.ReviewReceipt,
        beforeRecipePublication: (@Sendable () throws -> Void)?,
        pngFault: ValidatedExternalPublisher.PublicationFault?,
        recipeFault: ValidatedExternalPublisher.PublicationFault?
    ) async throws -> PNGRecipeExportResult {
        let pngDestination = pngDestination.standardizedFileURL
        let recipeDestination = recipeDestination.standardizedFileURL
        guard pngDestination.pathExtension.lowercased() == "png" else {
            throw GenerationExportError.invalidDestinationDirectory(pngDestination)
        }
        guard recipeDestination.pathExtension.lowercased() == "twisterrecipe" else {
            throw PortableRecipeError.wrongExtension(recipeDestination)
        }
        guard pngDestination != recipeDestination else {
            throw GenerationExportError.invalidDestinationDirectory(pngDestination)
        }
        _ = try validatedExportDirectory(pngDestination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: pngDestination.path) {
            throw GenerationExportError.destinationExists(pngDestination)
        }

        let output = try reviewablePNG(for: generation)
        let document = PortableRecipeDocument(
            generation: generation,
            exportedPNGData: output.data)
        try ValidatedExternalPublisher.preflightDocumentDestination(
            recipeDestination,
            kind: .portableRecipe,
            protectedRoots: libraryPaths().protectedExportRoots)
        let pngOutcome: ExternalPublicationOutcome
        #if DEBUG
        if let pngFault {
            pngOutcome = try await ValidatedExternalPublisher.publishReviewedPNGForTesting(
                output,
                to: pngDestination,
                receipt: receipt,
                kind: .galleryWithRecipe,
                protectedRoots: libraryPaths().protectedExportRoots,
                fault: pngFault)
        } else {
            pngOutcome = try await ValidatedExternalPublisher.publishReviewedPNG(
                output,
                to: pngDestination,
                receipt: receipt,
                kind: .galleryWithRecipe,
                protectedRoots: libraryPaths().protectedExportRoots)
        }
        #else
        let _ = pngFault
        let _ = recipeFault
        pngOutcome = try await ValidatedExternalPublisher.publishReviewedPNG(
            output,
            to: pngDestination,
            receipt: receipt,
            kind: .galleryWithRecipe,
            protectedRoots: libraryPaths().protectedExportRoots)
        #endif
        guard pngOutcome.isConfirmedVisible else {
            return PNGRecipeExportResult(pngOutcome: pngOutcome, recipeOutcome: nil)
        }
        do {
            try beforeRecipePublication?()
            let recipeOutcome: ExternalPublicationOutcome
            #if DEBUG
            if let recipeFault {
                recipeOutcome = ValidatedExternalPublisher.publishDocumentForTesting(
                    try PortableRecipeService.encode(document),
                    to: recipeDestination,
                    kind: .portableRecipe,
                    protectedRoots: libraryPaths().protectedExportRoots,
                    fault: recipeFault)
            } else {
                recipeOutcome = try PortableRecipeService.write(
                    document,
                    to: recipeDestination,
                    protectedRoots: libraryPaths().protectedExportRoots)
            }
            #else
            recipeOutcome = try PortableRecipeService.write(
                document,
                to: recipeDestination,
                protectedRoots: libraryPaths().protectedExportRoots)
            #endif
            return PNGRecipeExportResult(
                pngOutcome: pngOutcome,
                recipeOutcome: recipeOutcome)
        } catch {
            let publicationError = Self.externalPublicationError(
                from: error,
                destination: recipeDestination)
            return PNGRecipeExportResult(
                pngOutcome: pngOutcome,
                recipeOutcome: .failedBeforeVisibility(
                    recipeDestination,
                    error: publicationError))
        }
    }

    /// Exports one digest-bound reviewed batch into an existing folder without replacing any user
    /// file. Every source must verify before the receipt is consumed; publication then preserves
    /// deterministic order and collision-free names.
    func exportPNGs(
        for generations: [Generation],
        toDirectory directory: URL,
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind = .galleryBulk,
        derivation: PNGOutputProvenance.Derivation = .generatedImage
    ) async throws -> BulkGenerationExportResult {
        do {
            return try await exportPNGs(
                for: generations,
                toDirectory: directory,
                receipt: receipt,
                kind: kind,
                derivation: derivation,
                beforeEachPublication: nil)
        } catch {
            await OutputReviewGate.revoke(receipt)
            throw error
        }
    }

    #if DEBUG
    func exportPNGsForTesting(
        for generations: [Generation],
        toDirectory directory: URL,
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind = .galleryBulk,
        derivation: PNGOutputProvenance.Derivation = .generatedImage,
        beforeEachPublication: @escaping @Sendable (Int, URL) throws -> Void,
        faultForPublication: @escaping @Sendable (Int, URL) -> ValidatedExternalPublisher.PublicationFault? = { _, _ in nil }
    ) async throws -> BulkGenerationExportResult {
        do {
            return try await exportPNGs(
                for: generations,
                toDirectory: directory,
                receipt: receipt,
                kind: kind,
                derivation: derivation,
                beforeEachPublication: beforeEachPublication,
                faultForPublication: faultForPublication)
        } catch {
            await OutputReviewGate.revoke(receipt)
            throw error
        }
    }
    #endif

    private func exportPNGs(
        for generations: [Generation],
        toDirectory directory: URL,
        receipt: OutputReviewGate.ReviewReceipt,
        kind: OutputReviewGate.ExportKind,
        derivation: PNGOutputProvenance.Derivation,
        beforeEachPublication: (@Sendable (Int, URL) throws -> Void)?,
        faultForPublication: (@Sendable (Int, URL) -> ValidatedExternalPublisher.PublicationFault?)? = nil
    ) async throws -> BulkGenerationExportResult {
        let destinationDirectory = try validatedExportDirectory(directory)
        let existingNames = try FileManager.default.contentsOfDirectory(
            at: destinationDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        var reservedNames = Set(existingNames.map { $0.lastPathComponent.lowercased() })
        var publications: [ReviewedPNGPublication] = []
        for generation in generations {
            let output = try reviewablePNG(for: generation, derivation: derivation)
            let destination = try Self.availableDestination(
                baseName: "Twisterminigen-\(generation.seed)",
                directory: destinationDirectory,
                reservedNames: &reservedNames)
            publications.append(.init(output: output, destination: destination))
        }
        let publication: ReviewedPNGPublishResult
        #if DEBUG
        if let beforeEachPublication {
            publication = try await ValidatedExternalPublisher.publishReviewedPNGsForTesting(
                publications,
                receipt: receipt,
                kind: kind,
                protectedRoots: libraryPaths().protectedExportRoots,
                beforeEachPublication: beforeEachPublication,
                faultForPublication: faultForPublication ?? { _, _ in nil })
        } else {
            publication = try await ValidatedExternalPublisher.publishReviewedPNGs(
                publications,
                receipt: receipt,
                kind: kind,
                protectedRoots: libraryPaths().protectedExportRoots)
        }
        #else
        publication = try await ValidatedExternalPublisher.publishReviewedPNGs(
            publications,
            receipt: receipt,
            kind: kind,
            protectedRoots: libraryPaths().protectedExportRoots)
        #endif
        var items: [BulkGenerationExportResult.Item] = []
        items.reserveCapacity(generations.count)
        for (index, outcome) in publication.outcomes.enumerated() {
            let state: BulkGenerationExportResult.State
            switch outcome {
            case .publishedDurable:
                state = .publishedDurable
            case .publishedDurabilityWarning(_, let code):
                state = .publishedDurabilityWarning(code: code)
            case .failedBeforeVisibility(_, let error):
                state = .failedBeforeVisibility(error)
            case .stateUnknown(_, let error):
                state = .stateUnknown(error)
            }
            items.append(.init(
                generationID: generations[index].id,
                destination: publications[index].destination.standardizedFileURL,
                state: state))
        }
        for index in publication.outcomes.count ..< generations.count {
            items.append(.init(
                generationID: generations[index].id,
                destination: publications[index].destination.standardizedFileURL,
                state: .unattemptedDueToEarlierFailure))
        }
        return BulkGenerationExportResult(items: items)
    }

    private static func externalPublicationError(
        from error: Error,
        destination: URL
    ) -> ExternalPublishError {
        if let error = error as? ExternalPublishError { return error }
        if let error = error as? PortableRecipeError {
            switch error {
            case .destinationExists: return .destinationExists(destination)
            case .managedDestination: return .managedDestination(destination)
            case .wrongExtension: return .wrongExtension(expected: "twisterrecipe")
            case .writeFailed(let code): return .writeFailed(code)
            default: return .invalidDestination(destination)
            }
        }
        return .writeFailed(EIO)
    }

    private static func readRegularExportFile(
        _ url: URL,
        maximumBytes: Int,
        missingError: GenerationExportError
    ) throws -> Data {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
        } catch {
            throw missingError
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw GenerationExportError.unsafeSource(url)
        }
        guard let byteCount = values.fileSize, byteCount >= 0, byteCount <= maximumBytes else {
            throw GenerationExportError.fileTooLarge(url)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == byteCount else {
            throw GenerationExportError.integrityMismatch(url)
        }
        return data
    }

    private static func exportPath(_ child: URL, isWithin parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private func validatedExportDirectory(_ directory: URL) throws -> URL {
        let standardized = directory.standardizedFileURL
        let values: URLResourceValues
        do {
            values = try standardized.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isWritableKey,
            ])
        } catch {
            throw GenerationExportError.invalidDestinationDirectory(directory)
        }
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isWritable != false else {
            throw GenerationExportError.invalidDestinationDirectory(directory)
        }

        let resolved = standardized.resolvingSymlinksInPath()
        let paths = libraryPaths()
        let protectedDirectories = [
            paths.root, paths.images, paths.recipes, paths.quarantine, paths.thumbnails,
        ]
        guard !protectedDirectories.contains(where: {
            Self.exportPath(resolved, isWithin: $0.resolvingSymlinksInPath())
        }) else {
            throw GenerationExportError.managedDestination(directory)
        }
        return standardized
    }

    private static func availableDestination(
        baseName: String,
        directory: URL,
        reservedNames: inout Set<String>
    ) throws -> URL {
        for ordinal in 1 ... 100_000 {
            let suffix = ordinal == 1 ? "" : "-\(ordinal)"
            let fileName = "\(baseName)\(suffix).png"
            let normalizedName = fileName.lowercased()
            guard reservedNames.insert(normalizedName).inserted else { continue }
            return directory.appendingPathComponent(fileName, isDirectory: false)
        }
        throw GenerationExportError.bulkNameExhausted(directory)
    }
}

/// Adds standards-compatible PNG `tEXt` chunks without decoding or altering image pixels. The
/// metadata survives every clean export path and gives downstream tools a local AI disclosure,
/// producing build, model reference, and source Generation IDs.
enum PNGOutputProvenance {
    static let disclosure = "AI-generated locally with Krea 2; human review is required before distribution."
    private static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    enum Derivation: String, Sendable, Hashable {
        case generatedImage = "Original Krea generation"
        case reviewedGalleryCopy = "Reviewed Gallery copy"
        case foregroundCutout = "Apple Vision transparent foreground cut-out"
        case localAIUpscale4x = "Local AI 4x upscale"
    }

    static func embedding(
        in png: Data,
        generations: [Generation],
        derivation: Derivation? = nil
    ) throws -> Data {
        guard !generations.isEmpty, png.starts(with: signature) else {
            throw GenerationExportError.invalidPNGProvenance
        }
        guard let iendOffset = iendOffset(in: png) else {
            throw GenerationExportError.invalidPNGProvenance
        }

        let first = generations[0]
        let versionValues = Set(generations.map { $0.producerAppVersion ?? "unknown" })
        let buildValues = Set(generations.map { $0.producerAppBuild ?? "unknown" })
        let version = versionValues.count == 1 ? versionValues.first! : "mixed"
        let build = buildValues.count == 1 ? buildValues.first! : "mixed"
        let sourceIDs = generations.map(\.id.uuidString).joined(separator: ",")
        var fields = [
            ("AIGenerated", "true"),
            ("Description", disclosure),
            ("Software", "Twisterminigen \(version) build \(build)"),
            ("Model", "\(first.recipe.model.modelID)/\(first.recipe.model.variantID)"),
            ("SourceGenerationIDs", sourceIDs),
            ("ContentReview", "Required before distribution"),
        ]
        if let derivation {
            fields.append(("Transformation", derivation.rawValue))
        }

        var metadata = Data()
        for (keyword, value) in fields {
            metadata.append(textChunk(keyword: keyword, value: value))
        }
        var output = png
        output.insert(contentsOf: metadata, at: iendOffset)
        return output
    }

    /// Validates the complete PNG structure and the exact provenance envelope used by the review
    /// boundary. Looking for byte substrings is insufficient: arbitrary compressed pixels or
    /// trailing bytes could contain the same text without carrying valid PNG metadata.
    static func isValidReviewablePNG(
        _ png: Data,
        derivation: Derivation
    ) -> Bool {
        guard png.starts(with: signature), png.count >= signature.count + 12 else { return false }
        var offset = signature.count
        var chunkIndex = 0
        var sawImageData = false
        var fields: [String: [String]] = [:]
        let provenanceKeywords: Set<String> = [
            "AIGenerated", "Description", "Software", "Model",
            "SourceGenerationIDs", "ContentReview", "Transformation",
        ]

        while offset <= png.count - 12 {
            let length = Int(readUInt32(png, at: offset))
            guard length <= png.count - offset - 12 else { return false }
            let typeStart = offset + 4
            let payloadStart = typeStart + 4
            let payloadEnd = payloadStart + length
            let crcOffset = payloadEnd
            let typeBytes = png[typeStart ..< payloadStart]
            guard typeBytes.allSatisfy({
                      (65 ... 90).contains($0) || (97 ... 122).contains($0)
                  }),
                  let type = String(
                      data: Data(typeBytes),
                      encoding: .ascii),
                  type.utf8.count == 4,
                  readUInt32(png, at: crcOffset)
                    == crc32(Data(png[typeStart ..< payloadEnd])) else {
                return false
            }
            if chunkIndex == 0, !(type == "IHDR" && length == 13) { return false }
            if type == "IHDR" {
                guard chunkIndex == 0,
                      readUInt32(png, at: payloadStart) > 0,
                      readUInt32(png, at: payloadStart + 4) > 0,
                      validIHDR(
                          bitDepth: png[payloadStart + 8],
                          colorType: png[payloadStart + 9]),
                      png[payloadStart + 10] == 0,
                      png[payloadStart + 11] == 0,
                      png[payloadStart + 12] <= 1 else {
                    return false
                }
            }
            if type == "IDAT" { sawImageData = true }

            if type == "tEXt" {
                let payload = Data(png[payloadStart ..< payloadEnd])
                guard let separator = payload.firstIndex(of: 0), separator > payload.startIndex,
                      let keyword = String(
                          data: payload[payload.startIndex ..< separator],
                          encoding: .ascii),
                      (1 ... 79).contains(keyword.utf8.count) else {
                    return false
                }
                if provenanceKeywords.contains(keyword) {
                    guard let value = String(
                        data: payload[payload.index(after: separator) ..< payload.endIndex],
                        encoding: .utf8) else {
                        return false
                    }
                    fields[keyword, default: []].append(value)
                }
            } else if type == "zTXt" || type == "iTXt" {
                let payload = Data(png[payloadStart ..< payloadEnd])
                if let separator = payload.firstIndex(of: 0), separator > payload.startIndex,
                   let keyword = String(
                       data: payload[payload.startIndex ..< separator],
                       encoding: .ascii),
                   provenanceKeywords.contains(keyword) {
                    return false
                }
            }

            let nextOffset = offset + 12 + length
            if type == "IEND" {
                guard length == 0, nextOffset == png.count, sawImageData else { return false }
                let sourceIDs = fields["SourceGenerationIDs"] ?? []
                guard sourceIDs.count == 1 else { return false }
                let identifiers = sourceIDs[0].split(separator: ",", omittingEmptySubsequences: false)
                return fields["AIGenerated"] == ["true"]
                    && fields["Description"] == [disclosure]
                    && fields["ContentReview"] == ["Required before distribution"]
                    && fields["Transformation"] == [derivation.rawValue]
                    && fields["Software"]?.count == 1
                    && fields["Software"]?.first?.hasPrefix("Twisterminigen ") == true
                    && fields["Model"]?.count == 1
                    && fields["Model"]?.first?.isEmpty == false
                    && !identifiers.isEmpty
                    && identifiers.allSatisfy { UUID(uuidString: String($0)) != nil }
            }
            offset = nextOffset
            chunkIndex += 1
        }
        return false
    }

    private static func validIHDR(bitDepth: UInt8, colorType: UInt8) -> Bool {
        switch colorType {
        case 0: [1, 2, 4, 8, 16].contains(bitDepth)
        case 2, 4, 6: [8, 16].contains(bitDepth)
        case 3: [1, 2, 4, 8].contains(bitDepth)
        default: false
        }
    }

    private static func iendOffset(in png: Data) -> Int? {
        var offset = signature.count
        while offset <= png.count - 12 {
            let length = Int(readUInt32(png, at: offset))
            guard length <= png.count - offset - 12 else { return nil }
            let typeStart = offset + 4
            let typeEnd = typeStart + 4
            guard let type = String(data: png[typeStart..<typeEnd], encoding: .ascii) else {
                return nil
            }
            if type == "IEND" {
                return length == 0 ? offset : nil
            }
            offset += 12 + length
        }
        return nil
    }

    private static func textChunk(keyword: String, value: String) -> Data {
        let type = Data("tEXt".utf8)
        var payload = Data(keyword.utf8)
        payload.append(0)
        payload.append(Data(value.utf8))

        var chunk = Data()
        appendUInt32(UInt32(payload.count), to: &chunk)
        chunk.append(type)
        chunk.append(payload)
        var crcInput = type
        crcInput.append(payload)
        appendUInt32(crc32(crcInput), to: &chunk)
        return chunk
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Prepares the exact provenance-bearing bytes that the user sees and reviews. Publication lives
/// exclusively in `ValidatedExternalPublisher`, where a digest-bound receipt is consumed.
enum ReviewablePNGFactory {
    static func data(
        from png: Data,
        sourceGeneration: Generation,
        derivation: PNGOutputProvenance.Derivation
    ) throws -> ReviewablePNG {
        let tagged = try PNGOutputProvenance.embedding(
            in: png,
            generations: [sourceGeneration],
            derivation: derivation)
        return try ReviewablePNG(provenancePNGData: tagged, derivation: derivation)
    }

    static func data(
        from png: Data,
        sourceGenerations: [Generation],
        derivation: PNGOutputProvenance.Derivation
    ) throws -> ReviewablePNG {
        let tagged = try PNGOutputProvenance.embedding(
            in: png,
            generations: sourceGenerations,
            derivation: derivation)
        return try ReviewablePNG(provenancePNGData: tagged, derivation: derivation)
    }
}
