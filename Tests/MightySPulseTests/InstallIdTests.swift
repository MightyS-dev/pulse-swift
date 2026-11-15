import XCTest
@testable import MightySPulse

final class InstallIdTests: XCTestCase {
    private func storedID(_ storage: FakeStorage) -> String? {
        storage.files["install-id"].flatMap { String(data: $0, encoding: .utf8) }
    }

    func testInstallIdIsCreatedOnceAndReusedAfterRestart() {
        let h = Harness()
        h.send("first")
        let id = storedID(h.storage)
        XCTAssertNotNil(id?.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        h.send("second")
        XCTAssertEqual(storedID(h.storage), id)
        let restarted = Harness(storage: h.storage, clock: h.clock.fork())
        restarted.send("after.restart")
        XCTAssertEqual(storedID(restarted.storage), id)
        XCTAssertEqual(restarted.events[0]["userHash"] as? String, h.events[0]["userHash"] as? String)
    }

    func testUserHashIsSentWithoutSetUserAndEqualsHashOfInstallId() throws {
        let h = Harness()
        h.send("no.user")
        let id = try XCTUnwrap(storedID(h.storage))
        XCTAssertEqual(h.events[0]["userHash"] as? String, PulseHash.hex(id))
        XCTAssertEqual((h.events[0]["userHash"] as? String)?.count, 64)
    }

    func testSignalsTrackedBeforeInitializeAlsoCarryTheHash() throws {
        let h = Harness(initialize: false)
        h.runtime.track("early"); h.settle()
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        h.flush()
        let id = try XCTUnwrap(storedID(h.storage))
        XCTAssertEqual(h.events[0]["userHash"] as? String, PulseHash.hex(id))
    }

    func testSetUserOverridesAndNilRestoresInstallIdHash() throws {
        let h = Harness()
        h.send("anonymous")
        let id = try XCTUnwrap(storedID(h.storage))
        h.runtime.setUser("synthetic-user"); h.send("known")
        h.runtime.setUser(nil); h.send("anonymous.again")
        h.runtime.setUser("synthetic-user"); h.runtime.setUser(""); h.send("empty")
        XCTAssertEqual(h.events[0]["userHash"] as? String, PulseHash.hex(id))
        XCTAssertEqual(h.events[1]["userHash"] as? String, PulseHash.hex("synthetic-user"))
        XCTAssertEqual(h.events[2]["userHash"] as? String, PulseHash.hex(id))
        XCTAssertEqual(h.events[3]["userHash"] as? String, PulseHash.hex(id))
    }

    func testOptOutDeletesTheIdAndOptOutOffCreatesADifferentOne() throws {
        let h = Harness()
        h.send("before")
        let first = try XCTUnwrap(storedID(h.storage))
        h.runtime.optOut = true; h.settle()
        XCTAssertNil(h.storage.files["install-id"])
        h.runtime.optOut = false; h.settle()
        XCTAssertNil(h.storage.files["install-id"])
        h.send("after")
        let second = try XCTUnwrap(storedID(h.storage))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(h.events.last?["userHash"] as? String, PulseHash.hex(second))
    }

    func testUnreadableOrUnwritableInstallIdStillGivesAStableUserHash() throws {
        let storage = FakeStorage(); storage.failInstallID = true
        let h = Harness(storage: storage)
        h.send("one"); h.send("two")
        let first = try XCTUnwrap(h.events[0]["userHash"] as? String)
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(h.events[1]["userHash"] as? String, first)
        XCTAssertNil(storage.files["install-id"])
    }

    func testDamagedStoredIdIsReplaced() throws {
        let storage = FakeStorage(); storage.files["install-id"] = Data("not an id".utf8)
        let h = Harness(storage: storage)
        h.send("event")
        let id = try XCTUnwrap(storedID(storage))
        XCTAssertNotEqual(id, "not an id")
        XCTAssertEqual(h.events[0]["userHash"] as? String, PulseHash.hex(id))
    }

    func testSystemContextFieldsAreNonEmpty() {
        let system = PulseEnvironment.system()
        for key in ["platform", "osName", "osVersion", "appVersion", "deviceModel", "locale"] {
            XCTAssertFalse((system[key] ?? "").isEmpty, "\(key) is empty")
        }
    }

    func testFirstSignalsCarryFullContextBeforeAndAfterInitialize() {
        let h = Harness(initialize: false)
        h.runtime.track("before.init")
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions())
        h.runtime.track("right.after.init")
        h.flush()
        XCTAssertEqual(h.events.count, 2)
        for event in h.events {
            let system = event["system"] as? [String: Any] ?? [:]
            for key in ["platform", "osName", "osVersion", "appVersion", "deviceModel", "locale"] {
                XCTAssertFalse((system[key] as? String ?? "").isEmpty, "\(key) empty on \(event["type"] ?? "")")
            }
        }
    }
}
