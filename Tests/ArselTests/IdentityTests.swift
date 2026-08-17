import XCTest
@testable import Arsel

/// End-to-end through `ArselCore` with a mock transport: what actually leaves the
/// device after each identity operation.
final class IdentityTests: XCTestCase {
    private var transport: MockTransport!
    private var core: ArselCore!

    override func setUp() {
        super.setUp()
        transport = MockTransport()
        core = ArselCore(
            config: ArselConfig(clientKey: "pub_test", baseUrl: "https://api.example.test"),
            directory: tempDirectory(),
            transport: transport,
            secrets: InMemorySecretStore())
    }

    private func sentEvents() -> [[String: Any]] {
        transport.requests
            .filter { $0.url.path == "/v1/events/send" }
            .flatMap { request -> [[String: Any]] in
                if let batch = request.body["events"] as? [[String: Any]] { return batch }
                return [request.body]
            }
    }

    func testTrackCarriesIdentifiersAssertedBeforeIt() async {
        core.identify(externalId: "u-1", email: "user@example.com", phoneNumber: "+966501234567")
        core.track("order.placed", properties: ["sku": "A-1"])
        await core.flushNow()

        let events = sentEvents()
        XCTAssertEqual(events.map { $0["event"] as? String }, ["arsel.identify", "order.placed"])
        let order = events[1]
        XCTAssertEqual(order["external_id"] as? String, "u-1")
        XCTAssertEqual(order["email"] as? String, "user@example.com")
        XCTAssertEqual(order["phone_number"] as? String, "+966501234567")
        XCTAssertNotNil(order["anonymous_id"], "anonymousId rides even identified events")
    }

    func testChangingExternalIdClearsEmailAndPhone() async {
        core.identify(externalId: "u-1", email: "old@example.com", phoneNumber: "+966501234567")
        // A different externalId is a different person; the old email/phone must not
        // ride the new identity's events.
        core.identify(externalId: "u-2")
        core.track("after.switch")
        await core.flushNow()

        let after = sentEvents().last!
        XCTAssertEqual(after["external_id"] as? String, "u-2")
        XCTAssertNil(after["email"])
        XCTAssertNil(after["phone_number"])
    }

    func testSameExternalIdKeepsEmailAndPhone() async {
        core.identify(externalId: "u-1", email: "keep@example.com")
        core.identify(externalId: "u-1")
        core.track("still.same")
        await core.flushNow()
        XCTAssertEqual(sentEvents().last!["email"] as? String, "keep@example.com")
    }

    func testInvalidIdentifiersAreRejectedNotStored() async {
        core.identify(externalId: "u-1", email: "not-an-email", phoneNumber: "0501234567")
        core.track("check")
        await core.flushNow()

        let event = sentEvents().last!
        XCTAssertEqual(event["external_id"] as? String, "u-1")
        XCTAssertNil(event["email"], "malformed email must never be stored")
        XCTAssertNil(event["phone_number"], "non-E.164 phone must never be stored")
    }

    func testIdentifyWithNothingValidIsIgnored() async {
        core.identify(externalId: nil, email: "bad", phoneNumber: nil)
        await core.flushNow()
        XCTAssertTrue(sentEvents().isEmpty, "no arsel.identify for a no-op identify")
    }

    func testResetRotatesAnonymousIdAndForgetsIdentifiers() async {
        core.identify(externalId: "u-1", email: "user@example.com")
        core.track("before.reset")
        await core.flushNow()
        let anonBefore = core.anonymousId

        core.reset()
        core.track("after.reset")
        await core.flushNow()
        let anonAfter = core.anonymousId

        XCTAssertNotEqual(anonBefore, anonAfter)
        let after = sentEvents().last!
        XCTAssertEqual(after["event"] as? String, "after.reset")
        XCTAssertNil(after["external_id"])
        XCTAssertNil(after["email"])
        XCTAssertEqual(after["anonymous_id"] as? String, anonAfter)
    }

    func testResetNeverTouchesPushOptOut() async {
        core.optOut()
        await core.flushNow()
        core.reset()
        await core.flushNow()
        XCTAssertTrue(core.diagnostics().optedOut, "reset() must not resurrect push")
    }

    func testTrackRejectsReservedPrefix() async {
        core.track("arsel.session_start")
        core.track("  ")
        await core.flushNow()
        XCTAssertTrue(sentEvents().isEmpty)
    }

    func testEventsFlowWithNoPushTokenNoSecretNoPermission() async {
        core.track("no.push.here")
        await core.flushNow()
        XCTAssertEqual(sentEvents().count, 1)
        XCTAssertEqual(transport.requests.count, 1, "no registration attempt without a token")
    }

    func testDiagnosticsCarriesNoSecrets() async {
        core.identify(externalId: "u-1", email: "user@example.com")
        await core.flushNow()
        let snapshot = core.diagnostics()
        XCTAssertEqual(snapshot.sdkVersion, Wire.sdkVersion)
        XCTAssertTrue(snapshot.hasAssertedIdentity)
        let mirror = Mirror(reflecting: snapshot)
        for child in mirror.children {
            XCTAssertNotEqual(child.value as? String, "user@example.com",
                              "diagnostics must not expose identifier values")
        }
    }
}
