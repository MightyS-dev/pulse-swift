import Foundation
import XCTest
@testable import MightySPulse

final class HeatmapTests: XCTestCase {
    private let on = "{\"heatmaps\":true}"

    private func make(config: String? = "{\"heatmaps\":true}", options: PulseOptions = PulseOptions(), installSource: String? = nil,
                      fetchesConfig: Bool = false, initialize: Bool = true) -> Harness {
        let storage = FakeStorage()
        if let config = config { storage.files["config"] = Data(config.utf8) }
        return Harness(options: options, storage: storage, initialize: initialize, fetchesConfig: fetchesConfig, installSource: installSource)
    }
    private func tap(_ h: Harness, x: Double = 195, y: Double = 400, width: Double = 390, height: Double = 844,
                     keyboard: Bool = false, input: Bool = false, ignored: Bool = false) {
        h.runtime.heatmapTap(x: x, y: y, width: width, height: height, keyboardVisible: keyboard, inputTarget: input, ignored: ignored)
        h.settle()
    }
    private func maps(_ h: Harness) -> [[String: Any]] { h.eventsOfType("pulse.heatmap") }
    private func object(_ event: [String: Any]) -> [String: Any] { event["heatmap"] as? [String: Any] ?? [:] }
    private func points(_ event: [String: Any]) -> [[String: Any]] { object(event)["points"] as? [[String: Any]] ?? [] }
    private func kinds(_ event: [String: Any]) -> [String] { points(event).compactMap { $0["kind"] as? String } }
    private func screen(_ h: Harness, _ name: String = "Home") { h.runtime.screen(name); h.settle() }

    // MARK: math

    func testBucketAndOrientation() {
        XCTAssertEqual(PulseHeatmapMath.bucket(width: 599.9), "phone")
        XCTAssertEqual(PulseHeatmapMath.bucket(width: 600), "tablet")
        XCTAssertEqual(PulseHeatmapMath.bucket(width: 1023.9), "tablet")
        XCTAssertEqual(PulseHeatmapMath.bucket(width: 1024), "desktop")
        XCTAssertEqual(PulseHeatmapMath.orientation(width: 390, height: 844), "portrait")
        XCTAssertEqual(PulseHeatmapMath.orientation(width: 500, height: 500), "portrait")
        XCTAssertEqual(PulseHeatmapMath.orientation(width: 844, height: 390), "landscape")
    }
    func testFractionIsClampedAndRoundedToThreeDecimals() {
        XCTAssertEqual(PulseHeatmapMath.fraction(x: 100, width: 390), 0.256)
        XCTAssertEqual(PulseHeatmapMath.fraction(x: -5, width: 390), 0)
        XCTAssertEqual(PulseHeatmapMath.fraction(x: 900, width: 390), 1)
        XCTAssertEqual(PulseHeatmapMath.fraction(x: 195, width: 390), 0.5)
    }
    func testTopIsClampedAndRoundedToOneDecimal() {
        XCTAssertEqual(PulseHeatmapMath.top(y: 340.04), 340)
        XCTAssertEqual(PulseHeatmapMath.top(y: 1210.55), 1210.6)
        XCTAssertEqual(PulseHeatmapMath.top(y: -3), 0)
        XCTAssertEqual(PulseHeatmapMath.top(y: 250000), 100000)
    }
    func testScreenshotSourceRule() {
        XCTAssertTrue(PulseHeatmapMath.screenshotSourceAllowed("debug"))
        XCTAssertTrue(PulseHeatmapMath.screenshotSourceAllowed("other"))
        XCTAssertFalse(PulseHeatmapMath.screenshotSourceAllowed("appstore"))
        XCTAssertFalse(PulseHeatmapMath.screenshotSourceAllowed("testflight"))
        XCTAssertFalse(PulseHeatmapMath.screenshotSourceAllowed(nil))
        XCTAssertFalse(PulseHeatmapMath.screenshotSourceAllowed(""))
    }

    // MARK: settings

    func testOffByDefaultWithNoCacheAndAnUnreadableCache() {
        for config in [nil, "garbage", "{}", "{\"heatmaps\":\"true\"}", "{\"heatmaps\":false}"] {
            let h = make(config: config)
            screen(h); tap(h); h.runtime.flush {}; h.settle()
            XCTAssertTrue(maps(h).isEmpty, "config \(config ?? "nil")")
            XCTAssertFalse(h.runtime.heatmapGate.active)
        }
    }
    func testOnWhenTheCachedConfigSaysSo() {
        let h = make()
        screen(h); tap(h, x: 195, y: 340.04); h.flush()
        XCTAssertEqual(maps(h).count, 1)
        let sent = object(maps(h)[0])
        XCTAssertEqual(sent["screen"] as? String, "Home")
        XCTAssertEqual(sent["bucket"] as? String, "phone")
        XCTAssertEqual(sent["orientation"] as? String, "portrait")
        XCTAssertEqual(points(maps(h)[0]).count, 1)
        XCTAssertEqual(points(maps(h)[0])[0]["x"] as? Double, 0.5)
        XCTAssertEqual(points(maps(h)[0])[0]["y"] as? Double, 340)
        XCTAssertEqual(points(maps(h)[0])[0]["kind"] as? String, "tap")
        XCTAssertEqual(maps(h)[0]["type"] as? String, "pulse.heatmap")
    }
    func testTheSignalCarriesNoPropsAndTheWireNumbersAreShort() throws {
        let h = make()
        screen(h); tap(h, x: 100, y: 1210.55); h.flush()
        let event = try XCTUnwrap(maps(h).first)
        XCTAssertEqual((event["props"] as? [String: Any])?.count, 0)
        let raw = String(decoding: Harness.json(h.transport.requests.last { Harness.events($0).contains { $0["type"] as? String == "pulse.heatmap" } }!), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"x\":0.256"), raw)
        XCTAssertTrue(raw.contains("\"y\":1210.6"), raw)
    }
    func testCodeOptionCanOnlySwitchOff() {
        var off = PulseOptions(); off.captureHeatmaps = false
        let h = make(options: off)
        screen(h); tap(h); h.flush()
        XCTAssertTrue(maps(h).isEmpty)
        var yes = PulseOptions(); yes.captureHeatmaps = true
        let portalOff = make(config: "{\"heatmaps\":false}", options: yes)
        screen(portalOff); tap(portalOff); portalOff.flush()
        XCTAssertTrue(maps(portalOff).isEmpty, "true never forces it on over the portal")
    }
    func testAutomaticSignalsOffMeansNoHeatmapAnywhere() {
        var options = PulseOptions(); options.automaticSignals = false
        let code = make(options: options)
        screen(code); tap(code); code.flush()
        XCTAssertTrue(maps(code).isEmpty)
        let portal = make(config: "{\"heatmaps\":true,\"automaticSignals\":false}")
        screen(portal); tap(portal); portal.flush()
        XCTAssertTrue(maps(portal).isEmpty)
    }
    func testDisabledAndPausedTypeStopCapture() {
        for config in ["{\"heatmaps\":true,\"disabledSignals\":[\"pulse.heatmap\"]}", "{\"heatmaps\":true,\"pausedSignals\":[\"pulse.heatmap\"]}"] {
            let h = make(config: config)
            screen(h); tap(h); h.flush()
            XCTAssertTrue(maps(h).isEmpty, config)
        }
    }
    func testScreenViewsSwitchedOffMeansNoHeatmap() {
        for config in ["{\"heatmaps\":true,\"screenViews\":false}", "{\"heatmaps\":true,\"disabledSignals\":[\"pulse.screen_view\"]}",
                       "{\"heatmaps\":true,\"pausedSignals\":[\"pulse.screen_view\"]}"] {
            let h = make(config: config)
            screen(h); tap(h); h.flush()
            XCTAssertTrue(maps(h).isEmpty, config)
        }
    }
    func testNoScreenMeansNoCapture() {
        let h = make()
        tap(h); h.flush()
        XCTAssertTrue(maps(h).isEmpty)
        XCTAssertFalse(h.runtime.heatmapGate.active)
    }
    func testBeforeInitializeNothingIsCaptured() {
        let h = make(initialize: false)
        tap(h); h.runtime.screen("Home"); h.settle()
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        h.flush()
        XCTAssertTrue(maps(h).isEmpty)
    }
    func testAScreenSeenBeforeInitializeBecomesTheHeatmapScreen() {
        let h = make(initialize: false)
        h.runtime.screen("Splash"); h.settle()
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        tap(h); h.flush()
        XCTAssertEqual(object(maps(h)[0])["screen"] as? String, "Splash")
    }

    // MARK: refresh at runtime

    private func respond(_ h: Harness, body: String) {
        h.transport.handler = { (request: PulseRequest, done: @escaping (PulseResponse) -> Void) in
            done(request.method == "GET" ? PulseResponse(status: 200, body: Data(body.utf8)) : PulseResponse(status: 202))
        }
    }
    func testARefreshThatSwitchesOffDropsTheBufferAtOnce() {
        let h = make(fetchesConfig: false)
        screen(h); tap(h)
        XCTAssertTrue(h.runtime.heatmapGate.active)
        let off = Harness(storage: { let s = FakeStorage(); s.files["config"] = Data(on.utf8); return s }(), initialize: false, fetchesConfig: true)
        respond(off, body: "{\"heatmaps\":false}")
        off.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); off.settle()
        off.runtime.screen("Home"); off.settle()
        XCTAssertFalse(off.runtime.heatmapGate.active, "the refresh already switched it off")
        tap(off); off.flush()
        XCTAssertTrue(maps(off).isEmpty)
    }
    func testARefreshThatSwitchesOnStartsCaptureInTheSameRun() {
        let h = Harness(initialize: false, fetchesConfig: true)
        respond(h, body: on)
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        screen(h); tap(h); h.flush()
        XCTAssertEqual(maps(h).count, 1)
    }
    func testASwitchOffDropsPointsAlreadyBufferedAndSendsNothing() {
        let storage = FakeStorage(); storage.files["config"] = Data(on.utf8)
        let h = Harness(storage: storage, initialize: false, fetchesConfig: true)
        var answered = false
        h.transport.handler = { (request: PulseRequest, done: @escaping (PulseResponse) -> Void) in
            if request.method == "GET" { if answered { done(PulseResponse(status: 200, body: Data("{\"heatmaps\":false}".utf8))) } else { answered = true; done(PulseResponse(status: 304)) } }
            else { done(PulseResponse(status: 202)) }
        }
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.settle()
        screen(h); tap(h); tap(h)
        // A second refresh arrives mid-run.
        h.runtime.receivedConfigForTests(PulseResponse(status: 200, body: Data("{\"heatmaps\":false}".utf8))); h.settle()
        h.flush()
        XCTAssertTrue(maps(h).isEmpty)
    }
    func testOptOutDropsTheBufferAndStopsCapture() {
        let h = make()
        screen(h); tap(h)
        h.runtime.optOut = true; h.settle()
        XCTAssertFalse(h.runtime.heatmapGate.active)
        h.runtime.optOut = false; h.settle()
        screen(h, "Back"); tap(h); h.flush()
        XCTAssertEqual(maps(h).count, 1)
        XCTAssertEqual(object(maps(h)[0])["screen"] as? String, "Back")
        XCTAssertEqual(points(maps(h)[0]).count, 1, "the point from before the opt-out is gone")
    }

    // MARK: buffer flush triggers

    func testScreenChangeSendsTheOldBufferFirst() {
        let h = make()
        screen(h, "Home"); tap(h); tap(h, y: 500)
        screen(h, "Shop"); tap(h)
        h.flush()
        XCTAssertEqual(maps(h).count, 2)
        XCTAssertEqual(object(maps(h)[0])["screen"] as? String, "Home")
        XCTAssertEqual(points(maps(h)[0]).count, 2)
        XCTAssertEqual(object(maps(h)[1])["screen"] as? String, "Shop")
        let order = h.types()
        XCTAssertLessThan(order.firstIndex(of: "pulse.heatmap")!, order.lastIndex(of: "pulse.screen_view")!, "heatmap before the next screen view")
    }
    func testBucketAndOrientationChangesStartNewBuffers() {
        let h = make()
        screen(h)
        tap(h, width: 390, height: 844)
        tap(h, x: 400, width: 800, height: 600)
        tap(h, x: 300, width: 600, height: 800)
        tap(h, x: 300, width: 800, height: 600)
        h.flush()
        let shape = maps(h).map { "\(object($0)["bucket"] as? String ?? "")/\(object($0)["orientation"] as? String ?? "")" }
        XCTAssertEqual(shape, ["phone/portrait", "tablet/landscape", "tablet/portrait", "tablet/landscape"])
    }
    func testBackgroundFlushesTheBuffer() {
        let h = make()
        h.foreground(); screen(h); tap(h)
        h.background()
        // 0.9.8: the background itself flushes the buffer and sends at once, with no explicit flush.
        XCTAssertEqual(maps(h).count, 1, "the background itself sent the buffer")
        XCTAssertEqual(h.runtime.countForTests, 0, "nothing left waiting in the queue")
        h.flush()
        XCTAssertEqual(maps(h).count, 1, "a later flush does not send it twice")
    }
    func testFlushSendsOpenBufferAndEmptyBuffersAreNeverSent() {
        let h = make()
        screen(h); h.flush()
        XCTAssertTrue(maps(h).isEmpty)
        screen(h, "Other"); h.flush()
        XCTAssertTrue(maps(h).isEmpty)
        tap(h); h.flush(); h.flush()
        XCTAssertEqual(maps(h).count, 1)
    }
    func testTwoHundredPointsSplitIntoSeveralSignalsOfTheSameVisit() {
        let h = make()
        screen(h)
        for index in 0..<450 { tap(h, x: Double(index % 390), y: Double(index % 800) * 3) }
        h.flush()
        XCTAssertEqual(maps(h).map { points($0).count }, [200, 200, 50])
        XCTAssertTrue(maps(h).allSatisfy { object($0)["screen"] as? String == "Home" })
    }
    func testAtMostOneThousandPointsPerSession() {
        let h = make()
        screen(h)
        for index in 0..<1100 { h.runtime.heatmapTap(x: Double(index % 390), y: Double(index % 800) * 3, width: 390, height: 844, keyboardVisible: false, inputTarget: false, ignored: false) }
        h.settle(); h.flush()
        XCTAssertEqual(maps(h).reduce(0) { $0 + points($1).count }, 1000)
    }
    func testANewSessionStartsANewCountOfThousand() {
        let h = make()
        screen(h)
        for index in 0..<1000 { h.runtime.heatmapTap(x: Double(index % 390), y: Double(index % 800) * 3, width: 390, height: 844, keyboardVisible: false, inputTarget: false, ignored: false) }
        h.settle(); h.flush()
        let firstSession = maps(h).last?["sessionId"] as? String
        h.advance(2000)
        tap(h); h.flush()
        let last = maps(h).last
        XCTAssertEqual(points(last ?? [:]).count, 1)
        XCTAssertNotEqual(last?["sessionId"] as? String, firstSession, "after 30 minutes the signal starts a new session")
    }

    // MARK: caps

    func testHeatmapIsOutsideTheAutomaticCapsAndNeverCarriesDroppedAutomatic() {
        let h = make()
        // 101 screen views in one session: the 101st is over the per-session cap and is counted.
        for index in 0..<101 { screen(h, "S\(index)") }
        tap(h); h.flush()
        let heat = maps(h).last
        XCTAssertNil(Harness.system(heat ?? [:])["droppedAutomatic"])
        h.runtime.track("after"); h.flush()
        XCTAssertNotNil(Harness.system(h.events.last { $0["type"] as? String == "after" } ?? [:])["droppedAutomatic"])
        XCTAssertEqual(maps(h).count, 1)
    }

    // MARK: kinds

    func testRageIsTheThirdTapWithinASecondAndThirtyPoints() {
        let h = make()
        screen(h)
        tap(h, x: 100, y: 300); h.advance(0.2); tap(h, x: 110, y: 305); h.advance(0.2); tap(h, x: 105, y: 295); h.advance(0.2); tap(h, x: 100, y: 300)
        h.flush()
        XCTAssertEqual(kinds(maps(h)[0]), ["tap", "tap", "rage", "rage"])
    }
    func testNotRageWhenSlowOrFarApart() {
        let h = make()
        screen(h)
        tap(h, x: 100, y: 300); h.advance(0.6); tap(h, x: 100, y: 300); h.advance(0.6); tap(h, x: 100, y: 300)
        h.advance(0.1); tap(h, x: 300, y: 300); h.advance(0.1); tap(h, x: 100, y: 700); h.advance(0.1); tap(h, x: 100, y: 705)
        h.flush()
        XCTAssertEqual(kinds(maps(h)[0]), ["tap", "tap", "tap", "tap", "tap", "tap"])
    }
    func testRageClusterRestartsAfterAMiss() {
        let h = make()
        screen(h)
        tap(h, x: 100, y: 300); h.advance(0.1); tap(h, x: 100, y: 300); h.advance(0.1); tap(h, x: 100, y: 300)
        h.advance(0.1); tap(h, x: 350, y: 800); h.advance(0.1); tap(h, x: 350, y: 800)
        h.flush()
        XCTAssertEqual(kinds(maps(h)[0]), ["tap", "tap", "rage", "tap", "tap"])
    }

    // MARK: never capture

    func testKeyboardInputAndIgnoredTapsAreNeverCaptured() {
        let h = make()
        screen(h)
        tap(h, keyboard: true); tap(h, input: true); tap(h, ignored: true)
        h.flush()
        XCTAssertTrue(maps(h).isEmpty)
        tap(h); h.flush()
        XCTAssertEqual(points(maps(h)[0]).count, 1)
    }
    func testNonFiniteOrEmptyGeometryIsDropped() {
        let h = make()
        screen(h)
        tap(h, x: .nan); tap(h, y: .infinity); tap(h, width: 0); tap(h, height: -1)
        h.flush()
        XCTAssertTrue(maps(h).isEmpty)
    }
    func testNoElementTextOrIdsAreEverInTheSignal() {
        let h = make()
        screen(h, "Checkout"); tap(h); h.flush()
        let raw = String(decoding: Harness.json(h.transport.requests.last!), as: UTF8.self)
        let heat = maps(h)[0]
        XCTAssertEqual(Set(heat.keys), ["timestamp", "sessionId", "type", "debug", "system", "props", "heatmap", "userHash"])
        XCTAssertEqual(Set(object(heat).keys), ["screen", "bucket", "orientation", "points"])
        XCTAssertEqual(Set(points(heat)[0].keys), ["x", "y", "kind"])
        XCTAssertFalse(raw.contains("http"))
    }

    // MARK: debug screenshot

    private func shots(_ options: PulseOptions? = nil, source: String? = "debug", config: String? = "{\"heatmaps\":true}") -> Harness {
        var o = options ?? PulseOptions(); if options == nil { o.heatmapScreenshots = true }
        let h = make(config: config, options: o, installSource: source)
        h.transport.handler = { (request: PulseRequest, done: @escaping (PulseResponse) -> Void) in
            done(PulseResponse(status: request.url.path.hasSuffix("screenshot") ? 201 : 202))
        }
        screen(h)
        return h
    }
    private func ticket(_ h: Harness, width: Double = 390, height: Double = 844) -> PulseHeatmapShotTicket? {
        let done = expectation(description: "ticket"); var result: PulseHeatmapShotTicket?
        h.runtime.heatmapShotTicket(screen: "Home", width: width, height: height) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result
    }
    private func upload(_ h: Harness, _ t: PulseHeatmapShotTicket, type: String = "image/png", bytes: Int = 100) -> Bool {
        let done = expectation(description: "upload"); var result = false
        h.runtime.heatmapUpload(t, bytes: Data(repeating: 7, count: bytes), contentType: type) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result
    }
    private func uploads(_ h: Harness) -> [PulseRequest] { h.transport.requests.filter { $0.url.path.hasSuffix("/heatmap/screenshot") } }

    func testScreenshotOnlyWhenOptionIsOnAndTheSourceIsNotTheStoreAndHeatmapsAreOn() {
        XCTAssertNotNil(ticket(shots()))
        XCTAssertNil(ticket(shots(PulseOptions())), "the option is off by default")
        XCTAssertNil(ticket(shots(source: "appstore")))
        XCTAssertNil(ticket(shots(source: "testflight")))
        XCTAssertNil(ticket(shots(source: nil)), "an unknown source counts as distributed")
        XCTAssertNotNil(ticket(shots(source: "other")))
        XCTAssertNil(ticket(shots(config: "{\"heatmaps\":false}")))
        XCTAssertNil(ticket(shots(config: nil)))
    }
    func testTheShotHookFiresOnlyWhenAPictureMayBeWanted() {
        var asked: [String] = []
        var options = PulseOptions(); options.heatmapScreenshots = true
        let wanted = make(options: options, installSource: "debug", initialize: false)
        wanted.runtime.heatmapShotHook = { asked.append($0) }
        wanted.runtime.initialize(appKey: "synthetic-key", options: options, heatmapHooks: PulseHeatmapHooks(install: {}, shot: { asked.append($0) })); wanted.settle()
        wanted.runtime.screen("Home"); wanted.settle()
        XCTAssertEqual(asked, ["Home"])
        asked = []
        let store = make(options: options, installSource: "appstore", initialize: false)
        store.runtime.initialize(appKey: "synthetic-key", options: options, heatmapHooks: PulseHeatmapHooks(install: {}, shot: { asked.append($0) })); store.settle()
        store.runtime.screen("Home"); store.settle()
        XCTAssertTrue(asked.isEmpty)
    }
    func testTheTapHookIsInstalledOnlyOnceHeatmapsAreOn() {
        var installs = 0
        let hooks = PulseHeatmapHooks(install: { installs += 1 }, shot: { _ in })
        let off = make(config: nil, initialize: false)
        off.runtime.initialize(appKey: "synthetic-key", options: PulseOptions(), heatmapHooks: hooks); off.settle()
        off.runtime.screen("Home"); off.settle()
        XCTAssertEqual(installs, 0, "nothing is attached while heatmaps are off")
        let on = make(initialize: false)
        on.runtime.initialize(appKey: "synthetic-key", options: PulseOptions(), heatmapHooks: hooks); on.settle()
        on.runtime.screen("Home"); on.settle()
        XCTAssertEqual(installs, 1)
    }
    func testUploadRequestShape() throws {
        let h = shots()
        let t = try XCTUnwrap(ticket(h))
        XCTAssertEqual(t, PulseHeatmapShotTicket(screen: "Home", bucket: "phone", orientation: "portrait"))
        XCTAssertTrue(upload(h, t))
        let request = try XCTUnwrap(uploads(h).first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.contentType, "image/png")
        XCTAssertFalse(request.gzip)
        XCTAssertEqual(request.appKey, "synthetic-key")
        XCTAssertEqual(request.body.count, 100)
        let comps = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "in.mightys.dev")
        XCTAssertEqual(comps.path, "/api/v1/heatmap/screenshot")
        let query = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["screen": "Home", "bucket": "phone", "orientation": "portrait", "appVersion": "1.2.3", "debug": "true"])
    }
    func testAScreenNameWithQueryCharactersCannotSplitTheQuery() throws {
        let h = shots()
        h.runtime.screen("A&B=C+D"); h.settle()
        let done = expectation(description: "t"); var t: PulseHeatmapShotTicket?
        h.runtime.heatmapShotTicket(screen: "A&B=C+D", width: 390, height: 844) { t = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(upload(h, try XCTUnwrap(t)))
        let raw = try XCTUnwrap(uploads(h).first).url.absoluteString
        XCTAssertTrue(raw.contains("screen=A%26B%3DC%2BD"), raw)
    }
    func test201MarksDoneAndNoSecondPictureForTheSameView() throws {
        let h = shots()
        let t = try XCTUnwrap(ticket(h))
        XCTAssertTrue(upload(h, t))
        XCTAssertNil(ticket(h), "marked")
        XCTAssertFalse(upload(h, t))
        XCTAssertEqual(uploads(h).count, 1)
        // The marker survives a new process on the same storage.
        let again = Harness(options: { var o = PulseOptions(); o.heatmapScreenshots = true; return o }(), storage: h.storage, installSource: "debug")
        again.runtime.screen("Home"); again.settle()
        XCTAssertNil(ticket(again))
        // Another bucket, orientation or app version is a new picture.
        XCTAssertNotNil(ticket(h, width: 844, height: 390))
        XCTAssertNotNil(ticket(h, width: 800, height: 1000))
        let newVersion = Harness(options: { var o = PulseOptions(); o.heatmapScreenshots = true; return o }(), storage: h.storage, version: "1.3.0", installSource: "debug")
        newVersion.runtime.screen("Home"); newVersion.settle()
        XCTAssertNotNil(ticket(newVersion))
    }
    func testRefusalsMarkDoneAndAreNotRetried() throws {
        for status in [403, 415, 413, 422] {
            let h = shots()
            h.transport.handler = { (request: PulseRequest, done: @escaping (PulseResponse) -> Void) in done(PulseResponse(status: request.url.path.hasSuffix("screenshot") ? status : 202)) }
            let t = try XCTUnwrap(ticket(h))
            XCTAssertFalse(upload(h, t))
            XCTAssertNil(ticket(h), "status \(status) is final")
        }
    }
    func testRetryableAnswersWaitAndHonourRetryAfter() throws {
        let h = shots()
        h.transport.handler = { (request: PulseRequest, done: @escaping (PulseResponse) -> Void) in
            done(request.url.path.hasSuffix("screenshot") ? PulseResponse(status: 429, retryAfter: "120") : PulseResponse(status: 202))
        }
        let t = try XCTUnwrap(ticket(h))
        XCTAssertFalse(upload(h, t))
        XCTAssertNil(ticket(h), "waiting for Retry-After")
        h.advance(119)
        XCTAssertNil(ticket(h))
        h.advance(2)
        XCTAssertNotNil(ticket(h), "a later visit may try again")
        for status in [503, 507] {
            let g = shots()
            g.transport.handler = { (request: PulseRequest, done: @escaping (PulseResponse) -> Void) in done(PulseResponse(status: request.url.path.hasSuffix("screenshot") ? status : 202)) }
            let u = try XCTUnwrap(ticket(g))
            XCTAssertFalse(upload(g, u))
            XCTAssertNil(ticket(g), "status \(status) pauses for a minute")
            g.advance(61)
            XCTAssertNotNil(ticket(g), "and is not marked done")
        }
        let net = shots()
        net.transport.handler = { (request: PulseRequest, done: @escaping (PulseResponse) -> Void) in done(PulseResponse(status: request.url.path.hasSuffix("screenshot") ? 0 : 202)) }
        XCTAssertFalse(upload(net, try XCTUnwrap(ticket(net))))
        XCTAssertNotNil(ticket(net), "a network failure is retried on a later visit")
    }
    func testNoMoreThanTwentyPerHour() throws {
        let h = shots()
        h.transport.handler = { (request: PulseRequest, done: @escaping (PulseResponse) -> Void) in done(PulseResponse(status: request.url.path.hasSuffix("screenshot") ? 0 : 202)) }
        for index in 0..<20 {
            let name = "S\(index)"
            h.runtime.screen(name); h.settle()
            let done = expectation(description: "t\(index)"); var t: PulseHeatmapShotTicket?
            h.runtime.heatmapShotTicket(screen: name, width: 390, height: 844) { t = $0; done.fulfill() }
            wait(for: [done], timeout: 2)
            XCTAssertFalse(upload(h, try XCTUnwrap(t)))
        }
        h.runtime.screen("S21"); h.settle()
        let done = expectation(description: "t21"); var extra: PulseHeatmapShotTicket?
        h.runtime.heatmapShotTicket(screen: "S21", width: 390, height: 844) { extra = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertNil(extra)
        h.advance(3601)
        h.runtime.screen("S22"); h.settle()
        let again = expectation(description: "t22"); var later: PulseHeatmapShotTicket?
        h.runtime.heatmapShotTicket(screen: "S22", width: 390, height: 844) { later = $0; again.fulfill() }
        wait(for: [again], timeout: 2)
        XCTAssertNotNil(later)
    }
    func testOnlyRasterImagesWithinTwoMebibytesAreUploaded() throws {
        let h = shots()
        let t = try XCTUnwrap(ticket(h))
        XCTAssertFalse(upload(h, t, type: "image/svg+xml"))
        XCTAssertFalse(upload(h, t, type: "text/html"))
        XCTAssertFalse(upload(h, t, bytes: 2 * 1024 * 1024 + 1))
        XCTAssertFalse(upload(h, t, bytes: 0))
        XCTAssertTrue(uploads(h).isEmpty)
        XCTAssertTrue(upload(h, t, type: "image/jpeg", bytes: 2 * 1024 * 1024))
    }
    func testTurningHeatmapsOffMidRunStopsUploads() throws {
        let h = shots()
        let t = try XCTUnwrap(ticket(h))
        h.runtime.receivedConfigForTests(PulseResponse(status: 200, body: Data("{\"heatmaps\":false}".utf8))); h.settle()
        XCTAssertFalse(upload(h, t))
        XCTAssertTrue(uploads(h).isEmpty)
    }
    func testOptOutForgetsTheMarkersAndDeletesTheFile() throws {
        let h = shots()
        let t = try XCTUnwrap(ticket(h))
        XCTAssertTrue(upload(h, t))
        XCTAssertNotNil(h.storage.files[PulseHeatmapShots.fileName])
        h.runtime.optOut = true; h.settle()
        XCTAssertNil(h.storage.files[PulseHeatmapShots.fileName])
    }
    func testNoPictureWhenTheCurrentScreenChangedMeanwhile() {
        let h = shots()
        h.runtime.screen("Other"); h.settle()
        XCTAssertNil(ticket(h), "the ticket is for Home but Other is current")
    }
    func testEncoderScalesToTheLongestSideAndKeepsSmallPngs() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        let image = try XCTUnwrap(context.makeImage())
        let scaled = PulseHeatmapImage.scaled(image)
        XCTAssertEqual(scaled.width, 2048); XCTAssertEqual(scaled.height, 1024)
        let encoded = try XCTUnwrap(PulseHeatmapImage.encode(image))
        XCTAssertEqual(encoded.contentType, "image/png")
        XCTAssertEqual(Array(encoded.bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
    func testNoisyImageFallsBackToJpegAboveTwoMebibytesOfPng() throws {
        let side = 1400
        var raw = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 12345
        for index in 0..<raw.count { seed = seed &* 1664525 &+ 1013904223; raw[index] = UInt8(truncatingIfNeeded: seed >> 24) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(raw) as CFData))
        let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = try XCTUnwrap(PulseHeatmapImage.encode(image))
        XCTAssertEqual(encoded.contentType, "image/jpeg")
        XCTAssertLessThanOrEqual(encoded.bytes.count, 2 * 1024 * 1024)
    }
}
