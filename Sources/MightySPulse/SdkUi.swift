import Foundation

/// Knows which screens, windows and clicks belong to the SDK's own interface (App Control). That interface is never
/// app usage: no screen view, no heatmap point, no debug screenshot while it covers the app.
internal enum PulseSdkUi {
    /// Class names (without module) of everything the SDK puts on screen.
    static let ownedClassNames: Set<String> = ["ControlWindow", "ControlHostViewController", "ControlPanel"]
    private static let lock = NSLock()
    private static var shown = Set<ObjectIdentifier>()

    static func isOwned(rawClassName: String) -> Bool { ownedClassNames.contains(PulseScreenNames.className(rawClassName)) }

    /// True while any SDK-owned screen is up.
    static var visible: Bool { lock.lock(); defer { lock.unlock() }; return !shown.isEmpty }

    /// Called by a presenter when it shows or removes its screen.
    static func set(_ owner: AnyObject, visible now: Bool) {
        lock.lock(); defer { lock.unlock() }
        if now { shown.insert(ObjectIdentifier(owner)) } else { shown.remove(ObjectIdentifier(owner)) }
    }
}
