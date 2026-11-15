import Foundation
import XCTest
@testable import MightySPulse

final class DeliveryTests: XCTestCase {
    func testFirstBatchAfterInitializeLeavesAtOnce() {
        let h = Harness()
        h.runtime.track("first"); h.settle()
        XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertEqual(Harness.events(h.transport.requests[0]).count, 1)
        h.runtime.track("second"); h.settle()
        XCTAssertEqual(h.transport.requests.count, 1)
        h.advance(19.999); XCTAssertEqual(h.transport.requests.count, 1)
        h.advance(0.001); XCTAssertEqual(h.transport.requests.count, 2)
    }
    func testTimeCountAndBackgroundBatching() {
        var options = PulseOptions(); options.maxBatchSize = 2
        let h = Harness(options: options)
        h.runtime.track("one"); h.settle(); XCTAssertEqual(h.transport.requests.count, 1)
        h.runtime.track("timed"); h.settle(); XCTAssertEqual(h.transport.requests.count, 1)
        h.advance(19.999); XCTAssertEqual(h.transport.requests.count, 1)
        h.advance(0.001); XCTAssertEqual(h.transport.requests.count, 2)
        XCTAssertEqual(h.events.count, 2)
        h.runtime.track("two"); h.runtime.track("three"); h.settle()
        XCTAssertEqual(h.transport.requests.count, 3)
        XCTAssertEqual(Harness.events(h.transport.requests[2]).count, 2)
        h.runtime.track("background"); h.runtime.background(); h.settle()
        XCTAssertEqual(h.events.last?["type"] as? String, "background")
    }
    func testRetryableStatusesKeepExactWireBytes() {
        for status in [0, 302, 403, 408, 425, 429, 500, 502, 503, 599] {
            let h = Harness()
            h.transport.replies = [PulseResponse(status: status), PulseResponse(status: 202)]
            h.send("retry", props: ["large": String(repeating: "a", count: 1000)])
            XCTAssertEqual(h.transport.requests.count, 1, "status \(status)")
            let first = h.transport.requests[0]
            h.advance(0.999); XCTAssertEqual(h.transport.requests.count, 1)
            h.advance(0.001); XCTAssertEqual(h.transport.requests.count, 2)
            XCTAssertEqual(first.body, h.transport.requests.last?.body)
            XCTAssertEqual(first.gzip, h.transport.requests.last?.gzip)
            XCTAssertEqual(h.runtime.countForTests, 0)
        }
    }
    func testJitterExponentialBackoffAndCap() {
        for random in [0.0, 1.0] {
            let h = Harness(random: { random })
            h.transport.replies = (0..<12).map { _ in PulseResponse(status: 500) }
            h.send()
            for failure in 0..<12 {
                let delay = max(1, min(300, min(300, pow(2, Double(min(9, failure)))) * (0.5 + random)))
                let count = h.transport.requests.count
                h.advance(delay - 0.01); XCTAssertEqual(h.transport.requests.count, count)
                h.advance(0.01); XCTAssertEqual(h.transport.requests.count, count + 1)
            }
            XCTAssertEqual(h.runtime.countForTests, 0)
        }
    }
    func testRetryAfterSecondsDateCapAndBusyAdvice() {
        for status in [429, 503] {
            let h = Harness()
            h.transport.replies = [PulseResponse(status: status,
                body: Data("{\"recommendedSendIntervalSeconds\":30,\"pause\":false}".utf8), retryAfter: "60")]
            h.send(); h.advance(59.999); XCTAssertEqual(h.transport.requests.count, 1)
            h.advance(0.001); XCTAssertEqual(h.transport.requests.count, 2)
        }
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(PulseRuntime.retryAfter("999999999", now: now), now.addingTimeInterval(3600))
        XCTAssertEqual(PulseRuntime.retryAfter("Thu, 01 Jan 1970 00:02:00 GMT", now: now), now.addingTimeInterval(120))
        XCTAssertEqual(PulseRuntime.retryAfter("Fri, 02 Jan 1970 00:00:00 GMT", now: now), now.addingTimeInterval(3600))
        XCTAssertNil(PulseRuntime.retryAfter("bad", now: now))
        XCTAssertNil(PulseRuntime.retryAfter("-1", now: now))
        XCTAssertNil(PulseRuntime.retryAfter("infinity", now: now))
        let h = Harness(); h.transport.replies = [PulseResponse(status: 429, retryAfter: "999999999")]
        h.send(); h.advance(3599.999); XCTAssertEqual(h.transport.requests.count, 1)
        h.advance(0.001); XCTAssertEqual(h.transport.requests.count, 2)
    }
    func testBadEventsAreIsolatedWithBoundedRequests() {
        for status in [400, 413] {
            var options = PulseOptions(); options.maxBatchSize = 8; options.gzip = false
            let h = Harness(options: options)
            var delivered: [Int] = []
            h.transport.handler = { request, complete in
                let values = Harness.events(request).compactMap { ($0["value"] as? NSNumber)?.intValue }
                let bad = values.contains(2) || values.contains(5)
                if !bad { delivered.append(contentsOf: values) }
                complete(PulseResponse(status: bad ? status : 202))
            }
            for i in 0..<8 { h.runtime.track("event", value: Double(i)) }
            h.flush()
            XCTAssertEqual(delivered.sorted(), [0, 1, 3, 4, 6, 7])
            XCTAssertLessThanOrEqual(h.transport.requests.count, 15)
            XCTAssertEqual(h.runtime.countForTests, 0)
        }
    }
    func testUnauthorizedStopsUntilRestartAndPreservesQueue() {
        let h = Harness(); h.transport.replies = [PulseResponse(status: 401)]
        h.send(); h.runtime.track("new"); h.advance(3600); h.flush()
        XCTAssertEqual(h.transport.requests.count, 1)
        let restarted = Harness(storage: h.storage, clock: h.clock.fork())
        restarted.flush()
        XCTAssertEqual(restarted.events.count, 2)
        XCTAssertEqual(restarted.transport.requests[0].body, h.transport.requests[0].body)
    }
    func test415DisablesGzipUntilRestartAnd413OnlyForCurrentBatch() {
        for status in [415, 413] {
            let h = Harness(); h.transport.replies = [PulseResponse(status: status)]
            let props: [String: Any] = ["large": String(repeating: "q", count: 1000)]
            h.send("one", props: props)
            XCTAssertTrue(h.transport.requests[0].gzip)
            XCTAssertFalse(h.transport.requests[1].gzip)
            XCTAssertEqual(Harness.json(h.transport.requests[0]), h.transport.requests[1].body)
            h.send("two", props: props)
            XCTAssertEqual(h.transport.requests.last?.gzip, status == 413)
            h.transport.replies = [PulseResponse(status: 500)]
            h.send("retained")
            let restarted = Harness(storage: h.storage, clock: h.clock.fork())
            restarted.advance(1); restarted.send("after.restart", props: props)
            XCTAssertTrue(restarted.transport.requests.last!.gzip)
        }
    }
    func testFlushRespectsRetryDeadline() {
        let h = Harness(); h.transport.replies = [PulseResponse(status: 500, retryAfter: "60")]
        h.send(); h.flush(); h.runtime.background(); h.settle()
        XCTAssertEqual(h.transport.requests.count, 1)
        h.advance(60); XCTAssertEqual(h.transport.requests.count, 2)
    }
}
