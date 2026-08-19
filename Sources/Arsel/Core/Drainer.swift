import Foundation

/// Drains the durable queue, oldest first.
///
/// The rules, shared with the Android and web SDKs:
/// - stop at the first retryable failure — a later request overtaking an earlier
///   one would reorder a user's history;
/// - permanent failures (4xx) are dropped, not retried, or they wedge everything
///   behind them;
/// - re-read after a full pass, so anything enqueued mid-drain goes out now rather
///   than waiting for the next unrelated trigger.
final class Drainer {
    struct Context {
        let clientKey: String
        let baseUrl: URL
        let installationId: String
    }

    enum Outcome {
        case drained
        /// Stopped on a retryable failure; `retryAfterMs` when the server said how long.
        case retryLater(retryAfterMs: Int64?)
    }

    private let queue: RequestQueue
    private let store: StateStore
    private let secrets: SecretStore
    private let transport: Transport
    private let log: ArselLog
    private let clock: () -> Int64
    /// Asks the core to enqueue a fresh registration (dead secret, or a device-auth
    /// request that arrived before any registration).
    var onNeedsRegistration: (() -> Void)?

    init(
        queue: RequestQueue,
        store: StateStore,
        secrets: SecretStore,
        transport: Transport,
        log: ArselLog,
        clock: @escaping () -> Int64 = nowMillis
    ) {
        self.queue = queue
        self.store = store
        self.secrets = secrets
        self.transport = transport
        self.log = log
        self.clock = clock
    }

    /// Must run on the core's serial queue — it is the only writer of queue and state.
    func drain(context: Context) -> Outcome {
        // Requests skipped this drain (device-auth with no secret yet, or a dead
        // secret). They stay queued and are NOT retried within this drain — but the
        // pass continues past them, so the registration that fixes them (enqueued
        // behind them) still goes out. Ordering yields to liveness here, exactly as
        // in the Android SDK.
        var skipped = Set<String>()

        for _ in 0..<Self.maxPasses {
            let pending = queue.snapshot()
            let now = clock()
            let expired = pending.filter { DrainPolicy.isExpired(createdAtMs: $0.createdAtMs, nowMs: now) }
            if !expired.isEmpty {
                log.w("dropping \(expired.count) queued request(s) older than 7 days, unsent")
                queue.remove(ids: Set(expired.map(\.id)))
            }
            let live = pending.filter {
                !DrainPolicy.isExpired(createdAtMs: $0.createdAtMs, nowMs: now) && !skipped.contains($0.id)
            }
            if live.isEmpty {
                return skipped.isEmpty ? .drained : .retryLater(retryAfterMs: nil)
            }

            var index = 0
            while index < live.count {
                let group = nextGroup(live, from: index)
                index += group.count
                switch send(group: group, context: context) {
                case .sent:
                    continue
                case .sentRegistration:
                    // A fresh secret exists; whatever was waiting on it can retry
                    // in the next pass.
                    skipped.removeAll()
                case .skip:
                    skipped.formUnion(group.map(\.id))
                case .stop(let retryAfterMs):
                    return .retryLater(retryAfterMs: retryAfterMs)
                }
            }
        }
        return skipped.isEmpty ? .drained : .retryLater(retryAfterMs: nil)
    }

    /// Consecutive events batch together (one `{events: [...]}` request), and so do
    /// consecutive engagements. Runs never cross a request of another kind — batching
    /// across one would reorder the queue.
    private func nextGroup(_ live: [QueuedRequest], from index: Int) -> [QueuedRequest] {
        let head = live[index]
        guard head.kind == .event || head.kind == .engagement || head.kind == .inAppEvent else {
            return [head]
        }
        let cap = head.kind == .event ? Wire.eventBatchMax : Wire.engagementBatchMax
        var group = [head]
        var next = index + 1
        while next < live.count, live[next].kind == head.kind, group.count < cap {
            group.append(live[next])
            next += 1
        }
        return group
    }

    private enum SendResult {
        case sent
        /// A registration was confirmed — the device now holds a fresh secret.
        case sentRegistration
        /// Left in the queue; the pass continues past it.
        case skip
        /// Retryable failure — the whole drain stops so nothing overtakes it.
        case stop(retryAfterMs: Int64?)
    }

    private func send(group: [QueuedRequest], context: Context) -> SendResult {
        let kind = group[0].kind
        let items = group.compactMap { request -> [String: Any]? in
            guard let data = request.body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }
        guard items.count == group.count else {
            log.e("unreadable queued request body — dropping \(group.count) request(s)")
            queue.remove(ids: Set(group.map(\.id)))
            return .sent
        }

        let payload: [String: Any]
        let path: String
        var headers: [String: String] = [:]
        var authenticated = false

        switch kind {
        case .event:
            path = Wire.eventsPath
            payload = items.count == 1 ? items[0] : ["events": items]
            headers[Wire.authorizationHeader] = Wire.bearerPrefix + context.clientKey
            // Deterministic per batch: an identical batch resent after a timeout
            // carries the same key and dedupes inside the backend's window.
            headers[Wire.idempotencyKeyHeader] = Self.batchKey(group)
        case .engagement:
            path = Wire.engagementsPath(clientKey: context.clientKey)
            payload = PushBodies.engagements(installationId: context.installationId, events: items)
            guard let secret = secrets.read() else {
                // Nothing to authenticate with yet; only a registration mints one.
                // Keep it queued, make sure a registration is on its way, and let
                // the pass continue so that registration can actually be sent.
                onNeedsRegistration?()
                return .skip
            }
            headers[Wire.deviceAuthHeader] = secret
            authenticated = true
        case .inAppEvent:
            path = Wire.inAppEventsPath(clientKey: context.clientKey)
            payload = ["installationId": context.installationId, "events": items]
            guard let secret = secrets.read() else {
                onNeedsRegistration?()
                return .skip
            }
            headers[Wire.deviceAuthHeader] = secret
            authenticated = true
        case .register:
            path = Wire.subscriptionsPath(clientKey: context.clientKey)
            payload = items[0]
            // Unauthenticated on purpose: this is the call that mints the secret.
        case .state, .unsubscribe:
            path = kind == .state
                ? Wire.statePath(clientKey: context.clientKey)
                : Wire.unsubscribePath(clientKey: context.clientKey)
            payload = items[0]
            guard let secret = secrets.read() else {
                onNeedsRegistration?()
                return .skip
            }
            headers[Wire.deviceAuthHeader] = secret
            authenticated = true
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: context.baseUrl.absoluteString + path) else {
            queue.remove(ids: Set(group.map(\.id)))
            return .sent
        }

        let response = transport.post(url: url, body: body, headers: headers, authenticated: authenticated)
        recordOutcome(path: path, response: response)

        switch response.result {
        case .success:
            queue.remove(ids: Set(group.map(\.id)))
            if kind == .register {
                applyConfirmedRegistration(group[0], responseBody: response.body)
                return .sentRegistration
            }
            return .sent
        case .permanent:
            if kind == .event { reportPermanentDrop(items, code: response.code) }
            queue.remove(ids: Set(group.map(\.id)))
            return .sent
        case .reauth:
            // The secret is no longer accepted. Drop it, invalidate the fingerprint
            // so the next registration mints a fresh one, and leave the request
            // queued — it retries once re-registration has minted a new secret.
            log.w("device auth rejected — clearing secret and forcing re-registration")
            secrets.removeSecret()
            store.mutate { $0.lastRegisteredFingerprint = nil }
            onNeedsRegistration?()
            return .skip
        case .retryable:
            return .stop(retryAfterMs: response.retryAfterMs)
        }
    }

    /// The deferred half of registration bookkeeping, applied only on a confirmed
    /// 2xx. The `deviceSecret` in the body is returned exactly once — losing it
    /// strands this device without a way to authenticate anything ever again.
    private func applyConfirmedRegistration(_ request: QueuedRequest, responseBody: Data?) {
        if let data = responseBody,
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let secret = parsed["deviceSecret"] as? String, !secret.isEmpty {
            secrets.write(secret)
        }
        store.mutate {
            if let fingerprint = request.commitFingerprint {
                $0.lastRegisteredFingerprint = fingerprint
            }
        }
    }

    /// A permanent rejection is dropped, but a drop that takes identifiers with it
    /// must not be silent — one bad identifier would otherwise 400 every subsequent
    /// event with no visible cause.
    private func reportPermanentDrop(_ items: [[String: Any]], code: Int) {
        let carried = items.contains {
            $0["external_id"] != nil || $0["email"] != nil || $0["phone_number"] != nil
        }
        guard carried else { return }
        log.e("\(items.count) event(s) carrying identifiers were rejected permanently (HTTP \(code)) and dropped")
    }

    /// Diagnostics only — `diagnostics()` reads this, nothing branches on it.
    private func recordOutcome(path: String, response: TransportResponse) {
        store.mutate {
            $0.lastResponseCode = response.code
            $0.lastResponsePath = path
            $0.lastResponseAtMs = clock()
        }
    }

    static func batchKey(_ group: [QueuedRequest]) -> String {
        let first = group[0].id
        guard group.count > 1 else { return first }
        return "\(first):\(group[group.count - 1].id):\(group.count)"
    }

    /// Bound on re-read passes so two threads enqueueing in a tight loop cannot pin
    /// the drain forever. The next trigger picks up whatever is left.
    private static let maxPasses = 20
}
