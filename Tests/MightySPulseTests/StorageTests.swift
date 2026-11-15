import Foundation
import XCTest
@testable import MightySPulse

final class StorageTests: XCTestCase {
    func testQueueRestartAndDifferentKeys() {
        let h = Harness(); h.runtime.track("warmup"); h.settle()  // consumes the first at-once send
        h.runtime.track("saved"); h.settle()
        XCTAssertEqual(h.transport.requests.count, 1)
        let other = Harness(storage: h.storage, clock: h.clock.fork(), key: "other-key")
        other.flush(); XCTAssertTrue(other.transport.requests.isEmpty)
        let restarted = Harness(storage: h.storage, clock: h.clock.fork())
        XCTAssertEqual(restarted.events.first?["type"] as? String, "saved")
    }
    func testExactInflightBytesSurviveRestartWithoutMergingNewSignals() {
        let h = Harness(); h.transport.replies = [PulseResponse(status: 500, retryAfter: "60")]
        h.send("original", props: ["large": String(repeating: "x", count: 1000)])
        h.runtime.track("newer"); h.settle()
        let first = h.transport.requests[0]
        let restarted = Harness(storage: h.storage, clock: h.clock.fork())
        restarted.flush(); XCTAssertTrue(restarted.transport.requests.isEmpty)
        restarted.advance(60)
        XCTAssertEqual(restarted.transport.requests.count, 2)
        XCTAssertEqual(restarted.transport.requests[0].body, first.body)
        XCTAssertEqual(restarted.transport.requests[0].gzip, first.gzip)
        XCTAssertEqual(Harness.events(restarted.transport.requests[1])[0]["type"] as? String, "newer")
    }
    func testCorruptAndTruncatedSnapshotsAreDiscardedWithoutThrowing() throws {
        let h = Harness(); h.runtime.track("saved"); h.settle()
        let name = try XCTUnwrap(h.storage.queueName), original = h.storage.files[name]!
        for length in [0, 3, 35, original.count - 1] {
            let storage = FakeStorage(); storage.files[name] = Data(original.prefix(length))
            let restored = Harness(storage: storage)
            restored.send("healthy")
            XCTAssertEqual(restored.events.compactMap { $0["type"] as? String }, ["healthy"])
        }
        var corrupt = original; corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try PulseSnapshot.decode(corrupt))
    }
    func testAtomicFileStorageIgnoresTornTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PulseFileStorage(directory: root)
        XCTAssertNil(try storage.read("queue.bin"))
        try storage.replace("queue.bin", with: Data([1, 2, 3]))
        try Data([99]).write(to: root.appendingPathComponent("queue.bin.tmp"))
        XCTAssertEqual(try PulseFileStorage(directory: root).read("queue.bin"), Data([1, 2, 3]))
        try storage.replace("queue.bin", with: Data([4]))
        XCTAssertEqual(try storage.read("queue.bin"), Data([4]))
        try storage.remove("queue.bin"); try storage.remove("queue.bin")
        XCTAssertNil(try storage.read("queue.bin"))
    }
    func testActualFileQueueSurvivesANewRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-runtime-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FakeClock(), transport = FakeTransport()
        transport.handler = { _, _ in }  // first send leaves at once and never completes, so the batch stays on disk
        let first = PulseRuntime(clock: clock, transport: transport, storage: PulseFileStorage(directory: root), environment: { [:] })
        first.initialize(appKey: "synthetic-key", options: PulseOptions())
        first.track("saved.to.disk")
        for _ in 0..<10 { first.barrier() }
        XCTAssertEqual(transport.requests.count, 1)
        let next = FakeTransport()
        let restored = PulseRuntime(clock: clock, transport: next, storage: PulseFileStorage(directory: root), environment: { [:] })
        restored.initialize(appKey: "synthetic-key", options: PulseOptions())
        for _ in 0..<10 { restored.barrier() }
        XCTAssertEqual(next.requests.count, 1)
        XCTAssertEqual(Harness.events(next.requests[0])[0]["type"] as? String, "saved.to.disk")
    }
    func testStorageFailureBlocksNetworkUntilDurableAndRetries() {
        let h = Harness(); h.storage.failWrites = true
        h.send("saved.later")
        XCTAssertTrue(h.transport.requests.isEmpty)
        XCTAssertEqual(h.runtime.countForTests, 1)
        h.storage.failWrites = false; h.advance(1)
        XCTAssertEqual(h.events.first?["type"] as? String, "saved.later")
    }
    func testCapturedDuringWriteIsPersistedBeforeItIsSent() throws {
        let h = Harness()
        var inserted = false, durableAtSend: [Set<UUID>] = []
        h.storage.afterReplace = { name in
            if name.hasPrefix("queue-"), !inserted {
                inserted = true; h.runtime.track("during.write")
            }
        }
        h.transport.handler = { _, complete in
            let snapshot = try! PulseSnapshot.decode(h.storage.files[h.storage.queueName!]!)
            durableAtSend.append(Set(snapshot.entries.map(\.id)))
            XCTAssertTrue(snapshot.pending[0].ids.allSatisfy(durableAtSend.last!.contains))
            complete(PulseResponse(status: 202))
        }
        h.send("before.write")
        XCTAssertEqual(h.events.compactMap { $0["type"] as? String }.sorted(), ["before.write", "during.write"])
        XCTAssertFalse(durableAtSend.isEmpty)
    }
    func testBoundedCountAgeAndFutureTimestampPruning() throws {
        var options = PulseOptions(); options.maxQueueSize = 3
        let h = Harness(options: options)
        h.runtime.track("warmup"); h.settle()  // consumes the first at-once send
        for i in 0..<5 { h.runtime.track("bounded", value: Double(i)); h.settle() }
        h.flush(); XCTAssertEqual(h.events.compactMap { $0["value"] as? Double }, [2, 3, 4])
        let stale = Harness(); stale.runtime.track("warmup"); stale.settle(); stale.runtime.track("expired"); stale.settle()
        let restored = Harness(storage: stale.storage, clock: stale.clock.fork(advancing: 8 * 86400))
        restored.flush(); XCTAssertTrue(restored.transport.requests.isEmpty)
        let future = Harness(); future.runtime.track("warmup"); future.settle(); future.runtime.track("future"); future.settle()
        let rewind = Harness(storage: future.storage, clock: future.clock.fork(advancing: -7200))
        rewind.flush(); XCTAssertTrue(rewind.transport.requests.isEmpty)
        var excessive = PulseOptions(); excessive.maxQueueAgeDays = 999
        XCTAssertEqual(excessive.normalized().maxQueueAgeDays, 29)
    }
    func testFinalSaveDoesNotWaitForHangingTransport() {
        let h = Harness()
        h.transport.handler = { _, _ in }
        h.send("in.flight"); h.runtime.track("during.request"); h.settle()
        let start = Date()
        h.runtime.finalSave()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.2)
        XCTAssertTrue(h.transport.cancellations[0].cancelled)
        let restarted = Harness(storage: h.storage, clock: h.clock.fork())
        restarted.flush()
        XCTAssertEqual(restarted.events.compactMap { $0["type"] as? String }, ["in.flight", "during.request"])
    }
    func testBackgroundSaveIsBoundedWhileTransportHangs() throws {
        let h = Harness(); h.transport.handler = { _, _ in }
        h.send("in.flight"); h.runtime.track("last.capture")
        let start = Date()
        h.runtime.backgroundSave()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.2)
        let snapshot = try PulseSnapshot.decode(try XCTUnwrap(h.storage.files[h.storage.queueName!]))
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertFalse(h.transport.cancellations[0].cancelled)
        h.runtime.finalSave()
    }
}
