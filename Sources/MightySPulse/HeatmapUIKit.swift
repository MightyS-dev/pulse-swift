#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
import UIKit

/// Watches taps on a window and changes nothing: it never recognizes, never cancels or delays a touch, and lets every
/// other recognizer work at the same time. It reports one tap at the end of a single-finger touch that did not drag.
internal final class PulseTapObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    struct Candidate { let point: CGPoint; let input: Bool; let ignored: Bool; let keyboard: Bool }
    /// Called on the main thread with the tap position in window points, the window size and the three privacy flags.
    var report: ((CGPoint, CGSize, Bool, Bool, Bool) -> Void)?
    var isActive: () -> Bool = { false }
    private var candidate: Candidate?
    private var sequenceHadTwoFingers = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        delegate = self
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let window = view as? UIWindow, isActive(), let touch = touches.first else { candidate = nil; return }
        if (event.allTouches?.count ?? 1) > 1 || candidate != nil { candidate = nil; sequenceHadTwoFingers = true; return }
        sequenceHadTwoFingers = false
        let point = touch.location(in: window)
        // Decided now, before the tap's own action can change the screen or the keyboard.
        let flags = PulseHeatmapUIKit.flags(at: point, in: window)
        candidate = Candidate(point: point, input: flags.input, ignored: flags.ignored, keyboard: PulseHeatmapUIKit.keyboardVisible)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let window = view as? UIWindow, let start = candidate, let touch = touches.first else { return }
        let now = touch.location(in: window)
        if hypot(now.x - start.point.x, now.y - start.point.y) > PulseHeatmapMath.touchSlop { candidate = nil }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let window = view as? UIWindow, let tap = candidate, !sequenceHadTwoFingers {
            report?(tap.point, window.bounds.size, tap.keyboard, tap.input, tap.ignored)
        }
        candidate = nil
        finishIfDone(event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { candidate = nil; finishIfDone(event) }
    private func finishIfDone(_ event: UIEvent) {
        let all = event.allTouches ?? []
        if all.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) { sequenceHadTwoFingers = false; state = .failed }
    }
}

/// The iOS hook: a passive tap observer on each key window of the app. No swizzling, no app extensions.
internal enum PulseHeatmapUIKit {
    private static let lock = NSLock()
    private static var installed = false
    private static var visible = false
    private static var runtime: PulseRuntime?
    private static var observers: [NSObjectProtocol] = []

    static var keyboardVisible: Bool { lock.lock(); defer { lock.unlock() }; return visible }
    private static func setKeyboard(_ value: Bool) { lock.lock(); visible = value; lock.unlock() }

    static func install(runtime target: PulseRuntime) {
        guard !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
        lock.lock(); let first = !installed; installed = true; runtime = target; lock.unlock()
        guard first else { return }
        DispatchQueue.main.async {
            let center = NotificationCenter.default
            var tokens: [NSObjectProtocol] = []
            tokens.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in setKeyboard(true) })
            tokens.append(center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in setKeyboard(false) })
            tokens.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                if let window = note.object as? UIWindow { attach(to: window) }
            })
            tokens.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
                (note.object as? UIWindowScene)?.windows.forEach { if $0.isKeyWindow { attach(to: $0) } }
            })
            lock.lock(); observers = tokens; lock.unlock()
            for window in appWindows() where window.isKeyWindow { attach(to: window) }
        }
    }

    /// Keyboard and text-effects windows belong to the system, not to the app.
    static func isSystemWindow(className: String) -> Bool {
        className.contains("Keyboard") || className.contains("TextEffects") || PulseSdkUi.isOwned(rawClassName: className)
    }
    private static func application() -> UIApplication? {
        (UIApplication.self as AnyObject).perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? UIApplication
    }
    static func appWindows() -> [UIWindow] {
        (application()?.connectedScenes ?? []).compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
            .filter { !isSystemWindow(className: NSStringFromClass(type(of: $0))) }
    }
    private static func attach(to window: UIWindow) {
        guard window.windowScene != nil, !isSystemWindow(className: NSStringFromClass(type(of: window))) else { return }
        if window.gestureRecognizers?.contains(where: { $0 is PulseTapObserver }) == true { return }
        lock.lock(); let target = runtime; lock.unlock()
        guard let target = target else { return }
        let observer = PulseTapObserver(target: nil, action: nil)
        observer.isActive = { [target] in target.heatmapGate.active }
        observer.report = { [target] point, size, keyboard, input, ignored in
            target.heatmapTap(x: Double(point.x), y: Double(point.y), width: Double(size.width), height: Double(size.height),
                              keyboardVisible: keyboard, inputTarget: input, ignored: ignored)
        }
        window.addGestureRecognizer(observer)
    }

    /// Whether a tap at `point` hit a text input, a secure field or something marked to ignore. Main thread only.
    static func flags(at point: CGPoint, in window: UIWindow) -> (input: Bool, ignored: Bool) {
        var ignored = PulseHeatmapIgnoreMarker.covers(point, in: window)
        var input = false
        var view = window.hitTest(point, with: nil)
        while let current = view {
            if PulseHeatmapIgnoreFlag.isMarked(current) { ignored = true }
            if isInput(current) { input = true }
            view = current.superview
        }
        return (input, ignored)
    }
    static func isInput(_ view: UIView) -> Bool {
        if view is UITextField || view is UITextView || view is UITextInput { return true }
        return (view as? UITextInputTraits)?.isSecureTextEntry == true
    }

    // MARK: debug screenshot

    static func scheduleShot(_ screen: String, runtime target: PulseRuntime) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let window = captureWindow(for: screen, runtime: target) else { return }
            target.heatmapShotTicket(screen: screen, width: Double(window.bounds.width), height: Double(window.bounds.height)) { ticket in
                guard let ticket = ticket else { return }
                DispatchQueue.main.async {
                    guard let window = captureWindow(for: screen, runtime: target), let image = render(window) else { return }
                    DispatchQueue.global(qos: .utility).async {
                        guard let encoded = PulseHeatmapImage.encode(image) else { return }
                        target.heatmapUpload(ticket, bytes: encoded.bytes, contentType: encoded.contentType)
                    }
                }
            }
        }
    }
    /// The key window, only when the screen is still current, the app is in front and no keyboard is up.
    private static func captureWindow(for screen: String, runtime target: PulseRuntime) -> UIWindow? {
        guard target.heatmapGate.screen == screen, !keyboardVisible, !PulseSdkUi.visible, application()?.applicationState == .active else { return nil }
        return appWindows().first { $0.isKeyWindow && $0.bounds.width > 0 && $0.bounds.height > 0 }
    }
    private static func render(_ window: UIWindow) -> CGImage? {
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = max(0.1, min(window.traitCollection.displayScale, Double(PulseHeatmapImage.maxSide) / Double(max(bounds.width, bounds.height))))
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        return renderer.image { _ in _ = window.drawHierarchy(in: bounds, afterScreenUpdates: false) }.cgImage
    }
}

internal enum PulseHeatmapHook {
    static func install(runtime: PulseRuntime) { PulseHeatmapUIKit.install(runtime: runtime) }
    static func scheduleShot(_ screen: String, runtime: PulseRuntime) { PulseHeatmapUIKit.scheduleShot(screen, runtime: runtime) }
}
#endif
