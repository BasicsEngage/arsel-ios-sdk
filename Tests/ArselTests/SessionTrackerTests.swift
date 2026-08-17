import XCTest
@testable import Arsel

final class SessionTrackerTests: XCTestCase {
    private var store: StateStore!
    private var captured: [QueuedRequest] = []
    private var events: EventController!
    private var now: Int64 = 1_700_000_000_000

    override func setUp() {
        super.setUp()
        store = StateStore(directory: tempDirectory(), log: quietLog)
        captured = []
        events = EventController(
            store: store, enqueue: { self.captured.append($0) }, log: quietLog,
            clock: { self.now })
    }

    private func makeTracker() -> SessionTracker {
        SessionTracker(store: store, events: events, clock: { self.now })
    }

    private func names() -> [String] {
        captured.map {
            (try! JSONSerialization.jsonObject(
                with: $0.body.data(using: .utf8)!) as! [String: Any])["event"] as! String
        }
    }

    private func body(at index: Int) -> [String: Any] {
        try! JSONSerialization.jsonObject(
            with: captured[index].body.data(using: .utf8)!) as! [String: Any]
    }

    func testFirstForegroundStartsASession() {
        makeTracker().onForeground()
        XCTAssertEqual(names(), ["arsel.session_start"])
        XCTAssertEqual(store.current.sessionStartedAtMs, now)
    }

    func testShortBackgroundIsTheSameSessionResuming() {
        let tracker = makeTracker()
        tracker.onForeground()
        now += 60_000
        tracker.onBackground()
        now += SessionTracker.sessionGapMs - 1
        tracker.onForeground()
        XCTAssertEqual(names(), ["arsel.session_start"], "a resume inside the gap is not an event")
    }

    func testLongAbsenceEndsTheOldSessionBackdated() {
        let tracker = makeTracker()
        tracker.onForeground()
        let openedAt = now
        now += 120_000
        tracker.onBackground()
        let hiddenAt = now
        now += SessionTracker.sessionGapMs + 1
        tracker.onForeground()

        XCTAssertEqual(names(), ["arsel.session_start", "arsel.session_end", "arsel.session_start"])
        let end = body(at: 1)
        // Backdated to when the app actually left, not to when we noticed.
        XCTAssertEqual(end["timestamp"] as? String, EventBodies.iso8601(timestampMs: hiddenAt))
        XCTAssertEqual((end["data"] as? [String: Any])?["duration_seconds"] as? Int,
                       Int((hiddenAt - openedAt) / 1000))
    }

    func testProcessDeathClampDropsTheDeadSessionUnclosed() {
        let tracker = makeTracker()
        tracker.onForeground()
        // The process died foregrounded: no background was ever recorded, and days
        // pass. Closing it would fabricate a multi-day session.
        now += SessionTracker.maxSessionMs + 1
        tracker.onForeground()

        XCTAssertEqual(names(), ["arsel.session_start", "arsel.session_start"],
                       "no session_end spanning the dead days")
    }

    func testQuickRelaunchInsideMaxSessionIsStillTheSameSession() {
        let tracker = makeTracker()
        tracker.onForeground()
        now += 60_000
        tracker.onForeground() // watcher re-fire / crash relaunch
        XCTAssertEqual(names(), ["arsel.session_start"])
    }

    func testBackgroundWithoutSessionIsIgnored() {
        makeTracker().onBackground()
        XCTAssertEqual(captured.count, 0)
        XCTAssertEqual(store.current.backgroundedAtMs, 0)
    }

    /// The queue record's age is measured from ENQUEUE, not from the (backdated)
    /// event timestamp — a backdated session_end must not arrive pre-expired.
    func testBackdatedSessionEndCarriesEnqueueTimeCreatedAt() {
        let tracker = makeTracker()
        tracker.onForeground()
        tracker.onBackground()
        now += SessionTracker.sessionGapMs + 1
        tracker.onForeground()

        let end = captured[1]
        XCTAssertEqual(end.createdAtMs, now, "createdAt is enqueue time")
        let timestamp = body(at: 1)["timestamp"] as? String
        XCTAssertNotEqual(timestamp, EventBodies.iso8601(timestampMs: now),
                          "the body timestamp stays backdated")
    }
}
