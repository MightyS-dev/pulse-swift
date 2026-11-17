#if os(macOS)
import AppKit

/// The macOS hook: a local monitor of left mouse-up events. It returns every event unchanged.
internal enum PulseHeatmapAppKit {
    private static let lock = NSLock()
    private static var token: Any?

    static func install(runtime target: PulseRuntime) {
        lock.lock(); let first = token == nil; lock.unlock()
        guard first else { return }
        DispatchQueue.main.async {
            lock.lock()
            if token == nil {
                token = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [target] event in
                    handle(event, runtime: target)
                    return event
                }
            }
            lock.unlock()
        }
    }
    /// Reports one click. Reads the event only; nothing here can consume or delay it.
    static func handle(_ event: NSEvent, runtime target: PulseRuntime) {
        guard let window = event.window else { return }
        report(window: window, location: event.locationInWindow, runtime: target)
    }
    /// A click at `location` (window coordinates, origin bottom left) in `window`.
    static func report(window: NSWindow, location: NSPoint, runtime target: PulseRuntime) {
        guard !PulseSdkUi.visible, !PulseSdkUi.isOwned(rawClassName: NSStringFromClass(type(of: window))) else { return }
        guard target.heatmapGate.active, let content = window.contentView, let frame = content.superview else { return }
        let size = content.bounds.size
        let local = content.convert(location, from: nil)
        let top = content.isFlipped ? local.y : size.height - local.y
        guard local.x >= 0, local.x <= size.width, top >= 0, top <= size.height else { return }
        let found = flags(window: window, content: content, frame: frame, location: location)
        target.heatmapTap(x: Double(local.x), y: Double(top), width: Double(size.width), height: Double(size.height),
                          keyboardVisible: false, inputTarget: found.input, ignored: found.ignored)
    }
    static func flags(window: NSWindow, content: NSView, frame: NSView, location: NSPoint) -> (input: Bool, ignored: Bool) {
        var ignored = PulseHeatmapIgnoreMarker.covers(location, in: window)
        var input = false
        var view = content.hitTest(frame.convert(location, from: nil))
        while let current = view {
            if PulseHeatmapIgnoreFlag.isMarked(current) { ignored = true }
            if isInput(current) { input = true }
            view = current.superview
        }
        return (input, ignored)
    }
    /// Text views (which include the field editor), editable text fields and secure fields.
    static func isInput(_ view: NSView) -> Bool {
        if view is NSText || view is NSSecureTextField { return true }
        if let field = view as? NSTextField { return field.isEditable }
        return false
    }

    // MARK: debug screenshot

    static func scheduleShot(_ screen: String, runtime target: PulseRuntime) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let view = captureView(for: screen, runtime: target) else { return }
            target.heatmapShotTicket(screen: screen, width: Double(view.bounds.width), height: Double(view.bounds.height)) { ticket in
                guard let ticket = ticket else { return }
                DispatchQueue.main.async {
                    guard let view = captureView(for: screen, runtime: target), let image = render(view) else { return }
                    DispatchQueue.global(qos: .utility).async {
                        guard let encoded = PulseHeatmapImage.encode(image) else { return }
                        target.heatmapUpload(ticket, bytes: encoded.bytes, contentType: encoded.contentType)
                    }
                }
            }
        }
    }
    private static func captureView(for screen: String, runtime target: PulseRuntime) -> NSView? {
        guard target.heatmapGate.screen == screen, !PulseSdkUi.visible, NSApp?.isActive == true, let window = NSApp?.mainWindow, window.isVisible,
              let view = window.contentView, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        return view
    }
    private static func render(_ view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}

internal enum PulseHeatmapHook {
    static func install(runtime: PulseRuntime) { PulseHeatmapAppKit.install(runtime: runtime) }
    static func scheduleShot(_ screen: String, runtime: PulseRuntime) { PulseHeatmapAppKit.scheduleShot(screen, runtime: runtime) }
}
#endif
