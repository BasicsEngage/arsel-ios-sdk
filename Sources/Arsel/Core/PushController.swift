import Foundation

/// The push API: registration, device state, opt-out, and engagements.
/// Everything here is enqueue-only; delivery is the drain's job.
final class PushController {
    private let store: StateStore
    private let enqueue: (QueuedRequest) -> Void
    private let log: ArselLog
    private let clock: () -> Int64
    private let deviceSnapshot: () -> DeviceSnapshot

    init(
        store: StateStore,
        enqueue: @escaping (QueuedRequest) -> Void,
        log: ArselLog,
        clock: @escaping () -> Int64 = nowMillis,
        deviceSnapshot: @escaping () -> DeviceSnapshot = DeviceSnapshot.capture
    ) {
        self.store = store
        self.enqueue = enqueue
        self.log = log
        self.clock = clock
        self.deviceSnapshot = deviceSnapshot
    }

    func setToken(_ token: String, vendor: ArselPushVendor) {
        store.mutate {
            $0.pushToken = token
            $0.pushVendor = vendor.rawValue
        }
        registerIfNeeded()
    }

    /// Enqueue a registration when the device's registration-relevant facts changed
    /// (or `force`). The fingerprint is committed only when a drain confirms a 2xx.
    func registerIfNeeded(force: Bool = false) {
        let state = store.current
        guard !state.optedOut else {
            log.i("push is opted out on this device — not registering")
            return
        }
        guard let token = state.pushToken, let vendorRaw = state.pushVendor,
              let vendor = ArselPushVendor(rawValue: vendorRaw) else {
            // Ordinary: events flow with no push token at all. Registration happens
            // when the host passes one in.
            return
        }

        let anonymousId = store.anonymousIdOrCreate()
        let device = snapshotWithStatus()
        let fingerprint = [
            vendor.rawValue, token, anonymousId, ApnsEnvironment.current,
            device.enablementStatus ?? "", device.appVersion ?? "",
            device.osVersion ?? "", device.deviceTimezone ?? "", device.deviceLocale ?? "",
        ].joined(separator: "|")

        if !force && fingerprint == state.lastRegisteredFingerprint {
            return
        }

        let body = PushBodies.register(
            installationId: store.installationIdOrCreate(),
            vendor: vendor,
            deviceToken: token,
            anonymousId: anonymousId,
            apnsEnvironment: ApnsEnvironment.current,
            device: device)
        guard let json = serialize(body) else { return }
        enqueue(QueuedRequest(
            id: UUID().uuidString.lowercased(),
            kind: .register,
            body: json,
            // A newer registration snapshot evicts a queued older one; only the
            // latest state of the device is worth sending.
            dedupeKey: "register",
            createdAtMs: clock(),
            commitFingerprint: fingerprint))
    }

    /// Report polled permission / token facts without a full registration.
    func reportState() {
        let state = store.current
        guard !state.optedOut, let token = state.pushToken else { return }
        guard state.lastRegisteredFingerprint != nil else {
            // Never registered: the state route needs device auth, which only a
            // registration mints. Register instead — it carries the same facts.
            registerIfNeeded()
            return
        }
        let body = PushBodies.state(
            installationId: store.installationIdOrCreate(),
            deviceToken: token,
            device: snapshotWithStatus())
        guard let json = serialize(body) else { return }
        enqueue(QueuedRequest(
            id: UUID().uuidString.lowercased(),
            kind: .state,
            body: json,
            dedupeKey: "state",
            createdAtMs: clock()))
    }

    func setEnablementStatus(_ status: ArselEnablementStatus) {
        let changed = store.current.enablementStatus != status.rawValue
        store.mutate { $0.enablementStatus = status.rawValue }
        if changed { reportState() }
    }

    /// Durable opt-out. The backend revocation is non-resurrectable: a later
    /// register for this installation will not undo it. Distinct from `reset()`,
    /// which never touches push.
    func optOut() {
        store.mutate { $0.optedOut = true }
        guard store.current.lastRegisteredFingerprint != nil else {
            log.i("push opt-out recorded locally — this device never completed a registration, nothing to revoke")
            return
        }
        let body = PushBodies.unsubscribe(installationId: store.installationIdOrCreate())
        guard let json = serialize(body) else { return }
        enqueue(QueuedRequest(
            id: UUID().uuidString.lowercased(),
            kind: .unsubscribe,
            body: json,
            dedupeKey: "unsubscribe",
            createdAtMs: clock()))
    }

    /// One engagement signal. One engagement per notification tap: `opened` for the
    /// body, `clicked` for an action button — never both, or the two counters
    /// become identical by construction.
    func engagement(_ record: EngagementRecord) {
        guard let json = serialize(record.toJSON()) else { return }
        enqueue(QueuedRequest(
            id: UUID().uuidString.lowercased(),
            kind: .engagement,
            body: json,
            dedupeKey: nil,
            createdAtMs: clock()))
    }

    private func snapshotWithStatus() -> DeviceSnapshot {
        var device = deviceSnapshot()
        device.enablementStatus = store.current.enablementStatus
        return device
    }

    private func serialize(_ body: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else {
            log.e("could not serialize push request body — dropping")
            return nil
        }
        return json
    }
}
