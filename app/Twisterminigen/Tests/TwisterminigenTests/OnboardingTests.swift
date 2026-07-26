import Foundation
import Testing
@testable import Twisterminigen

@Suite("Onboarding launch policy")
struct OnboardingTests {
    @Test("Missing weights route a first launch to Models")
    func routeUsesReadiness() {
        #expect(OnboardingLaunchPolicy.initialSection(modelsReady: false) == .models)
        #expect(OnboardingLaunchPolicy.initialSection(modelsReady: true) == .generate)
        #expect(OnboardingLaunchPolicy.initialSection(
            modelsReady: false,
            environmentOverride: "gallery") == .gallery)
        #expect(OnboardingLaunchPolicy.initialSection(
            modelsReady: false,
            environmentOverride: "not-a-section") == .models)
    }

    @Test("Skip and Finish share one durable seen flag")
    func seenPersistence() {
        let defaults = VolatileUserDefaults()

        #expect(OnboardingLaunchPolicy.shouldPresent(defaults: defaults))
        OnboardingLaunchPolicy.markSeen(defaults: defaults)
        #expect(!OnboardingLaunchPolicy.shouldPresent(defaults: defaults))
    }

    @Test("Tour covers every primary workflow and starts with the license render gate")
    @MainActor
    func tourContentIsCompleteAndOrdered() {
        let pages = OnboardingView.pages
        #expect(pages.count == 12)
        #expect(pages.map(\.accessibilityID) == [
            "license-models",
            "generate",
            "render-controls",
            "remix",
            "regional-prompts",
            "lora",
            "queue",
            "presets",
            "gallery",
            "image-tools",
            "system-storage",
            "privacy",
        ])

        let firstPageText = ([pages[0].intro] + pages[0].rows.map(\.detail))
            .joined(separator: " ")
        #expect(firstPageText.contains("cannot be downloaded or used for rendering"))
        #expect(firstPageText.contains("Select the agreement checkbox"))
        #expect(firstPageText.contains("Accept terms"))

        let allText = pages
            .flatMap { [$0.title, $0.intro] + $0.rows.flatMap { [$0.term, $0.detail] } }
            .joined(separator: " ")
        #expect(allText.contains("does not train them"))
        #expect(allText.contains("Clear canvas never deletes Gallery"))
        #expect(allText.contains("Character Sheet"))
        #expect(allText.contains("Storage Manager"))
    }
}
