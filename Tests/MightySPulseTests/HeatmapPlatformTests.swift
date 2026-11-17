import Foundation
import XCTest
@testable import MightySPulse

final class HeatmapConfigTests: XCTestCase {
    func testHeatmapsKeyParsesAsABooleanOnly() {
        func parse(_ text: String) -> PulseRemoteConfig? { PulseRemoteConfig.parse(Data(text.utf8)) }
        XCTAssertTrue(parse("{\"heatmaps\":true}")?.heatmaps == true)
        XCTAssertTrue(parse("{\"heatmaps\":false}")?.heatmaps == false)
        for bad in ["{}", "{\"heatmaps\":1}", "{\"heatmaps\":\"true\"}", "{\"heatmaps\":null}"] { XCTAssertTrue(parse(bad)?.heatmaps == false, bad) }
    }
    func testDisabledAndPausedListsKeepTheHeatmapType() {
        let config = PulseRemoteConfig.parse(Data("{\"disabledSignals\":[\"pulse.heatmap\"],\"pausedSignals\":[\"pulse.heatmap\",\"x\"]}".utf8))
        XCTAssertEqual(config?.disabledSignals, ["pulse.heatmap"])
        XCTAssertEqual(config?.pausedSignals, ["pulse.heatmap"])
    }
    func testNewOptionsDefaults() {
        XCTAssertTrue(PulseOptions().captureHeatmaps)
        XCTAssertFalse(PulseOptions().heatmapScreenshots)
    }
    func testAllOnConfigDoesNotAllowHeatmaps() {
        XCTAssertFalse(PulseEffectiveConfig.allOn.sends("pulse.heatmap"))
    }
}

#if os(macOS)
import AppKit

final class HeatmapAppKitTests: XCTestCase {
    func testInputRules() {
        XCTAssertTrue(PulseHeatmapAppKit.isInput(NSTextView()))
        XCTAssertTrue(PulseHeatmapAppKit.isInput(NSSecureTextField()))
        let editable = NSTextField(); editable.isEditable = true
        XCTAssertTrue(PulseHeatmapAppKit.isInput(editable))
        let label = NSTextField(labelWithString: "Title")
        XCTAssertFalse(PulseHeatmapAppKit.isInput(label), "a label is not an input")
        XCTAssertFalse(PulseHeatmapAppKit.isInput(NSButton()))
        XCTAssertFalse(PulseHeatmapAppKit.isInput(NSView()))
    }
    func testIgnoreFlagIsOnTheViewAndFoundThroughSuperviews() {
        let parent = NSView(), child = NSView()
        parent.addSubview(child)
        XCTAssertFalse(PulseHeatmapIgnoreFlag.isMarked(parent))
        Pulse.heatmapIgnore(parent)
        XCTAssertTrue(PulseHeatmapIgnoreFlag.isMarked(parent))
        XCTAssertFalse(PulseHeatmapIgnoreFlag.isMarked(child))
    }
    func testClickHandlingNeverTouchesTheEventAndNoWindowMeansNothing() throws {
        let h = Harness()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        PulseHeatmapAppKit.handle(event, runtime: h.runtime)
        h.settle(); h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.heatmap").count, 0)
        XCTAssertEqual(event.type, .leftMouseUp)
        XCTAssertEqual(event.locationInWindow, NSPoint(x: 10, y: 10))
    }
    func testClicksOnInputsAndIgnoredViewsAreNotCapturedInARealWindow() throws {
        _ = NSApplication.shared
        let storage = FakeStorage(); storage.files["config"] = Data("{\"heatmaps\":true}".utf8)
        let h = Harness(storage: storage)
        h.runtime.screen("Home"); h.settle()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let content = try XCTUnwrap(window.contentView)
        let field = NSTextField(frame: NSRect(x: 0, y: 500, width: 200, height: 40)); field.isEditable = true
        let secure = NSSecureTextField(frame: NSRect(x: 0, y: 400, width: 200, height: 40))
        let plain = NSView(frame: NSRect(x: 0, y: 300, width: 200, height: 40))
        let flagged = NSView(frame: NSRect(x: 0, y: 200, width: 200, height: 40))
        let inner = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 40)); flagged.addSubview(inner)
        Pulse.heatmapIgnore(flagged)
        [field, secure, plain, flagged].forEach { content.addSubview($0) }
        for point in [NSPoint(x: 10, y: 520), NSPoint(x: 10, y: 420), NSPoint(x: 10, y: 220)] {
            PulseHeatmapAppKit.report(window: window, location: point, runtime: h.runtime)
        }
        h.settle(); h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.heatmap").count, 0)
        PulseHeatmapAppKit.report(window: window, location: NSPoint(x: 10, y: 320), runtime: h.runtime)
        PulseHeatmapAppKit.report(window: window, location: NSPoint(x: 900, y: 320), runtime: h.runtime)
        h.settle(); h.flush()
        let sent = h.eventsOfType("pulse.heatmap")
        XCTAssertEqual(sent.count, 1)
        let points = (sent[0]["heatmap"] as? [String: Any])?["points"] as? [[String: Any]]
        XCTAssertEqual(points?.count, 1, "the click outside the content is dropped")
        XCTAssertEqual(points?[0]["y"] as? Double, 280)
    }
    func testClicksOnTheSdksOwnPanelOrWhileItsScreenIsUpAreNeverCaptured() throws {
        _ = NSApplication.shared
        let storage = FakeStorage(); storage.files["config"] = Data("{\"heatmaps\":true}".utf8)
        let h = Harness(storage: storage)
        h.runtime.screen("Home"); h.settle()
        let panel = ControlPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        panel.contentView?.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        PulseHeatmapAppKit.report(window: panel, location: NSPoint(x: 10, y: 10), runtime: h.runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let owner = NSObject()
        PulseSdkUi.set(owner, visible: true)
        PulseHeatmapAppKit.report(window: window, location: NSPoint(x: 10, y: 10), runtime: h.runtime)
        PulseSdkUi.set(owner, visible: false)
        h.settle(); h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.heatmap").count, 0)
        PulseHeatmapAppKit.report(window: window, location: NSPoint(x: 10, y: 10), runtime: h.runtime)
        h.settle(); h.flush()
        XCTAssertEqual(h.eventsOfType("pulse.heatmap").count, 1, "the app's own click is captured again")
    }
    func testDesktopBucketIsFixedOnMac() {
        XCTAssertEqual(PulseHeatmapPlatform.fixedBucket, "desktop")
    }
}
#endif
