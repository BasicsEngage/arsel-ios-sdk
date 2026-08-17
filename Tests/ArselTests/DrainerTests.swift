import XCTest
@testable import Arsel

final class DrainerTests: XCTestCase {
    private var dir: URL!
    private var queue: RequestQueue!
    private var store: StateStore!
    private var secrets: InMemorySecretStore!
    private var transport: MockTransport!
    private var clock: Int64 = 1_700_000_000_000

    private func makeDrainer() -> Drainer {
        Drainer(
            queue: queue, store: store, secrets: secrets, transport: transport,
            log: quietLog, clock: { self.clock })
    }

    override func setUp() {
        super.setUp()
        dir = tempDirectory()
        queue = RequestQueue(directory: dir, log: quietLog)
        store = StateStore(directory: dir, log: quietLog)
        secrets = InMemorySecretStore()
        transport = MockTransport()
    }

    // MARK: Events

    func testSingleEventSendsBareBodyWithItsOwnIdempotencyKey() throws {
        queue.enqueue(makeQueuedEvent(id: "e1", name: "order.placed"))
        let outcome = makeDrainer().drain(context: .testContext())
        if case .retryLater = outcome { XCTFail("expected drained") }

        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, "https://api.example.test/v1/events/send")
        XCTAssertEqual(request.body["event"] as? String, "order.placed")
        XCTAssertNil(request.body["events"], "a single event is a bare body, not a batch envelope")
        XCTAssertEqual(request.headers["Authorization"], "Bearer pub_test")
        XCTAssertEqual(request.headers["Idempotency-Key"], "e1")
        XCTAssertFalse(request.authenticated)
        XCTAssertEqual(queue.count, 0)
    }

    func testConsecutiveEventsBatchWithDeterministicKey() throws {
        for index in 0..<3 { queue.enqueue(makeQueuedEvent(id: "e\(index)")) }
        _ = makeDrainer().drain(context: .testContext())

        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        let events = try XCTUnwrap(request.body["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(request.headers["Idempotency-Key"], "e0:e2:3")
    }

    func testBatchCapsAtFifty() throws {
        for index in 0..<60 { queue.enqueue(makeQueuedEvent(id: "e\(index)")) }
        _ = makeDrainer().drain(context: .testContext())

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual((transport.requests[0].body["events"] as? [[String: Any]])?.count, 50)
        XCTAssertEqual((transport.requests[1].body["events"] as? [[String: Any]])?.count, 10)
    }

    func testIdempotencyKeyIsStableAcrossRetries() {
        queue.enqueue(makeQueuedEvent(id: "e1"))
        transport.responses = [MockTransport.status(503), MockTransport.ok()]

        let drainer = makeDrainer()
        guard case .retryLater = drainer.drain(context: .testContext()) else {
            return XCTFail("expected retryLater on 503")
        }
        XCTAssertEqual(queue.count, 1, "retryable failures keep the event queued")
        _ = drainer.drain(context: .testContext())

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].headers["Idempotency-Key"], "e1")
        XCTAssertEqual(transport.requests[1].headers["Idempotency-Key"], "e1")
        XCTAssertEqual(queue.count, 0)
    }

    func testStopsAtFirstRetryableFailureSoNothingOvertakes() {
        queue.enqueue(makeQueuedEvent(id: "e1"))
        queue.enqueue(QueuedRequest(id: "r1", kind: .register, body: "{}", dedupeKey: "register", createdAtMs: clock))
        transport.responses = [MockTransport.status(500)]

        guard case .retryLater = makeDrainer().drain(context: .testContext()) else {
            return XCTFail("expected retryLater")
        }
        XCTAssertEqual(transport.requests.count, 1, "the register behind the failed event must NOT be sent")
        XCTAssertEqual(queue.count, 2)
    }

    func testRetryAfterIsSurfaced() {
        queue.enqueue(makeQueuedEvent(id: "e1"))
        transport.responses = [MockTransport.status(429, retryAfterMs: 42_000)]
        guard case .retryLater(let retryAfterMs) = makeDrainer().drain(context: .testContext()) else {
            return XCTFail("expected retryLater")
        }
        XCTAssertEqual(retryAfterMs, 42_000)
    }

    func testPermanentFailureDropsAndContinues() {
        queue.enqueue(makeQueuedEvent(id: "e1", externalId: "u-1"))
        // A 4xx will never succeed on a retry; holding it would wedge everything behind it.
        transport.responses = [MockTransport.status(400), MockTransport.ok()]
        queue.enqueue(QueuedRequest(id: "u1", kind: .unsubscribe,
            body: #"{"installationId":"i"}"#, dedupeKey: "unsubscribe", createdAtMs: clock))
        secrets.secret = "s3cret"

        let outcome = makeDrainer().drain(context: .testContext())
        if case .retryLater = outcome { XCTFail("expected drained") }
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(queue.count, 0)
    }

    func testExpiredRequestsDropUnsent() {
        queue.enqueue(makeQueuedEvent(id: "old", createdAtMs: clock - DrainPolicy.maxAgeMs - 1))
        queue.enqueue(makeQueuedEvent(id: "fresh", createdAtMs: clock))
        _ = makeDrainer().drain(context: .testContext())

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].headers["Idempotency-Key"], "fresh")
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: Registration bookkeeping

    func testRegisterSuccessCommitsSecretAndFingerprint() {
        transport.responses = [MockTransport.ok(
            body: #"{"subscriptionId":"sub-1","status":"ACTIVE","deviceSecret":"minted-secret"}"#)]
        queue.enqueue(QueuedRequest(
            id: "r1", kind: .register, body: #"{"installationId":"i"}"#,
            dedupeKey: "register", createdAtMs: clock,
            commitFingerprint: "fp-1"))

        _ = makeDrainer().drain(context: .testContext())

        XCTAssertEqual(secrets.secret, "minted-secret")
        XCTAssertEqual(store.current.lastRegisteredFingerprint, "fp-1")
        XCTAssertFalse(transport.requests[0].authenticated, "registration mints the secret — it cannot require one")
    }

    func testRegisterFailureCommitsNothing() {
        transport.responses = [MockTransport.status(500)]
        queue.enqueue(QueuedRequest(
            id: "r1", kind: .register, body: "{}", dedupeKey: "register",
            createdAtMs: clock, commitFingerprint: "fp-1"))
        _ = makeDrainer().drain(context: .testContext())

        XCTAssertNil(secrets.secret)
        XCTAssertNil(store.current.lastRegisteredFingerprint)
        XCTAssertEqual(queue.count, 1)
    }

    // MARK: Device-auth requests

    func testEngagementBatchEnvelopeAndDeviceAuth() throws {
        secrets.secret = "s3cret"
        queue.enqueue(makeQueuedEngagement(id: "b1", messageId: "m1"))
        queue.enqueue(makeQueuedEngagement(id: "b2", messageId: "m2"))
        _ = makeDrainer().drain(context: .testContext())

        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString,
            "https://api.example.test/api/v1/orgs/pub_test/push/engagements")
        XCTAssertEqual(request.body["installationId"] as? String, "install-1")
        let events = try XCTUnwrap(request.body["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["messageId"] as? String }, ["m1", "m2"])
        XCTAssertEqual(request.headers["X-Arsel-Device-Auth"], "s3cret")
        XCTAssertNil(request.headers["Idempotency-Key"], "engagements dedupe server-side by (message, event, device)")
        XCTAssertTrue(request.authenticated)
    }

    func testEngagementWithoutSecretSkipsButStillSendsTheRegisterBehindIt() {
        // The exact liveness case: engagements queued first, registration enqueued
        // after. Stopping at the engagement would deadlock the queue forever.
        queue.enqueue(makeQueuedEngagement(id: "b1"))
        transport.responses = [MockTransport.ok(body: #"{"deviceSecret":"fresh"}"#)]
        queue.enqueue(QueuedRequest(
            id: "r1", kind: .register, body: "{}", dedupeKey: "register", createdAtMs: clock))
        var registrationRequested = false
        let drainer = makeDrainer()
        drainer.onNeedsRegistration = { registrationRequested = true }

        _ = drainer.drain(context: .testContext())

        XCTAssertTrue(registrationRequested)
        let paths = transport.requests.map(\.url.path)
        XCTAssertTrue(paths.contains("/api/v1/orgs/pub_test/push/subscriptions"), "register was sent")
        // Once the register minted a secret, the engagement goes out in a later pass of
        // the SAME drain.
        XCTAssertTrue(paths.contains("/api/v1/orgs/pub_test/push/engagements"), "engagement sent after secret minted")
        XCTAssertEqual(queue.count, 0)
    }

    func testReauthClearsSecretAndFingerprintAndKeepsRequestQueued() {
        secrets.secret = "dead-secret"
        store.mutate { $0.lastRegisteredFingerprint = "fp-old" }
        queue.enqueue(makeQueuedEngagement(id: "b1"))
        transport.responses = [MockTransport.status(401, authenticated: true)]
        var registrationRequested = false
        let drainer = makeDrainer()
        drainer.onNeedsRegistration = { registrationRequested = true }

        guard case .retryLater = drainer.drain(context: .testContext()) else {
            return XCTFail("expected retryLater")
        }
        XCTAssertNil(secrets.secret)
        XCTAssertNil(store.current.lastRegisteredFingerprint)
        XCTAssertTrue(registrationRequested)
        XCTAssertEqual(queue.count, 1, "the engagement retries after re-registration")
    }

    func testDrainRecordsDiagnostics() {
        queue.enqueue(makeQueuedEvent(id: "e1"))
        _ = makeDrainer().drain(context: .testContext())
        XCTAssertEqual(store.current.lastResponseCode, 200)
        XCTAssertEqual(store.current.lastResponsePath, "/v1/events/send")
        XCTAssertEqual(store.current.lastResponseAtMs, clock)
    }
}
