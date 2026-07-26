import AppKit
import Observation
@preconcurrency import UserNotifications

/// Best-effort end-of-queue feedback. Notification permission is requested only when the user
/// intentionally starts a queue; VoiceOver feedback and a fallback chime do not require it.
enum QueueNotifier {
    enum Action: String, Equatable, Sendable {
        case openGallery
        case remix
    }

    struct Route: Identifiable, Equatable, Sendable {
        let id: UUID
        let action: Action
        let generationID: UUID?

        init(id: UUID = UUID(), action: Action, generationID: UUID?) {
            self.id = id
            self.action = action
            self.generationID = generationID
        }
    }

    private static let readyCategoryID = "queue-ready"
    private static let openOnlyCategoryID = "queue-open-only"
    private static let openGalleryActionID = "open-gallery"
    private static let remixActionID = "remix"
    private static let generationIDKey = "generation-id"

    /// Registers foreground presentation and notification actions. Safe for SwiftPM builds that
    /// have no bundle identifier: those builds still receive VoiceOver and fallback-sound feedback.
    static func installDelegate() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = QueueNotificationDelegate.shared

        let openGallery = UNNotificationAction(
            identifier: openGalleryActionID,
            title: "Open Gallery",
            options: [.foreground])
        let remix = UNNotificationAction(
            identifier: remixActionID,
            title: "Remix",
            options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: readyCategoryID,
                actions: [openGallery, remix],
                intentIdentifiers: [],
                options: []),
            UNNotificationCategory(
                identifier: openOnlyCategoryID,
                actions: [openGallery],
                intentIdentifiers: [],
                options: []),
        ])
    }

    /// Ask at the deliberate start of Queue, never at launch or after an image is already ready.
    static func prepareForQueueStart() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    @MainActor
    static func notifyFinished(count: Int, generationID: UUID?) {
        let message = count == 1
            ? "Queue finished — 1 image is ready."
            : "Queue finished — \(count) images are ready."
        announce(message)
        deliver(
            title: "Queue finished",
            body: message,
            generationID: generationID)
    }

    @MainActor
    static func notifyFailure(_ message: String, generationID: UUID?) {
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessibleMessage = body.isEmpty ? "The queue stopped because of an error." : body
        announce("Queue error. \(accessibleMessage)")
        deliver(
            title: "Queue needs attention",
            body: accessibleMessage,
            generationID: generationID)
    }

    static func action(for identifier: String) -> Action? {
        switch identifier {
        case remixActionID:
            return .remix
        case openGalleryActionID, UNNotificationDefaultActionIdentifier:
            return .openGallery
        default:
            return nil
        }
    }

    fileprivate static func route(actionIdentifier: String, generationIDText: String?) {
        guard let action = action(for: actionIdentifier) else { return }
        let route = Route(
            action: action,
            generationID: generationIDText.flatMap(UUID.init(uuidString:)))
        Task { @MainActor in
            QueueNotificationRouter.shared.enqueue(route)
        }
    }

    @MainActor
    private static func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: message])
    }

    @MainActor
    private static func deliver(title: String, body: String, generationID: UUID?) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSSound(named: "Glass")?.play()
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            else {
                Task { @MainActor in NSSound(named: "Glass")?.play() }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = generationID == nil
                ? openOnlyCategoryID
                : readyCategoryID
            if let generationID {
                content.userInfo = [generationIDKey: generationID.uuidString]
            }
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil))
        }
    }

    fileprivate static func generationIDText(from notification: UNNotification) -> String? {
        notification.request.content.userInfo[generationIDKey] as? String
    }
}

/// Buffers a notification action until the root SwiftUI view consumes it. Unlike a one-shot
/// NotificationCenter post, this survives the cold-launch interval before ContentView subscribes.
@MainActor
@Observable
final class QueueNotificationRouter {
    static let shared = QueueNotificationRouter()

    private(set) var pendingRoute: QueueNotifier.Route?

    func enqueue(_ route: QueueNotifier.Route) {
        pendingRoute = route
    }

    func takePendingRoute() -> QueueNotifier.Route? {
        defer { pendingRoute = nil }
        return pendingRoute
    }
}

/// Presents banners while Twisterminigen is frontmost and routes action taps back to SwiftUI.
private final class QueueNotificationDelegate: NSObject,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    static let shared = QueueNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        QueueNotifier.route(
            actionIdentifier: response.actionIdentifier,
            generationIDText: QueueNotifier.generationIDText(from: response.notification))
        completionHandler()
    }
}
