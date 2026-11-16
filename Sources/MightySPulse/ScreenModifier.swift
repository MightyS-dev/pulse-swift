#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Marks this view as a screen. Sends one `pulse.screen_view` signal with `name` each time the view appears.
    ///
    /// ```swift
    /// ContentView().pulseScreen("Home")
    /// ```
    ///
    /// SwiftUI gives no reliable automatic hook, so name each screen once. Works whether or not
    /// ``PulseOptions/automaticScreenViews`` is on. Use a fixed name, never user text or a URL.
    func pulseScreen(_ name: String) -> some View {
        onAppear { Pulse.screen(name) }
    }
}
#endif
