# Push notifications

Tokens, permission, engagement, rich media — and what iOS does and does not guarantee.

## APNs, directly

Arsel talks to Apple itself. There is no Firebase project in the iOS path and nothing to link:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    Arsel.setPushToken(apns: deviceToken)
}
```

For those tokens to be deliverable, upload your APNs auth key once under **Push → iOS** in the
dashboard: the `.p8`, its Key ID, your Team ID and your bundle ID.

If your app runs Firebase Messaging for its own reasons, leave it be — Arsel neither links it nor
uses its token.

### Sandbox and production

Apple runs two hosts, and a token minted for one is rejected by the other. The SDK resolves which
your build was signed for by reading `aps-environment` out of the embedded provisioning profile —
not `#if DEBUG`, which describes how the code was compiled rather than how it was signed, and so
would mislabel a TestFlight build compiled with debug symbols. It reports the result as
`apnsEnvironment` at registration, so one uploaded key serves debug, TestFlight and App Store
builds.

## Registration is not consent

The SDK registers the device as soon as it has a token — before any permission prompt, and on
devices where permission was denied. Registration creates the device row; **consent is the separate
five-state `enablementStatus` fact** (`AUTHORIZED` / `DENIED` / `NOT_DETERMINED` / `PROVISIONAL` /
`UNAUTHORIZED`), polled and reported automatically at initialize, on each foreground, and after the
permission prompt. A `DENIED` device still has its contact and its events.

At registration the backend returns a **device secret**, exactly once. The SDK stores it in the
Keychain (`AfterFirstUnlockThisDeviceOnly`) and presents it as `X-Arsel-Device-Auth` on every
authenticated call. You never touch it.

## Permission UX

`initialize()` never prompts. iOS shows the system dialog **once per install** — spend it from a
moment the user chose:

```swift
Button("Enable order updates") {
    Task {
        let granted = await Arsel.requestNotificationPermission()
        // granted == false is a normal outcome, not an error.
    }
}
```

On grant the SDK calls `registerForRemoteNotifications()` for you; your
`didRegisterForRemoteNotificationsWithDeviceToken` then feeds `setPushToken(apns:)` (raw-APNs
hosts). Provisional authorization (`.provisional`) is reported as `PROVISIONAL` — those devices
receive quietly and count separately.

## Engagement engagements

Wire the two `UNUserNotificationCenterDelegate` methods (see the
[quickstart](quickstart.md#6-wire-the-notification-delegate)):

| User did | Helper | Engagement |
| --- | --- | --- |
| Push arrived (app foregrounded) | `handleForegroundNotification(_:)` | `displayed` |
| Push arrived (background, NSE installed) | the extension | `delivered` |
| Tapped the body | `handleNotificationResponse(_:)` | `opened` |
| Tapped an action button | `handleNotificationResponse(_:)` | `clicked` (+ `actionId`) |
| Explicitly dismissed | `handleNotificationResponse(_:)` | `dismissed` |

**One engagement per tap** — a tap is `opened` *or* `clicked`, never both; otherwise the two counters
become identical by construction. Engagements ride the same durable queue as events and echo the
payload's `arsel_sig`/`arsel_kid` so the backend can verify they came from the device the message
was sent to.

Both helpers return the parsed `ArselPushMessage` (or nil when the push is not Arsel's, so
multiplexing hosts can fall through to their own handling). Deep-link **routing is yours** — the
SDK reports the engagement and hands you `message.deepLink`; it never opens URLs.

## Notification Service Extension

Two things only an NSE can do: engagement `delivered` when a push arrives with the app dead, and attach
`arsel_image` so rich pushes render. Both are optional; everything else works without it.

1. Xcode → add a **Notification Service Extension** target; link **`ArselNotificationExtension`** into it
   (not the full SDK).
2. Give the app and the extension a shared **App Group**, and a shared **Keychain access group**
   (for the device secret that authenticates the engagement). Pass both to the SDK:

```swift
ArselConfig(
    clientKey: "pub_…", baseUrl: "https://api.arsel.sa",
    appGroupId: "group.com.example.app",
    keychainAccessGroup: "TEAMID.com.example.shared")
```

3. In the extension:

```swift
import ArselNotificationExtension
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        if ArselNotificationExtensionHandler.didReceive(
            request, appGroupId: "group.com.example.app", withContentHandler: contentHandler) {
            return
        }
        contentHandler(request.content)   // not Arsel's — your own logic here
    }
}
```

**Honesty about the NSE:** iOS only launches it when the APNs payload carries
`mutable-content: 1`, may skip it under low power or storage pressure, and kills it at ~30 seconds.
`delivered` is therefore a *floor*, not a total — the backend treats it that way. A missed
`delivered` engagement is an accepted loss; the extension deliberately does not queue-and-retry.
Without the shared Keychain access group the extension still attaches media but cannot engagement.

## Payload reference

The backend's `arsel_*` data keys arrive in `userInfo`:
`arsel_v`, `arsel_mid`, `arsel_sig`, `arsel_kid`, `arsel_title`, `arsel_body`, `arsel_image`,
`arsel_deep_link`, `arsel_channel_id`, `arsel_actions`, `arsel_collapse_id`. `ArselPushMessage.from(userInfo:)`
parses them; unknown keys are ignored. `arsel_channel_id` is Android's notification-channel concept
and has no iOS meaning.
