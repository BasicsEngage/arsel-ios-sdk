import XCTest
@testable import Arsel

final class PushControllerTests: XCTestCase {
    private var store: StateStore!
    private var captured: [QueuedRequest] = []
    private var now: Int64 = 1_700_000_000_000

    override func setUp() {
        super.setUp()
        store = StateStore(directory: tempDirectory(), log: quietLog)
        captured = []
    }

    private func makeController() -> PushController {
        PushController(
            store: store,
            enqueue: { self.captured.append($0) },
            log: quietLog,
            clock: { self.now },
            deviceSnapshot: {
                DeviceSnapshot(
                    appVersion: "2.0", osVersion: "17.5", deviceModel: "iPhone14,2",
                    deviceTimezone: "Asia/Riyadh", deviceLocale: "ar-SA")
            })
    }

    private func body(at index: Int) -> [String: Any] {
        try! JSONSerialization.jsonObject(
            with: captured[index].body.data(using: .utf8)!) as! [String: Any]
    }

    func testRegisterBodyMatchesRegisterPushSubscriptionDto() {
        let controller = makeController()
        controller.setToken("apns-token-hex", vendor: .apns)

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].kind, .register)
        XCTAssertEqual(captured[0].dedupeKey, "register")
        let json = body(at: 0)
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["vendor"] as? String, "apns")
        XCTAssertEqual(json["deviceToken"] as? String, "apns-token-hex")
        XCTAssertNotNil(json["installationId"])
        XCTAssertNotNil(json["anonymousId"], "the contact binding rides every registration")
        XCTAssertEqual(json["appVersion"] as? String, "2.0")
        XCTAssertEqual(json["osVersion"] as? String, "17.5")
        XCTAssertEqual(json["deviceModel"] as? String, "iPhone14,2")
        XCTAssertEqual(json["deviceManufacturer"] as? String, "Apple")
        XCTAssertEqual(json["deviceTimezone"] as? String, "Asia/Riyadh")
        XCTAssertEqual(json["deviceLocale"] as? String, "ar-SA")
    }

    func testApnsRegistrationCarriesItsEnvironment() {
        makeController().setToken("apns-token", vendor: .apns)
        XCTAssertEqual(body(at: 0)["vendor"] as? String, "apns")
        XCTAssertNotNil(body(at: 0)["apnsEnvironment"])
    }

    func testMissingProvisioningProfileReadsAsProduction() {
        XCTAssertEqual(
            ApnsEnvironment.resolve(bundle: Bundle(for: type(of: self)), isSimulator: false),
            "production")
    }

    func testSimulatorReadsAsSandbox() {
        XCTAssertEqual(ApnsEnvironment.resolve(isSimulator: true), "sandbox")
    }

    func testUnchangedDeviceIsNotReRegistered() {
        let controller = makeController()
        controller.setToken("t1", vendor: .apns)
        // Simulate the drain confirming the registration.
        store.mutate { $0.lastRegisteredFingerprint = captured[0].commitFingerprint }
        controller.registerIfNeeded()
        XCTAssertEqual(captured.count, 1, "same fingerprint — nothing to report")

        controller.setToken("t2", vendor: .apns)
        XCTAssertEqual(captured.count, 2, "a rotated token is a new fact")
    }

    func testRegistrationCarriesTheAnonymousIdAsTheContactBinding() {
        let controller = makeController()
        controller.setToken("t1", vendor: .apns)

        // The binding the backend resolves through its identifier ladder — without it
        // a subscription registered before identify() strands on its own contact.
        XCTAssertEqual(body(at: 0)["anonymousId"] as? String, store.anonymousIdOrCreate())
    }

    func testOptOutIsDurableAndBlocksReRegistration() {
        let controller = makeController()
        controller.setToken("t1", vendor: .apns)
        store.mutate { $0.lastRegisteredFingerprint = captured[0].commitFingerprint }
        captured.removeAll()

        controller.optOut()
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].kind, .unsubscribe)
        XCTAssertEqual(body(at: 0).keys.sorted(), ["installationId"])

        captured.removeAll()
        controller.registerIfNeeded(force: true)
        XCTAssertTrue(captured.isEmpty, "an opted-out device must not re-register")
    }

    func testOptOutWithoutRegistrationHasNothingToRevoke() {
        let controller = makeController()
        controller.optOut()
        XCTAssertTrue(captured.isEmpty)
        XCTAssertTrue(store.current.optedOut, "still recorded locally")
    }

    func testStateReportMatchesPushDeviceStateDto() {
        let controller = makeController()
        controller.setToken("t1", vendor: .apns)
        store.mutate { $0.lastRegisteredFingerprint = captured[0].commitFingerprint }
        captured.removeAll()

        controller.setEnablementStatus(.authorized)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].kind, .state)
        let json = body(at: 0)
        XCTAssertEqual(json["enablementStatus"] as? String, "AUTHORIZED")
        XCTAssertEqual(json["deviceToken"] as? String, "t1")
        // Facts the state DTO does not whitelist must be absent.
        XCTAssertNil(json["deviceModel"])
        XCTAssertNil(json["deviceManufacturer"])
        XCTAssertNil(json["platform"])
        XCTAssertNil(json["vendor"])
    }

    func testUnchangedEnablementStatusIsNotReReported() {
        let controller = makeController()
        controller.setToken("t1", vendor: .apns)
        store.mutate { $0.lastRegisteredFingerprint = captured[0].commitFingerprint }
        captured.removeAll()

        controller.setEnablementStatus(.denied)
        controller.setEnablementStatus(.denied)
        XCTAssertEqual(captured.count, 1)
    }

    func testStateBeforeRegistrationRoutesToRegisterInstead() {
        let controller = makeController()
        controller.setToken("t1", vendor: .apns)
        captured.removeAll() // registration queued but never confirmed

        controller.reportState()
        // The state route needs device auth, which only a registration mints.
        XCTAssertEqual(captured.map(\.kind), [.register])
    }

    func testEngagementRecordShape() {
        let controller = makeController()
        controller.engagement(EngagementRecord(
            messageId: "m-1", eventType: .clicked, timestampMs: now,
            signature: "sig", signatureKeyId: "kid",
            actionId: "buy", deepLink: "app://product/1"))

        XCTAssertEqual(captured[0].kind, .engagement)
        let json = body(at: 0)
        XCTAssertEqual(json["messageId"] as? String, "m-1")
        XCTAssertEqual(json["eventType"] as? String, "clicked")
        XCTAssertEqual(json["signature"] as? String, "sig")
        XCTAssertEqual(json["signatureKeyId"] as? String, "kid")
        XCTAssertEqual(json["actionId"] as? String, "buy")
        XCTAssertEqual(json["deepLink"] as? String, "app://product/1")
        XCTAssertNotNil(json["timestamp"])
    }
}

final class ArselPushMessageTests: XCTestCase {
    func testParsesUserInfo() throws {
        let userInfo: [AnyHashable: Any] = [
            "arsel_v": "1",
            "arsel_mid": "mid-1",
            "arsel_sig": "sig",
            "arsel_kid": "kid",
            "arsel_title": "Hello",
            "arsel_body": "World",
            "arsel_image": "https://cdn.example/img.png",
            "arsel_deep_link": "app://home",
            "arsel_collapse_id": "promo",
            "arsel_actions": #"[{"actionId":"buy","label":"Buy now","deepLink":"app://buy"},{"actionId":"later","label":"Later"}]"#,
            "aps": ["alert": ["title": "Hello"]],
        ]
        let message = try XCTUnwrap(ArselPushMessage.from(userInfo: userInfo))
        XCTAssertEqual(message.messageId, "mid-1")
        XCTAssertEqual(message.wireVersion, "1")
        XCTAssertEqual(message.deepLink, "app://home")
        XCTAssertEqual(message.actions.count, 2)
        XCTAssertEqual(message.actions[0].actionId, "buy")
        XCTAssertEqual(message.actions[0].deepLink, "app://buy")
        XCTAssertNil(message.actions[1].deepLink)
    }

    func testForeignPushIsNotClaimed() {
        XCTAssertFalse(ArselPushMessage.isArsel(userInfo: ["aps": ["alert": "hi"]]))
        XCTAssertNil(ArselPushMessage.from(userInfo: ["title": "someone else's push"]))
    }

    func testVersionlessEnvelopeFallsBackToMessageId() {
        XCTAssertTrue(ArselPushMessage.isArsel(userInfo: ["arsel_mid": "m-1"]))
        XCTAssertNotNil(ArselPushMessage.from(userInfo: ["arsel_mid": "m-1"]))
    }

    func testMalformedActionsAreSkippedNotFatal() throws {
        let message = try XCTUnwrap(ArselPushMessage.from(userInfo: [
            "arsel_mid": "m-1",
            "arsel_actions": "not json",
        ]))
        XCTAssertTrue(message.actions.isEmpty)
    }
}
