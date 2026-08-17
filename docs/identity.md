# Identity

How a device's events become a person, and what login/logout must and must not do.

## Anonymous first

`initialize()` mints a random **anonymous id**, persisted on the device. Every event carries it as
`anonymous_id` — including events sent *after* identification, because it is the identity the
backend merges *from*. A visitor who never logs in is still a contact with a history.

## The identifier ladder

When the backend resolves an event to a contact, stronger identifiers win:

```
contact_id  >  external_id  >  email  >  phone_number  >  anonymous_id
```

The SDK never sends `contact_id` (that is a server-side identifier); it sends whatever you asserted
via `identify()` plus the anonymous id.

## `identify()` — client-asserted

```swift
Arsel.identify(externalId: user.id)                       // preferred
Arsel.identify(email: "user@example.com")
Arsel.identify(externalId: user.id, phoneNumber: "+966501234567")
```

- Call once per login. Identifiers persist and ride every later event.
- Emits `arsel.identify` immediately, so the merge happens now — not on the next unrelated event.
- **Prefer `externalId` alone.** It binds the contact without putting an email address in app
  memory, and it survives the user changing their address.
- **Validation is client-side and strict**: email must look like an email, phone must be E.164
  (`+9665…`). An invalid value is *rejected and logged, never stored* — a stored bad identifier
  would turn every subsequent event into a permanent 400 and silently drop the user's history.
- **Changing `externalId` to a different value drops stored email and phone.** They belonged to the
  previous identity. Re-assert them if they carry over.

## How the push subscription finds the same contact

Registration carries the anonymous id, so the device resolves through the identifier ladder exactly
as an event does: a subscription registered before login still lands on the contact its events
built, and `identify()` merges that contact forward.

When your backend already knows who is signed in and you want the binding asserted server-side,
read `Arsel.installationId`, send it to your server, and have it call
`POST /v1/push/devices` with your secret API key. That binding is authoritative and overrides
the anonymous one — and the secret key never leaves your server.

## `reset()` — logout

```swift
Arsel.reset()
```

Rotates the anonymous id (the next person on this device does not inherit the history), forgets
`externalId`/email/phone, closes session state, and re-registers the device under the new anonymous
identity.

**`reset()` never touches push.** The backend's opt-out is durable and non-resurrectable, so a
logout that called it would permanently kill push on a shared device for everyone after.

## `optOut()` — the user said stop

```swift
Arsel.optOut()
```

Durable, server-side, per-device push revocation. A later registration of the same installation
does not undo it — re-opt-in is an explicit act on the backend. Wire this to a "stop sending me
notifications" control, never to logout.

| | `reset()` | `optOut()` |
| --- | --- | --- |
| Meaning | different person now | this device said stop |
| Anonymous id | rotated | untouched |
| Identifiers | forgotten | untouched |
| Push | untouched | revoked, durably |
| When | logout | an explicit user opt-out |
