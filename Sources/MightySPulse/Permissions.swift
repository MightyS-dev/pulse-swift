import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Where the SDK reads permission statuses. Reading only: there is no call here that asks the user for anything.
internal protocol PulsePermissionSource: AnyObject {
    func start()
    /// Reads the statuses again, in the background. Called when the app comes to the foreground.
    func refresh()
    /// Waits, bounded, until the first notification status is cached. Never called on the main thread.
    func awaitReady(timeout: TimeInterval)
    /// Cached values only: `notificationPermission` and, where the platform has it, `trackingPermission`.
    func snapshot() -> [String: String]
}
internal final class PulseNoPermissions: PulsePermissionSource {
    func start() {}
    func refresh() {}
    func awaitReady(timeout: TimeInterval) {}
    func snapshot() -> [String: String] { [:] }
}

/// Pure mapping from the raw system values to the names that are sent.
internal enum PulsePermission {
    /// `UNAuthorizationStatus` raw values.
    static func notification(rawValue: Int) -> String? {
        switch rawValue {
        case 0: return "notDetermined"
        case 1: return "denied"
        case 2: return "granted"
        case 3: return "provisional"
        case 4: return "ephemeral"
        default: return nil
        }
    }
    /// `ATTrackingManager.AuthorizationStatus` raw values.
    static func tracking(rawValue: Int) -> String? {
        switch rawValue {
        case 0: return "notDetermined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "authorized"
        default: return nil
        }
    }
    /// The App Tracking Transparency status, read only when the app has already loaded that framework (an app that
    /// uses it). The SDK does not link the framework and never loads it, so an app that has no tracking code is not
    /// touched. It calls the status getter and nothing else. Nil on platforms without it.
    static func trackingRawValue() -> Int? {
        #if os(iOS) || os(tvOS)
        guard let manager = NSClassFromString("ATTrackingManager") else { return nil }
        let selector = NSSelectorFromString("trackingAuthorizationStatus")
        guard let method = class_getClassMethod(manager, selector) else { return nil }
        typealias Getter = @convention(c) (AnyClass, Selector) -> UInt
        let read = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return Int(read(manager, selector))
        #else
        return nil
        #endif
    }
}

#if canImport(UserNotifications)
/// The notification status from `UNUserNotificationCenter.getNotificationSettings`, cached. Only read when the
/// process is a real app or app extension bundle: the notification center cannot be used from a bare command line tool.
internal final class PulseLivePermissions: PulsePermissionSource {
    private let lock = NSLock()
    private var notification: String?
    private var started = false
    private let ready = DispatchGroup()

    private var canRead: Bool {
        let ext = Bundle.main.bundleURL.pathExtension
        return Bundle.main.bundleIdentifier != nil && (ext == "app" || ext == "appex")
    }
    func start() {
        lock.lock(); let first = !started; started = true; lock.unlock()
        if first { read(waiting: true) }
    }
    func refresh() { read(waiting: false) }
    private func read(waiting: Bool) {
        guard canRead else { return }
        if waiting { ready.enter() }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            if let self = self {
                let value = PulsePermission.notification(rawValue: settings.authorizationStatus.rawValue)
                self.lock.lock(); self.notification = value; self.lock.unlock()
            }
            if waiting { self?.ready.leave() }
        }
    }
    func awaitReady(timeout: TimeInterval) { _ = ready.wait(timeout: .now() + max(0, timeout)) }
    func snapshot() -> [String: String] {
        var values: [String: String] = [:]
        lock.lock(); let status = notification; lock.unlock()
        if let status = status { values["notificationPermission"] = status }
        if let raw = PulsePermission.trackingRawValue(), let name = PulsePermission.tracking(rawValue: raw) {
            values["trackingPermission"] = name
        }
        return values
    }
}
#else
internal typealias PulseLivePermissions = PulseNoPermissions
#endif

/// The time this process started, from the process table. Not the system boot time. Nil when it cannot be read.
internal enum PulseProcessStart {
    static func read() -> Date? {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        guard started.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
        #else
        return nil
        #endif
    }
}
