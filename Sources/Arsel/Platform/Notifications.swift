import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UserNotifications)
extension Arsel {
    /// Ask for notification permission. **Call this from a moment that explains
    /// itself** — a settings screen, an onboarding step the user chose — never from
    /// cold start: iOS shows the system prompt exactly once, and a decline is
    /// unrecoverable without a trip to the Settings app.
    ///
    /// On grant, registers with APNs so the token arrives at your
    /// `didRegisterForRemoteNotificationsWithDeviceToken`. Either way, the
    /// resulting permission state is reported to the backend — a `DENIED` device
    /// still has its contact and events.
    @discardableResult
    public static func requestNotificationPermission(
        options: UNAuthorizationOptions = [.alert, .badge, .sound]
    ) async -> Bool {
        guard core != nil else {
            print("[arsel] requestNotificationPermission() called before initialize() — ignoring")
            return false
        }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: options)) ?? false
        refreshPermissionState()
        #if canImport(UIKit)
        if granted {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
        #endif
        return granted
    }

    /// Poll `UNNotificationSettings` and report the five-state permission fact the
    /// backend records. Called automatically at initialize and on each foreground.
    static func refreshPermissionState() {
        guard core != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            core?.setEnablementStatus(enablementStatus(from: settings.authorizationStatus))
        }
    }

    static func enablementStatus(from status: UNAuthorizationStatus) -> ArselEnablementStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .provisional: return .provisional
        #if !os(macOS)
        case .ephemeral: return .authorized
        #endif
        @unknown default: return .notDetermined
        }
    }

    // MARK: Notification-center delegate helpers

    /// Whether a received notification is Arsel's, for hosts that multiplex
    /// several push sources in one delegate.
    public static func isArselNotification(userInfo: [AnyHashable: Any]) -> Bool {
        ArselPushMessage.isArsel(userInfo: userInfo)
    }

    /// Call from `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    ///
    /// Engagements exactly one engagement per tap — `opened` for the notification body,
    /// `clicked` for an action button, `dismissed` for an explicit dismissal —
    /// never two for one gesture, or the counters become identical by construction.
    ///
    /// Returns the parsed message when it was Arsel's (deep-link routing is the
    /// host's job — the SDK never opens URLs), or nil when the notification belongs
    /// to someone else.
    @discardableResult
    public static func handleNotificationResponse(
        _ response: UNNotificationResponse
    ) -> ArselPushMessage? {
        let userInfo = response.notification.request.content.userInfo
        guard let core, let message = ArselPushMessage.from(userInfo: userInfo) else { return nil }

        var record = EngagementRecord(
            messageId: message.messageId,
            eventType: .opened,
            timestampMs: nowMillis(),
            signature: message.signature,
            signatureKeyId: message.keyId,
            deepLink: message.deepLink)
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            break // opened, as built
        case UNNotificationDismissActionIdentifier:
            record.eventType = .dismissed
            record.deepLink = nil
        default:
            record.eventType = .clicked
            record.actionId = response.actionIdentifier
            record.deepLink = message.actions
                .first { $0.actionId == response.actionIdentifier }?.deepLink ?? message.deepLink
        }
        core.engagement(record)
        return message
    }

    /// Call from `userNotificationCenter(_:willPresent:withCompletionHandler:)`.
    /// Engagements `displayed` for an Arsel push shown while the app is foregrounded,
    /// and returns the parsed message (nil when not Arsel's). Presentation options
    /// remain the host's decision.
    @discardableResult
    public static func handleForegroundNotification(
        _ notification: UNNotification
    ) -> ArselPushMessage? {
        let userInfo = notification.request.content.userInfo
        guard let core, let message = ArselPushMessage.from(userInfo: userInfo) else { return nil }
        core.engagement(EngagementRecord(
            messageId: message.messageId,
            eventType: .displayed,
            timestampMs: nowMillis(),
            signature: message.signature,
            signatureKeyId: message.keyId))
        return message
    }
}
#else
extension Arsel {
    static func refreshPermissionState() {}
}
#endif
