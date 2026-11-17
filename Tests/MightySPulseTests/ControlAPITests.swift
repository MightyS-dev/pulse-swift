import Foundation
import XCTest
@testable import MightySPulse

final class ControlAPITests: XCTestCase {
    typealias Build = ControlRulesBuilder
    private func release(_ mode: PulseControlMode = .automatic) -> PulseOptions {
        var options = PulseOptions(); options.debug = false; options.control = mode; return options
    }

    func testOptionDefaultsToAutomaticAndPublicApiExists() {
        XCTAssertEqual(PulseOptions().control, .automatic)
        let api = Pulse.control
        XCTAssertEqual(api.state, .normal)
        XCTAssertTrue(api.notices.isEmpty)
        let token = api.onChange { _ in }
        token.cancel(); token.cancel()
    }

    func testManualModeKeepsStateCurrentAndShowsNothing() {
        let server = ControlServer(.rules(Build.required()))
        let h = Harness.control(server, options: release(.manual))
        XCTAssertEqual(h.primary.kind, .updateRequired)
        XCTAssertTrue(h.presenter.screens.isEmpty)
        XCTAssertEqual(h.presenter.hides, 0)
    }

    func testOnChangeFiresOnTheCallbackQueueAndTheTokenStopsIt() {
        let server = ControlServer(.status(500))
        let h = Harness.control(server, options: release(.manual))
        var seen: [ControlState.Kind] = []
        let token = PulseControl(engine: h.control).onChange { seen.append($0.kind) }
        server.reply = .rules(Build.required()); h.checkControl()
        XCTAssertEqual(seen, [.updateRequired])
        server.reply = .rules(Build.required()); h.checkControl()
        XCTAssertEqual(seen, [.updateRequired], "no call when nothing changed")
        token.cancel()
        server.reply = .rules(Build.make()); h.checkControl()
        XCTAssertEqual(seen, [.updateRequired])
        XCTAssertEqual(PulseControl(engine: h.control).state, .normal)
    }

    func testStateCarriesReadyTextsAndTheStoreLink() throws {
        let h = Harness.control(ControlServer(.rules(Build.required())), options: release())
        let state = h.primary
        XCTAssertEqual(state.kind, .updateRequired)
        XCTAssertEqual(state.title, "Update required")
        XCTAssertTrue(state.body.contains("Orchard"))
        XCTAssertEqual(state.buttonText, "Update")
        XCTAssertEqual(state.url?.absoluteString, "itms-apps://apps.apple.com/app/id1")
        XCTAssertFalse(state.allowContinue)
        XCTAssertFalse(state.isTestBuild)
    }

    func testCustomTextsReplaceTheDefaultsAndLanguageFollowsTheApp() {
        let rules = Build.make(["update": ["ios": ["min": "9.0.0", "mode": "required", "storeUrl": "https://apps.apple.com/app/id1"]],
                                "texts": ["custom": ["updateRequired": ["title": NSNull(), "body": "Please update {appName} now", "buttonText": "Go"]]]])
        let german = Harness.control(ControlServer(.rules(rules)), options: release(), environment: .test(languages: ["de-DE"]))
        XCTAssertEqual(german.primary.title, "Update erforderlich")
        XCTAssertEqual(german.primary.body, "Please update Orchard now")
        XCTAssertEqual(german.primary.buttonText, "Go")
    }

    func testDebugBuildShowsTheTestBannerAndLetsTheUserContinue() {
        let h = Harness.control(ControlServer(.rules(Build.required())), options: { var o = PulseOptions(); o.debug = true; return o }())
        XCTAssertEqual(h.primary.kind, .updateRequired)
        XCTAssertTrue(h.primary.isTestBuild)
        XCTAssertTrue(h.primary.allowContinue)
        PulseControl(engine: h.control).dismiss(); h.settle()
        XCTAssertEqual(h.primary, .normal, "Continue hides the preview for this run")
    }

    func testDismissIsRefusedWhenTheScreenBlocks() {
        let h = Harness.control(ControlServer(.rules(Build.required())), options: release())
        PulseControl(engine: h.control).dismiss(); h.settle()
        XCTAssertEqual(h.primary.kind, .updateRequired)
        let blocked = Harness.control(ControlServer(.rules(Build.make(["blocked": [["version": "1.2.3", "platforms": ["ios"], "allowContinue": false]]]))), options: release())
        PulseControl(engine: blocked.control).dismiss(); blocked.settle()
        XCTAssertEqual(blocked.primary.kind, .versionBlocked)
        let soft = Harness.control(ControlServer(.rules(Build.make(["blocked": [["version": "1.2.3", "platforms": NSNull(), "allowContinue": true]]]))), options: release())
        XCTAssertTrue(soft.primary.allowContinue)
        PulseControl(engine: soft.control).dismiss(); soft.settle()
        XCTAssertEqual(soft.primary, .normal)
    }

    func testSuggestedUpdateIsQuietForADayAfterDismiss() {
        let clock = FakeClock()
        let rules = Build.make(["update": ["ios": ["min": NSNull(), "latest": "2.0.0", "mode": "suggested", "storeUrl": "https://apps.apple.com/app/id1"]]])
        let h = Harness.control(ControlServer(.rules(rules)), options: release(), clock: clock)
        XCTAssertEqual(h.primary.kind, .updateSuggested)
        XCTAssertEqual(h.primary.buttonText, "Update")
        PulseControl(engine: h.control).dismiss(); h.settle()
        XCTAssertEqual(h.primary, .normal)
        let again = Harness.control(ControlServer(.rules(rules)), options: release(), storage: h.storage, clock: clock.fork(advancing: 23 * 3600))
        XCTAssertEqual(again.primary, .normal)
        let next = Harness.control(ControlServer(.rules(rules)), options: release(), storage: h.storage, clock: clock.fork(advancing: 25 * 3600))
        XCTAssertEqual(next.primary.kind, .updateSuggested)
    }

    func testAnnouncementCardIsShownOnceAndRemembered() {
        let clock = FakeClock()
        let until = ControlRulesBuilder.iso(clock.now.addingTimeInterval(86400))
        let rules = Build.make(["announcement": ["id": "a7", "title": "Winter event", "body": "Snow is here", "url": "https://example.com/x",
                                                 "buttonText": NSNull(), "until": until, "platforms": NSNull()]])
        let h = Harness.control(ControlServer(.rules(rules)), options: release(), clock: clock)
        XCTAssertEqual(h.primary.kind, .announcement)
        XCTAssertEqual(h.primary.title, "Winter event")
        XCTAssertEqual(h.primary.buttonText, "OK")
        XCTAssertEqual(h.primary.url?.absoluteString, "https://example.com/x")
        PulseControl(engine: h.control).dismiss(); h.settle()
        XCTAssertEqual(h.primary, .normal)
        let restart = Harness.control(ControlServer(.rules(rules)), options: release(), storage: h.storage, clock: clock.fork(advancing: 60))
        XCTAssertEqual(restart.primary, .normal)
    }

    func testWhatsNewAfterAnUpdateAndAnnouncementWaitsBehindASuggestedUpdate() {
        let clock = FakeClock(), storage = FakeStorage()
        let old = Harness(storage: storage, clock: clock, version: "1.2.2")
        old.runtime.control.start(appKey: "synthetic-key", base: URL(string: "https://in.mightys.dev/api/v1/control")!, options: PulseOptions(), sdk: "x@1", appVersion: "1.2.2")
        old.settle()
        let until = ControlRulesBuilder.iso(clock.now.addingTimeInterval(86400))
        let rules = Build.make(["whatsNew": ["version": "1.2.3", "body": "Faster sync"],
                                "announcement": ["id": "b1", "title": "Hello", "body": "World", "url": NSNull(), "buttonText": NSNull(), "until": until, "platforms": NSNull()],
                                "update": ["ios": ["min": NSNull(), "latest": "9.0.0", "mode": "suggested", "storeUrl": "https://apps.apple.com/app/id1"]]])
        let h = Harness.control(ControlServer(.rules(rules)), options: release(), storage: storage, clock: clock.fork(advancing: 100))
        XCTAssertEqual(h.primary.kind, .updateSuggested)
        XCTAssertEqual(h.control.snapshot.notices.map(\.kind), [.whatsNew])
        PulseControl(engine: h.control).dismiss(); h.settle()
        XCTAssertEqual(h.primary.kind, .whatsNew)
        XCTAssertEqual(h.primary.title, "What's new in 1.2.3")
        XCTAssertEqual(h.primary.version, "1.2.3")
        PulseControl(engine: h.control).dismiss(); h.settle()
        XCTAssertEqual(h.primary.kind, .announcement)
    }

    func testAppExtensionKeepsTheStateAndShowsNothing() {
        let h = Harness.control(ControlServer(.rules(Build.required())), options: release(), environment: .test(isExtension: true))
        XCTAssertEqual(h.primary.kind, .updateRequired)
        XCTAssertTrue(h.presenter.screens.isEmpty)
    }

    func testAutomaticModeHandsTheScreenToThePresenterAndHidesItWhenNormal() throws {
        let server = ControlServer(.rules(Build.required()))
        let h = Harness.control(server, options: release())
        let shown = try XCTUnwrap(h.presenter.screens.last)
        XCTAssertEqual(shown.primary.kind, .updateRequired)
        XCTAssertEqual(shown.continueText, "Continue")
        XCTAssertEqual(shown.tryAgainText, "Try again")
        XCTAssertEqual(shown.testBanner, "Test build: App Control preview")
        server.reply = .rules(Build.make()); h.checkControl()
        XCTAssertGreaterThan(h.presenter.hides, 0)
        XCTAssertEqual(h.primary, .normal)
    }

    func testUpdateWithoutALinkHasNoUpdateButtonAndOpensNothing() {
        var opened = 0
        let h = Harness.control(ControlServer(.rules(Build.required(url: nil))), options: release(), environment: .test(opened: { _ in opened += 1 }))
        PulseControl(engine: h.control).openStore(); h.settle()
        XCTAssertEqual(opened, 0)
        XCTAssertNil(h.primary.url)
    }

    func testNoExitCallInTheSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MightySPulse")
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasPrefix("Control") {
            let text = try String(contentsOf: root.appendingPathComponent(name))
            XCTAssertFalse(text.contains("exit("), name)
            XCTAssertFalse(text.contains("terminate("), name)
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), "dash in \(name)")
        }
    }
}
