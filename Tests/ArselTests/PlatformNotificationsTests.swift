import XCTest
@testable import Arsel

#if canImport(UserNotifications)
import UserNotifications

/// The `Platform/` layer, which only exists on a real iOS build.
///
/// `swift test` on Linux compiles none of this — `Notifications.swift` sits entirely behind
/// `#if canImport(UserNotifications)`. These run under `make test` on a simulator, which is the
/// only place the permission mapping and the notification-centre handlers are ever executed.
///
/// Delivery-dependent cases need the runner to hold notification authorisation; grant it in CI
/// with `xcrun simctl privacy booted grant notifications <runner-bundle-id>`. They skip rather
/// than fail when it is absent, so the deterministic cases still gate the build.
final class PlatformNotificationsTests: XCTestCase {
    private var transport: MockTransport!
    private var secrets: InMemorySecretStore!
    private var previousCore: ArselCore?

    override func setUp() {
        super.setUp()
        transport = MockTransport()
        secrets = InMemorySecretStore()
        // Engagements ride an authenticated route: the drainer skips the batch and asks for a
        // registration instead when no device secret exists, so seed one a registration would
        // have minted.
        secrets.secret = "device-secret"
        previousCore = Arsel.core
        Arsel.core = ArselCore(
            config: ArselConfig(clientKey: "pub_test", baseUrl: "https://api.example.test"),
            directory: tempDirectory(),
            transport: transport,
            secrets: secrets)
    }

    override func tearDown() {
        Arsel.core = previousCore
        super.tearDown()
    }

    private func arselPayload(
        messageId: String = "11111111-2222-4333-8444-555555555555",
        deepLink: String? = nil
    ) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            Wire.DataKey.version: "1",
            Wire.DataKey.messageId: messageId,
            Wire.DataKey.signature: "c2lnbmF0dXJl",
            Wire.DataKey.signatureKeyId: "v1",
            Wire.DataKey.title: "Title",
            Wire.DataKey.body: "Body",
        ]
        if let deepLink { userInfo[Wire.DataKey.deepLink] = deepLink }
        return userInfo
    }

    private func engagements() -> [[String: Any]] {
        transport.requests
            .filter { $0.url.path.hasSuffix("/engagements") }
            .flatMap { request -> [[String: Any]] in
                (request.body["events"] as? [[String: Any]]) ?? [request.body]
            }
    }

    // MARK: Permission mapping

    /// Every `UNAuthorizationStatus` the OS can report, including the two that are easy to get
    /// wrong: `provisional` is a real subscription, and `ephemeral` (App Clips) is authorised.
    func testEnablementStatusCoversEveryAuthorizationStatus() {
        XCTAssertEqual(Arsel.enablementStatus(from: .authorized), .authorized)
        XCTAssertEqual(Arsel.enablementStatus(from: .denied), .denied)
        XCTAssertEqual(Arsel.enablementStatus(from: .notDetermined), .notDetermined)
        XCTAssertEqual(Arsel.enablementStatus(from: .provisional), .provisional)
        #if !os(macOS)
        XCTAssertEqual(Arsel.enablementStatus(from: .ephemeral), .authorized)
        #endif
    }

    /// Reads real `UNNotificationSettings` off the simulator. Asserts only that it reports
    /// something — the runner's actual grant state is environmental.
    func testRefreshPermissionStateReportsAStatus() {
        Arsel.refreshPermissionState()

        let reported = expectation(description: "enablement status reported")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reported.fulfill() }
        wait(for: [reported], timeout: 5)

        XCTAssertNotNil(Arsel.diagnostics()?.enablementStatus)
    }

    // MARK: Ownership

    func testIsArselNotificationDiscriminatesBySchemaMarker() {
        XCTAssertTrue(Arsel.isArselNotification(userInfo: arselPayload()))
        XCTAssertFalse(Arsel.isArselNotification(userInfo: ["aps": ["alert": "someone else's"]]))
        XCTAssertFalse(Arsel.isArselNotification(userInfo: [:]))
    }

    // MARK: Foreground presentation

    /// Uses a genuinely delivered `UNNotification` rather than a synthesised one: the OS has no
    /// public initialiser for it, and a hand-built stand-in would test the stand-in.
    func testForegroundNotificationEngagementsDisplayed() async throws {
        let notification = try await deliverAndFetch(payload: arselPayload())

        let message = Arsel.handleForegroundNotification(notification)

        XCTAssertEqual(message?.messageId, "11111111-2222-4333-8444-555555555555")
        await Arsel.core?.flushNow()
        let displayed = engagements().filter { $0["eventType"] as? String == "displayed" }
        XCTAssertEqual(displayed.count, 1)
        XCTAssertEqual(displayed.first?["messageId"] as? String, "11111111-2222-4333-8444-555555555555")
    }

    /// A push that is not Arsel's must be handed straight back, with nothing recorded — hosts
    /// multiplex several push sources through one delegate.
    func testForegroundNotificationIgnoresForeignPush() async throws {
        let notification = try await deliverAndFetch(payload: ["aps": ["alert": "someone else's"]])

        XCTAssertNil(Arsel.handleForegroundNotification(notification))

        await Arsel.core?.flushNow()
        XCTAssertTrue(engagements().isEmpty)
    }

    // MARK: Delivery helper

    private func deliverAndFetch(payload: [AnyHashable: Any]) async throws -> UNNotification {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        try XCTSkipUnless(
            settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
            "runner lacks notification authorisation — grant it with `xcrun simctl privacy booted grant notifications`")

        let identifier = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = "Title"
        content.body = "Body"
        content.userInfo = payload
        try await center.add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))

        // Delivery is asynchronous; poll rather than sleep a fixed amount.
        for _ in 0..<20 {
            if let delivered = await center.deliveredNotifications()
                .first(where: { $0.request.identifier == identifier }) {
                return delivered
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw XCTSkip("notification was not delivered on this runner")
    }
}
#endif
