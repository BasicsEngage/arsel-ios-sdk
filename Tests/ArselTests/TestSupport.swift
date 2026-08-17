import Foundation
import XCTest
@testable import Arsel

/// Records every request and answers from a scripted queue (last response repeats).
final class MockTransport: Transport {
    struct Recorded {
        let url: URL
        let body: [String: Any]
        let headers: [String: String]
        let authenticated: Bool
    }

    private(set) var requests: [Recorded] = []
    var responses: [TransportResponse] = []

    static func ok(body: String = "{}") -> TransportResponse {
        TransportResponse(result: .success, code: 200, body: Data(body.utf8), retryAfterMs: nil)
    }

    static func status(_ code: Int, authenticated: Bool = false, retryAfterMs: Int64? = nil) -> TransportResponse {
        TransportResponse(
            result: classify(code: code, authenticated: authenticated),
            code: code, body: nil, retryAfterMs: retryAfterMs)
    }

    func post(url: URL, body: Data, headers: [String: String], authenticated: Bool) -> TransportResponse {
        let parsed = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        requests.append(Recorded(url: url, body: parsed, headers: headers, authenticated: authenticated))
        if responses.count > 1 { return responses.removeFirst() }
        return responses.first ?? Self.ok()
    }
}

final class InMemorySecretStore: SecretStore {
    var secret: String?
    func read() -> String? { secret }
    func write(_ value: String) { secret = value }
    func removeSecret() { secret = nil }
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arsel-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let quietLog = ArselLog(level: .none)

extension Drainer.Context {
    static func testContext() -> Drainer.Context {
        Drainer.Context(
            clientKey: "pub_test",
            baseUrl: URL(string: "https://api.example.test")!,
            installationId: "install-1")
    }
}

func makeQueuedEvent(
    id: String = UUID().uuidString,
    name: String = "order.placed",
    createdAtMs: Int64 = nowMillis(),
    externalId: String? = nil
) -> QueuedRequest {
    var body: [String: Any] = [
        "event": name,
        "anonymous_id": "anon-1",
        "data": [:] as [String: Any],
        "timestamp": EventBodies.iso8601(timestampMs: createdAtMs),
    ]
    if let externalId { body["external_id"] = externalId }
    let json = String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
    return QueuedRequest(id: id, kind: .event, body: json, dedupeKey: nil, createdAtMs: createdAtMs)
}

func makeQueuedEngagement(id: String = UUID().uuidString, messageId: String = "mid-1") -> QueuedRequest {
    let record = EngagementRecord(messageId: messageId, eventType: .opened, timestampMs: nowMillis())
    let json = String(data: try! JSONSerialization.data(withJSONObject: record.toJSON()), encoding: .utf8)!
    return QueuedRequest(id: id, kind: .engagement, body: json, dedupeKey: nil, createdAtMs: nowMillis())
}
