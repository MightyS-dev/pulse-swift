import Foundation
import XCTest
@testable import MightySPulse

/// A new session id starts when the next signal arrives 30 minutes or more after the previous signal.
final class SessionRuleTests: XCTestCase {
    private func ids(_ h: Harness, _ type: String) -> [String] {
        h.events.filter { $0["type"] as? String == type }.map { $0["sessionId"] as! String }
    }
    private func started(_ h: Harness) -> Int { h.events.filter { $0["type"] as? String == "pulse.session_started" }.count }

    func testSameIdWithin29MinutesAndNewIdAtThirty() {
        let h = Harness(automatic: true)
        h.send("a")
        h.advance(29 * 60 + 59); h.send("b")
        XCTAssertEqual(Set(ids(h, "a") + ids(h, "b")).count, 1)
        h.advance(30 * 60); h.send("c")
        XCTAssertNotEqual(ids(h, "c")[0], ids(h, "b")[0])
        XCTAssertEqual(started(h), 2)
    }

    func testExactlyThirtyMinutesRotates() {
        let h = Harness(automatic: true)
        h.send("a"); h.advance(1800); h.send("b")
        XCTAssertNotEqual(ids(h, "a")[0], ids(h, "b")[0])
        XCTAssertEqual(started(h), 2)
    }

    func testFourteenHourGapInsideOneRunningProcessRotatesOnce() {
        let h = Harness(automatic: true)
        h.send("a")
        h.advance(14 * 3600); h.send("b"); h.send("c")
        XCTAssertNotEqual(ids(h, "a")[0], ids(h, "b")[0])
        XCTAssertEqual(ids(h, "b"), ids(h, "c"))
        XCTAssertEqual(started(h), 2)
    }

    func testRestartAfter31MinutesGivesNewIdAndOneSessionStarted() {
        let first = Harness(automatic: true)
        first.send("a")
        let second = Harness(storage: first.storage, clock: first.clock.fork(advancing: 31 * 60), automatic: true)
        second.send("b")
        XCTAssertNotEqual(ids(first, "a")[0], ids(second, "b")[0])
        XCTAssertEqual(started(second), 1)
    }

    func testFlushAndTimersAloneDoNotExtendASession() {
        let h = Harness(automatic: true)
        h.send("a")
        for _ in 0..<40 { h.advance(60); h.flush() }
        h.send("b")
        XCTAssertNotEqual(ids(h, "a")[0], ids(h, "b")[0])
        XCTAssertEqual(started(h), 2)
    }

    func testIdleIsMeasuredFromTheLastSignalNotTheSessionStart() {
        let h = Harness(automatic: true)
        h.send("a")
        h.advance(20 * 60); h.send("b")
        h.advance(20 * 60); h.send("c")
        XCTAssertEqual(Set(ids(h, "a") + ids(h, "b") + ids(h, "c")).count, 1)
        h.advance(40 * 60); h.flush(); h.advance(5 * 60); h.send("d")
        XCTAssertNotEqual(ids(h, "c")[0], ids(h, "d")[0])
        XCTAssertEqual(started(h), 2)
    }

    func testSignalsTrackedBeforeInitializeUseTheirOwnCaptureTime() {
        let h = Harness(initialize: false, automatic: true)
        h.runtime.track("early1"); h.settle()
        h.clock.advance(14 * 3600)
        h.runtime.track("early2"); h.settle()
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        h.flush()
        XCTAssertNotEqual(ids(h, "early1")[0], ids(h, "early2")[0])
        XCTAssertEqual(started(h), 2)
    }

    func testDroppedInvalidSignalsNeitherStartNorExtendASession() {
        let h = Harness(automatic: true)
        h.send("a")
        for _ in 0..<5 { h.advance(10 * 60); h.runtime.track("   "); h.runtime.track("bad", value: .nan); h.flush() }
        h.send("b")
        XCTAssertNotEqual(ids(h, "a")[0], ids(h, "b")[0])
        XCTAssertEqual(started(h), 2)
        XCTAssertEqual(h.events.filter { ($0["type"] as? String)?.hasPrefix("pulse.") == false }.count, 2)
    }
}
