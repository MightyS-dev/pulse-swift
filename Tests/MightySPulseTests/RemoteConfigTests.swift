import Foundation
import XCTest
@testable import MightySPulse

final class RemoteConfigTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private let allGroupsOff = "{\"version\":2,\"groups\":{\"device\":false,\"screen\":false,\"settings\":false,\"network\":false,\"app\":false,\"usage\":false}}"
    private func body(version: Int = 3) -> String {
        "{\"version\":\(version),\"screenViews\":true,\"automaticSignals\":true,\"groups\":{\"device\":true,\"screen\":true,\"settings\":true,\"network\":true,\"app\":true,\"usage\":true},\"disabledSignals\":[]}"
    }
    private func configRequests(_ h: Harness) -> [PulseRequest] { h.transport.requests.filter { $0.method == "GET" } }
    private func respond(_ h: Harness, status: Int = 200, body: String = "", hang: Bool = false) {
        h.transport.handler = { (request: PulseRequest, done: @escaping (PulseResponse) -> Void) in
            if request.method == "GET" { if !hang { done(PulseResponse(status: status, body: Data(body.utf8))) } }
            else { done(PulseResponse(status: 202)) }
        }
    }
    private func types(_ h: Harness) -> [String] { h.events.compactMap { $0["type"] as? String } }
    private func system(_ event: [String: Any]) -> [String: String] { event["system"] as? [String: String] ?? [:] }
    private func screenViews(_ h: Harness) -> Int { types(h).filter { $0 == "pulse.screen_view" }.count }

    // Parsing

    func testParsesAFullBodyAndIgnoresUnknownKeys() throws {
        let text = "{\"version\":3,\"unknownKey\":1,\"disabledSignals\":[\"pulse.app_updated\"]}"
        let config = try XCTUnwrap(PulseRemoteConfig.parse(data(text)))
        XCTAssertEqual(config.version, 3)
        XCTAssertEqual(config.disabledSignals, ["pulse.app_updated"])
        XCTAssertTrue(config.screenViews)
        XCTAssertEqual(config.etag, "\"3\"")
    }
    func testMissingKeysMeanOn() throws {
        let config = try XCTUnwrap(PulseRemoteConfig.parse(data("{}")))
        XCTAssertNil(config.version)
        let effective = PulseEffectiveConfig(options: PulseOptions(), remote: config)
        XCTAssertTrue(effective.capturesScreens); XCTAssertTrue(effective.sends("pulse.session_started"))
        XCTAssertTrue(effective.removedKeys.isEmpty); XCTAssertTrue(effective.sends("pulse.app_updated"))
    }
    func testWrongTypesMeanOnAndUnknownSignalNamesAreIgnored() throws {
        let text = "{\"version\":\"x\",\"screenViews\":\"no\",\"automaticSignals\":0,\"groups\":{\"device\":null,\"screen\":\"false\",\"usage\":false,\"other\":false},\"disabledSignals\":[\"pulse.new_install\",\"made.up\",7]}"
        let config = try XCTUnwrap(PulseRemoteConfig.parse(data(text)))
        XCTAssertNil(config.version)
        XCTAssertTrue(config.screenViews); XCTAssertTrue(config.automaticSignals)
        XCTAssertEqual(config.groups["device"], true); XCTAssertEqual(config.groups["screen"], true)
        XCTAssertEqual(config.groups["usage"], false)
        XCTAssertEqual(config.disabledSignals, ["pulse.new_install"])
    }
    func testBadBodiesGiveNilAndNeverThrow() {
        for text in ["", "not json", "[1,2]", "\"x\"", "null", "{"] { XCTAssertNil(PulseRemoteConfig.parse(data(text)), text) }
        XCTAssertNil(PulseRemoteConfig.parse(nil))
        XCTAssertNil(PulseRemoteConfig.parse(Data(repeating: 32, count: PulseRemoteConfig.maxBytes + 1)))
    }
    func testGroupsCoverFortySixKeysOnceAndNoBaseKey() {
        let all = PulseRemoteConfig.groupKeys.values.flatMap { $0 }
        XCTAssertEqual(all.count, 46)
        XCTAssertEqual(Set(all).count, 46)
        for base in ["platform", "osName", "osVersion", "appVersion", "appBuildNumber", "deviceModel", "locale", "sdkName", "sdkVersion", "bundleId"] {
            XCTAssertFalse(all.contains(base), base)
        }
    }

    // Fetch, cache and apply

    func testFetchesOncePerLaunchWithTheKeyAndNoEtagWithoutACache() {
        let g = Harness(initialize: false, fetchesConfig: true)
        respond(g, body: body())
        g.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); g.settle()
        g.send(); g.send()
        let requests = configRequests(g)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url.path, "/api/v1/config")
        XCTAssertEqual(requests[0].appKey, "synthetic-key")
        XCTAssertNil(requests[0].ifNoneMatch)
        XCTAssertEqual(requests[0].timeout, 10)
        XCTAssertTrue(requests[0].body.isEmpty)
        XCTAssertFalse(requests[0].gzip)
        XCTAssertEqual(g.storage.files["config"], data(body()))
    }
    func testSecondLaunchSendsTheCachedVersionAndA304KeepsTheCache() {
        let storage = FakeStorage()
        storage.files["config"] = data(body(version: 7))
        let h = Harness(storage: storage, initialize: false, fetchesConfig: true)
        respond(h, status: 304)
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        XCTAssertEqual(configRequests(h).first?.ifNoneMatch, "\"7\"")
        XCTAssertEqual(storage.files["config"], data(body(version: 7)))
    }
    func testAFetchedConfigAppliesOnlyFromTheNextLaunch() {
        let storage = FakeStorage()
        let off = body().replacingOccurrences(of: "\"screenViews\":true", with: "\"screenViews\":false")
        let first = Harness(storage: storage, initialize: false, fetchesConfig: true)
        respond(first, body: off)
        first.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); first.settle()
        first.runtime.screen("Home"); first.flush()
        XCTAssertEqual(screenViews(first), 1, "this run keeps everything on")
        let second = Harness(storage: storage, initialize: false, fetchesConfig: true)
        respond(second, status: 304)
        second.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); second.settle()
        second.runtime.screen("Home"); second.flush()
        XCTAssertEqual(screenViews(second), 0)
    }
    func testFailuresKeepTheCacheWithoutRetrying() {
        for status in [401, 500, 429, 0] {
            let storage = FakeStorage()
            storage.files["config"] = data(body(version: 4))
            let h = Harness(storage: storage, initialize: false, fetchesConfig: true)
            respond(h, status: status, body: "garbage")
            h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
            XCTAssertEqual(storage.files["config"], data(body(version: 4)), "status \(status)")
            XCTAssertEqual(configRequests(h).count, 1, "no retry loop")
        }
    }
    func testABadBodyOnA200IsNotStoredAndNoCacheMeansAllOn() {
        let empty = FakeStorage()
        let h = Harness(storage: empty, initialize: false, fetchesConfig: true)
        respond(h, status: 200, body: "not json")
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        XCTAssertNil(empty.files["config"])
        h.runtime.screen("Home"); h.flush()
        XCTAssertEqual(screenViews(h), 1)
    }
    func testDamagedCacheMeansAllOn() {
        let storage = FakeStorage()
        storage.files["config"] = data("{{{")
        let h = Harness(storage: storage)
        h.runtime.screen("Home"); h.flush()
        XCTAssertEqual(screenViews(h), 1)
    }
    func testUnreadableStorageMeansAllOn() {
        let storage = FakeStorage()
        storage.failReads = true
        let h = Harness(storage: storage)
        var answer: Bool?
        let g = Harness(storage: storage, initialize: false)
        g.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()) { answer = $0 }; g.settle()
        XCTAssertEqual(answer, true)
        XCTAssertNotNil(h.runtime)
    }

    // Precedence: the portal decides, a code option can only switch things off

    private func runWith(_ options: PulseOptions, config: String) -> Harness {
        let storage = FakeStorage(); storage.files["config"] = data(config)
        let h = Harness(options: options, storage: storage, automatic: true)
        h.runtime.screen("Home"); h.flush()
        return h
    }
    func testCodeFalseForScreenViewsKeepsManualCallsAndOnlyStopsTheHook() {
        var options = PulseOptions(); options.automaticScreenViews = false
        let h = runWith(options, config: "{}")
        XCTAssertEqual(screenViews(h), 1, "a manual screen call still sends")
        XCTAssertFalse(PulseEffectiveConfig(options: options, remote: .allOn).capturesScreens)
        XCTAssertTrue(PulseEffectiveConfig(options: PulseOptions(), remote: .allOn).capturesScreens)
    }
    func testCodeTrueNeverOverridesAPortalOff() throws {
        var on = PulseOptions(); on.automaticScreenViews = true; on.automaticSignals = true
        XCTAssertEqual(screenViews(runWith(on, config: "{\"screenViews\":false}")), 0)
        for text in ["{\"screenViews\":false}", "{\"automaticSignals\":false}", "{\"disabledSignals\":[\"pulse.screen_view\"]}"] {
            let remote = try XCTUnwrap(PulseRemoteConfig.parse(data(text)))
            XCTAssertFalse(PulseEffectiveConfig(options: on, remote: remote).capturesScreens, text)
        }
        XCTAssertEqual(types(runWith(on, config: "{\"automaticSignals\":false}")), [])
    }
    func testCodeFalseForAutomaticSignalsStopsTheThreeButNotManualScreens() {
        var options = PulseOptions(); options.automaticSignals = false
        let sent = types(runWith(options, config: "{}"))
        XCTAssertFalse(sent.contains("pulse.session_started")); XCTAssertFalse(sent.contains("pulse.new_install"))
        XCTAssertTrue(sent.contains("pulse.screen_view"))
    }
    func testThePortalAloneDecidesTheThreeAutomaticSignals() {
        let sent = types(runWith(PulseOptions(), config: "{\"disabledSignals\":[\"pulse.new_install\"]}"))
        XCTAssertTrue(sent.contains("pulse.session_started")); XCTAssertFalse(sent.contains("pulse.new_install"))
    }
    func testResolvedCallbackReportsWhetherToInstallTheScreenHook() {
        var noHook = PulseOptions(); noHook.automaticScreenViews = false
        let cases: [(String, PulseOptions, Bool)] = [("{\"screenViews\":false}", PulseOptions(), false),
            ("{\"disabledSignals\":[\"pulse.screen_view\"]}", PulseOptions(), false),
            ("{\"automaticSignals\":false}", PulseOptions(), false), ("{}", noHook, false), ("{}", PulseOptions(), true)]
        for (text, options, expected) in cases {
            let storage = FakeStorage(); storage.files["config"] = data(text)
            let h = Harness(storage: storage, initialize: false)
            var answer: Bool?
            h.runtime.initialize(appKey: "synthetic-key", options: options) { answer = $0 }; h.settle()
            XCTAssertEqual(answer, expected, text)
        }
    }

    // Effects

    private func run(_ text: String) -> Harness {
        let storage = FakeStorage(); storage.files["config"] = data(text)
        let h = Harness(storage: storage, automatic: true)
        h.runtime.screen("Home"); h.flush()
        h.send("custom")
        return h
    }
    func testScreenViewsOffDropsAutomaticAndManualScreenViewsOnly() {
        let sent = types(run("{\"screenViews\":false}"))
        XCTAssertFalse(sent.contains("pulse.screen_view"))
        XCTAssertTrue(sent.contains("pulse.session_started")); XCTAssertTrue(sent.contains("custom"))
    }
    func testAutomaticSignalsOffDropsAllFourAutomaticTypes() {
        XCTAssertEqual(types(run("{\"automaticSignals\":false}")), ["custom"])
    }
    func testOneDisabledTypeIsDroppedAndTheRestStay() {
        let sent = types(run("{\"disabledSignals\":[\"pulse.new_install\"]}"))
        XCTAssertFalse(sent.contains("pulse.new_install"))
        XCTAssertTrue(sent.contains("pulse.session_started")); XCTAssertTrue(sent.contains("pulse.screen_view"))
    }
    func testEachGroupOffRemovesExactlyItsKeys() {
        let allKeys = PulseRemoteConfig.groupKeys.values.flatMap { $0 }
        let device = FakeDevice(Dictionary(uniqueKeysWithValues: allKeys.map { ($0, "x") }))
        let reference = Harness(device: device)
        reference.send("custom")
        let baseline = system(reference.events.last!)
        for (group, keys) in PulseRemoteConfig.groupKeys { XCTAssertFalse(keys.isDisjoint(with: baseline.keys), group) }
        for (group, keys) in PulseRemoteConfig.groupKeys {
            let storage = FakeStorage()
            storage.files["config"] = data("{\"groups\":{\"\(group)\":false}}")
            let h = Harness(storage: storage, device: device)
            h.send("custom")
            let fields = system(h.events.last!)
            XCTAssertEqual(Set(baseline.keys).subtracting(fields.keys), keys.intersection(baseline.keys), group)
            XCTAssertTrue(Set(fields.keys).subtracting(baseline.keys).isEmpty, group)
            for base in ["platform", "osName", "osVersion", "appVersion", "deviceModel", "locale", "sdkName", "sdkVersion"] {
                XCTAssertNotNil(fields[base], base)
            }
        }
    }
    func testAllGroupsOffKeepsTheBaseFields() {
        let allKeys = PulseRemoteConfig.groupKeys.values.flatMap { $0 }
        let device = FakeDevice(Dictionary(uniqueKeysWithValues: allKeys.map { ($0, "x") }))
        let storage = FakeStorage(); storage.files["config"] = data(allGroupsOff)
        let h = Harness(storage: storage, device: device, automatic: true)
        h.send("custom")
        let fields = system(h.events.last!)
        XCTAssertNotNil(fields["platform"]); XCTAssertNotNil(fields["appVersion"])
        for key in allKeys { XCTAssertNil(fields[key], key) }
    }
    func testSignalsTrackedBeforeInitializeAreFilteredToo() {
        let storage = FakeStorage(); storage.files["config"] = data("{\"screenViews\":false}")
        let h = Harness(storage: storage, initialize: false)
        h.runtime.screen("Early"); h.settle()
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle(); h.flush()
        XCTAssertEqual(screenViews(h), 0)
    }

    // Opt-out and blocking

    func testOptOutDeletesTheConfigFile() {
        let storage = FakeStorage(); storage.files["config"] = data(body())
        let h = Harness(storage: storage)
        h.runtime.optOut = true; h.settle()
        XCTAssertNil(storage.files["config"])
    }
    func testNoRequestWhenOptedOutAndNothingStoredFromALateReply() {
        let storage = FakeStorage()
        let h = Harness(storage: storage, initialize: false, fetchesConfig: true)
        var late: ((PulseResponse) -> Void)?
        h.transport.handler = { (request: PulseRequest, done: @escaping (PulseResponse) -> Void) in
            if request.method == "GET" { late = done } else { done(PulseResponse(status: 202)) }
        }
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        h.runtime.optOut = true; h.settle()
        late?(PulseResponse(status: 200, body: data(body()))); h.settle()
        XCTAssertNil(storage.files["config"])
        let optedOut = FakeStorage(); optedOut.files["opt-out"] = Data([1])
        let g = Harness(storage: optedOut, initialize: false, fetchesConfig: true)
        g.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); g.settle()
        XCTAssertTrue(configRequests(g).isEmpty)
    }
    func testAHungConfigRequestDoesNotDelayTrackOrFlush() {
        let h = Harness(initialize: false, fetchesConfig: true)
        respond(h, hang: true)
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        h.send("custom")
        XCTAssertEqual(configRequests(h).count, 1)
        XCTAssertTrue(types(h).contains("custom"))
    }
    func testWorkCompletesWhileTheMainThreadIsBlocked() {
        let h = Harness(initialize: false, fetchesConfig: true)
        respond(h, body: body())
        let finished = expectation(description: "done")
        DispatchQueue.global().async {
            h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
            h.send("custom")
            finished.fulfill()
        }
        // The main thread waits here and runs nothing; the work above must still complete.
        XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: 5), .completed)
        XCTAssertEqual(configRequests(h).count, 1)
    }
}
