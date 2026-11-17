import Foundation

/// What the platform gives the runtime: attach the tap hook, and take a debug picture of a screen.
internal struct PulseHeatmapHooks {
    let install: () -> Void
    let shot: (String) -> Void
}

internal enum PulseHeatmapPlatform {
    /// A desktop window has no phone or tablet class, so macOS always reports the desktop bucket.
    static let fixedBucket: String? = {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return "desktop"
        #else
        return nil
        #endif
    }()
}

/// The heatmap side of the runtime: settings, screen tracking, taps and the debug screenshot. All of it runs on the
/// state queue; the platform hook only reads the gate and calls the three entry points at the end.
internal extension PulseRuntime {
    /// Capture is allowed right now: started, not opted out, and the newest settings and code options say yes.
    func heatmapAllowed() -> Bool {
        appKey != nil && !optOut && !stopped && liveConfig.sends(PulseHeatmapMath.signalType)
    }
    /// A debug picture is wanted: the app asked for it, the build is not from the App Store or TestFlight, heatmaps are on.
    func heatmapScreenshotsAllowed() -> Bool {
        options.heatmapScreenshots && PulseHeatmapMath.screenshotSourceAllowed(system["installSource"]) && heatmapAllowed()
    }
    /// Applies the newest settings: off stops capture and drops the buffer at once; on attaches the platform hook.
    func refreshHeatmap(at date: Date) {
        let allowed = heatmapAllowed()
        if !allowed { heatmap.drop() }
        else if !heatmapHooked { heatmapHooked = true; heatmapInstaller?() }
        syncHeatmapScreen(allowed: allowed, at: date)
    }
    private func syncHeatmapScreen(allowed: Bool, at date: Date) {
        let visible = allowed && effective.sends(PulseRemoteConfig.screenViewType) ? lastScreen : nil
        heatmap.setScreen(visible, at: date)
        heatmapGate.set(active: allowed && heatmap.screen != nil, screen: heatmap.screen)
    }
    /// The screen changed: the points of the old screen go out first, then the new screen is the one taps belong to.
    func screenChangedForHeatmap(_ name: String, at date: Date) {
        let allowed = heatmapAllowed()
        if allowed, !heatmapHooked { heatmapHooked = true; heatmapInstaller?() }
        syncHeatmapScreen(allowed: allowed, at: date)
        if heatmapScreenshotsAllowed(), heatmap.screen == name { heatmapShotHook?(name) }
    }
    /// Sends one buffer as a `pulse.heatmap` signal. It is outside the automatic caps and never carries `droppedAutomatic`.
    func emitHeatmap(_ object: [String: Any], at date: Date) {
        guard heatmapAllowed() else { return }
        captureOnQueue(PulseHeatmapMath.signalType, value: nil, props: [:], screen: nil, at: date, error: nil, heatmapObject: object)
        heatmap.adoptSession(session)
    }

    /// One tap or click at `x`, `y` points from the top left of a window `width` by `height` points. The flags are the
    /// privacy rules the platform can see; a tap with any of them set is dropped here and never leaves the main thread.
    func heatmapTap(x: Double, y: Double, width: Double, height: Double,
                    keyboardVisible: Bool, inputTarget: Bool, ignored: Bool) {
        guard !keyboardVisible, !inputTarget, !ignored, heatmapGate.active else { return }
        let at = clock.now
        state.async { [self] in
            guard heatmapAllowed() else { heatmap.drop(); return }
            let session = at.timeIntervalSince(lastActivity) >= 1800 ? PulseHeatmapCapture.pendingSession : self.session
            heatmap.tap(x: x, y: y, width: width, height: height,
                        bucket: heatmapFixedBucket ?? PulseHeatmapMath.bucket(width: width), at: at, session: session)
        }
    }

    /// Whether a picture of the current screen is wanted now. The completion runs on the state queue.
    func heatmapShotTicket(screen: String, width: Double, height: Double, completion: @escaping (PulseHeatmapShotTicket?) -> Void) {
        state.async { [self] in
            guard heatmapScreenshotsAllowed(), heatmap.screen == screen else { completion(nil); return }
            completion(shots.ticket(screen: screen, width: width, height: height, appVersion: system["appVersion"] ?? "",
                                    fixedBucket: heatmapFixedBucket))
        }
    }
    /// Uploads one encoded picture through the normal transport. Failures are silent.
    func heatmapUpload(_ ticket: PulseHeatmapShotTicket, bytes: Data, contentType: String, completion: @escaping (Bool) -> Void = { _ in }) {
        state.async { [self] in
            guard heatmapScreenshotsAllowed(), let signals = endpoint, let key = appKey else { completion(false); return }
            let address = signals.deletingLastPathComponent().appendingPathComponent("heatmap").appendingPathComponent("screenshot")
            shots.upload(ticket, bytes: bytes, contentType: contentType, appVersion: system["appVersion"] ?? "", endpoint: address,
                         appKey: key, send: { request, done in
                _ = transport.send(request) { [weak self] response in
                    guard let self = self else { return }
                    self.state.async { done(response) }
                }
            }, completion: completion)
        }
    }
}
