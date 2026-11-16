import Foundation
import XCTest
@testable import MightySPulse

final class BatchIdTests: XCTestCase {
    private let large: [String: Any] = ["large": String(repeating: "a", count: 1000)]

    func testIdIsThirtyTwoLowercaseHexCharacters() throws {
        let h = Harness()
        h.send("one")
        let id = try XCTUnwrap(h.transport.requests[0].batchId)
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(PulseBatchID.isValid(id))
        XCTAssertEqual(id, id.lowercased())
        XCTAssertFalse(PulseBatchID.isValid(id.uppercased() + "0"))
        XCTAssertFalse(PulseBatchID.isValid(String(id.dropFirst())))
        XCTAssertFalse(PulseBatchID.isValid(String(repeating: "g", count: 32)))
    }
    func testSameIdAndSameContentOnRetryAfterEveryRetryableFailure() throws {
        for status in [0, 429, 500, 503] {
            let h = Harness()
            h.transport.replies = [PulseResponse(status: status), PulseResponse(status: 202)]
            h.send("retry", props: large)
            h.advance(1)
            XCTAssertEqual(h.transport.requests.count, 2, "status \(status)")
            let first = h.transport.requests[0], second = h.transport.requests[1]
            XCTAssertNotNil(first.batchId)
            XCTAssertEqual(first.batchId, second.batchId, "status \(status)")
            XCTAssertEqual(Harness.json(first), Harness.json(second))
        }
    }
    func testSignalAddedBeforeRetryGoesToANewBatchWithANewId() throws {
        let h = Harness()
        h.transport.replies = [PulseResponse(status: 500), PulseResponse(status: 202), PulseResponse(status: 202)]
        h.send("original")
        h.runtime.track("newer"); h.settle()
        h.advance(1)
        let first = h.transport.requests[0], retry = h.transport.requests[1]
        XCTAssertEqual(first.batchId, retry.batchId)
        XCTAssertEqual(Harness.json(first), Harness.json(retry))
        h.advance(20)
        let next = try XCTUnwrap(h.transport.requests.last)
        XCTAssertEqual(Harness.events(next).map { $0["type"] as? String }, ["newer"])
        XCTAssertNotEqual(next.batchId, first.batchId)
    }
    func testIdAndContentSurviveARestartWithTheBatchInFlight() throws {
        let h = Harness(); h.transport.replies = [PulseResponse(status: 500, retryAfter: "60")]
        h.send("original", props: large)
        let first = h.transport.requests[0]
        let restarted = Harness(storage: h.storage, clock: h.clock.fork())
        restarted.advance(60)
        let resent = try XCTUnwrap(restarted.transport.requests.first)
        XCTAssertEqual(first.batchId, resent.batchId)
        XCTAssertEqual(Harness.json(first), Harness.json(resent))
    }
    func testConsecutiveBatchesHaveDifferentIds() throws {
        let h = Harness()
        h.send("one"); h.send("two"); h.send("three")
        let ids = h.transport.requests.compactMap(\.batchId)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 3)
    }
    func testSplitAfter400GivesEachHalfItsOwnNewId() throws {
        let h = Harness()
        h.transport.replies = [PulseResponse(status: 400), PulseResponse(status: 202), PulseResponse(status: 202)]
        h.runtime.track("a"); h.runtime.track("b"); h.flush()
        XCTAssertEqual(h.transport.requests.count, 3)
        let ids = h.transport.requests.compactMap(\.batchId)
        XCTAssertEqual(Set(ids).count, 3)
    }
    func testGzipFallbackKeepsTheIdBecauseTheContentIsTheSame() throws {
        let h = Harness(); h.transport.replies = [PulseResponse(status: 415)]
        h.send("one", props: large)
        XCTAssertEqual(h.transport.requests.count, 2)
        XCTAssertEqual(h.transport.requests[0].batchId, h.transport.requests[1].batchId)
        XCTAssertEqual(Harness.json(h.transport.requests[0]), h.transport.requests[1].body)
    }
    func testSavedBatchFromAnOlderFileGetsAValidId() throws {
        let batch = PulseBatch(ids: [UUID()], json: Data("[]".utf8), wire: Data("[]".utf8), gzip: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        object.removeValue(forKey: "batchId")
        let older = try JSONDecoder().decode(PulseBatch.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(PulseBatchID.isValid(older.batchId))
        object["batchId"] = "not-an-id"
        let bad = try JSONDecoder().decode(PulseBatch.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(PulseBatchID.isValid(bad.batchId))
    }
    func testBackgroundSaveKeepsTheIdForTheNextLaunch() throws {
        let h = Harness(); h.transport.replies = [PulseResponse(status: 500, retryAfter: "60")]
        h.send("original")
        let first = h.transport.requests[0]
        h.runtime.background(); h.runtime.backgroundSave(); h.settle()
        let restarted = Harness(storage: h.storage, clock: h.clock.fork())
        restarted.advance(60)
        XCTAssertEqual(restarted.transport.requests.first?.batchId, first.batchId)
    }
    func testConfigRequestCarriesNoBatchId() {
        let h = Harness(fetchesConfig: true)
        h.send("one")
        for request in h.transport.requests where request.method == "GET" { XCTAssertNil(request.batchId) }
    }
}
