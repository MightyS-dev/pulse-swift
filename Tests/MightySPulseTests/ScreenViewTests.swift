import Foundation
import XCTest
@testable import MightySPulse

final class ScreenViewTests: XCTestCase {
    private func screens(_ h: Harness) -> [[String: Any]] { h.events.filter { $0["type"] as? String == "pulse.screen_view" } }
    private func props(_ event: [String: Any]) -> [String: Any] { event["props"] as? [String: Any] ?? [:] }

    func testTheSdksOwnScreensAreNeverAppScreens() {
        for owned in ["MightySPulse.ControlHostViewController", "ControlHostViewController", "MightySPulse.ControlWindow", "MightySPulse.ControlPanel"] {
            XCTAssertNil(PulseScreenNames.screenName(rawClassName: owned, isContainer: false, isEmbeddedChild: false), owned)
        }
        XCTAssertEqual(PulseScreenNames.screenName(rawClassName: "MyApp.ControlCenterViewController", isContainer: false, isEmbeddedChild: false),
                       "ControlCenterViewController", "an app class that merely starts with Control stays a screen")
    }
    func testClassNameLosesModulePrefixAndGenerics() {
        XCTAssertEqual(PulseScreenNames.className("MyApp.HomeViewController"), "HomeViewController")
        XCTAssertEqual(PulseScreenNames.className("MyApp.Feed<MyApp.Item>"), "Feed")
        XCTAssertEqual(PulseScreenNames.className("Plain"), "Plain")
    }
    func testSwiftMangledNamesOfPrivateAndNestedClassesBecomeTheirOwnName() {
        // The Objective-C runtime names private and nested Swift classes in mangled form. Real names from swiftc.
        let hash = "8D9C4663DACC9BB988956ACC6F1E8558"
        XCTAssertEqual(PulseScreenNames.className("_TtC5MyAppP33_\(hash)18HomeViewController"), "HomeViewController")
        XCTAssertEqual(PulseScreenNames.className("_TtC5MyAppP33_\(hash)7Detail2"), "Detail2")
        XCTAssertEqual(PulseScreenNames.className("_TtCC5MyApp5Outer7InnerVC"), "InnerVC")
        XCTAssertEqual(PulseScreenNames.className("_TtCC5MyApp5OuterP33_\(hash)9PrivInner"), "PrivInner")
        XCTAssertEqual(PulseScreenNames.screenName(rawClassName: "_TtC5MyAppP33_\(hash)18HomeViewController", isContainer: false,
                                                   isEmbeddedChild: false), "HomeViewController")
        XCTAssertNil(PulseScreenNames.screenName(rawClassName: "_TtCC5MyApp5OuterP33_\(hash)13ControlWindow", isContainer: false,
                                                 isEmbeddedChild: false), "an owned name stays owned after demangling")
    }
    func testMangledNamesThatDoNotParseOrComeFromTheSystemAreStillSkipped() {
        for raw in ["_TtC5MyApp", "_TtC5MyApp99Short", "_TtC5MyApp4Home7", "_TtGC5MyApp4FeedSS_", "_TtC5MyAppP33_x4Home", "_Tt"] {
            XCTAssertNil(PulseScreenNames.screenName(rawClassName: raw, isContainer: false, isEmbeddedChild: false), raw)
        }
        XCTAssertNil(PulseScreenNames.screenName(rawClassName: "_TtC8StoreKit17ProductController", isContainer: false,
                                                 isEmbeddedChild: false, fromSystemFramework: true), "a system framework class")
        XCTAssertEqual(PulseScreenNames.screenName(rawClassName: "MyApp.Home", isContainer: false, isEmbeddedChild: false,
                                                   fromSystemFramework: true), "Home", "only mangled names use the framework rule")
        XCTAssertTrue(PulseScreenNames.isSystemFramework(bundlePath: "/System/Library/Frameworks/StoreKit.framework"))
        XCTAssertTrue(PulseScreenNames.isSystemFramework(bundlePath: "/sim/RuntimeRoot/System/Library/PrivateFrameworks/X.framework"))
        XCTAssertFalse(PulseScreenNames.isSystemFramework(bundlePath: "/private/var/containers/Bundle/Application/ID/MyApp.app"))
    }
    func testCapturedNameForAnAppController() {
        XCTAssertEqual(PulseScreenNames.screenName(rawClassName: "MyApp.SettingsViewController", isContainer: false,
                                                   isEmbeddedChild: false), "SettingsViewController")
    }
    func testContainersEmbeddedChildrenAndSystemControllersAreSkipped() {
        XCTAssertNil(PulseScreenNames.screenName(rawClassName: "UINavigationController", isContainer: true, isEmbeddedChild: false))
        XCTAssertNil(PulseScreenNames.screenName(rawClassName: "MyApp.Child", isContainer: false, isEmbeddedChild: true))
        for system in ["UIAlertController", "UIInputWindowController", "UISystemKeyboardController", "_UIRemoteViewController",
                       "UIKitCore.UIEditingOverlayViewController", "UIHostingController<MyApp.Content>",
                       "SwiftUI.UIHostingController<MyApp.Content>", "SFSafariViewController", "UIActivityViewController"] {
            XCTAssertNil(PulseScreenNames.screenName(rawClassName: system, isContainer: false, isEmbeddedChild: false), system)
        }
    }
    func testAnAppSubclassOfAHostingControllerKeepsItsOwnName() {
        XCTAssertEqual(PulseScreenNames.screenName(rawClassName: "MyApp.ProfileScreen", isContainer: false, isEmbeddedChild: false),
                       "ProfileScreen")
    }
    func testNamesAreCleanedAndCut() {
        XCTAssertEqual(PulseScreenNames.clean("  Home\n"), "Home")
        XCTAssertNil(PulseScreenNames.clean("   "))
        XCTAssertEqual(PulseScreenNames.clean(String(repeating: "a", count: 300))?.count, 128)
    }

    func testScreenSendsNameAndPreviousScreen() {
        let h = Harness()
        h.runtime.screen("Home"); h.runtime.screen("Settings"); h.flush()
        let sent = screens(h)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(props(sent[0])["screen"] as? String, "Home")
        XCTAssertNil(props(sent[0])["previousScreen"])
        XCTAssertEqual(props(sent[1])["screen"] as? String, "Settings")
        XCTAssertEqual(props(sent[1])["previousScreen"] as? String, "Home")
    }
    func testSameScreenAgainIsNotRepeatedButReturnIsSent() {
        let h = Harness()
        for name in ["Home", "Home", "Detail", "Home"] { h.runtime.screen(name) }
        h.flush()
        XCTAssertEqual(screens(h).compactMap { props($0)["screen"] as? String }, ["Home", "Detail", "Home"])
        XCTAssertEqual(props(screens(h)[2])["previousScreen"] as? String, "Detail")
    }
    func testOptOutSuppressesAndResetsDedupe() {
        let h = Harness()
        h.runtime.screen("Home"); h.settle()
        h.runtime.optOut = true; h.settle()
        h.runtime.screen("Other"); h.flush()
        XCTAssertTrue(screens(h).isEmpty || screens(h).allSatisfy { props($0)["screen"] as? String == "Home" })
        h.runtime.optOut = false; h.settle()
        h.runtime.screen("Home"); h.flush()
        let last = screens(h).last
        XCTAssertEqual(props(last ?? [:])["screen"] as? String, "Home")
        XCTAssertNil(props(last ?? [:])["previousScreen"])
    }
    func testScreenBeforeInitializeIsKeptAndSent() {
        let h = Harness(initialize: false)
        h.runtime.screen("Splash"); h.settle()
        h.runtime.initialize(appKey: "synthetic-key", options: PulseOptions()); h.flush()
        XCTAssertEqual(screens(h).count, 1)
    }
    func testScreenViewSignalsAreMarkedDebugLikeAnyOther() {
        var options = PulseOptions(); options.debug = true
        let h = Harness(options: options)
        h.runtime.screen("Home"); h.flush()
        XCTAssertEqual(screens(h).first?["debug"] as? Bool, true)
    }

    func testOffSwitchInstallsNothingAndOnInstallsOnce() {
        var installs = 0
        let off = PulseScreenInstaller { installs += 1 }
        off.activate(enabled: false); off.activate(enabled: false)
        XCTAssertEqual(installs, 0)
        let on = PulseScreenInstaller { installs += 1 }
        on.activate(enabled: true); on.activate(enabled: true); on.activate(enabled: false)
        XCTAssertEqual(installs, 1)
        XCTAssertTrue(PulseOptions().automaticScreenViews)
    }

    // Order, timestamps and flush: screens travel exactly like track.
    private func sequence(_ h: Harness) -> [(String, String)] {
        h.events.filter { ($0["type"] as? String)?.hasPrefix("pulse.") != true || $0["type"] as? String == "pulse.screen_view" }
            .map { ($0["type"] as? String == "pulse.screen_view" ? (props($0)["screen"] as? String ?? "?") : ($0["type"] as? String ?? "?"),
                    $0["timestamp"] as? String ?? "") }
    }
    func testTrackScreenScreenTrackIsOneOrderedSequenceDeliveredByTheFlushThatFollows() {
        let h = Harness()
        h.runtime.track("a"); h.runtime.screen("home"); h.runtime.screen("detail"); h.runtime.track("b")
        h.flush()
        let seq = sequence(h)
        XCTAssertEqual(seq.map { $0.0 }, ["a", "home", "detail", "b"])
        let stamps = seq.map { $0.1 }
        XCTAssertEqual(stamps, stamps.sorted())
        XCTAssertEqual(Set(stamps).count, stamps.count, "timestamps strictly increase")
        XCTAssertEqual(h.transport.requests.count, 1, "one batch")
    }
    func testScreensAreDeliveredByAFlushWhileTheMainThreadIsBlocked() {
        let h = Harness()
        h.runtime.track("a"); h.runtime.screen("home"); h.runtime.screen("detail"); h.runtime.track("b")
        XCTAssertTrue(Thread.isMainThread)
        let done = DispatchSemaphore(value: 0)
        h.runtime.flush { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)   // blocks the main thread until the flush completes
        XCTAssertEqual(sequence(h).map { $0.0 }, ["a", "home", "detail", "b"])
    }
    func testNothingIsLeftBehindForALaterRunWithAnOldTimestamp() {
        let storage = FakeStorage()
        let h = Harness(storage: storage)
        h.runtime.track("a"); h.runtime.screen("home"); h.runtime.screen("detail")
        h.flush()
        XCTAssertEqual(screens(h).count, 2)
        let next = Harness(storage: storage, clock: h.clock.fork(advancing: 3600))
        next.flush()
        XCTAssertTrue(next.events.isEmpty, "nothing replayed by the next run")
    }
    func testScreenKeepsCallTimeTimestampEvenWhenTheQueueIsBusy() {
        let h = Harness()
        let gate = DispatchSemaphore(value: 0)
        h.runtime.pauseQueue(until: gate)                    // keeps the state queue busy
        h.runtime.screen("home")
        h.clock.advance(60)
        h.runtime.track("later")
        gate.signal(); h.flush()
        let seq = sequence(h)
        XCTAssertEqual(seq.map { $0.0 }, ["home", "later"])
        XCTAssertLessThan(seq[0].1, seq[1].1)
    }
#if canImport(UIKit) && !os(watchOS)
    func testUIKitHookPathEnqueuesInOrderWithTrack() {
        let h = Harness()
        PulseScreenHook.install { h.runtime.screen($0) }
        h.runtime.track("a")
        PulseScreenHook.appeared(HomeViewController()); PulseScreenHook.appeared(DetailViewController())
        h.runtime.track("b"); h.flush()
        XCTAssertEqual(sequence(h).map { $0.0 }, ["a", "HomeViewController", "DetailViewController", "b"])
    }
#endif
}
#if canImport(UIKit) && !os(watchOS)
import UIKit
private final class HomeViewController: UIViewController {}
private final class DetailViewController: UIViewController {}
#endif
