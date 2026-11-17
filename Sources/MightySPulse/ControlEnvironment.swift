import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What the screens call back into when the user presses a button.
internal struct ControlActions {
    var update: () -> Void
    var dismiss: () -> Void
    var tryAgain: () -> Void
}

/// Draws the built-in screens. Every method runs on the main thread. A presenter holds no state the engine depends on:
/// the engine can always call `show` again with the same screen, or `hide`.
internal protocol ControlPresenter: AnyObject {
    func show(_ screen: ControlScreen, actions: ControlActions)
    func hide()
}

/// The facts App Control reads from the app and the system, in one place so tests can replace them.
internal final class ControlEnvironment {
    /// The platform key of the rules (`ios`, `macos`), or nil on a platform with no App Control (tvOS, watchOS).
    let platform: String?
    let appName: String
    let preferredLanguages: () -> [String]
    let isExtension: Bool
    let locale: Locale
    let timeZone: TimeZone
    /// Whether the SDK can build a store link itself. It cannot on Apple platforms: a link needs the numeric store id.
    let canBuildStoreLink: Bool
    let openURL: (URL) -> Void
    /// Where state callbacks and presenter calls run.
    let callbackQueue: DispatchQueue
    /// Whether lifecycle notifications are observed.
    let observesLifecycle: Bool

    @_optimize(size) init(platform: String?, appName: String, preferredLanguages: @escaping () -> [String], isExtension: Bool, locale: Locale,
         timeZone: TimeZone, canBuildStoreLink: Bool, openURL: @escaping (URL) -> Void, callbackQueue: DispatchQueue,
         observesLifecycle: Bool) {
        self.platform = platform; self.appName = appName; self.preferredLanguages = preferredLanguages
        self.isExtension = isExtension; self.locale = locale; self.timeZone = timeZone
        self.canBuildStoreLink = canBuildStoreLink; self.openURL = openURL; self.callbackQueue = callbackQueue
        self.observesLifecycle = observesLifecycle
    }

    @inline(never) @_optimize(size) static var system: ControlEnvironment {
        let info = Bundle.main.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "this app"
        let platform: String?
        #if os(iOS)
        #if targetEnvironment(macCatalyst)
        platform = "macos"
        #else
        platform = "ios"
        #endif
        #elseif os(macOS)
        platform = "macos"
        #else
        platform = nil
        #endif
        return ControlEnvironment(
            platform: platform, appName: name,
            preferredLanguages: {
                // An app that ships several languages has chosen one for itself; an app that ships only its development
                // language gets the system's languages, so the built-in translations are used.
                let shipped = Bundle.main.localizations.filter { $0 != "Base" }
                return (shipped.count > 1 ? Bundle.main.preferredLocalizations : []) + Locale.preferredLanguages
            },
            isExtension: PulseEnvironment.extensionIdentifier(bundlePath: Bundle.main.bundlePath, info: info) != nil,
            locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent, canBuildStoreLink: false,
            openURL: { ControlSystem.open($0) }, callbackQueue: .main, observesLifecycle: true)
    }

    /// The presenter for this platform, or nil when there is none (a platform without screens, an app extension).
    @_optimize(size) static func systemPresenter() -> ControlPresenter? {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        return ControlUIKitPresenter()
        #elseif os(macOS)
        return ControlAppKitPresenter()
        #else
        return nil
        #endif
    }
}

internal enum ControlSystem {
    /// Opens a link. Never touches `UIApplication.shared` directly, so the file also builds for app extensions.
    @_optimize(size) static func open(_ url: URL) {
        DispatchQueue.main.async {
            #if canImport(UIKit) && !os(watchOS)
            let application = (UIApplication.self as AnyObject).perform(NSSelectorFromString("sharedApplication"))?
                .takeUnretainedValue() as? UIApplication
            application?.open(url, options: [:], completionHandler: nil)
            #elseif os(macOS)
            NSWorkspace.shared.open(url)
            #endif
        }
    }
    /// The notifications that mean the app came to the foreground.
    @_optimize(size) static var foregroundNotifications: [Notification.Name] {
        #if canImport(UIKit) && !os(watchOS)
        return [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification]
        #elseif os(macOS)
        return [NSApplication.didBecomeActiveNotification]
        #else
        return []
        #endif
    }
}
