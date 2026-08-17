import UIKit
import UserNotifications
import Arsel

/// Initializes the SDK exactly as an integrator would — once, early — and wires the
/// notification delegate the way the SDK's quickstart prescribes.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Before launch finishes, or taps that cold-start the app are lost to everyone.
        UNUserNotificationCenter.current().delegate = self

        Arsel.initialize(config: ArselConfig(
            clientKey: HarnessConfig.clientKey,
            baseUrl: HarnessConfig.baseUrl,
            // Verbose so the whole flow is visible in the Xcode console.
            logLevel: .debug,
            appGroupId: HarnessConfig.appGroupId,
            keychainAccessGroup: HarnessConfig.keychainAccessGroup))
        SdkEventLog.shared.log(
            "Arsel.initialize(clientKey=\(HarnessConfig.clientKeyPreview), baseUrl=\(HarnessConfig.baseUrl))")

        // Registration is not consent: ask APNs for a token at launch. The permission
        // prompt is a separate, user-chosen moment.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        HarnessState.shared.apnsTokenHex = hex
        SdkEventLog.shared.log("APNs token acquired (\(hex.count) hex chars)")
        Arsel.setPushToken(apns: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on simulators that cannot reach APNs; real delivery needs a device.
        SdkEventLog.shared.log("APNs registration FAILED: \(error.localizedDescription)")
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let message = Arsel.handleNotificationResponse(response) {
            // The engagement is already reported (opened / clicked / dismissed — exactly one).
            // Deep-link routing is the host's job; the harness just shows what it got.
            SdkEventLog.shared.log(
                "tap: mid=\(message.messageId) deepLink=\(message.deepLink ?? "-")")
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if let message = Arsel.handleForegroundNotification(notification) {
            SdkEventLog.shared.log("foreground push: mid=\(message.messageId) — displayed engagement reported")
        }
        completionHandler([.banner, .list, .sound])
    }
}

/// Host-side facts the delegate learns and the screen shows. The APNs token is the host's
/// own (it arrives at the delegate, not through the SDK) — everything SDK-owned on screen
/// still comes from `diagnostics()`.
final class HarnessState: ObservableObject {
    static let shared = HarnessState()

    @Published var apnsTokenHex: String?
}
