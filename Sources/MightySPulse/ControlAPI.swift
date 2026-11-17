import Foundation

/// A handle returned by ``PulseControl/onChange(_:)``. Call ``cancel()`` to stop the callbacks.
public final class ControlSubscription {
    private let lock = NSLock()
    private var cancelled = false
    private let onCancel: () -> Void
    @_optimize(size) internal init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    /// Stops the callbacks. Safe to call more than once.
    @_optimize(size) public func cancel() {
        lock.lock(); let first = !cancelled; cancelled = true; lock.unlock()
        if first { onCancel() }
    }
    @_optimize(size) deinit { }
}

/// Reads and steers App Control: the update, block and maintenance rules set in the Pulse dashboard.
///
/// By default the SDK checks the rules after ``Pulse/initialize(appKey:options:)`` and shows its own screens. With
/// ``PulseControlMode/manual`` it only keeps ``state`` current and you draw the screens:
///
/// ```swift
/// var options = PulseOptions()
/// options.control = .manual
/// Pulse.initialize(appKey: "YOUR_APP_KEY", options: options)
/// Pulse.control.onChange { state in /* show your own screen for state.kind */ }
/// ```
///
/// Nothing here blocks, throws or closes your app. If the rules cannot be read, the last known state stays (or `normal`).
public final class PulseControl {
    internal let engine: ControlEngine
    @_optimize(size) internal init(engine: ControlEngine) { self.engine = engine }

    /// What to show right now. ``ControlState/Kind/normal`` until the rules say otherwise.
    public var state: ControlState { engine.snapshot.primary }
    /// A banner or card that comes with ``state`` (for example an announcement next to a suggested update).
    public var notices: [ControlState] { engine.snapshot.notices }

    /// Calls `handler` on the main thread whenever ``state`` or ``notices`` change.
    ///
    /// - Returns: A token; call ``ControlSubscription/cancel()`` to stop. Keeping the token is optional.
    @discardableResult
    @_optimize(size) public func onChange(_ handler: @escaping (ControlState) -> Void) -> ControlSubscription {
        engine.subscribe(handler)
    }
    /// Asks the server for the rules now, without waiting for the next time the app comes to the foreground.
    /// Returns at once; the result arrives through ``onChange(_:)``.
    @_optimize(size) public func checkNow() { engine.checkNow() }
    /// Opens the store page (or the announcement link) of the current state. Does nothing for states without a link.
    @_optimize(size) public func openStore() { engine.openStore() }
    /// Closes a screen the user may close: a suggested update, an announcement, a what's new card, a maintenance banner,
    /// or any screen with ``ControlState/allowContinue`` set. Does nothing for a screen that blocks the app.
    @_optimize(size) public func dismiss() { engine.dismiss() }
}
