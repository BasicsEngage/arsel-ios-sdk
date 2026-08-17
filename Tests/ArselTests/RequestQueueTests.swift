import XCTest
@testable import Arsel

final class RequestQueueTests: XCTestCase {
    func testPersistsAcrossInstancesInOrder() {
        let dir = tempDirectory()
        let first = RequestQueue(directory: dir, log: quietLog)
        first.enqueue(makeQueuedEvent(id: "a"))
        first.enqueue(makeQueuedEvent(id: "b"))
        first.enqueue(makeQueuedEvent(id: "c"))

        // A new instance over the same directory is "the process died and relaunched".
        let second = RequestQueue(directory: dir, log: quietLog)
        XCTAssertEqual(second.snapshot().map(\.id), ["a", "b", "c"])
    }

    func testRemoveSettledIds() {
        let dir = tempDirectory()
        let queue = RequestQueue(directory: dir, log: quietLog)
        queue.enqueue(makeQueuedEvent(id: "a"))
        queue.enqueue(makeQueuedEvent(id: "b"))
        queue.remove(ids: ["a"])
        XCTAssertEqual(queue.snapshot().map(\.id), ["b"])
        XCTAssertEqual(RequestQueue(directory: dir, log: quietLog).snapshot().map(\.id), ["b"])
    }

    func testDedupeKeyEvictsOlderRequest() {
        let queue = RequestQueue(directory: tempDirectory(), log: quietLog)
        queue.enqueue(QueuedRequest(
            id: "r1", kind: .register, body: "{}", dedupeKey: "register", createdAtMs: 1))
        queue.enqueue(makeQueuedEvent(id: "e1"))
        queue.enqueue(QueuedRequest(
            id: "r2", kind: .register, body: "{}", dedupeKey: "register", createdAtMs: 2))
        XCTAssertEqual(queue.snapshot().map(\.id), ["e1", "r2"])
    }

    func testEventsNeverEvictEachOther() {
        let queue = RequestQueue(directory: tempDirectory(), log: quietLog)
        for index in 0..<10 { queue.enqueue(makeQueuedEvent(id: "e\(index)")) }
        XCTAssertEqual(queue.count, 10)
    }

    func testDepthCapDropsOldest() {
        let queue = RequestQueue(directory: tempDirectory(), log: quietLog, maxDepth: 25)
        for index in 0...25 {
            queue.enqueue(makeQueuedEvent(id: "e\(index)"))
        }
        XCTAssertEqual(queue.count, 25)
        XCTAssertEqual(queue.snapshot().first?.id, "e1")
    }

    func testCorruptFileStartsEmptyRatherThanCrashing() throws {
        let dir = tempDirectory()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("queue.json"))
        XCTAssertEqual(RequestQueue(directory: dir, log: quietLog).count, 0)
    }

    func testDrainPolicyAgeCap() {
        let now: Int64 = 10 * 24 * 60 * 60 * 1000
        XCTAssertTrue(DrainPolicy.isExpired(createdAtMs: 0, nowMs: now))
        XCTAssertFalse(DrainPolicy.isExpired(createdAtMs: now - DrainPolicy.maxAgeMs, nowMs: now))
        XCTAssertTrue(DrainPolicy.isExpired(createdAtMs: now - DrainPolicy.maxAgeMs - 1, nowMs: now))
    }
}
