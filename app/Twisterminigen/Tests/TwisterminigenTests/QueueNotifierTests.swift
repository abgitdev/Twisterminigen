import Testing
@preconcurrency import UserNotifications
@testable import Twisterminigen

@Suite("Queue notification routing")
struct QueueNotifierTests {
    @Test("Actions route to Gallery or Remix and ignore dismissals")
    func actionMapping() {
        #expect(QueueNotifier.action(for: "open-gallery") == .openGallery)
        #expect(QueueNotifier.action(for: "remix") == .remix)
        #expect(QueueNotifier.action(for: UNNotificationDefaultActionIdentifier) == .openGallery)
        #expect(QueueNotifier.action(for: UNNotificationDismissActionIdentifier) == nil)
        #expect(QueueNotifier.action(for: "future-action") == nil)
    }

    @MainActor
    @Test("Cold-launch routes wait until the root view consumes them")
    func bufferedRoute() throws {
        let router = QueueNotificationRouter()
        let route = QueueNotifier.Route(
            action: .remix,
            generationID: UUID())

        router.enqueue(route)
        #expect(router.pendingRoute == route)
        #expect(router.takePendingRoute() == route)
        #expect(router.pendingRoute == nil)
        #expect(router.takePendingRoute() == nil)
    }

    @MainActor
    @Test("Only the immutable queue-run outcome drives terminal feedback")
    func terminalOutcome() {
        let generationID = UUID()
        #expect(GenerateViewModel.queueTerminalNotification(
            totalCount: 2,
            completedCount: 2,
            remainingCount: 0,
            failureMessage: nil,
            generationID: generationID
        ) == .finished(count: 2, generationID: generationID))

        #expect(GenerateViewModel.queueTerminalNotification(
            totalCount: 2,
            completedCount: 1,
            remainingCount: 1,
            failureMessage: "  Gallery write failed.  ",
            generationID: generationID
        ) == .failed(message: "Gallery write failed.", generationID: generationID))

        // An intentional stop leaves work pending and has no failure owned by this queue run.
        #expect(GenerateViewModel.queueTerminalNotification(
            totalCount: 2,
            completedCount: 1,
            remainingCount: 1,
            failureMessage: nil,
            generationID: generationID
        ) == nil)
    }
}
