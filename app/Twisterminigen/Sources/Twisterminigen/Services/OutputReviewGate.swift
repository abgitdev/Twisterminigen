import AppKit
import CryptoKit
import Foundation

struct ReviewablePNG: Sendable, Hashable {
    let data: Data
    let derivation: PNGOutputProvenance.Derivation
    let sha256: String

    init(
        provenancePNGData data: Data,
        derivation: PNGOutputProvenance.Derivation
    ) throws {
        guard PNGOutputProvenance.isValidReviewablePNG(
            data,
            derivation: derivation) else {
            throw GenerationExportError.invalidPNGProvenance
        }
        self.data = data
        self.derivation = derivation
        self.sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    fileprivate var binding: OutputReviewGate.OutputBinding {
        .init(sha256: sha256, derivation: derivation)
    }
}

/// Organizational half of the local content filter: prompt screening prevents known prohibited
/// requests, while every user-facing distribution path requires an affirmative review of the
/// exact PNG bytes that are about to leave managed storage. No decision or image leaves the Mac.
@MainActor
enum OutputReviewGate {
    enum ExportKind: String, Sendable, Hashable {
        case galleryImage
        case galleryBulk
        case galleryWithRecipe
        case saveCopy
        case dragAndDrop
        case finderCopy
        case foregroundCutout
        case localAIUpscale

        var alertLabel: String {
            switch self {
            case .galleryImage, .saveCopy: "image"
            case .galleryBulk: "Gallery images"
            case .galleryWithRecipe: "image and recipe"
            case .dragAndDrop: "dragged image"
            case .finderCopy: "Finder copy"
            case .foregroundCutout: "transparent cut-out"
            case .localAIUpscale: "AI-upscaled image"
            }
        }
    }

    struct OutputBinding: Sendable, Hashable {
        let sha256: String
        let derivation: PNGOutputProvenance.Derivation
    }

    /// Ordered, exact-byte checklist used by the modal review flow. The next item cannot be
    /// skipped or substituted, and completion is true only after every bound output was visible
    /// and explicitly confirmed in sequence.
    struct ReviewChecklist {
        private let outputs: [ReviewablePNG]
        private(set) var reviewedCount = 0

        init(outputs: [ReviewablePNG]) {
            self.outputs = outputs
        }

        var currentOutput: ReviewablePNG? {
            guard reviewedCount < outputs.count else { return nil }
            return outputs[reviewedCount]
        }

        var outputCount: Int { outputs.count }
        var isComplete: Bool { !outputs.isEmpty && reviewedCount == outputs.count }

        fileprivate func exactlyCompletes(_ candidate: [ReviewablePNG]) -> Bool {
            isComplete && outputs == candidate
        }

        mutating func confirmVisibleOutput(_ output: ReviewablePNG) throws {
            guard let expected = currentOutput, expected == output else {
                throw ReceiptError.outputBindingMismatch
            }
            reviewedCount += 1
        }
    }

    /// The opaque value is bound to exact output digests, derivations, kind, and count. The gate
    /// also records its nonce and removes it on first successful validation, so copying this value
    /// cannot authorize a second publication.
    struct ReviewReceipt: Sendable, Hashable {
        fileprivate let id: UUID
        fileprivate let bindings: [OutputBinding]
        fileprivate let kind: ExportKind
        fileprivate let outputCount: Int
    }

    enum ReceiptError: Error, Equatable, LocalizedError, Sendable {
        case invalidOrAlreadyUsed
        case outputBindingMismatch

        var errorDescription: String? {
            switch self {
            case .invalidOrAlreadyUsed:
                "The output review confirmation is invalid or has already been used. Review the output again."
            case .outputBindingMismatch:
                "The reviewed output changed before publication. Review the exact final output again."
            }
        }
    }

    private static var issuedReceipts: [UUID: ReviewReceipt] = [:]

    static func reviewBeforeExport(
        outputs: [ReviewablePNG],
        kind: ExportKind,
        previewPNG: Data? = nil
    ) -> ReviewReceipt? {
        guard !outputs.isEmpty else { return nil }
        if let previewPNG {
            guard outputs.count == 1, previewPNG == outputs[0].data else { return nil }
        }

        var checklist = ReviewChecklist(outputs: outputs)
        while let output = checklist.currentOutput {
            guard let image = NSImage(data: output.data) else { return nil }
            let ordinal = checklist.reviewedCount + 1
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = outputs.count == 1
                ? "Review AI-generated \(kind.alertLabel) before export"
                : "Review \(kind.alertLabel) · \(ordinal) of \(outputs.count)"
            let instruction = outputs.count == 1
                ? "Confirm that you reviewed this exact visible output and that it is lawful, safe, and compliant with the Krea 2 Acceptable Use Policy. The reviewed PNG includes AI provenance metadata."
                : "Review this exact output. Every image must be shown and confirmed separately before the batch can be authorized."
            alert.informativeText = instruction
                + "\n\nSHA-256 \(output.sha256)\nTransformation: \(output.derivation.rawValue)"
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
            imageView.layer?.cornerRadius = 8
            alert.accessoryView = imageView
            alert.addButton(withTitle: ordinal == outputs.count
                ? "Reviewed — Export"
                : "Reviewed — Next")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            do {
                try checklist.confirmVisibleOutput(output)
            } catch {
                return nil
            }
        }
        guard checklist.isComplete else { return nil }
        return issueReceipt(after: checklist, outputs: outputs, kind: kind)
    }

    static func consume(
        _ receipt: ReviewReceipt,
        outputs: [ReviewablePNG],
        kind: ExportKind
    ) throws {
        guard let issued = issuedReceipts.removeValue(forKey: receipt.id), issued == receipt else {
            throw ReceiptError.invalidOrAlreadyUsed
        }
        let bindings = outputs.map(\.binding)
        guard receipt.kind == kind,
              receipt.outputCount == outputs.count,
              receipt.bindings == bindings else {
            throw ReceiptError.outputBindingMismatch
        }
    }

    static func revoke(_ receipt: ReviewReceipt) {
        guard issuedReceipts[receipt.id] == receipt else { return }
        issuedReceipts.removeValue(forKey: receipt.id)
    }

    #if DEBUG
    /// Unit tests exercise the exact binding/consumption boundary without modal AppKit UI.
    static func reviewedForTesting(
        outputs: [ReviewablePNG],
        kind: ExportKind
    ) -> ReviewReceipt {
        issueReceipt(outputs: outputs, kind: kind)
    }

    static func receiptForTesting(
        after checklist: ReviewChecklist,
        outputs: [ReviewablePNG],
        kind: ExportKind
    ) -> ReviewReceipt? {
        issueReceipt(after: checklist, outputs: outputs, kind: kind)
    }
    #endif

    private static func issueReceipt(
        after checklist: ReviewChecklist,
        outputs: [ReviewablePNG],
        kind: ExportKind
    ) -> ReviewReceipt? {
        guard checklist.exactlyCompletes(outputs) else { return nil }
        return issueReceipt(outputs: outputs, kind: kind)
    }

    private static func issueReceipt(
        outputs: [ReviewablePNG],
        kind: ExportKind
    ) -> ReviewReceipt {
        let receipt = ReviewReceipt(
            id: UUID(),
            bindings: outputs.map(\.binding),
            kind: kind,
            outputCount: outputs.count)
        issuedReceipts[receipt.id] = receipt
        return receipt
    }
}
