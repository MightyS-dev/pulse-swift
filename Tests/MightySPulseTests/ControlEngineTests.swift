import Foundation
import XCTest
@testable import MightySPulse

/// The fail-open laws of App Control (SDK_ZAJEDNICKO section 8, groups 3 to 9) against a scripted server and a fake clock.
final class ControlEngineTests: XCTestCase {
    typealias Build = ControlRulesBuilder

    // MARK: 1 and 3. Initialize never waits, and every failure keeps the last known state

    func testInitializeReturnsAtOnceWhenTheServerNeverAnswers() {
        var total = 0.0
        for _ in 0..<20 {
            let h = Harness(initialize: false)
            h.controlTransport.handler = { _, _ in }
            let start = DispatchTime.now().uptimeNanoseconds
            h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions())
            total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            h.settle()
        }
        XCTAssertLessThan(total / 20, 5, "average milliseconds per initialize with a hanging control server")
    }

    func testSevenFailuresNeverLockAndNeverRetry() {
        let big = Data(repeating: 0x20, count: 10 * 1024 * 1024)
        let failures: [(String, ControlServer.Reply)] = [
            ("server down", .status(0)), ("dns error", .status(0)), ("tls error", .status(0)), ("500", .status(500)),
            ("30 s without an answer", .hang), ("not json", .body(Data("<html>".utf8))), ("10 MB body", .body(big))]
        for (name, failure) in failures {
            // Without a cache: normal. With a good earlier answer: the last known state stays.
            let server = ControlServer(failure)
            let fresh = Harness.control(server)
            XCTAssertEqual(fresh.primary.kind, .normal, name)
            XCTAssertTrue(fresh.presenter.screens.isEmpty, name)
            XCTAssertEqual(server.requests.count, 1, name)
            fresh.advance(100)
            XCTAssertEqual(server.requests.count, 1, "no retry loop: \(name)")
            if case .hang = failure { XCTAssertEqual(fresh.controlTransport.cancellations.last?.cancelled, true, "cut at 5 s") }

            let good = ControlServer(.rules(Build.required()))
            let known = Harness.control(good)
            XCTAssertEqual(known.primary.kind, .updateRequired, name)
            good.reply = failure
            known.advance(120); known.foregroundControl()
            XCTAssertEqual(good.requests.count, 2, name)
            XCTAssertEqual(known.primary.kind, .updateRequired, "last known stays: \(name)")
        }
    }

    func testWrongFormatAndUnknownContainersKeepTheLastKnownState() {
        let server = ControlServer(.rules(Build.required()))
        let h = Harness.control(server)
        for bad in [Build.make(["format": 2]), Build.make(["update": "x"]), Data("[]".utf8)] {
            server.reply = .rules(bad)
            h.advance(61); h.foregroundControl()
            XCTAssertEqual(h.primary.kind, .updateRequired)
        }
    }

    // MARK: 4. Cache

    func testFirstLaunchWithoutNetworkOrCacheIsNormal() {
        let h = Harness.control(ControlServer(.status(0)))
        XCTAssertEqual(h.primary, .normal)
        XCTAssertNil(h.storage.files.keys.first { $0.hasPrefix("control-") && !$0.hasPrefix("control-local-") })
    }

    func testGoodAnswerIsCachedUnderSixteenHexAndSurvivesARestart() throws {
        let storage = FakeStorage(), clock = FakeClock()
        _ = Harness.control(ControlServer(.rules(Build.required())), storage: storage, clock: clock)
        let name = "control-" + String(PulseHash.hex("synthetic-key").prefix(16))
        XCTAssertNotNil(storage.files[name])
        let offline = Harness.control(ControlServer(.status(0)), storage: storage, clock: clock.fork(advancing: 3600))
        XCTAssertEqual(offline.primary.kind, .updateRequired)
    }

    func testCacheOlderThanThirtyDaysDropsTheLock() {
        let storage = FakeStorage(), clock = FakeClock()
        _ = Harness.control(ControlServer(.rules(Build.required())), storage: storage, clock: clock)
        let young = Harness.control(ControlServer(.status(0)), storage: storage, clock: clock.fork(advancing: 29 * 86400))
        XCTAssertEqual(young.primary.kind, .updateRequired)
        let old = Harness.control(ControlServer(.status(0)), storage: storage, clock: clock.fork(advancing: 31 * 86400))
        XCTAssertEqual(old.primary.kind, .normal)
    }

    func testExpiredMaintenanceFromCacheIsIgnoredAndItNeverOutlastsSeventyTwoHours() {
        let storage = FakeStorage(), clock = FakeClock()
        let start = clock.now.addingTimeInterval(60), end = clock.now.addingTimeInterval(86400 * 10)
        _ = Harness.control(ControlServer(.rules(Build.maintenance(from: start, to: end))), storage: storage, clock: clock)
        let inside = Harness.control(ControlServer(.status(0)), storage: storage, clock: clock.fork(advancing: 3600))
        XCTAssertEqual(inside.primary.kind, .maintenance)
        let late = Harness.control(ControlServer(.status(0)), storage: storage, clock: clock.fork(advancing: 60 + 73 * 3600))
        XCTAssertEqual(late.primary.kind, .normal, "a cached window is cut 72 hours after it starts")
        let ended = Harness.control(ControlServer(.status(0)), storage: storage, clock: clock.fork(advancing: 86400 * 11))
        XCTAssertEqual(ended.primary.kind, .normal)
    }

    func testNotModifiedKeepsTheCacheAndRefreshesTheTime() throws {
        let storage = FakeStorage(), clock = FakeClock()
        let server = ControlServer(.rules(Build.required()))
        let h = Harness.control(server, storage: storage, clock: clock)
        XCTAssertEqual(server.requests[0].ifNoneMatch, nil)
        server.reply = .notModified
        h.advance(61 * 60 * 24 * 20); h.foregroundControl()
        XCTAssertEqual(server.requests.last?.ifNoneMatch, "\"7\"")
        XCTAssertEqual(h.primary.kind, .updateRequired)
        let name = "control-" + String(PulseHash.hex("synthetic-key").prefix(16))
        let cache = try XCTUnwrap(ControlCache.decode(storage.files[name]))
        XCTAssertEqual(cache.at.timeIntervalSince1970, clock.now.timeIntervalSince1970, accuracy: 1)
        // Twenty days after the refresh the lock still holds; a year of silence would not.
        let later = Harness.control(ControlServer(.status(0)), storage: storage, clock: clock.fork(advancing: 20 * 86400))
        XCTAssertEqual(later.primary.kind, .updateRequired)
    }

    // MARK: 5. Off and disabled SDK versions

    func testDisabledSdkVersionAndOffSwitchClearAShownScreen() {
        let server = ControlServer(.rules(Build.required()))
        let h = Harness.control(server)
        XCTAssertEqual(h.primary.kind, .updateRequired)
        XCTAssertEqual(h.presenter.screens.last?.primary.kind, .updateRequired)
        server.reply = .rules(Build.make(["disabledSdkVersions": ["pulse-swift@\(PulseInfo.version)"],
                                          "update": ["ios": ["min": "9.0.0", "mode": "required", "storeUrl": "https://apps.apple.com/app/id1"]]]))
        h.checkControl()
        XCTAssertEqual(h.primary, .normal)
        XCTAssertGreaterThan(h.presenter.hides, 0)
        server.reply = .rules(Build.required()); h.checkControl()
        XCTAssertEqual(h.primary.kind, .updateRequired)
        server.reply = .rules(Build.make(["off": true])); h.checkControl()
        XCTAssertEqual(h.primary, .normal)
    }

    // MARK: 6. Loop guard

    func testStoreVersionEqualToInstalledGivesASuggestion() {
        let h = Harness.control(ControlServer(.rules(Build.required(min: "2.0.0", storeVersion: "1.2.3"))))
        XCTAssertEqual(h.primary.kind, .updateSuggested)
        XCTAssertTrue(h.primary.allowContinue)
    }

    func testThreeReturnsFromTheStoreOnTheSameVersionGiveASuggestion() {
        var opened: [URL] = []
        let h = Harness.control(ControlServer(.rules(Build.required())), environment: .test(opened: { opened.append($0) }))
        XCTAssertEqual(h.primary.kind, .updateRequired)
        for round in 1...3 {
            XCTAssertEqual(h.primary.kind, .updateRequired, "before return \(round)")
            h.control.openStore(); h.settle()
            h.foregroundControl()
        }
        XCTAssertEqual(opened.count, 3)
        XCTAssertEqual(opened.first?.scheme, "itms-apps")
        XCTAssertEqual(h.primary.kind, .updateSuggested)
    }

    func testRequiredWithoutAnyStoreLinkBecomesASuggestion() {
        let h = Harness.control(ControlServer(.rules(Build.required(url: nil))))
        XCTAssertEqual(h.primary.kind, .updateSuggested)
        XCTAssertNil(h.primary.buttonText)
    }

    // MARK: 7. Opt-out and identity

    func testOptOutDoesNotStopControlAndTheRequestCarriesNoIdentity() throws {
        let server = ControlServer(.rules(Build.required()))
        let h = Harness.control(server)
        h.runtime.optOut = true; h.settle()
        h.advance(61); h.foregroundControl()
        XCTAssertEqual(server.requests.count, 2, "control keeps checking while analytics is off")
        let request = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(request.appKey, "")
        XCTAssertTrue(request.anonymous)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.lastPathComponent, String(PulseHash.hex("synthetic-key").prefix(32)))
        XCTAssertFalse(request.url.absoluteString.contains("synthetic-key"))
        let real = PulseURLTransport.makeRequest(request)
        let names = Set((real.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertTrue(names.isSubset(of: ["accept", "user-agent", "if-none-match"]), "\(names)")
        XCTAssertEqual(real.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(real.value(forHTTPHeaderField: "If-None-Match"), "\"7\"")
        XCTAssertFalse(real.httpShouldHandleCookies)
        XCTAssertNil(real.httpBody)
    }

    func testControlLeavesAnalyticsDataAlone() {
        let h = Harness.control(ControlServer(.rules(Build.required())))
        h.send("kept")
        XCTAssertEqual(h.events.count, 1)
        h.runtime.optOut = true; h.settle()
        XCTAssertNotNil(h.storage.files.keys.first { $0.hasPrefix("control-") }, "opt-out clears analytics, not the control cache")
    }

    // MARK: 8. Off

    func testOffSendsNoRequestAndStaysNormal() {
        let server = ControlServer(.rules(Build.required()))
        var options = PulseOptions(); options.control = .off
        let h = Harness.control(server, options: options)
        h.advance(500); h.foregroundControl(); h.checkControl()
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(h.primary, .normal)
        XCTAssertTrue(h.presenter.screens.isEmpty)
    }

    func testPlatformWithoutControlIsInert() {
        let server = ControlServer(.rules(Build.required()))
        let h = Harness.control(server, environment: .test(platform: nil))
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(h.primary, .normal)
    }

    // MARK: 9. Scheduled maintenance by the clock, offline

    func testScheduledMaintenanceStartsAndEndsOnTimeWithoutTheNetwork() {
        let clock = FakeClock()
        let start = clock.now.addingTimeInterval(1800), end = start.addingTimeInterval(3600)
        let server = ControlServer(.rules(Build.maintenance(from: start, to: end, headsUp: 10)))
        var release = PulseOptions(); release.debug = false
        let h = Harness.control(server, options: release, clock: clock)
        XCTAssertEqual(h.primary, .normal)
        server.reply = .status(0)
        h.advance(1800 - 600 + 1)
        XCTAssertEqual(h.primary.kind, .maintenanceUpcoming, "heads up ten minutes before")
        h.advance(600 - 1 + 4)
        XCTAssertEqual(h.primary.kind, .maintenance, "within 5 s of the start")
        XCTAssertFalse(h.primary.allowContinue)
        XCTAssertNotNil(h.primary.endsAt)
        h.advance(3600)
        XCTAssertEqual(h.primary.kind, .normal, "the window ends by itself")
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(h.presenter.screens.map(\.primary.kind).contains(.maintenance), true)
    }

    func testForegroundChecksAtMostOncePerMinute() {
        let server = ControlServer(.rules(Build.make()))
        let h = Harness.control(server)
        h.foregroundControl(); h.foregroundControl()
        XCTAssertEqual(server.requests.count, 1)
        h.advance(61); h.foregroundControl()
        XCTAssertEqual(server.requests.count, 2)
        h.checkControl()
        XCTAssertEqual(server.requests.count, 3, "checkNow ignores the minute")
    }
}
