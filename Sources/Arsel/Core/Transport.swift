import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TransportResult {
    case success
    case retryable
    /// On an authed route, the device secret is no longer accepted. Re-registering
    /// mints a new one; retrying with the old one never succeeds.
    case reauth
    case permanent
}

struct TransportResponse {
    let result: TransportResult
    let code: Int
    let body: Data?
    /// Parsed `Retry-After`, when the server asked us to wait a specific amount.
    let retryAfterMs: Int64?
}

/// No status line at all — DNS failure, offline, TLS error.
let CODE_NO_RESPONSE = -1

protocol Transport {
    /// Blocking; only ever called on the drain queue, never the main thread.
    func post(url: URL, body: Data, headers: [String: String], authenticated: Bool) -> TransportResponse
}

/// Status → retry policy. Pure, and the same table the Android and web SDKs use:
/// this is the decision that separates a device that eventually delivers from one
/// that gives up forever.
func classify(code: Int, authenticated: Bool) -> TransportResult {
    if (200...299).contains(code) { return .success }
    if code == 408 || code == 429 || (500...599).contains(code) { return .retryable }
    // Behind the backend's deliberately opaque 404, an authed 401/403/404 all mean
    // one thing: this secret is dead.
    if authenticated && (code == 401 || code == 403 || code == 404) { return .reauth }
    // An unknown push key and an org whose push channel is not switched on yet both answer a
    // bare 404. The second is ordinary onboarding — giving up permanently here would
    // strand a device that would have worked tomorrow.
    if code == 404 { return .retryable }
    return .permanent
}

/// RFC 7231 allows delta-seconds or an HTTP-date; servers in the wild send both.
func parseRetryAfterMs(_ rawHeader: String?, nowMs: Int64 = nowMillis()) -> Int64? {
    guard let header = rawHeader?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
    if let seconds = Int64(header) { return max(0, seconds * 1000) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: header) else { return nil }
    return max(0, Int64(date.timeIntervalSince1970 * 1000) - nowMs)
}

func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

final class URLSessionTransport: Transport {
    private let session: URLSession
    private let timeout: TimeInterval
    private let log: ArselLog

    init(timeout: TimeInterval, log: ArselLog) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        // The SDK never relies on cookies; a cross-origin credential would ride for no reason.
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
        self.timeout = timeout
        self.log = log
    }

    func post(url: URL, body: Data, headers: [String: String], authenticated: Bool) -> TransportResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Wire.sdkHeaderValue, forHTTPHeaderField: Wire.sdkHeader)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        // Blocking bridge: the drain loop is sequential by design (stop at the first
        // retryable failure), so an async pipeline here would buy nothing.
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: TransportResponse = TransportResponse(
            result: .retryable, code: CODE_NO_RESPONSE, body: nil, retryAfterMs: nil)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil, let http = response as? HTTPURLResponse else {
                outcome = TransportResponse(result: .retryable, code: CODE_NO_RESPONSE, body: nil, retryAfterMs: nil)
                return
            }
            let retryAfter = parseRetryAfterMs(http.value(forHTTPHeaderField: "Retry-After"))
            outcome = TransportResponse(
                result: classify(code: http.statusCode, authenticated: authenticated),
                code: http.statusCode,
                body: data,
                retryAfterMs: retryAfter)
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            log.w("POST \(url.path) hung past its timeout — treating as a network failure")
            return TransportResponse(result: .retryable, code: CODE_NO_RESPONSE, body: nil, retryAfterMs: nil)
        }
        if outcome.result != .success {
            log.w("POST \(url.path) -> \(outcome.code) (\(outcome.result))")
        }
        return outcome
    }
}
