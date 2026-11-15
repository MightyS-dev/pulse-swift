import Foundation
import XCTest
@testable import MightySPulse

final class UsageAndSignalTests: XCTestCase {
    private func system(_ event: [String: Any]) -> [String: String] { event["system"] as? [String: String] ?? [:] }
    private func named(_ h: Harness, _ type: String) -> [[String: Any]] { h.events.filter { $0["type"] as? String == type } }
    private func installID(_ storage: FakeStorage) -> String? { storage.files["install-id"].flatMap { String(data: $0, encoding: .utf8) } }
    private func seed(_ storage: FakeStorage, _ usage: PulseUsage) throws {
        storage.files["usage"] = try JSONEncoder().encode(usage)
        storage.files["install-id"] = Data("0123456789abcdef0123456789abcdef".utf8)
    }
    private func usage(days: [String] = [], distinct: Int = 0, sessions: [PulseUsage.Completed] = [], previous: Int? = nil,
                       version: String? = nil, build: String? = nil, total: Int = 5) -> PulseUsage {
        PulseUsage(firstSessionDate: "2026-01-02", firstSessionIsNewInstall: true, totalSessionsCount: total, days: days,
                   distinctDays: distinct, sessions: sessions, previousSessionSeconds: previous, appVersion: version,
                   appBuildNumber: build, current: nil)
    }

    // Device fields

    func testDeviceFieldsAreSentWhenTheDeviceGivesThemAndOmittedWhenItGivesNothing() {
        let device = FakeDevice(["screenWidth": "393", "connectionType": "wifi", "colorScheme": "dark"])
        let h = Harness(device: device)
        h.send("with")
        XCTAssertTrue(device.started)
        let withValues = system(h.events[0])
        XCTAssertEqual(withValues["screenWidth"], "393"); XCTAssertEqual(withValues["connectionType"], "wifi")
        XCTAssertEqual(withValues["colorScheme"], "dark")
        let bare = Harness()
        bare.send("without")
        for key in ["screenWidth", "connectionType", "colorScheme", "orientation", "fontScale", "lowPowerMode"] {
            XCTAssertNil(system(bare.events[0])[key], key)
        }
        XCTAssertFalse(system(bare.events[0]).values.contains(""))
    }
    func testDynamicValuesChangeBetweenTwoSignals() {
        let device = FakeDevice(["orientation": "portrait", "colorScheme": "light", "connectionType": "wifi",
                                 "lowPowerMode": "false", "fontScale": "1", "reduceMotion": "false"])
        let h = Harness(device: device)
        h.send("one")
        device.set("orientation", "landscape"); device.set("colorScheme", "dark"); device.set("connectionType", "cellular")
        device.set("lowPowerMode", "true"); device.set("fontScale", "1.35"); device.set("reduceMotion", "true")
        h.send("two")
        let first = system(h.events[0]), second = system(h.events[1])
        for key in ["orientation", "colorScheme", "connectionType", "lowPowerMode", "fontScale", "reduceMotion"] {
            XCTAssertNotEqual(first[key], second[key], key)
        }
        XCTAssertEqual(second["orientation"], "landscape")
    }
    func testTimeZoneAndOffsetAreSentOnEverySignal() {
        let h = Harness()
        h.send("one")
        XCTAssertEqual(system(h.events[0])["timeZone"], TimeZone(identifier: "UTC")!.identifier)
        XCTAssertEqual(system(h.events[0])["utcOffsetMinutes"], "0")
    }
    func testFirstSignalsBeforeAndAfterInitializeCarryTheFullSet() {
        let device = FakeDevice(["screenWidth": "393", "colorScheme": "light", "connectionType": "wifi"])
        let h = Harness(initialize: false, device: device, automatic: true)
        h.runtime.track("before.init")
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions())
        h.runtime.track("right.after.init")
        h.flush()
        let user = h.events.filter { !($0["type"] as! String).hasPrefix("pulse.") }
        XCTAssertEqual(user.count, 2)
        for event in user {
            let values = system(event)
            for key in ["screenWidth", "colorScheme", "connectionType", "timeZone", "utcOffsetMinutes", "firstSessionDate",
                        "totalSessionsCount", "distinctDaysUsed", "distinctDaysUsedLastMonth", "sessionSeconds", "bundleId" ]
            where key != "bundleId" { XCTAssertFalse((values[key] ?? "").isEmpty, "\(key) missing on \(event["type"] ?? "")") }
            XCTAssertTrue(system(event).values.allSatisfy { !$0.isEmpty })
        }
        XCTAssertEqual(named(h, "pulse.session_started").count, 1)
    }

    // Session statistics

    func testStatisticsAcrossSessionsDaysAverageAndPrevious() {
        let h = Harness(automatic: true)
        h.send("a")
        let a = system(named(h, "a")[0])
        XCTAssertEqual(a["totalSessionsCount"], "1"); XCTAssertEqual(a["distinctDaysUsed"], "1")
        XCTAssertEqual(a["distinctDaysUsedLastMonth"], "1"); XCTAssertEqual(a["firstSessionDate"], "2026-11-13")
        XCTAssertEqual(a["isNewInstall"], "true"); XCTAssertEqual(a["sessionSeconds"], "0")
        XCTAssertNil(a["previousSessionSeconds"]); XCTAssertNil(a["averageSessionSeconds"])
        h.advance(100); h.send("b")
        XCTAssertEqual(system(named(h, "b")[0])["sessionSeconds"], "100")
        XCTAssertEqual(system(named(h, "b")[0])["totalSessionsCount"], "1")
        h.advance(2000); h.send("c")
        let c = system(named(h, "c")[0])
        XCTAssertEqual(c["totalSessionsCount"], "2"); XCTAssertEqual(c["previousSessionSeconds"], "100")
        XCTAssertEqual(c["averageSessionSeconds"], "100"); XCTAssertNil(c["isNewInstall"])
        XCTAssertEqual(c["distinctDaysUsed"], "1"); XCTAssertEqual(c["sessionSeconds"], "0")
        h.advance(86400); h.send("d")
        let d = system(named(h, "d")[0])
        XCTAssertEqual(d["totalSessionsCount"], "3"); XCTAssertEqual(d["distinctDaysUsed"], "2")
        XCTAssertEqual(d["distinctDaysUsedLastMonth"], "2"); XCTAssertEqual(d["previousSessionSeconds"], "0")
        XCTAssertEqual(d["averageSessionSeconds"], "50"); XCTAssertEqual(d["firstSessionDate"], "2026-11-13")
    }
    func testThirtyDayWindowAndNinetyDayAverage() throws {
        let storage = FakeStorage()
        try seed(storage, usage(days: ["2026-09-01", "2026-10-20", "2026-11-01"], distinct: 3,
                                sessions: [.init(date: "2026-06-01", seconds: 500), .init(date: "2026-10-20", seconds: 100)], previous: 100))
        let h = Harness(storage: storage, automatic: true)
        h.send("x")
        let values = system(named(h, "x")[0])
        XCTAssertEqual(values["distinctDaysUsed"], "4")
        XCTAssertEqual(values["distinctDaysUsedLastMonth"], "3")
        XCTAssertEqual(values["averageSessionSeconds"], "100")
        XCTAssertEqual(values["totalSessionsCount"], "6")
        XCTAssertEqual(values["firstSessionDate"], "2026-01-02")
        XCTAssertNil(values["isNewInstall"])
        let stored = try JSONDecoder().decode(PulseUsage.self, from: try XCTUnwrap(storage.files["usage"]))
        XCTAssertFalse(stored.days.contains("2026-09-01")); XCTAssertEqual(stored.distinctDays, 4)
        XCTAssertEqual(stored.sessions.count, 1)
    }
    func testSessionEndedByARestartCountsAsCompleted() {
        let first = Harness(automatic: true)
        first.send("one"); first.advance(300); first.send("two")
        first.runtime.backgroundSave()
        let second = Harness(storage: first.storage, clock: first.clock.fork(advancing: 5000), automatic: true)
        second.send("three")
        let values = system(second.events.last!)
        XCTAssertEqual(values["totalSessionsCount"], "2")
        XCTAssertEqual(values["previousSessionSeconds"], "300")
        XCTAssertEqual(values["averageSessionSeconds"], "300")
        XCTAssertNil(values["isNewInstall"])
    }
    func testStatisticsKeepWorkingWhenTheUsageFileCannotBeUsed() {
        let storage = FakeStorage(); storage.failUsage = true
        let h = Harness(storage: storage, automatic: true)
        h.send("one"); h.advance(100); h.send("two"); h.advance(2000); h.send("three")
        let three = system(named(h, "three")[0])
        XCTAssertEqual(three["totalSessionsCount"], "2")
        XCTAssertEqual(three["previousSessionSeconds"], "100")
        XCTAssertNil(storage.files["usage"])
        XCTAssertEqual(named(h, "pulse.session_started").count, 2)
    }
    func testDamagedUsageFileIsReplaced() {
        let storage = FakeStorage(); storage.files["usage"] = Data("{broken".utf8)
        let h = Harness(storage: storage, automatic: true)
        h.send("one")
        XCTAssertEqual(system(named(h, "one")[0])["totalSessionsCount"], "1")
        XCTAssertNotNil(try? JSONDecoder().decode(PulseUsage.self, from: storage.files["usage"] ?? Data()))
    }
    func testOptOutDeletesTheUsageFileAndStartsAgain() throws {
        let h = Harness(automatic: true)
        h.send("one")
        XCTAssertNotNil(h.storage.files["usage"])
        h.runtime.optOut = true; h.settle()
        XCTAssertNil(h.storage.files["usage"]); XCTAssertNil(h.storage.files["install-id"])
        let before = h.events.count
        h.send("while.opted.out")
        XCTAssertEqual(h.events.count, before)
        h.runtime.optOut = false; h.settle()
        h.send("back")
        let back = system(named(h, "back")[0])
        XCTAssertEqual(back["totalSessionsCount"], "1")
        XCTAssertEqual(named(h, "pulse.new_install").count, 2)
    }

    // Automatic signals

    func testAutomaticSignalsAreSentOncePerSessionAndOnceForInstall() {
        let h = Harness(automatic: true)
        h.send("a"); h.send("b"); h.send("c")
        XCTAssertEqual(named(h, "pulse.session_started").count, 1)
        XCTAssertEqual(named(h, "pulse.new_install").count, 1)
        XCTAssertEqual(named(h, "pulse.app_updated").count, 0)
        XCTAssertEqual(h.events.map { $0["type"] as! String }, ["pulse.session_started", "pulse.new_install", "a", "b", "c"])
        XCTAssertEqual(Set(h.events.map { $0["sessionId"] as! String }).count, 1)
        h.advance(2000); h.send("d")
        XCTAssertEqual(named(h, "pulse.session_started").count, 2)
        XCTAssertEqual(named(h, "pulse.new_install").count, 1)
        let restarted = Harness(storage: h.storage, clock: h.clock.fork(advancing: 10), automatic: true)
        restarted.send("e")
        XCTAssertEqual(named(restarted, "pulse.session_started").count, 1)
        XCTAssertEqual(named(restarted, "pulse.new_install").count, 0)
    }
    func testAutomaticSignalsCarryContextAndFollowTheDebugFlag() {
        let device = FakeDevice(["colorScheme": "dark"])
        var options = PulseOptions(); options.debug = true
        let h = Harness(options: options, device: device, automatic: true)
        h.send("a")
        for event in h.events {
            XCTAssertEqual(event["debug"] as? Bool, true)
            XCTAssertEqual(system(event)["colorScheme"], "dark")
            XCTAssertEqual(system(event)["totalSessionsCount"], "1")
            XCTAssertEqual((event["userHash"] as? String)?.count, 64)
            XCTAssertEqual((event["props"] as? [String: Any])?.count, 0)
        }
    }
    func testAppUpdateIsDetectedFromStoredVersionAndBuild() throws {
        let storage = FakeStorage()
        try seed(storage, usage(version: "1.2.2", build: "41"))
        let h = Harness(storage: storage, automatic: true)
        h.send("x")
        let updated = named(h, "pulse.app_updated")
        XCTAssertEqual(updated.count, 1)
        let props = try XCTUnwrap(updated[0]["props"] as? [String: String])
        XCTAssertEqual(props, ["previousVersion": "1.2.2", "previousBuild": "41"])
        XCTAssertEqual(named(h, "pulse.new_install").count, 0)
        let same = Harness(storage: storage, clock: h.clock.fork(advancing: 5000), automatic: true)
        same.send("y")
        XCTAssertEqual(named(same, "pulse.app_updated").count, 0)
        let buildOnly = Harness(storage: storage, clock: h.clock.fork(advancing: 9000), automatic: true, build: "43")
        buildOnly.send("z")
        XCTAssertEqual((named(buildOnly, "pulse.app_updated")[0]["props"] as? [String: String])?["previousBuild"], "42")
    }
    func testOptOutSuppressesAutomaticSignals() {
        let h = Harness(automatic: true)
        h.runtime.optOut = true; h.settle()
        h.send("a")
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertNil(h.storage.files["usage"])
    }
    func testNoAutomaticSignalsAreAddedWhenTheyAreSwitchedOffInternally() {
        let h = Harness()
        h.send("a")
        XCTAssertEqual(h.events.count, 1)
    }
}

final class MainQueueIndependenceTests: XCTestCase {
    // The test itself holds the main thread, so a hop to the main queue can never run while it waits.
    func testFlushAndSendNeverNeedTheMainQueue() throws {
        XCTAssertTrue(Thread.isMainThread)
        let transport = FakeTransport()
        let runtime = PulseRuntime(clock: FakeClock(), transport: transport, storage: FakeStorage(),
                                   environment: PulseEnvironment.system, device: PulseLiveDevice())
        let started = Date()
        runtime.initialize(appKey: "synthetic-key", options: PulseOptions())
        runtime.track("from.main")
        let done = DispatchSemaphore(value: 0)
        runtime.flush { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "flush did not complete while the main queue was blocked")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let events = transport.requests.flatMap { Harness.events($0) }
        let event = try XCTUnwrap(events.first { $0["type"] as? String == "from.main" })
        let system = try XCTUnwrap(event["system"] as? [String: String])
        XCTAssertEqual(system["deviceBrand"], "Apple")
        XCTAssertNotNil(system["installSource"]); XCTAssertNotNil(system["totalSessionsCount"])
    }
}
