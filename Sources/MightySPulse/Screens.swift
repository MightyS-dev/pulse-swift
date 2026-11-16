import Foundation

internal enum PulseScreenNames {
    static let maxLength = 128
    /// Trims, removes control characters and cuts to 128 characters. Empty text gives nil.
    static func clean(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxLength)))
    }
    /// A class name without its module prefix and without generic arguments: "MyApp.Home" and
    /// "MyApp.Feed<MyApp.Item>" give "Home" and "Feed".
    static func className(_ raw: String) -> String {
        let head = raw.split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        return head.split(separator: ".").last.map(String.init) ?? head
    }
    /// System and hosting classes that are never a screen of the app.
    static func isSystemOrHosting(_ raw: String) -> Bool {
        if raw.hasPrefix("SwiftUI.") || raw.hasPrefix("_TtGC7SwiftUI") || raw.hasPrefix("_TtC7SwiftUI") { return true }
        let name = className(raw)
        if name.hasPrefix("_") || name == "UIHostingController" { return true }
        let systemPrefixes = ["UIAlert", "UIInput", "UIEditing", "UISystem", "UICompatibility", "UIPrediction", "UIRemote",
                              "UIKeyboard", "UIDictation", "UIActivity", "UIDocumentBrowser", "UIMenu", "UIContext",
                              "UIPopover", "UIColorPicker", "UIFontPicker", "UIImagePicker", "UITextInput", "UIReferenceLibrary",
                              "SFSafari", "SFAuthentication", "PHPicker", "CNContact", "MFMail", "MFMessage"]
        return systemPrefixes.contains { name.hasPrefix($0) }
    }
    /// The name to send for a view controller, or nil when it must be skipped.
    static func screenName(rawClassName: String, isContainer: Bool, isEmbeddedChild: Bool) -> String? {
        guard !isContainer, !isEmbeddedChild, !isSystemOrHosting(rawClassName) else { return nil }
        return clean(className(rawClassName))
    }
}

/// Installs automatic capture once, and only when the option is on.
internal final class PulseScreenInstaller {
    private let lock = NSLock()
    private var installed = false
    private let install: () -> Void
    init(install: @escaping () -> Void) { self.install = install }
    func activate(enabled: Bool) {
        guard enabled else { return }
        lock.lock()
        let first = !installed
        installed = true
        lock.unlock()
        if first { install() }
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit
import ObjectiveC

internal enum PulseScreenHook {
    private static let lock = NSLock()
    private static var sink: ((String) -> Void)?
    private static var swizzled = false

    /// Swaps in a `viewDidAppear` that calls the original first and then records the screen name.
    static func install(sink newSink: @escaping (String) -> Void) {
        lock.lock()
        sink = newSink
        let already = swizzled
        swizzled = true
        lock.unlock()
        guard !already else { return }
        let selector = #selector(UIViewController.viewDidAppear(_:))
        guard let method = class_getInstanceMethod(UIViewController.self, selector) else { return }
        typealias Original = @convention(c) (UIViewController, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (UIViewController, Bool) -> Void = { controller, animated in
            original(controller, selector, animated)
            PulseScreenHook.appeared(controller)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
    static func appeared(_ controller: UIViewController) {
        let isContainer = controller is UINavigationController || controller is UITabBarController
            || controller is UIPageViewController || controller is UISplitViewController
        var embedded = false
        if let parent = controller.parent {
            embedded = !(parent is UINavigationController || parent is UITabBarController
                || parent is UIPageViewController || parent is UISplitViewController)
        }
        guard let name = PulseScreenNames.screenName(rawClassName: NSStringFromClass(type(of: controller)),
                                                     isContainer: isContainer, isEmbeddedChild: embedded) else { return }
        lock.lock(); let target = sink; lock.unlock()
        target?(name)
    }
}
#else
internal enum PulseScreenHook {
    /// No automatic capture on this platform: use `Pulse.screen(_:)` or the SwiftUI modifier.
    static func install(sink: @escaping (String) -> Void) {}
}
#endif
