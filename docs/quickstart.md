# Quickstart

From nothing to events flowing and a device registered for push.

## 1. Add the package

Xcode → *File → Add Package Dependencies…* → the repository URL. Add **`Arsel`** to your app
target. (Leave `ArselNotificationExtension` for later — it is only for a Notification Service Extension,
[push-notifications.md](push-notifications.md#notification-service-extension).)

## 2. Initialize

Once, early. `initialize` is idempotent and never prompts for anything.

```swift
import Arsel

// UIKit
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Arsel.initialize(config: ArselConfig(
        clientKey: "pub_…",
        baseUrl: "https://api.arsel.sa"))
    return true
}

// SwiftUI
@main
struct MyApp: App {
    init() {
        Arsel.initialize(config: ArselConfig(clientKey: "pub_…", baseUrl: "https://api.arsel.sa"))
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

`clientKey` is the org's **publishable** key (Arsel dashboard → push setup). It is safe in an app
binary; your secret API key is not.

## 3. Track and identify

```swift
Arsel.track("product.viewed", properties: ["sku": "A-1023", "price": 149.99])

// On login — everything tracked before this merges onto the contact:
Arsel.identify(externalId: user.id)

// On logout:
Arsel.reset()
```

That is the whole events API. It needs no permission, no token, no push setup, and it survives
offline stretches and force-quits — events are persisted before any send.

**Verify:** trigger a few `track()` calls, then check the org's event stream in the Arsel
dashboard. On a device with no connectivity, `Arsel.diagnostics()?.pendingRequests` shows the
queue holding them.

## 4. Push — token first

Registration is not consent: do this at launch. The permission prompt comes separately.

```swift
// You call this yourself when you're ready to hold a token — or let
// requestNotificationPermission() do it on grant.
UIApplication.shared.registerForRemoteNotifications()

func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Arsel.setPushToken(apns: deviceToken)
}
```

Arsel sends to iOS through Apple directly, so there is no Firebase project involved. Upload your
APNs auth key once under **Push → iOS** in the dashboard — the `.p8`, its Key ID, your Team ID and
your bundle ID — and these tokens become deliverable.

## 5. Push — ask for permission, from a moment that explains itself

```swift
Button("Enable order updates") {
    Task { await Arsel.requestNotificationPermission() }
}
```

Never call this from cold start. iOS shows the system prompt **once**; a decline is unrecoverable
without a trip to the Settings app. On grant the SDK registers with APNs for you and reports the
permission state either way.

## 6. Wire the notification delegate

```swift
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let message = Arsel.handleNotificationResponse(response) {
            // The engagement is already reported. Routing is yours:
            if let deepLink = message.deepLink, let url = URL(string: deepLink) {
                // navigate
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Arsel.handleForegroundNotification(notification)
        completionHandler([.banner, .list, .sound])
    }
}
```

Set the delegate before the app finishes launching (`UNUserNotificationCenter.current().delegate = self`
in `didFinishLaunching`), or taps that cold-start the app are lost to everyone, not just Arsel.

## 7. Verify end to end

1. `Arsel.diagnostics()` → `hasPushToken: true`, `hasDeviceSecret: true` (registration
   confirmed), `enablementStatus: "AUTHORIZED"`.
2. Send a test push from the Arsel dashboard.
3. Tap it — the campaign's `opened` count moves.

If something doesn't, `diagnostics()` is designed to be pasted into a support ticket: it carries
status and the last HTTP outcome, and no secrets.
