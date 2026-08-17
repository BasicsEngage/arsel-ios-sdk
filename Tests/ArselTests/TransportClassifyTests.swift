import XCTest
@testable import Arsel

final class TransportClassifyTests: XCTestCase {
    func testSuccessRange() {
        XCTAssertEqual(classify(code: 200, authenticated: false), .success)
        XCTAssertEqual(classify(code: 201, authenticated: true), .success)
        XCTAssertEqual(classify(code: 299, authenticated: false), .success)
    }

    func testRetryable() {
        XCTAssertEqual(classify(code: 408, authenticated: false), .retryable)
        XCTAssertEqual(classify(code: 429, authenticated: false), .retryable)
        XCTAssertEqual(classify(code: 429, authenticated: true), .retryable)
        XCTAssertEqual(classify(code: 500, authenticated: false), .retryable)
        XCTAssertEqual(classify(code: 503, authenticated: true), .retryable)
        XCTAssertEqual(classify(code: 599, authenticated: false), .retryable)
    }

    func testAuthenticatedRejectionsMeanDeadSecret() {
        XCTAssertEqual(classify(code: 401, authenticated: true), .reauth)
        XCTAssertEqual(classify(code: 403, authenticated: true), .reauth)
        XCTAssertEqual(classify(code: 404, authenticated: true), .reauth)
    }

    /// An unknown push key and an org whose push channel is not yet enabled both answer a
    /// bare 404; the second is ordinary onboarding, so it must stay retryable.
    func testUnauthenticated404IsRetryable() {
        XCTAssertEqual(classify(code: 404, authenticated: false), .retryable)
    }

    func testPermanent() {
        XCTAssertEqual(classify(code: 400, authenticated: false), .permanent)
        XCTAssertEqual(classify(code: 400, authenticated: true), .permanent)
        XCTAssertEqual(classify(code: 401, authenticated: false), .permanent)
        XCTAssertEqual(classify(code: 413, authenticated: false), .permanent)
        XCTAssertEqual(classify(code: 422, authenticated: true), .permanent)
    }

    func testRetryAfterDeltaSeconds() {
        XCTAssertEqual(parseRetryAfterMs("30"), 30_000)
        XCTAssertEqual(parseRetryAfterMs("0"), 0)
        XCTAssertNil(parseRetryAfterMs(nil))
        XCTAssertNil(parseRetryAfterMs(""))
        XCTAssertNil(parseRetryAfterMs("soon"))
    }

    func testRetryAfterHttpDate() {
        let now: Int64 = 1_700_000_000_000 // 2023-11-14T22:13:20Z
        let value = parseRetryAfterMs("Tue, 14 Nov 2023 22:14:20 GMT", nowMs: now)
        XCTAssertEqual(value, 60_000)
        // A date in the past clamps to zero rather than going negative.
        XCTAssertEqual(parseRetryAfterMs("Tue, 14 Nov 2023 22:12:20 GMT", nowMs: now), 0)
    }
}
