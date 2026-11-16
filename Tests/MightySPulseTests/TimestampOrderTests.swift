import Foundation
import XCTest
@testable import MightySPulse

final class TimestampOrderTests: XCTestCase {
    private func millis(_ event: [String: Any]) -> Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: event["timestamp"] as! String)!
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
    private func types(_ events: [[String: Any]]) -> [String] { events.map { $0["type"] as! String } }

    func testThreeSignalsInTheSameMillisecondGetPlusZeroPlusOnePlusTwo() {
        let h = Harness()
        h.runtime.track("a"); h.runtime.track("b"); h.runtime.track("c"); h.flush()
        let stamps = h.events.map(millis)
        XCTAssertEqual(types(h.events), ["a", "b", "c"])
        XCTAssertEqual(stamps, [stamps[0], stamps[0] + 1, stamps[0] + 2])
    }
    func testAutomaticSignalsComeBeforeTheTriggerInOrderAndTime() {
        let h = Harness(automatic: true)
        h.runtime.track("first"); h.runtime.track("second"); h.flush()
        let events = h.events
        XCTAssertEqual(types(events).suffix(2), ["first", "second"])
        let stamps = events.map(millis)
        XCTAssertGreaterThanOrEqual(events.count, 3)
        for index in 1..<stamps.count { XCTAssertEqual(stamps[index], stamps[index - 1] + 1) }
        XCTAssertTrue(types(events).prefix(events.count - 2).allSatisfy { $0.hasPrefix("pulse.") })
    }
    func testSignalsTrackedBeforeInitializeKeepTheirCaptureOrder() {
        let h = Harness(initialize: false)
        h.runtime.track("a"); h.runtime.track("b")
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        h.runtime.track("c"); h.flush()
        let stamps = h.events.map(millis)
        XCTAssertEqual(types(h.events), ["a", "b", "c"])
        XCTAssertEqual(stamps, [stamps[0], stamps[0] + 1, stamps[0] + 2])
    }
    func testAClockThatGoesBackwardsStillYieldsIncreasingTimestamps() {
        let h = Harness()
        h.runtime.track("a"); h.settle()
        h.clock.advance(-5); h.runtime.track("b"); h.settle()
        h.runtime.track("c"); h.flush()
        let stamps = h.events.map(millis)
        XCTAssertEqual(types(h.events), ["a", "b", "c"])
        XCTAssertEqual(stamps, [stamps[0], stamps[0] + 1, stamps[0] + 2])
    }
    func testALaterClockReadingIsKept() {
        let h = Harness()
        h.runtime.track("a"); h.settle()
        h.clock.advance(2); h.runtime.track("b"); h.flush()
        let stamps = h.events.map(millis)
        XCTAssertEqual(stamps[1] - stamps[0], 2000)
    }
}
