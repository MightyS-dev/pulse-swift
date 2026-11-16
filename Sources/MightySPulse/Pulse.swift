import Foundation

/// Privacy-first analytics for apps and games.
///
/// `Pulse` is the whole public entry point of the package. Call ``initialize(appKey:options:)`` once at
/// startup, then send named signals with ``track(_:value:props:)``.
///
/// ```swift
/// Pulse.initialize(appKey: "YOUR_APP_KEY")
/// Pulse.track("level.complete")
/// Pulse.track("purchase", value: 4.99, props: ["sku": "gems_100"])
/// ```
///
/// The SDK reads no advertising or device identifier. Sessions are random ids that rotate after 30 minutes of
/// inactivity. Signals are batched, queued on disk while offline and sent gzipped. No public call throws into the
/// host app, and none blocks the main thread.
public enum Pulse {
    private static let runtime = PulseRuntime(clock: PulseSystemClock(), transport: PulseURLTransport(),
                                             storage: PulseFileStorage.standard(), environment: PulseEnvironment.system,
                                             device: PulseLiveDevice(), fetchesConfig: true)
    private static let lifecycle = PulseLifecycle(runtime: runtime)
    private static let screens = PulseScreenInstaller { [runtime] in PulseScreenHook.install { runtime.screen($0) } }

    /// Starts the SDK. Call it once, early in app startup. Later calls are ignored.
    ///
    /// Up to 100 signals tracked before this call are kept in memory and sent after it. Nothing is sent earlier.
    /// The first batch after start is sent at once; later batches follow the flush interval or batch size.
    ///
    /// - Parameters:
    ///   - appKey: Your app key from the Pulse dashboard.
    ///   - options: Delivery and environment settings. See ``PulseOptions``.
    public static func initialize(appKey: String, options: PulseOptions = PulseOptions()) {
        _ = lifecycle
        runtime.initialize(appKey: appKey, options: options) { [screens] enabled in screens.activate(enabled: enabled) }
    }
    /// Records that the user is now looking at the screen called `name`.
    ///
    /// Sends a `pulse.screen_view` signal with the screen name and, when known, the previous screen name. Use it
    /// for screens the SDK cannot see by itself. The name is trimmed and cut to 128 characters; never put a
    /// URL, a title typed by the user or any personal text in it. The same name twice in a row is sent once.
    /// Safe to call from any thread; it returns at once and respects ``optOut``.
    public static func screen(_ name: String) { runtime.screen(name) }
    /// Records one named signal (event). Safe to call from any thread; it returns at once and never throws.
    ///
    /// Invalid signals are ignored. Do not put personal information in the name, value or props.
    ///
    /// - Parameters:
    ///   - type: The signal name, for example `"level.complete"`. Must contain non-whitespace text and fit 200
    ///     UTF-16 code units.
    ///   - value: An optional finite number, for example a price or a score.
    ///   - props: Optional properties. Strings, booleans (sent as `"true"` or `"false"`) and finite numbers are
    ///     kept; other value types are dropped. At most 32 properties are kept.
    public static func track(_ type: String, value: Double? = nil, props: [String: Any]? = nil) {
        runtime.track(type, value: value, props: props)
    }
    /// Sets or clears the optional user id.
    ///
    /// The id is hashed with SHA-256 on the device. Only the hex digest is stored or sent; the raw id never is.
    ///
    /// - Parameter identifier: Your own account id, or `nil` to clear the user for future signals.
    public static func setUser(_ identifier: String?) { runtime.setUser(identifier) }
    /// Sends queued signals now and waits until the signals captured by this call have left the queue.
    ///
    /// The wait also ends on opt-out, a rejected app key, shutdown or task cancellation. Offline delivery can take
    /// indefinitely, so await it from a task and never block the main thread. Returning does not prove
    /// server-side storage.
    public static func flush() async {
        await runtime.flushAsync()
    }
    /// Whether collection is switched off for this app on this device.
    ///
    /// Setting it to `true` stops collection at once, clears the queue and remembers the choice across launches.
    /// Setting it to `false` resumes collection. Connect it to your consent or settings screen.
    public static var optOut: Bool {
        get { runtime.optOut }
        set { runtime.optOut = newValue }
    }
}

// This gate handles cancellation racing continuation registration or transport completion.
internal final class PulseFlushGate {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var finished = false
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func install(_ callback: @escaping () -> Void) {
        lock.lock()
        if finished { lock.unlock(); callback() }
        else { completion = callback; lock.unlock() }
    }
    func finish() {
        lock.lock(); finished = true; let callback = completion; completion = nil; lock.unlock()
        callback?()
    }
}
internal extension PulseRuntime {
    func flushAsync() async {
        let gate = PulseFlushGate()
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.install { continuation.resume() }
                if Task.isCancelled { gate.finish(); return }
                flush(id: id, isCancelled: { gate.isFinished }) { gate.finish() }
            }
        }, onCancel: { gate.finish(); self.cancelFlush(id: id) })
    }
}
