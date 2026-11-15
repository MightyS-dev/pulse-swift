import Foundation
import XCTest
@testable import MightySPulse

final class PrivacyAndConcurrencyTests: XCTestCase {
    func testPreinitializeQueueIsBoundedAndDoesNotThrow() {
        let h = Harness(initialize: false)
        h.runtime.initialize(appKey: "\r\n", options: PulseOptions())
        h.runtime.setUser("before.init")
        for i in 0..<105 { h.runtime.track("early", value: Double(i)) }
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions())
        h.flush()
        XCTAssertEqual(h.events.compactMap { $0["value"] as? Double }, (5..<105).map(Double.init))
        h.runtime.initialize(appKey: "ignored-second-key", options: PulseOptions())
        h.send("still.first")
        XCTAssertEqual(h.transport.requests.last?.appKey, "synthetic-key")
    }
    func testOptOutPersistsClearsQueueAndResetsUser() {
        let h = Harness()
        h.runtime.setUser("private.synthetic.raw")
        h.transport.replies = [PulseResponse(status: 500)]
        h.send("before")
        for data in h.storage.files.values {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private.synthetic.raw"))
        }
        let event = h.events[0]
        XCTAssertEqual(event["userHash"] as? String, PulseHash.hex("private.synthetic.raw"))
        h.runtime.optOut = true
        XCTAssertTrue(h.runtime.optOut)
        h.runtime.track("ignored"); h.runtime.setUser("ignored.raw"); h.settle()
        XCTAssertEqual(h.runtime.countForTests, 0)
        XCTAssertEqual(h.storage.files["opt-out"], Data([1]))
        XCTAssertNil(h.storage.queueName)
        let restarted = Harness(storage: h.storage, clock: h.clock.fork())
        XCTAssertTrue(restarted.runtime.optOut)
        restarted.send("ignored.after.restart"); XCTAssertTrue(restarted.transport.requests.isEmpty)
        restarted.runtime.optOut = false; restarted.settle()
        restarted.send("anonymous")
        XCTAssertNotNil(restarted.events[0]["userHash"])
        XCTAssertNotEqual(restarted.events[0]["userHash"] as? String, PulseHash.hex(""))
        XCTAssertNotEqual(event["sessionId"] as? String, restarted.events[0]["sessionId"] as? String)
    }
    func testUnreadableCorruptAndFailedPrivacyWritesFailClosed() {
        for corrupt in [Data(), Data([2]), Data([0, 0]), Data("bad".utf8)] {
            let storage = FakeStorage(); storage.files["opt-out"] = corrupt
            let h = Harness(storage: storage)
            XCTAssertTrue(h.runtime.optOut); h.send(); XCTAssertTrue(h.transport.requests.isEmpty)
        }
        let unreadable = FakeStorage(); unreadable.failReads = true
        let closed = Harness(storage: unreadable)
        XCTAssertTrue(closed.runtime.optOut); closed.send(); XCTAssertTrue(closed.transport.requests.isEmpty)
        let h = Harness(); h.storage.failPreference = true
        h.runtime.optOut = true; h.settle()
        h.runtime.optOut = false; h.settle()
        XCTAssertTrue(h.runtime.optOut)
        h.send(); XCTAssertTrue(h.transport.requests.isEmpty)
        h.storage.failPreference = false; h.advance(1)
        XCTAssertFalse(h.runtime.optOut)
        h.send("enabled"); XCTAssertEqual(h.events.count, 1)
    }
    func testOptOutBeforeInitializationAndCancelsActiveRequest() {
        let h = Harness(initialize: false)
        h.runtime.track("discarded.early"); h.runtime.optOut = true; h.settle()
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.flush()
        XCTAssertTrue(h.transport.requests.isEmpty)
        h.runtime.optOut = false; h.settle()
        var completion: ((PulseResponse) -> Void)?
        h.transport.handler = { _, callback in completion = callback }
        h.send("active"); h.runtime.optOut = true; h.settle()
        XCTAssertTrue(h.transport.cancellations[0].cancelled)
        completion?(PulseResponse(status: 202)); h.settle()
        XCTAssertEqual(h.runtime.countForTests, 0)
        XCTAssertTrue(h.runtime.optOut)
    }
    func testPrivacyChangesBeforeInitializationInvalidateAllApplicationQueues() {
        let first = Harness(); first.runtime.track("old.first"); first.settle()
        let second = Harness(storage: first.storage, key: "other-key")
        second.runtime.track("old.second"); second.settle()
        let settings = Harness(storage: first.storage, initialize: false)
        settings.runtime.optOut = true; settings.settle()
        settings.runtime.optOut = false; settings.settle()
        let restoredFirst = Harness(storage: first.storage)
        let restoredSecond = Harness(storage: first.storage, key: "other-key")
        restoredFirst.flush(); restoredSecond.flush()
        XCTAssertTrue(restoredFirst.transport.requests.isEmpty)
        XCTAssertTrue(restoredSecond.transport.requests.isEmpty)
    }
    func testUserClearAndSessionRotationAfterThirtyMinutes() {
        let h = Harness()
        h.runtime.setUser("synthetic"); h.send("first")
        h.advance(1799); h.send("same")
        XCTAssertEqual(h.events[0]["sessionId"] as? String, h.events[1]["sessionId"] as? String)
        h.advance(1800); h.runtime.setUser(nil); h.send("rotated")
        XCTAssertNotEqual(h.events[1]["sessionId"] as? String, h.events[2]["sessionId"] as? String)
        XCTAssertNotNil(h.events[2]["userHash"]); XCTAssertNotEqual(h.events[2]["userHash"] as? String, h.events[0]["userHash"] as? String)
        h.runtime.setUser(""); h.send("empty"); XCTAssertEqual(h.events[3]["userHash"] as? String, h.events[2]["userHash"] as? String)
    }
    func testTenThreadsCaptureTenThousandSignalsWithoutLossOrDuplication() {
        var options = PulseOptions(); options.maxQueueSize = 10000; options.maxBatchSize = 1000; options.gzip = false
        let h = Harness(options: options)
        DispatchQueue.concurrentPerform(iterations: 10) { thread in
            for i in 0..<1000 { h.runtime.track("parallel", value: Double(thread * 1000 + i)) }
        }
        h.flush(); h.settle(128)
        let values = h.events.compactMap { ($0["value"] as? NSNumber)?.intValue }
        XCTAssertEqual(values.sorted(), Array(0..<10000))
        XCTAssertEqual(Set(values).count, 10000)
        XCTAssertEqual(h.runtime.countForTests, 0)
        XCTAssertTrue(h.transport.requests.allSatisfy { Harness.events($0).count <= 1000 })
    }
    func testBodyAndBatchCaps() {
        var options = PulseOptions(); options.maxBatchSize = Int.max; options.maxQueueSize = 2000; options.gzip = false
        let h = Harness(options: options)
        var props: [String: Any] = [:]
        for i in 0..<7 { props["key\(i)"] = String(repeating: "x", count: 1024) }
        for i in 0..<300 { h.runtime.track("large", value: Double(i), props: props) }
        h.flush()
        XCTAssertEqual(h.events.count, 300)
        XCTAssertGreaterThan(h.transport.requests.count, 1)
        XCTAssertTrue(h.transport.requests.allSatisfy { $0.body.count <= 1048576 })
        XCTAssertEqual(options.normalized().maxBatchSize, 1000)
    }
    func testFlushCancellationReturnsWithoutDroppingQueue() async {
        let h = Harness()
        h.transport.handler = { _, _ in }
        h.runtime.track("offline"); h.settle()
        let task = Task { await h.runtime.flushAsync() }
        task.cancel()
        await task.value
        h.settle()
        XCTAssertEqual(h.runtime.countForTests, 1)
        XCTAssertEqual(h.runtime.waiterCountForTests, 0)
        h.runtime.finalSave()
    }
    func testOptOutConcurrentWithTrackNeverRestoresCollection() {
        let h = Harness()
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i % 5 == 0 { h.runtime.optOut = true }
            else { h.runtime.track("race", value: Double(i)) }
        }
        h.settle()
        XCTAssertTrue(h.runtime.optOut)
        XCTAssertEqual(h.runtime.countForTests, 0)
        XCTAssertTrue(h.transport.requests.isEmpty)
    }
}
