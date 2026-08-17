import XCTest
@testable import Arsel

final class EventBodiesTests: XCTestCase {
    func testSnakeCaseFieldNamesMatchIngestEventDto() {
        let body = EventBodies.event(
            name: "order.placed",
            properties: ["sku": "A-1023"],
            anonymousId: "anon-1",
            externalId: "u-9",
            email: "user@example.com",
            phoneNumber: "+966501234567",
            timestampMs: 1_700_000_000_000)
        XCTAssertEqual(body["event"] as? String, "order.placed")
        XCTAssertEqual(body["anonymous_id"] as? String, "anon-1")
        XCTAssertEqual(body["external_id"] as? String, "u-9")
        XCTAssertEqual(body["email"] as? String, "user@example.com")
        XCTAssertEqual(body["phone_number"] as? String, "+966501234567")
        XCTAssertEqual(body["timestamp"] as? String, "2023-11-14T22:13:20.000Z")
        XCTAssertEqual((body["data"] as? [String: Any])?["sku"] as? String, "A-1023")
        // Nothing the DTO would forbid.
        XCTAssertEqual(
            Set(body.keys),
            ["event", "anonymous_id", "external_id", "email", "phone_number", "data", "timestamp"])
    }

    func testUnsetIdentifiersAreAbsentNotNull() {
        let body = EventBodies.event(
            name: "e", properties: [:], anonymousId: "a",
            externalId: nil, email: nil, phoneNumber: nil, timestampMs: 0)
        XCTAssertFalse(body.keys.contains("external_id"))
        XCTAssertFalse(body.keys.contains("email"))
        XCTAssertFalse(body.keys.contains("phone_number"))
    }

    func testLengthCapsMirrorTheDto() {
        let body = EventBodies.event(
            name: String(repeating: "n", count: 200),
            properties: [:],
            anonymousId: String(repeating: "a", count: 200),
            externalId: String(repeating: "x", count: 300),
            email: nil, phoneNumber: nil, timestampMs: 0)
        XCTAssertEqual((body["event"] as? String)?.count, 80)
        XCTAssertEqual((body["anonymous_id"] as? String)?.count, 128)
        XCTAssertEqual((body["external_id"] as? String)?.count, 255)
    }

    func testSanitizeDateBecomesIso8601() {
        let data = EventBodies.sanitize(["at": Date(timeIntervalSince1970: 1_700_000_000)])
        XCTAssertEqual(data["at"] as? String, "2023-11-14T22:13:20.000Z")
    }

    func testSanitizePassesJsonSafeValuesAndStringifiesTheRest() {
        let data = EventBodies.sanitize([
            "s": "text", "i": 42, "d": 1.5, "b": true,
            "inf": Double.infinity,
            "url": URL(string: "https://arsel.sa")!,
        ])
        XCTAssertEqual(data["s"] as? String, "text")
        XCTAssertEqual(data["i"] as? Int, 42)
        XCTAssertEqual(data["d"] as? Double, 1.5)
        XCTAssertEqual(data["b"] as? Bool, true)
        // Non-finite numbers are not valid JSON — stringified, not dropped.
        XCTAssertEqual(data["inf"] as? String, "inf")
        XCTAssertNotNil(data["url"] as? String)
    }

    func testSanitizeNestedStructuresAndDepthCap() {
        let nested: [String: Any] = ["l1": ["l2": ["l3": "deep"] as [String: Any]] as [String: Any]]
        let data = EventBodies.sanitize(nested)
        let l1 = data["l1"] as? [String: Any]
        let l2 = l1?["l2"] as? [String: Any]
        XCTAssertEqual(l2?["l3"] as? String, "deep")

        // Something nested past the cap is dropped, not sent malformed.
        var deep: Any = "leaf"
        for _ in 0..<20 { deep = ["k": deep] }
        let capped = EventBodies.sanitize(["root": deep])
        let encoded = try? JSONSerialization.data(withJSONObject: capped)
        XCTAssertNotNil(encoded, "sanitized output must always be serializable")
    }

    func testSanitizeDropsOversizedProperties() {
        let big = String(repeating: "x", count: 70 * 1024)
        let data = EventBodies.sanitize(["big": big, "small": "ok"])
        XCTAssertNil(data["big"])
        XCTAssertEqual(data["small"] as? String, "ok")
    }

    func testReservedNames() {
        XCTAssertTrue(EventBodies.sessionStart.hasPrefix("arsel."))
        XCTAssertTrue(EventBodies.sessionEnd.hasPrefix("arsel."))
        XCTAssertTrue(EventBodies.identify.hasPrefix("arsel."))
    }
}

final class IdentifiersTests: XCTestCase {
    func testValidPhones() {
        XCTAssertTrue(Identifiers.isValidPhone("+966501234567"))
        XCTAssertTrue(Identifiers.isValidPhone("+201001234567"))
        XCTAssertTrue(Identifiers.isValidPhone("+14155552671"))
        XCTAssertTrue(Identifiers.isValidPhone("+1234567"))       // 7 digits: minimum
        XCTAssertTrue(Identifiers.isValidPhone("+123456789012345")) // 15 digits: maximum
    }

    func testInvalidPhones() {
        XCTAssertFalse(Identifiers.isValidPhone("966501234567"))   // no +
        XCTAssertFalse(Identifiers.isValidPhone("+0501234567"))    // leading zero
        XCTAssertFalse(Identifiers.isValidPhone("+123456"))        // too short
        XCTAssertFalse(Identifiers.isValidPhone("+1234567890123456")) // too long
        XCTAssertFalse(Identifiers.isValidPhone("+96650123456a"))
        XCTAssertFalse(Identifiers.isValidPhone("+966 501234567"))
        XCTAssertFalse(Identifiers.isValidPhone(""))
    }

    func testValidEmails() {
        XCTAssertTrue(Identifiers.isValidEmail("user@example.com"))
        XCTAssertTrue(Identifiers.isValidEmail("a.b+tag@sub.domain.sa"))
    }

    func testInvalidEmails() {
        XCTAssertFalse(Identifiers.isValidEmail("user"))
        XCTAssertFalse(Identifiers.isValidEmail("user@"))
        XCTAssertFalse(Identifiers.isValidEmail("@example.com"))
        XCTAssertFalse(Identifiers.isValidEmail("user@nodot"))
        XCTAssertFalse(Identifiers.isValidEmail("user@domain."))
        XCTAssertFalse(Identifiers.isValidEmail("us er@example.com"))
        XCTAssertFalse(Identifiers.isValidEmail("a@b@c.com"))
    }
}
