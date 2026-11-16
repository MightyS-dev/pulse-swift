import Foundation
import XCTest
@testable import MightySPulse

/// Flush with nothing to deliver completes at once.
final class FlushEmptyQueueTests: XCTestCase {
    private func assertFlushCompletes(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(description: "flush")
        let start = Date()
        h.runtime.flush { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, file: file, line: line)
    }

    func testFlushOnAnEmptyQueueCompletesAtOnce() { assertFlushCompletes(Harness()) }

    func testFlushAfterEverythingWasDeliveredCompletesAtOnce() {
        let h = Harness(); h.send("a")
        XCTAssertFalse(h.transport.requests.isEmpty)
        assertFlushCompletes(h)
    }

    func testFlushBeforeInitializeCompletesAtOnce() { assertFlushCompletes(Harness(initialize: false)) }

    func testFlushOnAnEmptyQueueCompletesAtOnceWhenStorageFails() {
        let storage = FakeStorage(); storage.failReads = true; storage.failWrites = true
        assertFlushCompletes(Harness(storage: storage))
    }
}
