import Foundation
import XCTest
@testable import MightySPulse

final class AutoEventTests: XCTestCase {
    private func harness(config: String? = AutoFixtures.optIn, options: PulseOptions = PulseOptions(),
                         permissions: PulsePermissionSource = PulseNoPermissions(), processStart: Date? = nil,
                         storage: FakeStorage? = nil, clock: FakeClock = FakeClock()) -> Harness {
        Harness(options: options, storage: storage ?? AutoFixtures.storage(config: config), clock: clock, automatic: true,
                permissions: permissions, processStart: processStart)
    }

    // MARK: opt-in app_opened and app_backgrounded

    func testOpenAndBackgroundAreNotSentUnlessTheCachedConfigListsThem() {
        let none = harness(config: nil)
        none.foreground(); none.advance(5); none.background(); none.flush()
        XCTAssertFalse(none.types().contains("pulse.app_opened")); XCTAssertFalse(none.types().contains("pulse.app_backgrounded"))
        let unreadable = FakeStorage(); unreadable.failReads = true
        let failed = harness(storage: unreadable)
        failed.foreground(); failed.background(); failed.flush()
        XCTAssertFalse(failed.types().contains("pulse.app_opened"))
        let empty = harness(config: "{\"enabledSignals\":[]}")
        empty.foreground(); empty.flush()
        XCTAssertFalse(empty.types().contains("pulse.app_opened"))
        XCTAssertFalse(none.types().contains("pulse.session_started"), "an unsent foreground does not start a session")
    }
    func testOpenedFiresOncePerRealForegroundAndColdStartIsTrueOnlyTheFirstTime() {
        let h = harness()
        h.foreground(); h.foreground()
        h.advance(10); h.background(); h.background()
        h.advance(10); h.foreground(); h.flush()
        let opened = h.eventsOfType("pulse.app_opened")
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(Harness.props(opened[0])["coldStart"] as? String, "true")
        XCTAssertEqual(Harness.props(opened[1])["coldStart"] as? String, "false")
        XCTAssertEqual(h.eventsOfType("pulse.app_backgrounded").count, 1)
    }
    func testBackgroundedCarriesTheForegroundSeconds() {
        let h = harness()
        h.foreground(); h.advance(42); h.background(); h.flush()
        let sent = h.eventsOfType("pulse.app_backgrounded")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual((Harness.props(sent[0])["foregroundSeconds"] as? NSNumber)?.intValue, 42)
    }
    func testBackgroundedNeverOpensASessionAndIsDroppedAfterThirtyMinutesOfSilence() {
        let h = harness()
        h.foreground(); h.advance(1801); h.background(); h.advance(5); h.foreground()
        h.advance(1801); h.background(); h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.app_backgrounded").count, 0)
        XCTAssertEqual(h.eventsOfType("pulse.app_opened").count, 2)
        XCTAssertEqual(h.eventsOfType("pulse.session_started").count, 2, "only the opens started sessions")
        h.foreground(); h.advance(30); h.runtime.track("x"); h.settle(); h.advance(10); h.background(); h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.app_backgrounded").count, 1, "recent activity: sent")
        let counted = harness(config: AutoFixtures.optIn)
        counted.foreground(); counted.advance(1801); counted.background(); counted.foreground(); counted.runtime.track("a"); counted.flush()
        XCTAssertEqual(Harness.system(counted.eventsOfType("a")[0])["previousForegroundSeconds"], "1801", "counters still update")
    }
    func testBackgroundWithoutAForegroundSendsNothing() {
        let h = harness()
        h.background(); h.flush()
        XCTAssertTrue(h.eventsOfType("pulse.app_backgrounded").isEmpty)
    }
    func testPortalSwitchesApply() {
        let paused = harness(config: "{\"enabledSignals\":[\"pulse.app_opened\",\"pulse.app_backgrounded\"],\"pausedSignals\":[\"pulse.app_opened\"]}")
        paused.foreground(); paused.runtime.track("x"); paused.advance(3); paused.background(); paused.flush()
        XCTAssertTrue(paused.eventsOfType("pulse.app_opened").isEmpty)
        XCTAssertEqual(paused.eventsOfType("pulse.app_backgrounded").count, 1)
        let disabled = harness(config: "{\"enabledSignals\":[\"pulse.app_opened\"],\"disabledSignals\":[\"pulse.app_opened\"]}")
        disabled.foreground(); disabled.flush()
        XCTAssertTrue(disabled.eventsOfType("pulse.app_opened").isEmpty)
        let automaticOff = harness(config: "{\"enabledSignals\":[\"pulse.app_opened\"],\"automaticSignals\":false}")
        automaticOff.foreground(); automaticOff.flush()
        XCTAssertTrue(automaticOff.eventsOfType("pulse.app_opened").isEmpty)
        var options = PulseOptions(); options.automaticSignals = false
        let code = harness(options: options)
        code.foreground(); code.flush()
        XCTAssertTrue(code.eventsOfType("pulse.app_opened").isEmpty, "a code option can switch it off")
    }
    func testDebugFlagAndOptOut() {
        var options = PulseOptions(); options.debug = true
        let h = harness(options: options)
        h.foreground(); h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.app_opened").first?["debug"] as? Bool, true)
        let off = harness()
        off.runtime.optOut = true; off.settle()
        off.foreground(); off.advance(2); off.background(); off.flush()
        XCTAssertTrue(off.events.isEmpty)
    }
    // MARK: quota guards

    func testPerSessionCapsAndDroppedAutomaticIsSentOnce() {
        let h = harness()
        for _ in 0..<25 { h.foreground(); h.advance(1); h.background(); h.advance(1) }
        h.runtime.track("manual.one"); h.runtime.track("manual.two"); h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.app_opened").count, 20)
        XCTAssertEqual(h.eventsOfType("pulse.app_backgrounded").count, 20)
        let manual = h.eventsOfType("manual.one") + h.eventsOfType("manual.two")
        XCTAssertEqual(Harness.system(manual[0])["droppedAutomatic"], "10")
        XCTAssertNil(Harness.system(manual[1])["droppedAutomatic"], "the count is sent once, then reset")
        let withCount = h.events.filter { Harness.system($0)["droppedAutomatic"] != nil }
        XCTAssertEqual(withCount.count, 1)
    }
    func testDeepLinkAndPermissionChangeCaps() {
        let permissions = FakePermissions(["notificationPermission": "notDetermined"])
        let h = harness(permissions: permissions)
        h.runtime.track("warm"); h.settle()
        for index in 0..<12 { h.runtime.deepLink(URL(string: "myapp://item/\(index)")!) }
        for index in 0..<8 { permissions.set("notificationPermission", index % 2 == 0 ? "granted" : "denied"); h.runtime.track("tick"); h.settle() }
        h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.deep_link").count, 10)
        XCTAssertEqual(h.eventsOfType("pulse.permission_changed").count, 5)
        XCTAssertEqual(h.events.compactMap { Harness.system($0)["droppedAutomatic"] }.compactMap(Int.init).reduce(0, +), 2 + 3)
    }
    func testScreenViewCapIsOneHundredPerSession() {
        let h = harness()
        for index in 0..<105 { h.runtime.screen("Screen\(index)") }
        h.runtime.track("manual"); h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.screen_view").count, 100)
        XCTAssertEqual(Harness.system(h.eventsOfType("manual")[0])["droppedAutomatic"], "5")
    }
    func testDayCapOf300AutomaticSignalsAndTheRollOver() {
        let h = harness()
        for session in 0..<3 {
            if session > 0 { h.advance(1801) }
            for index in 0..<100 { h.runtime.screen("S\(session)-\(index)") }
            h.settle()
        }
        h.runtime.track("manual.after"); h.runtime.trackError(NSError(domain: "T", code: 1), symbols: []); h.flush()
        let automatic: Set<String> = ["pulse.session_started", "pulse.new_install", "pulse.app_updated", "pulse.screen_view"]
        XCTAssertEqual(h.events.filter { automatic.contains($0["type"] as? String ?? "") }.count, 300)
        XCTAssertEqual(Harness.system(h.eventsOfType("manual.after")[0])["droppedAutomatic"], "4")
        XCTAssertEqual(h.eventsOfType("pulse.error").count, 1, "errors are never capped by the day guard")
        h.advance(86400)
        h.runtime.screen("NextDay"); h.flush()
        XCTAssertTrue(h.events.contains { Harness.props($0)["screen"] as? String == "NextDay" })
    }
    func testManualSignalsAreNeverCapped() {
        let h = harness()
        for index in 0..<400 { h.runtime.track("manual", props: ["n": index]) }
        h.flush()
        XCTAssertEqual(h.eventsOfType("manual").count, 400)
    }

    // MARK: usage group: foreground counters

    func testForegroundCountersAreOnSignalsAndRollOverWithTheLocalDay() {
        let h = harness(config: nil)
        h.foreground(); h.runtime.track("a"); h.settle()
        h.advance(30); h.background(); h.advance(5); h.foreground(); h.runtime.track("b"); h.flush()
        let a = Harness.system(h.eventsOfType("a")[0]), b = Harness.system(h.eventsOfType("b")[0])
        XCTAssertEqual(a["foregroundsToday"], "1"); XCTAssertNil(a["previousForegroundSeconds"])
        XCTAssertEqual(b["foregroundsToday"], "2"); XCTAssertEqual(b["previousForegroundSeconds"], "30")
        h.advance(86400); h.background(); h.foreground(); h.runtime.track("c"); h.flush()
        XCTAssertEqual(Harness.system(h.eventsOfType("c")[0])["foregroundsToday"], "1")
    }
    func testUsageGroupOffRemovesTheForegroundKeys() {
        let h = harness(config: "{\"groups\":{\"usage\":false}}")
        h.foreground(); h.advance(3); h.background(); h.foreground(); h.runtime.track("a"); h.flush()
        let system = Harness.system(h.eventsOfType("a")[0])
        XCTAssertNil(system["foregroundsToday"]); XCTAssertNil(system["previousForegroundSeconds"])
    }
    func testCountersSurviveARestartTheSameDay() {
        let storage = AutoFixtures.storage(config: nil), clock = FakeClock()
        let first = harness(config: nil, storage: storage, clock: clock)
        first.foreground(); first.advance(10); first.background(); first.runtime.finalSave(); first.settle()
        let second = harness(config: nil, storage: storage, clock: clock.fork(advancing: 60))
        second.foreground(); second.runtime.track("a"); second.flush()
        let system = Harness.system(second.eventsOfType("a")[0])
        XCTAssertEqual(system["foregroundsToday"], "2"); XCTAssertEqual(system["previousForegroundSeconds"], "10")
    }

    // MARK: launchMs

    func testLaunchMsIsOnTheColdSessionStartOnly() {
        let clock = FakeClock()
        let h = harness(config: nil, processStart: clock.now.addingTimeInterval(-2), clock: clock)
        h.advance(0.3); h.foreground(); h.advance(1)
        h.runtime.track("a"); h.flush()
        XCTAssertEqual(Harness.system(h.eventsOfType("pulse.session_started")[0])["launchMs"], "2300")
        XCTAssertNil(Harness.system(h.eventsOfType("a")[0])["launchMs"])
        h.advance(1801); h.runtime.track("b"); h.flush()
        let starts = h.eventsOfType("pulse.session_started")
        XCTAssertEqual(starts.count, 2)
        XCTAssertNil(Harness.system(starts[1])["launchMs"], "a later session is not a cold start")
    }
    func testLaunchMsFallsBackToTheFirstSignalAndIsOmittedWhenUnknown() {
        let clock = FakeClock()
        let fallback = harness(config: nil, processStart: clock.now.addingTimeInterval(-1.5), clock: clock)
        fallback.advance(0.5); fallback.runtime.track("a"); fallback.flush()
        XCTAssertEqual(Harness.system(fallback.eventsOfType("pulse.session_started")[0])["launchMs"], "2000")
        let unknown = harness(config: nil)
        unknown.runtime.track("a"); unknown.flush()
        XCTAssertNil(Harness.system(unknown.eventsOfType("pulse.session_started")[0])["launchMs"])
    }

    // MARK: previousScreenSeconds

    func testPreviousScreenSecondsExcludesBackgroundTime() {
        let h = harness(config: nil)
        h.foreground(); h.runtime.screen("A"); h.advance(5); h.background(); h.advance(100)
        h.foreground(); h.advance(3); h.runtime.screen("B"); h.flush()
        let views = h.eventsOfType("pulse.screen_view")
        XCTAssertNil(Harness.props(views[0])["previousScreenSeconds"], "no previous screen")
        XCTAssertEqual((Harness.props(views[1])["previousScreenSeconds"] as? NSNumber)?.intValue, 8)
    }
    func testPreviousScreenSecondsWithoutLifecycleCountsWallTime() {
        let h = harness(config: nil)
        h.runtime.screen("A"); h.advance(10); h.runtime.screen("B"); h.advance(4); h.runtime.screen("A"); h.flush()
        let seconds = h.eventsOfType("pulse.screen_view").map { (Harness.props($0)["previousScreenSeconds"] as? NSNumber)?.intValue }
        XCTAssertEqual(seconds, [nil, 10, 4])
    }

    // MARK: deep links

    func testDeepLinkPropsKeepOnlySchemeHostPathAndUtm() {
        let url = URL(string: "https://example.com/p/42/photos/3F2504E0-4F89-41D3-9A0C-0305E82C3301/jane@example.com?utm_source=news&utm_medium=email&utm_campaign=fall&token=abc&utm_content=x#frag")!
        let props = PulseDeepLink.props(url)
        XCTAssertEqual(props["scheme"], "https"); XCTAssertEqual(props["host"], "example.com")
        XCTAssertEqual(props["path"], "/p/:id/photos/:id/<filtered>")
        XCTAssertEqual(props["utmSource"], "news"); XCTAssertEqual(props["utmMedium"], "email"); XCTAssertEqual(props["utmCampaign"], "fall")
        XCTAssertEqual(props.count, 6, "no query, fragment or other parameter")
        XCTAssertFalse(props.values.contains { $0.contains("abc") || $0.contains("frag") })
    }
    func testDeepLinkCustomSchemeAndLimits() {
        let custom = PulseDeepLink.props(URL(string: "myapp://item/123456")!)
        XCTAssertEqual(custom["scheme"], "myapp"); XCTAssertEqual(custom["host"], "item"); XCTAssertEqual(custom["path"], "/:id")
        XCTAssertNil(custom["utmSource"])
        let long = PulseDeepLink.props(URL(string: "https://example.com/" + String(repeating: "abc/", count: 80))!)
        XCTAssertLessThanOrEqual(long["path"]?.utf16.count ?? 0, 128)
        let utm = PulseDeepLink.props(URL(string: "https://example.com/?utm_source=" + String(repeating: "a", count: 200))!)
        XCTAssertEqual(utm["utmSource"]?.count, 64)
        XCTAssertNil(PulseDeepLink.props(URL(string: "https://example.com/?utm_source=a%40b.com")!)["utmSource"].flatMap { $0.contains("@") ? $0 : nil })
        let bare = PulseDeepLink.props(URL(string: "myapp:/only/path")!)
        XCTAssertEqual(bare["scheme"], "myapp"); XCTAssertNil(bare["host"])
    }
    func testDeepLinkSignalIsSentOncePerCallAndFollowsTheSwitches() {
        let h = harness(config: nil)
        h.runtime.deepLink(URL(string: "myapp://item/7?utm_source=x")!); h.flush()
        let sent = h.eventsOfType("pulse.deep_link")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(Harness.props(sent[0])["path"] as? String, "/:id")
        XCTAssertEqual(Harness.props(sent[0])["utmSource"] as? String, "x")
        let paused = harness(config: "{\"pausedSignals\":[\"pulse.deep_link\"]}")
        paused.runtime.deepLink(URL(string: "myapp://item/7")!); paused.flush()
        XCTAssertTrue(paused.eventsOfType("pulse.deep_link").isEmpty)
        let disabled = harness(config: "{\"disabledSignals\":[\"pulse.deep_link\"]}")
        disabled.runtime.deepLink(URL(string: "myapp://item/7")!); disabled.flush()
        XCTAssertTrue(disabled.eventsOfType("pulse.deep_link").isEmpty)
        var options = PulseOptions(); options.automaticSignals = false
        let code = harness(config: nil, options: options)
        code.runtime.deepLink(URL(string: "myapp://item/7")!); code.flush()
        XCTAssertTrue(code.eventsOfType("pulse.deep_link").isEmpty)
        let off = harness(config: nil)
        off.runtime.optOut = true; off.settle(); off.runtime.deepLink(URL(string: "myapp://item/7")!); off.flush()
        XCTAssertTrue(off.events.isEmpty)
    }

    // MARK: permissions

    func testStatusMapping() {
        XCTAssertEqual((0...4).map { PulsePermission.notification(rawValue: $0) },
                       ["notDetermined", "denied", "granted", "provisional", "ephemeral"])
        XCTAssertNil(PulsePermission.notification(rawValue: 9))
        XCTAssertEqual((0...3).map { PulsePermission.tracking(rawValue: $0) }, ["notDetermined", "restricted", "denied", "authorized"])
        XCTAssertNil(PulsePermission.tracking(rawValue: 7))
    }
    func testPermissionKeysAreInTheirGroupOnEverySignal() {
        let permissions = FakePermissions(["notificationPermission": "denied", "trackingPermission": "notDetermined"])
        let h = harness(config: nil, permissions: permissions)
        h.runtime.track("a"); h.flush()
        let system = Harness.system(h.eventsOfType("a")[0])
        XCTAssertEqual(system["notificationPermission"], "denied"); XCTAssertEqual(system["trackingPermission"], "notDetermined")
        XCTAssertEqual(permissions.started, 1)
        let off = harness(config: "{\"groups\":{\"permissions\":false}}", permissions: permissions)
        off.runtime.track("a"); off.flush()
        let none = Harness.system(off.eventsOfType("a")[0])
        XCTAssertNil(none["notificationPermission"]); XCTAssertNil(none["trackingPermission"])
        XCTAssertEqual(PulseRemoteConfig.groupKeys["permissions"], ["notificationPermission", "trackingPermission"])
    }
    func testPlainRuntimeSendsNoPermissionKeys() {
        let h = harness(config: nil)
        h.runtime.track("a"); h.flush()
        XCTAssertNil(Harness.system(h.eventsOfType("a")[0])["notificationPermission"])
    }
    func testPermissionChangedIsSentOnceOnTheFirstSignalAfterTheStatusDiffers() {
        let permissions = FakePermissions(["notificationPermission": "notDetermined"])
        let h = harness(config: nil, permissions: permissions)
        h.runtime.track("a"); h.flush()
        XCTAssertTrue(h.eventsOfType("pulse.permission_changed").isEmpty, "the first stored status is not a change")
        permissions.set("notificationPermission", "granted")
        h.runtime.track("b"); h.runtime.track("c"); h.flush()
        let changes = h.eventsOfType("pulse.permission_changed")
        XCTAssertEqual(changes.count, 1)
        let props = Harness.props(changes[0])
        XCTAssertEqual(props["permission"] as? String, "notification"); XCTAssertEqual(props["from"] as? String, "notDetermined")
        XCTAssertEqual(props["to"] as? String, "granted")
        let types = h.types()
        XCTAssertLessThan(types.firstIndex(of: "pulse.permission_changed")!, types.firstIndex(of: "b")!)
    }
    func testPermissionChangeIsFoundAfterARestartAndTrackingToo() {
        let storage = AutoFixtures.storage(config: nil), clock = FakeClock()
        let permissions = FakePermissions(["notificationPermission": "denied", "trackingPermission": "notDetermined"])
        let first = harness(config: nil, permissions: permissions, storage: storage, clock: clock)
        first.runtime.track("a"); first.flush(); first.runtime.finalSave(); first.settle()
        permissions.set("trackingPermission", "authorized")
        let second = harness(config: nil, permissions: permissions, storage: storage, clock: clock.fork(advancing: 60))
        second.runtime.track("b"); second.flush()
        let changes = second.eventsOfType("pulse.permission_changed")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(Harness.props(changes[0])["permission"] as? String, "tracking")
        XCTAssertEqual(Harness.props(changes[0])["to"] as? String, "authorized")
    }
    func testPermissionChangeFollowsTheSwitches() {
        for config in ["{\"pausedSignals\":[\"pulse.permission_changed\"]}", "{\"disabledSignals\":[\"pulse.permission_changed\"]}",
                       "{\"automaticSignals\":false}"] {
            let permissions = FakePermissions(["notificationPermission": "denied"])
            let h = harness(config: config, permissions: permissions)
            h.runtime.track("a"); h.settle(); permissions.set("notificationPermission", "granted"); h.runtime.track("b"); h.flush()
            XCTAssertTrue(h.eventsOfType("pulse.permission_changed").isEmpty, config)
        }
    }
    func testForegroundRefreshesPermissions() {
        let permissions = FakePermissions()
        let h = harness(config: nil, permissions: permissions)
        h.foreground()
        XCTAssertGreaterThanOrEqual(permissions.refreshed, 1)
    }
    func testOptOutDeletesTheAutomaticFiles() {
        let h = harness()
        h.foreground(); h.advance(3); h.background(); h.runtime.finalSave(); h.settle()
        XCTAssertNotNil(h.storage.files[PulseAutomatic.fileName])
        h.runtime.optOut = true; h.settle()
        XCTAssertNil(h.storage.files[PulseAutomatic.fileName])
        XCTAssertNil(h.storage.files[PulseExitMarker.fileName])
    }

    // MARK: config client

    func testConfigParsesEnabledAndPausedSignalsAndIgnoresPauseExpensive() throws {
        let text = "{\"enabledSignals\":[\"pulse.app_opened\",\"made.up\",3],\"pausedSignals\":[\"pulse.screen_view\",\"manual.x\"],\"pauseExpensiveAt90\":false}"
        let config = try XCTUnwrap(PulseRemoteConfig.parse(Data(text.utf8)))
        XCTAssertEqual(config.enabledSignals, ["pulse.app_opened"])
        XCTAssertEqual(config.pausedSignals, ["pulse.screen_view"])
        let effective = PulseEffectiveConfig(options: PulseOptions(), remote: config)
        XCTAssertTrue(effective.sends("pulse.app_opened")); XCTAssertFalse(effective.sends("pulse.app_backgrounded"))
        XCTAssertFalse(effective.sends("pulse.screen_view")); XCTAssertTrue(effective.sends("manual.x"))
        XCTAssertTrue(effective.sends("pulse.deep_link"))
        let wrong = try XCTUnwrap(PulseRemoteConfig.parse(Data("{\"enabledSignals\":\"pulse.app_opened\",\"pausedSignals\":7}".utf8)))
        XCTAssertTrue(wrong.enabledSignals.isEmpty); XCTAssertTrue(wrong.pausedSignals.isEmpty)
    }

    // MARK: no prompt, no identifier, manifest

    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MightySPulse")
    }
    func testSourcesNeverRequestAPermissionOrReadAnAdvertisingIdentifier() throws {
        let files = try FileManager.default.contentsOfDirectory(at: sourcesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in ["requestAuthorization", "requestTrackingAuthorization", "advertisingIdentifier", "ASIdentifierManager",
                         "identifierForVendor"] {
                XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) mentions \(word)")
            }
        }
    }
    func testPrivacyManifestStillDeclaresNoRequiredReasonApiAndNoTracking() throws {
        let file = sourcesDirectory.appendingPathComponent("Resources/PrivacyInfo.xcprivacy")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyAccessedAPITypes"] as? [Any])?.count, 0)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
    }
}

#if os(macOS)
import AppKit
final class AutoLifecycleTests: XCTestCase {
    func testNotificationsMapToOneOpenAndOneBackgroundPerTransition() {
        let h = Harness(storage: AutoFixtures.storage(config: AutoFixtures.optIn), automatic: true)
        let lifecycle = PulseLifecycle(runtime: h.runtime)
        let center = NotificationCenter.default
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        h.settle(); h.advance(7)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        h.settle(); h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.app_opened").count, 1)
        XCTAssertEqual(h.eventsOfType("pulse.app_backgrounded").count, 1)
        _ = lifecycle
    }
}
#endif
