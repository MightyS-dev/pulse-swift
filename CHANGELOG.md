# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.5] - 2026-11-16

- A batch that is sent again after a lost answer is stored only once.

## [0.9.4] - 2026-11-16

- Settings from the portal: once per launch the SDK reads the app's settings in the background and applies them from the next launch. The dashboard can switch screen views, the automatic signals, single signal types and groups of fields on or off. Everything stays on when the settings cannot be read.
- New option `automaticSignals` (default `true`). In code these options can only switch things off; they never override a switch made in the dashboard.
- Screen views are captured automatically on UIKit: the SDK sends `pulse.screen_view` with `screen` (the view
  controller's class name) and `previousScreen` when known. Navigation, tab bar, page and split containers, SwiftUI
  hosting wrappers and system controllers are skipped, and the same screen appearing again is not repeated.
- New `.pulseScreen("Name")` view modifier for SwiftUI and `Pulse.screen("Name")` for screens the SDK cannot see.
- New option `automaticScreenViews` (default `true`). Set it to `false` to install no automatic capture at all.
- macOS (AppKit) apps send screen views only through the manual calls.
- Screen views are captured exactly like other signals: in call order, with the time of the call, in the same batches.
- Signals captured in the same millisecond keep their order: timestamps are strictly increasing.

## [0.9.3] - 2026-11-15

- Every signal now carries the device, screen, settings, app and usage fields the platform can give, with nothing to
  set up: device type, brand, architecture, screen size and scale, orientation, appearance, language and region, time
  zone, text size and accessibility settings, network type, low power mode, install source, app name and bundle
  identifier, and session statistics (first session date, number of sessions, days of use, session lengths).
- The SDK sends three automatic signals: `pulse.session_started`, `pulse.new_install` and `pulse.app_updated`.
- Values that can change are cached and refreshed when the system reports a change, so signals never wait for the main
  thread. Session statistics live in one small file in the app's own storage and are deleted by opt-out.
- The bundle identifier is now sent by default.

## [0.9.2] - 2026-11-15

- Users are counted without any setup: the SDK sends a random anonymous install id (hashed) until you call `setUser`.
  The id is created on first launch, stored only in the app's own storage, deleted with the app and replaced after opt-out.
- `setUser` stays optional and replaces the install id hash; `setUser(nil)` returns to it.
- The bundled privacy manifest now lists Device ID (not linked to the user's identity, not used for tracking, analytics).
- The app version falls back to the build number (`CFBundleVersion`) when the bundle has no marketing version.

## [0.9.1] - 2026-11-15

- README: a Test mode section that explains how signals are marked as test or real.

## [0.9.0] - 2026-11-15

Initial public release.

- `Pulse.initialize(appKey:options:)`, `Pulse.track(_:value:props:)`, `Pulse.setUser(_:)`, `Pulse.flush()` and
  `Pulse.optOut`.
- `PulseOptions` for host, flush interval, batch size, queue size, queue age, gzip, debug flag and app version.
- No advertising ID, no device identifier, no cookies. Random sessions that rotate after 30 minutes of inactivity.
  The optional user id is hashed with SHA-256 on the device.
- Batched, gzipped delivery with an offline queue on disk, retries and backoff.
- One-call opt-out that is remembered across launches.
- Bundled privacy manifest (`PrivacyInfo.xcprivacy`).
- iOS 15, macOS 12, tvOS 15 and watchOS 8, Swift tools 5.7 or newer, no third-party dependencies.
