import Testing
@testable import Twisterminigen

@Suite("App foreground launch policy", .serialized)
@MainActor
struct AppLaunchActivationTests {
    @Test("Only the first visible window requests foreground")
    func purePolicy() {
        var policy = AppLaunchActivationPolicy()

        let hiddenBefore = policy.shouldRequestForeground(windowIsVisible: false)
        let firstVisible = policy.shouldRequestForeground(windowIsVisible: true)
        let secondVisible = policy.shouldRequestForeground(windowIsVisible: true)
        let hiddenAfter = policy.shouldRequestForeground(windowIsVisible: false)

        #expect(!hiddenBefore)
        #expect(firstVisible)
        #expect(!secondVisible)
        #expect(!hiddenAfter)
        #expect(policy.hasRequestedForeground)
    }

    @Test("A background App Intent launch makes no AppKit activation calls")
    func injectedBackgroundLaunch() {
        var regularPolicyRequests = 0
        var activationRequests = 0
        AppForegroundActivation.installForTesting(.init(
            setRegularPolicy: { regularPolicyRequests += 1 },
            activate: { activationRequests += 1 }))
        defer { AppForegroundActivation.resetAfterTesting() }

        AppForegroundActivation.applicationDidFinishLaunching()
        #expect(regularPolicyRequests == 0)
        #expect(activationRequests == 0)

        AppForegroundActivation.windowVisibilityDidChange(isVisible: false)
        #expect(regularPolicyRequests == 0)
        #expect(activationRequests == 0)

        AppForegroundActivation.windowVisibilityDidChange(isVisible: true)
        AppForegroundActivation.windowVisibilityDidChange(isVisible: true)
        #expect(regularPolicyRequests == 1)
        #expect(activationRequests == 1)
    }
}
