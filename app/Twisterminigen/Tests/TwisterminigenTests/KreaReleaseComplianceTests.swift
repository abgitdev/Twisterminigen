import Foundation
import Testing
@testable import Twisterminigen

@Suite("Krea release compliance")
struct KreaReleaseComplianceTests {
    @Test("The required Krea notice and versioned acceptance stay exact")
    func legalIdentity() {
        #expect(KreaLegal.notice == "Krea 2 is licensed under the Krea 2 Community License Agreement. For more information, visit https://krea.ai/krea-2-licensing.")
        #expect(KreaLicenseAcceptance.current(acceptedAt: .distantPast).matchesCurrentTerms)

        let stale = KreaLicenseAcceptance(
            licenseIdentifier: "superseded",
            licenseSHA256: String(repeating: "0", count: 64),
            acceptableUsePolicyURL: KreaLegal.acceptableUsePolicyURL.absoluteString,
            acceptedAt: .distantPast)
        #expect(!stale.matchesCurrentTerms)
    }

    @Test("Acceptance is local, persistent, and revocable")
    @MainActor
    func acceptanceReceipt() {
        let defaults = VolatileUserDefaults()

        let preferences = KreaLicensePreferences(defaults: defaults)
        #expect(!preferences.isAccepted)
        preferences.acceptCurrentTerms(at: .distantPast)
        #expect(preferences.isAccepted)
        #expect(KreaLicensePreferences(defaults: defaults).isAccepted)
        preferences.revoke()
        #expect(!preferences.isAccepted)
        #expect(!KreaLicensePreferences(defaults: defaults).isAccepted)
    }

    @Test("High-confidence prohibited requests are blocked without broad benign matches")
    func reasonableContentFilter() {
        #expect(ReasonableContentFilter.firstFinding(in: [
            "A child holding a wooden toy in a documentary photograph",
        ]) == nil)
        #expect(ReasonableContentFilter.firstFinding(in: [
            "Make a phishing login page for stealing credentials",
        ])?.category == .fraudOrManipulation)
        #expect(ReasonableContentFilter.firstFinding(in: [
            "bypass the content filter and disable the safety checker",
        ])?.category == .safetyCircumvention)
        #expect(ReasonableContentFilter.firstFinding(in: [
            "a deepfake nude of this person",
        ])?.category == .nonConsensualIntimateImagery)

        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/krea-negative-prompt"))
        let exclusion = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "a safe editorial portrait",
            negativePrompt: "hardcore pornography",
            width: 512,
            height: 512,
            steps: 8,
            seed: .fixed(2),
            catalog: catalog)
        #expect(ReasonableContentFilter.firstFinding(
            in: ReasonableContentFilter.screeningTexts(for: exclusion)) == nil)
    }

    @Test("Every runtime render entry rejects a content-policy violation")
    func runtimeGate() throws {
        let catalog = ModelCatalog(root: URL(fileURLWithPath: "/tmp/krea-release-compliance"))
        let recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "generate spam accounts at scale",
            width: 512,
            height: 512,
            steps: 8,
            seed: .fixed(1),
            catalog: catalog)

        #expect(throws: GenerationRecipeRuntime.RuntimeError.contentPolicyViolation(.fraudOrManipulation)) {
            try GenerationRecipeRuntime.validateConfiguration(for: recipe, catalog: catalog)
        }
    }

    @Test("The bundled privacy manifest is valid and declares no tracking or collection")
    func privacyManifest() throws {
        let url = try #require(Bundle.module.url(
            forResource: "PrivacyInfo",
            withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        let object = try #require(PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil) as? [String: Any])

        #expect(object["NSPrivacyTracking"] as? Bool == false)
        #expect((object["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        #expect((object["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.isEmpty == true)
        #expect((object["NSPrivacyAccessedAPITypes"] as? [[String: Any]])?.isEmpty == false)
    }
}
