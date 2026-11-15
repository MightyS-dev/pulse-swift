import Foundation
import XCTest
@testable import MightySPulse

final class AdviceTests: XCTestCase {
    func testRecommendationAndPauseOverrideCountFlushAndBackground() {
        var options = PulseOptions(); options.maxBatchSize = 2
        let h = Harness(options: options)
        h.transport.replies = [PulseResponse(status: 202,
            body: Data("{\"recommendedSendIntervalSeconds\":120,\"pause\":true,\"error\":null}".utf8))]
        h.send("first")
        h.runtime.track("two"); h.runtime.track("three"); h.flush(); h.runtime.background(); h.settle()
        h.advance(119.999); XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertEqual(h.runtime.countForTests, 2)
        h.advance(0.001); XCTAssertEqual(h.transport.requests.count, 2)
        h.runtime.track("four"); h.settle()
        h.advance(119.999); XCTAssertEqual(h.transport.requests.count, 2)
        h.advance(0.001); XCTAssertEqual(h.transport.requests.count, 3)
    }
    func testAdviceClampsAndInvalidFieldsDoNotHidePause() {
        let cases: [(String, Double)] = [
            ("{\"recommendedSendIntervalSeconds\":1,\"pause\":true}", 5),
            ("{\"recommendedSendIntervalSeconds\":999999,\"pause\":true}", 3600),
            ("{\"recommendedSendIntervalSeconds\":\"bad\",\"pause\":true}", 20),
            ("{\"recommendedSendIntervalSeconds\":-1,\"pause\":true}", 20),
            ("{\"pause\":true}", 20)]
        for (body, interval) in cases {
            let h = Harness(); h.transport.replies = [PulseResponse(status: 202, body: Data(body.utf8))]
            h.send(); h.runtime.track("paused"); h.flush()
            h.advance(interval - 0.001); XCTAssertEqual(h.transport.requests.count, 1, body)
            h.advance(0.001); XCTAssertEqual(h.transport.requests.count, 2, body)
        }
    }
    func testEmptyUnknownAndMalformedAdviceKeepsDefaultInterval() {
        for body in ["", "null", "[]", "malformed", "{}", "{\"pause\":\"true\"}",
                     "{\"recommendedSendIntervalSeconds\":0}", "{\"recommendedSendIntervalSeconds\":true}",
                     "{\"recommendedSendIntervalSeconds\":-1}", "{\"RecommendedSendIntervalSeconds\":60}",
                     "{\"recommendedSendIntervalSeconds\":60,\"recommendedSendIntervalSeconds\":30}",
                     "{\"unknown\":{\"nested\":[true,false,null]}}", String(repeating: "x", count: 65537)] {
            let h = Harness(); h.transport.replies = [PulseResponse(status: 202, body: Data(body.utf8))]
            h.send(); h.runtime.track("next"); h.settle()
            h.advance(19.999); XCTAssertEqual(h.transport.requests.count, 1, body.prefix(80).description)
            h.advance(0.001); XCTAssertEqual(h.transport.requests.count, 2)
        }
    }
    func testBusyAdviceUsesLongestDeadlineAndSurvivesRestart() {
        let h = Harness()
        h.transport.replies = [PulseResponse(status: 503,
            body: Data("{\"recommendedSendIntervalSeconds\":30,\"pause\":false}".utf8), retryAfter: "60")]
        h.send(); let first = h.transport.requests[0]
        let restarted = Harness(storage: h.storage, clock: h.clock.fork())
        restarted.flush(); restarted.advance(59.999)
        XCTAssertTrue(restarted.transport.requests.isEmpty)
        restarted.advance(0.001)
        XCTAssertEqual(restarted.transport.requests[0].body, first.body)
        XCTAssertEqual(restarted.runtime.countForTests, 0)
    }
    func testPauseKeepsNewestSignalsAndExpiresOldOnes() {
        var options = PulseOptions(); options.maxQueueSize = 3; options.maxBatchSize = 2
        let h = Harness(options: options)
        h.transport.replies = [PulseResponse(status: 202,
            body: Data("{\"recommendedSendIntervalSeconds\":30,\"pause\":true}".utf8))]
        h.send("first")
        for i in 0..<5 { h.runtime.track("queued", value: Double(i)); h.settle() }
        XCTAssertEqual(h.runtime.countForTests, 3)
        h.flush(); h.advance(30)
        XCTAssertEqual(h.events.dropFirst().compactMap { $0["value"] as? Double }, [2, 3, 4])
        var short = PulseOptions(); short.maxQueueAgeDays = 0.0001
        let expiring = Harness(options: short)
        expiring.transport.replies = [PulseResponse(status: 202, body: Data("{\"pause\":true}".utf8))]
        expiring.send("first"); expiring.runtime.track("expires"); expiring.settle()
        expiring.advance(19); expiring.runtime.track("fresh"); expiring.settle()
        expiring.flush(); expiring.advance(1)
        XCTAssertEqual(expiring.events.compactMap { $0["type"] as? String }, ["first", "fresh"])
    }
    func testAdviceShapeRejectsDuplicateEscapedKeysAndDeepNesting() {
        XCTAssertFalse(PulseAdviceShape.accepts(Data("{\"pause\":true,\"pa\\u0075se\":false}".utf8)))
        XCTAssertFalse(PulseAdviceShape.accepts(Data((String(repeating: "[", count: 34) + String(repeating: "]", count: 34)).utf8)))
        XCTAssertTrue(PulseAdviceShape.accepts(Data("{\"pa\\u0075se\":true,\"unknown\":{\"nested\":[null,1,\"quoted\\\"value\"]}}".utf8)))
        XCTAssertFalse(PulseAdviceShape.accepts(Data("{\"pause\":true,}".utf8)))
    }
}
