import XCTest
@testable import ArselNotificationExtension

final class ExtensionEngagementTests: XCTestCase {
    func testDeliveredBodyMatchesEngagementBatchDto() throws {
        let body = ExtensionEngagement.deliveredBody(
            installationId: "inst-1",
            messageId: "mid-1",
            signature: "sig",
            signatureKeyId: "kid",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(body["installationId"] as? String, "inst-1")
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["messageId"] as? String, "mid-1")
        XCTAssertEqual(events[0]["eventType"] as? String, "delivered")
        XCTAssertEqual(events[0]["signature"] as? String, "sig")
        XCTAssertEqual(events[0]["signatureKeyId"] as? String, "kid")
        XCTAssertEqual(events[0]["timestamp"] as? String, "2023-11-14T22:13:20.000Z")
    }

    func testDeliveredBodyOmitsAbsentSignature() throws {
        let body = ExtensionEngagement.deliveredBody(
            installationId: "inst-1", messageId: "mid-1", signature: nil, signatureKeyId: nil)
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertNil(events[0]["signature"])
        XCTAssertNil(events[0]["signatureKeyId"])
    }

    func testContextDecodeRoundTrip() throws {
        let json = #"{"clientKey":"pub_abc","baseUrl":"https://api.arsel.sa","installationId":"i-1","keychainAccessGroup":"TEAM.group"}"#
        let context = try XCTUnwrap(ExtensionContext.decode(Data(json.utf8)))
        XCTAssertEqual(context.clientKey, "pub_abc")
        XCTAssertEqual(context.baseUrl, "https://api.arsel.sa")
        XCTAssertEqual(context.installationId, "i-1")
        XCTAssertEqual(context.keychainAccessGroup, "TEAM.group")
    }

    func testContextDecodeRejectsMissingFields() {
        XCTAssertNil(ExtensionContext.decode(Data(#"{"clientKey":"pub_abc"}"#.utf8)))
        XCTAssertNil(ExtensionContext.decode(Data("not json".utf8)))
    }
}
