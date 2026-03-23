import AppKit
import ComposableArchitecture
import Foundation
import UserNotifications

/// Posts macOS desktop notifications via UNUserNotificationCenter.
/// Handles permission requests and focus-based suppression.
final class NotificationService: NSObject, Sendable, UNUserNotificationCenterDelegate {
    /// Callback when user taps "Open" on a notification. (paneID, workspaceID)
    nonisolated(unsafe) var onOpenPane: ((UUID, UUID) -> Void)?

    private static let categoryID = "nex-agent"
    private static let openActionID = "open"
    private static let dismissActionID = "dismiss"

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    /// Register notification categories with action buttons.
    private func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: Self.openActionID,
            title: "Open",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: Self.dismissActionID,
            title: "Dismiss",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [openAction, dismissAction],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Request notification permission. Call once on app launch.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                print("NotificationService: permission error — \(error)")
            }
        }
    }

    /// Post a desktop notification.
    /// - Parameters:
    ///   - title: Notification title
    ///   - body: Notification body text
    ///   - paneID: The pane that triggered this notification (used as identifier for dedup)
    ///   - workspaceID: The workspace owning this pane (for navigation on tap)
    func post(title: String, body: String, paneID: UUID, workspaceID: UUID? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID

        var userInfo: [String: String] = ["paneID": paneID.uuidString]
        if let workspaceID {
            userInfo["workspaceID"] = workspaceID.uuidString
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: "nex-\(paneID.uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("NotificationService: post error — \(error)")
            }
        }
    }

    /// Remove a delivered notification for a specific pane.
    func removeNotification(for paneID: UUID) {
        let identifier = "nex-\(paneID.uuidString)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when the app is in the foreground.
    /// Suppression is handled at the call site (AppReducer checks focus state).
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Handle notification action button taps.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case Self.openActionID, UNNotificationDefaultActionIdentifier:
            guard let paneIDString = userInfo["paneID"] as? String,
                  let paneID = UUID(uuidString: paneIDString),
                  let workspaceIDString = userInfo["workspaceID"] as? String,
                  let workspaceID = UUID(uuidString: workspaceIDString) else { return }

            await MainActor.run {
                NSApp.activate()
                onOpenPane?(paneID, workspaceID)
            }

        case Self.dismissActionID:
            break // Just dismiss, nothing to do

        default:
            break
        }
    }
}

// MARK: - TCA Dependency

extension NotificationService: DependencyKey {
    static let liveValue = NotificationService()
    static let testValue = NotificationService()
}

extension DependencyValues {
    var notificationService: NotificationService {
        get { self[NotificationService.self] }
        set { self[NotificationService.self] = newValue }
    }
}
