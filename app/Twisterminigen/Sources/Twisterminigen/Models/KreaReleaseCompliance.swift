import Foundation
import Observation

/// Stable legal identifiers used by the UI, release bundler, and persisted acceptance receipt.
/// The SHA-256 is for `reference/krea-2/docs/KREA-2-COMMUNITY-LICENSE` at Krea license v1,
/// dated June 22, 2026. A changed upstream agreement deliberately invalidates old acceptance.
enum KreaLegal {
    static let licenseIdentifier = "Krea 2 Community License Agreement v1 (2026-06-22)"
    static let licenseSHA256 = "7cd975008d1b944452d1fca9e9a6099e5cd4c46d36fdc283c7691da9307fc29e"
    static let licenseURL = URL(string: "https://www.krea.ai/krea-2-licensing")!
    static let acceptableUsePolicyURL = URL(string: "https://www.krea.ai/krea-2-use-policy")!
    static let notice = "Krea 2 is licensed under the Krea 2 Community License Agreement. For more information, visit https://krea.ai/krea-2-licensing."

    static let localImplementationNotice = """
    Twisterminigen is an independent, modified MLX implementation for Apple silicon. It is not an
    official Krea product and is not endorsed by Krea. Model weights are downloaded separately and
    remain subject to the Krea 2 Community License Agreement and Acceptable Use Policy.
    """

    /// The release bundler places the complete agreement in the main macOS bundle. SwiftPM's raw
    /// command-line product has no app resource root, so development runs fall back to the official
    /// web copy while the distribution gate requires this local file.
    static func bundledLicenseURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "KREA-2-COMMUNITY-LICENSE", withExtension: "txt")
    }
}

struct KreaLicenseAcceptance: Codable, Equatable, Sendable {
    let licenseIdentifier: String
    let licenseSHA256: String
    let acceptableUsePolicyURL: String
    let acceptedAt: Date

    static func current(acceptedAt: Date = Date()) -> Self {
        Self(
            licenseIdentifier: KreaLegal.licenseIdentifier,
            licenseSHA256: KreaLegal.licenseSHA256,
            acceptableUsePolicyURL: KreaLegal.acceptableUsePolicyURL.absoluteString,
            acceptedAt: acceptedAt)
    }

    var matchesCurrentTerms: Bool {
        licenseIdentifier == KreaLegal.licenseIdentifier
            && licenseSHA256.caseInsensitiveCompare(KreaLegal.licenseSHA256) == .orderedSame
            && acceptableUsePolicyURL == KreaLegal.acceptableUsePolicyURL.absoluteString
    }
}

/// App-owned, revocable receipt. It contains no account identity and never leaves the Mac.
@MainActor
@Observable
final class KreaLicensePreferences {
    private static let defaultsKey = "krea-2-license-acceptance.v1"

    private let defaults: UserDefaults
    private(set) var acceptance: KreaLicenseAcceptance?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(KreaLicenseAcceptance.self, from: data),
           decoded.matchesCurrentTerms {
            acceptance = decoded
        } else {
            acceptance = nil
        }
    }

    var isAccepted: Bool { acceptance?.matchesCurrentTerms == true }

    func acceptCurrentTerms(at date: Date = Date()) {
        let receipt = KreaLicenseAcceptance.current(acceptedAt: date)
        acceptance = receipt
        if let data = try? JSONEncoder().encode(receipt) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func revoke() {
        acceptance = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    #if DEBUG
    /// Test-only construction keeps production Release initializers fail-closed without creating
    /// a CFPreferences suite or plist for every generated view model.
    static func acceptedForTesting() -> KreaLicensePreferences {
        let defaults = VolatileUserDefaults()
        let preferences = KreaLicensePreferences(defaults: defaults)
        preferences.acceptCurrentTerms(at: .distantPast)
        return preferences
    }
    #endif
}

/// A deterministic, local input safety layer for the open-weights deployment. It runs before
/// every render path (Generate, Queue, presets, and App Intent) and sends no prompt off-device.
/// Deliberately high-confidence rules reduce harmful use without treating ordinary artistic,
/// documentary, medical, or fictional vocabulary as an automatic violation.
enum ReasonableContentFilter {
    static let identifier = "twisterminigen.local-input-safety.v1"

    enum Category: String, Codable, CaseIterable, Sendable {
        case childSexualExploitation = "child sexual exploitation"
        case nonConsensualIntimateImagery = "non-consensual intimate imagery"
        case deceptiveImpersonation = "deceptive impersonation or election interference"
        case weaponsOrMassSurveillance = "weapons development or mass surveillance"
        case fraudOrManipulation = "fraud, spam, or false engagement"
        case threatsOrTargetedAbuse = "threats or targeted abuse"
        case explicitSexualContent = "sexually explicit content"
        case safetyCircumvention = "safety-filter circumvention"
    }

    struct Finding: Error, Equatable, LocalizedError, Sendable {
        let category: Category

        var errorDescription: String? {
            "The local Krea safety filter blocked this request for possible \(category.rawValue). Revise the prompt or use content that complies with the Krea 2 Acceptable Use Policy."
        }
    }

    static func validate(recipe: GenerationRecipe) throws {
        if let finding = firstFinding(in: screeningTexts(for: recipe)) { throw finding }
    }

    static func firstFinding(in texts: [String]) -> Finding? {
        for text in texts where !text.isEmpty {
            let value = normalized(text)
            guard !value.isEmpty else { continue }

            if containsAny(value, phrases: [
                "csam", "child pornography", "child porn", "sexualized minor",
                "sexualise a minor", "sexualize a minor",
            ]) || (containsAny(value, phrases: [
                "underage", "preteen", "minor", "little girl", "little boy",
            ]) && containsAny(value, phrases: [
                "porn", "pornographic", "sexually explicit", "sexualized", "nude", "naked",
                "genitals",
            ])) {
                return Finding(category: .childSexualExploitation)
            }

            if containsAny(value, phrases: [
                "revenge porn", "non consensual intimate", "nonconsensual intimate",
                "deepfake nude", "deepfake naked", "undress this person", "nudify",
                "intimate image without consent",
            ]) {
                return Finding(category: .nonConsensualIntimateImagery)
            }

            if containsAny(value, phrases: [
                "deceive voters", "mislead voters", "fake election result", "fake ballot",
                "voter suppression deepfake", "impersonate them to scam", "impersonate to defraud",
            ]) {
                return Finding(category: .deceptiveImpersonation)
            }

            if containsAny(value, phrases: [
                "weapon targeting system", "autonomous weapon targeting", "build a dirty bomb",
                "bomb making instructions", "military surveillance target", "mass surveillance",
                "track everyone without consent",
            ]) {
                return Finding(category: .weaponsOrMassSurveillance)
            }

            if containsAny(value, phrases: [
                "phishing login page", "forge an identity document", "fake reviews at scale",
                "generate spam accounts", "scam payment receipt",
            ]) {
                return Finding(category: .fraudOrManipulation)
            }

            if containsAny(value, phrases: [
                "credible death threat", "threaten this real person", "dox and threaten",
                "incite violence against",
            ]) {
                return Finding(category: .threatsOrTargetedAbuse)
            }

            if containsAny(value, phrases: [
                "hardcore pornography", "graphic sex act", "explicit pornographic scene",
                "sexually explicit pornography",
            ]) {
                return Finding(category: .explicitSexualContent)
            }

            if containsAny(value, phrases: [
                "bypass content filter", "bypass the content filter",
                "disable safety checker", "disable the safety checker",
                "circumvent moderation", "remove safety restrictions", "evade the safety filter",
            ]) {
                return Finding(category: .safetyCircumvention)
            }
        }
        return nil
    }

    static func screeningTexts(for recipe: GenerationRecipe) -> [String] {
        [
            recipe.prompts.positive,
            recipe.prompts.exactText ?? "",
        ] + recipe.regions.map(\.prompt)
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return scalars.reduce(into: "") { result, character in
            if character == " ", result.last == " " { return }
            result.append(character)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ value: String, phrases: [String]) -> Bool {
        let padded = " \(value) "
        return phrases.contains { phrase in
            padded.contains(" \(normalized(phrase)) ")
        }
    }
}
