import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif os(macOS)
import AppKit
#elseif os(watchOS)
import WatchKit
#endif

/// Device state that can change while the app runs (or that the system only hands out on the main thread).
internal protocol PulseDeviceSource: AnyObject {
    func start()
    /// Waits, bounded, until the first values are cached. Never called on the main thread.
    func awaitReady(timeout: TimeInterval)
    /// Cached values only. Cheap and safe from any thread.
    func snapshot() -> [String: String]
}
internal final class PulseNoDevice: PulseDeviceSource {
    func start() {}
    func awaitReady(timeout: TimeInterval) {}
    func snapshot() -> [String: String] { [:] }
}

/// Pure mapping helpers, shared by every platform.
internal enum PulseDeviceFormat {
    static func orientation(width: Double, height: Double) -> String {
        width > height ? "landscape" : (width < height ? "portrait" : "square")
    }
    /// "UICTContentSizeCategoryAccessibilityXXL" gives "AccessibilityXXL". Unknown or unspecified gives nil.
    static func categoryName(raw: String) -> String? {
        let prefix = "UICTContentSizeCategory"
        guard raw.hasPrefix(prefix) else { return nil }
        let name = String(raw.dropFirst(prefix.count))
        return scales[name] == nil ? nil : name
    }
    private static let scales: [String: Double] = [
        "XS": 0.82, "S": 0.88, "M": 0.94, "L": 1, "XL": 1.12, "XXL": 1.24, "XXXL": 1.35,
        "AccessibilityM": 1.65, "AccessibilityL": 1.94, "AccessibilityXL": 2.35,
        "AccessibilityXXL": 2.76, "AccessibilityXXXL": 3.12]
    static func fontScale(categoryName: String) -> String? { scales[categoryName].map(PulseEnvironment.number) }
    static func connection(satisfied: Bool, wifi: Bool, cellular: Bool, wired: Bool) -> String {
        if !satisfied { return "none" }
        if wifi { return "wifi" }
        if cellular { return "cellular" }
        if wired { return "ethernet" }
        return "other"
    }
    static func flag(_ value: Bool) -> String { value ? "true" : "false" }
}

/// Reads UIKit, AppKit and WatchKit values on the main thread, caches them, and refreshes the cache from the
/// system notifications. Signals only ever read the cache. The network path comes from a path monitor and the
/// power state from a notification.
internal final class PulseLiveDevice: PulseDeviceSource {
    private let lock = NSLock()
    private var started = false
    private var main: [String: String] = [:]
    private var connection: String?
    private var lowPower = false
    private var observers: [NSObjectProtocol] = []
    private let ready = DispatchGroup()
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    #endif

    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        ready.enter()
        startNetwork()
        updatePower()
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) {
            [weak self] _ in self?.updatePower()
        })
        if Thread.isMainThread { setUpMain() } else { DispatchQueue.main.async { [self] in setUpMain() } }
    }
    func awaitReady(timeout: TimeInterval) { _ = ready.wait(timeout: .now() + max(0, timeout)) }
    func snapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var values = main
        if let connection = connection { values["connectionType"] = connection }
        values["lowPowerMode"] = PulseDeviceFormat.flag(lowPower)
        return values
    }

    private func updatePower() {
        #if os(tvOS)
        let enabled = false
        #else
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        #endif
        lock.lock(); lowPower = enabled; lock.unlock()
    }
    private func startNetwork() {
        #if canImport(Network)
        ready.enter()
        let monitor = NWPathMonitor()
        var first = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let value = PulseDeviceFormat.connection(
                satisfied: path.status == .satisfied, wifi: path.usesInterfaceType(.wifi),
                cellular: path.usesInterfaceType(.cellular), wired: path.usesInterfaceType(.wiredEthernet))
            self.lock.lock(); self.connection = value; self.lock.unlock()
            if first { first = false; self.ready.leave() }
        }
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "dev.mightys.pulse.network", qos: .utility))
        #endif
    }
    private func store(_ values: [String: String]) {
        lock.lock(); main = values; lock.unlock()
    }
    private func setUpMain() {
        refresh()
        installObservers()
        ready.leave()
    }
    private func watch(_ center: NotificationCenter, _ names: [Notification.Name]) {
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    private func installObservers() {
        var names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification, UIApplication.willEnterForegroundNotification,
            UIContentSizeCategory.didChangeNotification,
            UIAccessibility.reduceMotionStatusDidChangeNotification, UIAccessibility.boldTextStatusDidChangeNotification,
            UIAccessibility.invertColorsStatusDidChangeNotification, UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            UIAccessibility.reduceTransparencyStatusDidChangeNotification, UIScreen.didConnectNotification,
            UIScreen.didDisconnectNotification]
        names.append(UIAccessibility.differentiateWithoutColorDidChangeNotification)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        names.append(UIDevice.orientationDidChangeNotification)
        #endif
        watch(NotificationCenter.default, names)
    }
    private func refresh() {
        var v: [String: String] = [:]
        let screen = UIScreen.main
        let bounds = screen.bounds, scale = Double(screen.scale)
        v["screenWidth"] = PulseEnvironment.number(Double(bounds.width))
        v["screenHeight"] = PulseEnvironment.number(Double(bounds.height))
        v["screenScale"] = PulseEnvironment.number(scale)
        v["screenWidthPx"] = PulseEnvironment.number(Double(bounds.width) * scale)
        v["screenHeightPx"] = PulseEnvironment.number(Double(bounds.height) * scale)
        v["screenCount"] = String(UIScreen.screens.count)
        switch screen.traitCollection.userInterfaceStyle {
        case .dark: v["colorScheme"] = "dark"
        case .light: v["colorScheme"] = "light"
        default: break
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        v["orientation"] = PulseDeviceFormat.orientation(width: Double(bounds.width), height: Double(bounds.height))
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: v["deviceType"] = "phone"
        case .pad: v["deviceType"] = "tablet"
        case .tv: v["deviceType"] = "tv"
        case .carPlay: v["deviceType"] = "car"
        case .mac: v["deviceType"] = "desktop"
        default: if UIDevice.current.userInterfaceIdiom.rawValue == 6 { v["deviceType"] = "vision" }
        }
        #endif
        if PulseEnvironment.extensionIdentifier(bundlePath: Bundle.main.bundlePath, info: Bundle.main.infoDictionary) == nil,
           let name = PulseDeviceFormat.categoryName(raw: screen.traitCollection.preferredContentSizeCategory.rawValue) {
            v["contentSizeCategory"] = name
            if let scale = PulseDeviceFormat.fontScale(categoryName: name) { v["fontScale"] = scale }
        }
        v["reduceMotion"] = PulseDeviceFormat.flag(UIAccessibility.isReduceMotionEnabled)
        v["boldText"] = PulseDeviceFormat.flag(UIAccessibility.isBoldTextEnabled)
        v["invertColors"] = PulseDeviceFormat.flag(UIAccessibility.isInvertColorsEnabled)
        v["increaseContrast"] = PulseDeviceFormat.flag(UIAccessibility.isDarkerSystemColorsEnabled)
        v["reduceTransparency"] = PulseDeviceFormat.flag(UIAccessibility.isReduceTransparencyEnabled)
        v["differentiateWithoutColor"] = PulseDeviceFormat.flag(UIAccessibility.shouldDifferentiateWithoutColor)
        store(v)
    }
    #elseif os(macOS)
    private func installObservers() {
        watch(NotificationCenter.default, [NSApplication.didFinishLaunchingNotification, NSApplication.didBecomeActiveNotification,
                                           NSApplication.didChangeScreenParametersNotification])
        watch(NSWorkspace.shared.notificationCenter, [NSWorkspace.accessibilityDisplayOptionsDidChangeNotification])
        watch(DistributedNotificationCenter.default(), [Notification.Name("AppleInterfaceThemeChangedNotification")])
    }
    private func refresh() {
        var v: [String: String] = [:]
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let size = screen.frame.size, scale = Double(screen.backingScaleFactor)
            v["screenWidth"] = PulseEnvironment.number(Double(size.width))
            v["screenHeight"] = PulseEnvironment.number(Double(size.height))
            v["screenScale"] = PulseEnvironment.number(scale)
            v["screenWidthPx"] = PulseEnvironment.number(Double(size.width) * scale)
            v["screenHeightPx"] = PulseEnvironment.number(Double(size.height) * scale)
        }
        if !NSScreen.screens.isEmpty { v["screenCount"] = String(NSScreen.screens.count) }
        if let app = NSApp as NSApplication?,
           let match = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            v["colorScheme"] = match == .darkAqua ? "dark" : "light"
        }
        let workspace = NSWorkspace.shared
        v["reduceMotion"] = PulseDeviceFormat.flag(workspace.accessibilityDisplayShouldReduceMotion)
        v["increaseContrast"] = PulseDeviceFormat.flag(workspace.accessibilityDisplayShouldIncreaseContrast)
        v["reduceTransparency"] = PulseDeviceFormat.flag(workspace.accessibilityDisplayShouldReduceTransparency)
        v["invertColors"] = PulseDeviceFormat.flag(workspace.accessibilityDisplayShouldInvertColors)
        v["differentiateWithoutColor"] = PulseDeviceFormat.flag(workspace.accessibilityDisplayShouldDifferentiateWithoutColor)
        store(v)
    }
    #elseif os(watchOS)
    private func installObservers() {
        watch(NotificationCenter.default, [WKExtension.applicationDidBecomeActiveNotification])
    }
    private func refresh() {
        var v: [String: String] = [:]
        let device = WKInterfaceDevice.current()
        let size = device.screenBounds.size, scale = Double(device.screenScale)
        v["screenWidth"] = PulseEnvironment.number(Double(size.width))
        v["screenHeight"] = PulseEnvironment.number(Double(size.height))
        v["screenScale"] = PulseEnvironment.number(scale)
        v["screenWidthPx"] = PulseEnvironment.number(Double(size.width) * scale)
        v["screenHeightPx"] = PulseEnvironment.number(Double(size.height) * scale)
        v["reduceMotion"] = PulseDeviceFormat.flag(WKAccessibilityIsReduceMotionEnabled())
        store(v)
    }
    #else
    private func installObservers() {}
    private func refresh() {}
    #endif
}
