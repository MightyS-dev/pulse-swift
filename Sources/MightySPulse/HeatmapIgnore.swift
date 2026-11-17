import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
import ObjectiveC

internal enum PulseHeatmapIgnoreFlag {
    private static var key: UInt8 = 0
    static func mark(_ view: UIView) { objc_setAssociatedObject(view, &key, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    static func isMarked(_ view: UIView) -> Bool { (objc_getAssociatedObject(view, &key) as? Bool) == true }
}

/// The invisible view behind `.pulseHeatmapIgnore()`: taps inside its frame are never captured.
internal final class PulseHeatmapIgnoreMarker: UIView {
    private static let registry = NSHashTable<PulseHeatmapIgnoreMarker>.weakObjects()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; backgroundColor = .clear; isAccessibilityElement = false
        PulseHeatmapIgnoreMarker.registry.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    /// Whether `point` (in `window` coordinates) is inside a live marker of that window. Main thread only.
    static func covers(_ point: CGPoint, in window: UIWindow) -> Bool {
        for marker in registry.allObjects where marker.window === window && !marker.isHidden {
            if marker.convert(marker.bounds, to: window).contains(point) { return true }
        }
        return false
    }
}

public extension Pulse {
    /// Keeps a view, and everything inside it, out of the tap heatmap. Taps on it are never captured.
    ///
    /// ```swift
    /// Pulse.heatmapIgnore(paymentView)
    /// ```
    ///
    /// Text fields, text views and secure fields are skipped without this. Call it on the main thread.
    static func heatmapIgnore(_ view: UIView) { PulseHeatmapIgnoreFlag.mark(view) }
}
#elseif os(macOS)
import AppKit
import ObjectiveC

internal enum PulseHeatmapIgnoreFlag {
    private static var key: UInt8 = 0
    static func mark(_ view: NSView) { objc_setAssociatedObject(view, &key, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    static func isMarked(_ view: NSView) -> Bool { (objc_getAssociatedObject(view, &key) as? Bool) == true }
}

/// The invisible view behind `.pulseHeatmapIgnore()`: clicks inside its frame are never captured.
internal final class PulseHeatmapIgnoreMarker: NSView {
    private static let registry = NSHashTable<PulseHeatmapIgnoreMarker>.weakObjects()
    override init(frame: NSRect) { super.init(frame: frame); PulseHeatmapIgnoreMarker.registry.add(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// Whether `point` (in window coordinates) is inside a live marker of that window. Main thread only.
    static func covers(_ point: NSPoint, in window: NSWindow) -> Bool {
        for marker in registry.allObjects where marker.window === window && !marker.isHidden {
            if marker.convert(marker.bounds, to: nil).contains(point) { return true }
        }
        return false
    }
}

public extension Pulse {
    /// Keeps a view, and everything inside it, out of the click heatmap. Clicks on it are never captured.
    ///
    /// Text views, editable text fields and secure fields are skipped without this. Call it on the main thread.
    static func heatmapIgnore(_ view: NSView) { PulseHeatmapIgnoreFlag.mark(view) }
}
#endif

#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit) && !os(watchOS)
internal struct PulseHeatmapIgnoreBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { PulseHeatmapIgnoreMarker() }
    func updateUIView(_ view: UIView, context: Context) {}
}
#elseif os(macOS)
internal struct PulseHeatmapIgnoreBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PulseHeatmapIgnoreMarker() }
    func updateNSView(_ view: NSView, context: Context) {}
}
#endif

public extension View {
    /// Keeps this view out of the tap heatmap: taps inside its frame are never captured.
    ///
    /// ```swift
    /// PaymentForm().pulseHeatmapIgnore()
    /// ```
    ///
    /// Text fields and secure fields are skipped without this. Does nothing where heatmaps are not captured (tvOS, watchOS).
    @ViewBuilder func pulseHeatmapIgnore() -> some View {
        #if (canImport(UIKit) && !os(watchOS) && !os(tvOS)) || os(macOS)
        background(PulseHeatmapIgnoreBackground())
        #else
        self
        #endif
    }
}
#endif
