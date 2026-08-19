# In-App Messaging — iOS SDK Contract

**Status:** backend shipped 2026-08-17. SDK side not started.
**Canonical spec:** `IN-APP-MESSAGING-WIRE-CONTRACT.md` at the platform root. This file is the iOS-specific reading of it.

---

## 1. What this is, and why it is not push

Push is delivered by APNs whether or not the app is open. An in-app message is **drawn by the app itself, while the user is in it**. There is no APNs in the path and nothing is ever "delivered".

1. The SDK fetches a **bundle** — every message this device may currently show — on foreground, and caches it.
2. The user does something; the SDK matches it against each message's **trigger**.
3. The SDK applies the **frequency caps** locally and draws the winner.
4. The SDK reports **impression / click / dismiss** beacons.

Audience, consent, campaign window, grant expiry and lifetime caps are all resolved server-side before a message enters the bundle. The device decides *when*, never *who qualifies*.

**iOS starts from the strongest position of the three platforms**: `track()` and `SessionTracker` already exist, so all three trigger types work from day one. What is missing is only the view layer.

---

## 2. Endpoints

### 2.1 Bundle

```
GET {baseUrl}/api/v1/orgs/{clientKey}/in-app/bundle?installationId={id}
Headers:
  X-Arsel-Device-Auth: <deviceSecret>    // required
  X-Arsel-SDK: ios/<version>             // required — gates capability
  If-None-Match: "<bundleVersion>"       // optional
```

`200` returns the bundle, `304` means the cached copy stands.

```jsonc
{
  "contractVersion": 1,
  "bundleVersion": "7f3c1a9e",
  "ttlSeconds": 900,
  "messages": [
    {
      "campaignId": "…",
      "messageId": "…",                 // echo on every beacon
      "variantKey": "default",
      "priority": 100,
      "expiresAt": "2026-09-01T00:00:00Z",   // nullable
      "trigger": {
        "type": "APP_OPEN" | "SCREEN_VIEW" | "CUSTOM_EVENT",
        "eventName": "cart.viewed",
        "properties": { "tier": "gold" }     // equality, AND-ed
      },
      "displayRules": {
        "maxPerSession": 1, "maxLifetime": 3,
        "minSecondsBetween": 86400, "delaySeconds": 0
      },
      "layout": "MODAL",
      "content": {
        "headline": "…", "body": "…", "imageUrl": "https://…",
        "backgroundColor": "#FFFFFF", "textColor": "#101010",
        "showCloseButton": true
      },
      "buttons": [
        { "buttonId": "cta_primary", "label": "Shop now",
          "action": "DEEP_LINK", "value": "myapp://cart", "style": "PRIMARY" }
      ]
    }
  ]
}
```

Add the paths to `Wire.swift` alongside `subscriptionsPath` and `engagementsPath`. Refetch on foreground (respecting `ttlSeconds`) and on the sync ping. Never poll.

### 2.2 Beacons

```
POST {baseUrl}/api/v1/orgs/{clientKey}/in-app/events
Headers: X-Arsel-Device-Auth, X-Arsel-SDK
{
  "installationId": "…",
  "events": [                              // max 50, matching engagementBatchMax
    {
      "messageId": "…",                    // required
      "campaignId": "…",                   // required
      "eventType": "impression" | "clicked" | "dismissed" | "expired",
      "timestamp": "2026-08-17T10:03:22.581Z",
      "buttonId": "cta_primary",           // clicked only
      "triggerEventName": "cart.viewed",
      "visibleSeconds": 4                  // dismissed only
    }
  ]
}
→ 202 { "accepted": n, "duplicates": n, "rejected": n }
```

Route these through the existing `RequestQueue` and `Drainer` — they already provide disk durability, retry and process-death survival.

**No `sent`, `delivered` or `failed`.** Nothing was sent; `impression` is the denominator for every rate.

### 2.3 Sync ping

A push may arrive carrying data key **`arsel_iam_sync` = `"1"`**, with no title and no body. **Do not render it** — refetch the bundle and return.

A device that declined notification permission still receives in-app messages perfectly well; it just collects them on the next foreground. Never make eligibility depend on the ping arriving.

---

## 3. Capability gating

The bundle endpoint reads `X-Arsel-SDK` and returns an **empty bundle** below the IAM-capable minimum, currently `ios/1.1.0` (`IN_APP_MIN_SDK_VERSION` in the backend).

Bump the SDK version past that threshold **only once the renderer actually works**. An SDK claiming 1.1.0 without one receives payloads it silently drops — the invisible failure the gate exists to prevent.

`IN_APP_SUPPORTED_LAYOUTS.ios` currently claims all five layouts; trim it in the backend if the first release ships fewer.

---

## 4. Work required in this SDK

Everything below is additive — the transport, queue, device auth and event pipeline all already exist.

- `InAppRepository` — bundle fetch, disk cache, `bundleVersion` / `If-None-Match`
- `TriggerEngine` — subscribes to the **same `track()` calls already being sent**, matches event name plus property predicates, applies caps and priority
- Renderer — a `UIWindow` overlay at `.alert` level, or a presented `UIViewController`. Needs top-view-controller resolution that survives a presented modal, and must not fight the host's own presentation
- Beacons through `RequestQueue`
- Handle `arsel_iam_sync` in `PushController`
- New public API on `Arsel`: `setInAppMessagingEnabled(_:)` and `pauseInAppMessages()` so a host can suppress messages during checkout, plus a delegate for hosts that want to draw the message themselves

**Do not send a second copy of trigger events.** The SDK already posts `track()` to `/v1/events/send`; the trigger engine observes those calls locally rather than re-reporting them. Duplicating would double-count every event in segments and automations.

---

## 5. Display rules — evaluation order

When a trigger fires:

1. Drop anything past `expiresAt`.
2. Drop anything at `maxLifetime`.
3. Drop anything at `maxPerSession` this session.
4. Drop anything inside `minSecondsBetween`.
5. Take the **highest `priority`**; tie-break on earliest `expiresAt`, then server order.
6. **One at a time.** Never stack.
7. Honour `delaySeconds`; abandon if the user navigates away first.

A cap may be exceeded by one across a bundle-refresh boundary — accepted and specified, because a synchronous server check would put the network between the trigger and the message.

---

## 6. Checklist before the first release

- [ ] Renders every layout in `IN_APP_SUPPORTED_LAYOUTS.ios` (or the backend list is trimmed)
- [ ] Overlay survives a host-presented modal and rotation; VoiceOver reaches the buttons
- [ ] `arsel_iam_sync` refreshes the bundle and renders nothing
- [ ] Beacons carry the exact `messageId` from the bundle
- [ ] Repeat displays reuse the same `messageId` — dedupe is `(messageId, eventType, subscriptionId)`, so repeats collapse to one impression row by design
- [ ] `If-None-Match` sent, 304 handled
- [ ] Trigger engine observes existing `track()` calls rather than re-posting them
- [ ] Version bumped to ≥ `1.1.0` only once the renderer works
