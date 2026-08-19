import Foundation

/// The events API. Separate from `PushController` on purpose: it targets a different
/// route with a different credential (the publishable client key, not the device
/// secret), and it works with no push token, no device secret and no notification
/// permission. Nothing here may depend on the device being registered for push.
final class EventController {
    private let store: StateStore
    private let enqueue: (QueuedRequest) -> Void
    private let log: ArselLog
    private let clock: () -> Int64

    /// Notified after an event is durably queued.
    ///
    /// This is the only place that sees every event exactly once: downstream of the blank and
    /// reserved-name rejects, downstream of the trim, and never on a retry — retries live entirely
    /// in the drain re-reading the queue file. Set after init because the observer needs the core,
    /// which needs this controller.
    var onEvent: ((String, [String: Any], Int64) -> Void)?

    init(
        store: StateStore,
        enqueue: @escaping (QueuedRequest) -> Void,
        log: ArselLog,
        clock: @escaping () -> Int64 = nowMillis
    ) {
        self.store = store
        self.enqueue = enqueue
        self.log = log
        self.clock = clock
    }

    func track(_ name: String, properties: [String: Any] = [:], timestampMs: Int64? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.w("track() called with a blank event name — ignoring")
            return
        }
        guard !trimmed.hasPrefix(EventBodies.reservedPrefix) else {
            log.w("'\(EventBodies.reservedPrefix)' is reserved for the SDK — ignoring '\(trimmed)'")
            return
        }
        enqueueEvent(name: trimmed, properties: properties, timestampMs: timestampMs ?? clock())
    }

    /// SDK-emitted events, exempt from the reserved-prefix check that guards `track`.
    func trackReserved(_ name: String, properties: [String: Any] = [:], timestampMs: Int64? = nil) {
        enqueueEvent(name: name, properties: properties, timestampMs: timestampMs ?? clock())
    }

    private func enqueueEvent(name: String, properties: [String: Any], timestampMs: Int64) {
        let state = store.current
        let body = EventBodies.event(
            name: name,
            properties: properties,
            anonymousId: store.anonymousIdOrCreate(),
            externalId: state.externalId,
            email: state.email,
            phoneNumber: state.phoneNumber,
            timestampMs: timestampMs)
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else {
            log.e("could not serialize event '\(name)' — dropping")
            return
        }
        // No dedupe key: every event is its own fact. A shared key would let a later
        // event evict an earlier one that is the only copy of something billable.
        // createdAt is ENQUEUE time — the drain's age cap measures queue residence.
        // The event's own (possibly backdated) timestamp lives in the body only.
        enqueue(QueuedRequest(
            id: UUID().uuidString.lowercased(),
            kind: .event,
            body: json,
            dedupeKey: nil,
            createdAtMs: clock()))
        // Last, so an observer never sees an event that failed to queue.
        onEvent?(name, properties, timestampMs)
    }
}
