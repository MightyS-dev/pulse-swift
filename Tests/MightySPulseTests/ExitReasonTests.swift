import Foundation
import XCTest
@testable import MightySPulse

final class ExitReasonTests: XCTestCase {
    private func payload(_ end: Date, _ json: Data) -> PulseExitPayload { PulseExitPayload(json: json, end: end) }
    private func harness(exits: FakeExits = FakeExits(), options: PulseOptions = PulseOptions(), config: String? = nil,
                         storage: FakeStorage? = nil, clock: FakeClock = FakeClock()) -> Harness {
        Harness(options: options, storage: storage ?? AutoFixtures.storage(config: config), clock: clock, automatic: true, exits: exits)
    }
    private func errors(_ h: Harness) -> [[String: Any]] { h.eventsOfType("pulse.error") }
    private func error(_ event: [String: Any]) -> [String: Any] { event["error"] as? [String: Any] ?? [:] }
    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: parsing the MetricKit JSON

    func testFixtureGivesOneRecordPerDiagnosticWithTheMappedReason() throws {
        let end = Date(timeIntervalSince1970: 1794556800)
        let records = PulseExitPayload.records(json: try AutoFixtures.fixture("metrickit-diagnostics-full"), end: end)
        XCTAssertEqual(records.map(\.reason), ["crash", "hang", "cpu_exception", "disk_write_exception"])
        XCTAssertTrue(records.allSatisfy { $0.time == end })
    }
    func testCrashFramesComeFromTheAttributedThreadTopFirstAndAreAddresses() throws {
        let records = PulseExitPayload.records(json: try AutoFixtures.fixture("metrickit-diagnostics-full"),
                                               end: Date(timeIntervalSince1970: 1794556800))
        XCTAssertEqual(records[0].frames, ["MyApp+0x124f7", "MyApp+0x12345", "dyld+0x1000"])
        XCTAssertEqual(records[1].frames, ["UIKitCore+0x9", "MyApp+0x200"])
        XCTAssertEqual(records[2].frames, ["MyApp+0x4d"])
        XCTAssertEqual(records[3].frames, [])
    }
    func testNothingBeyondReasonTimeAndTraceIsRead() throws {
        let records = PulseExitPayload.records(json: try AutoFixtures.fixture("metrickit-diagnostics-full"),
                                               end: Date(timeIntervalSince1970: 1794556800))
        for record in records {
            let text = "\(record)"
            XCTAssertFalse(text.contains("com.example.secret")); XCTAssertFalse(text.contains("1.2.3"))
        }
    }
    func testDamagedOrUnknownJsonGivesNoRecordsAndNeverThrows() {
        for text in ["", "nope", "[]", "{}", "{\"crashDiagnostics\":5}", "{\"crashDiagnostics\":[7,null]}"] {
            _ = PulseExitPayload.records(json: Data(text.utf8), end: Date())
        }
        XCTAssertTrue(PulseExitPayload.records(json: Data("{\"crashDiagnostics\":[7]}".utf8), end: Date()).isEmpty,
                      "an entry that is not an object is skipped")
        let bare = PulseExitPayload.records(json: Data("{\"crashDiagnostics\":[{}]}".utf8), end: Date())
        XCTAssertEqual(bare.map(\.reason), ["crash"]); XCTAssertEqual(bare[0].frames, [])
    }
    func testTimestampTextAndFallbackToTheJsonEndTime() {
        XCTAssertEqual(PulseExitPayload.parseTime("2026-11-16 08:00:00"), Date(timeIntervalSince1970: 1794556800 + 3 * 86400))
        XCTAssertNil(PulseExitPayload.parseTime("yesterday"))
        let json = Data("{\"timeStampEnd\":\"2026-11-16 08:00:00\"}".utf8)
        XCTAssertEqual(PulseExitPayload.endTime(PulseExitPayload(json: json, end: nil)), PulseExitPayload.parseTime("2026-11-16 08:00:00"))
    }

    // MARK: sending

    func testEachReasonIsSentAsAnExitErrorWithTheOsTime() throws {
        let exits = FakeExits(), h = harness(exits: exits)
        let end = h.clock.now.addingTimeInterval(-3600)
        exits.send([payload(end, try AutoFixtures.fixture("metrickit-diagnostics-full"))]); h.flush()
        let sent = errors(h)
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(sent.map { error($0)["type"] as? String }, ["crash", "hang", "cpu_exception", "disk_write_exception"])
        for event in sent {
            XCTAssertEqual(error(event)["kind"] as? String, "exit")
            XCTAssertNil(error(event)["message"])
            XCTAssertEqual(event["timestamp"] as? String, iso(end))
        }
        XCTAssertEqual(error(sent[0])["frames"] as? [String], ["MyApp+0x124f7", "MyApp+0x12345", "dyld+0x1000"])
        XCTAssertEqual(error(sent[0])["symbolicated"] as? Bool, false)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: sent), as: UTF8.self).contains("com.example.secret"))
    }
    func testTheSameRecordIsNeverSentTwiceEvenAfterARestart() throws {
        let storage = AutoFixtures.storage(config: nil), clock = FakeClock(), exits = FakeExits()
        let first = harness(exits: exits, storage: storage, clock: clock)
        let end = clock.now.addingTimeInterval(-3600), data = try AutoFixtures.fixture("metrickit-diagnostics-full")
        exits.send([payload(end, data)]); first.settle()
        exits.send([payload(end, data)]); first.flush()
        XCTAssertEqual(errors(first).count, 4)
        XCTAssertNotNil(storage.files[PulseExitMarker.fileName])
        first.runtime.finalSave(); first.settle()
        let again = FakeExits(), second = harness(exits: again, storage: storage, clock: clock.fork(advancing: 120))
        again.send([payload(end, data)]); second.flush()
        XCTAssertTrue(errors(second).isEmpty)
        again.send([payload(end.addingTimeInterval(1800), data)]); second.flush()
        XCTAssertEqual(errors(second).count, 4, "a newer payload is new")
    }
    func testRecordsOlderThanSevenDaysAreSkipped() throws {
        let exits = FakeExits(), h = harness(exits: exits)
        exits.send([payload(h.clock.now.addingTimeInterval(-8 * 86400), try AutoFixtures.fixture("metrickit-diagnostics-full"))]); h.flush()
        XCTAssertTrue(errors(h).isEmpty)
        exits.send([payload(h.clock.now.addingTimeInterval(-6 * 86400), try AutoFixtures.fixture("metrickit-diagnostics-full"))]); h.flush()
        XCTAssertEqual(errors(h).count, 4)
    }
    func testAtMostTenPerLaunch() throws {
        func diagnostics(_ count: Int) -> String {
            (0..<count).map { "{\"callStackTree\":{\"callStacks\":[{\"threadAttributed\":true,\"callStackRootFrames\":[{\"binaryName\":\"A\",\"offsetIntoBinaryTextSegment\":\($0)}]}]}}" }
                .joined(separator: ",")
        }
        let json = Data("{\"crashDiagnostics\":[\(diagnostics(6))],\"hangDiagnostics\":[\(diagnostics(6))]}".utf8)
        let exits = FakeExits(), h = harness(exits: exits)
        exits.send([payload(h.clock.now.addingTimeInterval(-60), json)]); h.flush()
        XCTAssertEqual(errors(h).count, 10)
        exits.send([payload(h.clock.now.addingTimeInterval(-30), json)]); h.flush()
        XCTAssertEqual(errors(h).count, 10, "the cap is per launch, not per payload")
    }
    func testDefaultsFollowCaptureErrorsAndOptOut() throws {
        let off = FakeExits()
        var options = PulseOptions(); options.captureErrors = false
        let disabled = harness(exits: off, options: options)
        XCTAssertEqual(off.starts, 0)
        off.send([payload(disabled.clock.now.addingTimeInterval(-60), try AutoFixtures.fixture("metrickit-diagnostics-full"))]); disabled.flush()
        XCTAssertTrue(errors(disabled).isEmpty)
        let exits = FakeExits(), h = harness(exits: exits)
        XCTAssertEqual(exits.starts, 1)
        h.runtime.optOut = true; h.settle()
        exits.send([payload(h.clock.now.addingTimeInterval(-60), try AutoFixtures.fixture("metrickit-diagnostics-full"))]); h.flush()
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertNil(h.storage.files[PulseExitMarker.fileName])
    }
    func testTypeOnlyDropsFramesAndErrorsIgnoreTheAutomaticSwitchesAndTheDayCap() throws {
        var options = PulseOptions(); options.errorDetail = .typeOnly
        let exits = FakeExits(), h = harness(exits: exits, options: options, config: "{\"automaticSignals\":false}")
        exits.send([payload(h.clock.now.addingTimeInterval(-60), try AutoFixtures.fixture("metrickit-diagnostics-full"))]); h.flush()
        let sent = errors(h)
        XCTAssertEqual(sent.count, 4)
        XCTAssertNil(error(sent[0])["frames"]); XCTAssertEqual(error(sent[0])["kind"] as? String, "exit")
    }
    func testDamagedPayloadIsSkippedWithoutMovingTheMarker() {
        let exits = FakeExits(), h = harness(exits: exits)
        exits.send([payload(h.clock.now.addingTimeInterval(-60), Data("garbage".utf8)), PulseExitPayload(json: Data("{}".utf8), end: nil)]); h.flush()
        XCTAssertTrue(errors(h).isEmpty)
    }
}
