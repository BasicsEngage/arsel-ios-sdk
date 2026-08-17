import Foundation

/// How a queued request proves who it is. Resolved at drain time, never baked into
/// the body: a request enqueued before registration completes still authenticates,
/// and a rotated secret is never replayed from disk.
enum QueuedKind: String, Codable {
    /// `POST /v1/events/send`, `Authorization: Bearer pub_…`. Batchable.
    case event
    /// `POST …/push/engagements`, `X-Arsel-Device-Auth`. Batchable; body is ONE engagement —
    /// the drain wraps consecutive runs into the `{installationId, events}` envelope.
    case engagement
    /// `POST …/push/subscriptions`. Unauthenticated — it is the call that mints the secret.
    case register
    /// `POST …/push/subscriptions/state`, `X-Arsel-Device-Auth`.
    case state
    /// `POST …/push/subscriptions/unsubscribe`, `X-Arsel-Device-Auth`.
    case unsubscribe
}

/// A pending backend call, persisted until delivered.
struct QueuedRequest: Codable {
    /// UUID minted at enqueue and persisted — for events it doubles as the
    /// `Idempotency-Key`, identical across every retry, closing the duplicate
    /// window between a server 2xx and the dequeue that never happened.
    let id: String
    let kind: QueuedKind
    /// JSON object, already fully built. Identifiers were resolved at enqueue time
    /// so a later `reset()` cannot rewrite history.
    let body: String
    /// A newer request with the same key evicts the queued older one (register/state):
    /// only the latest snapshot of a device is worth sending. Nil for events and
    /// engagements — every one is its own fact.
    let dedupeKey: String?
    /// ENQUEUE time, never the event's own timestamp: the drain's age cap measures
    /// queue residence, and a backdated `session_end` would otherwise arrive
    /// pre-expired. (This exact conflation was a shipped bug in the Android SDK.)
    let createdAtMs: Int64
    /// Written to `lastRegisteredFingerprint` only when the drain sees a confirmed
    /// 2xx — committing at enqueue would leave the SDK believing it had registered
    /// after a request that never reached the server.
    var commitFingerprint: String? = nil
}

/// Durable FIFO of pending requests: one JSON file, rewritten atomically on every
/// change. The volume ceiling is user-generated events on one device — file-sized,
/// not database-sized.
final class RequestQueue {
    /// Bound on total queued requests; beyond it the oldest are dropped. Protects
    /// the host's disk from an SDK bug or an endless offline stretch.
    static let maxDepth = 5_000

    private let fileURL: URL
    private var items: [QueuedRequest]
    private let log: ArselLog
    private let maxDepth: Int

    init(directory: URL, log: ArselLog, maxDepth: Int = RequestQueue.maxDepth) {
        self.fileURL = directory.appendingPathComponent("queue.json")
        self.log = log
        self.maxDepth = maxDepth
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([QueuedRequest].self, from: data) {
            self.items = decoded
        } else {
            self.items = []
        }
    }

    var count: Int { items.count }

    func snapshot() -> [QueuedRequest] { items }

    func enqueue(_ request: QueuedRequest) {
        if let key = request.dedupeKey {
            items.removeAll { $0.dedupeKey == key }
        }
        items.append(request)
        if items.count > maxDepth {
            log.w("request queue exceeded \(maxDepth) — dropping oldest")
            items.removeFirst(items.count - maxDepth)
        }
        persist()
    }

    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.e("could not persist request queue: \(error)")
        }
    }
}

/// The queue drain's "give up" rule, kept pure so it can be asserted directly.
/// Without it, a device offline for a fortnight would on reconnect replay a
/// fortnight of stale engagement into the analytics pipeline.
enum DrainPolicy {
    /// Requests older than this are dropped unsent. Well beyond any realistic
    /// offline stretch, short enough that what does arrive is worth bucketing.
    static let maxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000

    static func isExpired(createdAtMs: Int64, nowMs: Int64) -> Bool {
        nowMs - createdAtMs > maxAgeMs
    }
}
