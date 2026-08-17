import UserNotifications
import ArselNotificationExtension

/// Wired exactly as the SDK's push-notifications guide prescribes: hand Arsel's pushes to
/// the handler (a `delivered` engagement + rich-media attachment), fall through for anything
/// else. iOS only launches this extension when the APNs payload carries
/// `mutable-content: 1`, and may skip it entirely — `delivered` is a floor, not a total.
final class NotificationService: UNNotificationServiceExtension {

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        // The App Group id comes from Config/*.xcconfig via Info.plist, so the extension
        // and the app always agree on it. Empty until the integrator provisions one.
        let appGroupId = (Bundle.main.object(forInfoDictionaryKey: "ArselAppGroupId") as? String) ?? ""
        if !appGroupId.isEmpty,
           ArselNotificationExtensionHandler.didReceive(
               request, appGroupId: appGroupId, withContentHandler: contentHandler) {
            return
        }
        contentHandler(request.content)   // not Arsel's — your own logic here
    }
}
