#if !(canImport(UIKit) && !os(watchOS) && !os(tvOS)) && !os(macOS)
/// tvOS and watchOS capture no taps and no pictures.
internal enum PulseHeatmapHook {
    static func install(runtime: PulseRuntime) {}
    static func scheduleShot(_ screen: String, runtime: PulseRuntime) {}
}
#endif
