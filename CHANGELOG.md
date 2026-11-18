# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.8] - 2026-11-18

- Session length: the SDK reports when the app goes to the background, so sessions show their real length. `pulse.app_backgrounded` is on by default and does not count toward your plan.
- Screens from private or nested view controllers are now recorded under their own class name (they were skipped before).
- tvOS builds again: the update and maintenance screens are left out on tvOS.

## [0.9.7] - 2026-11-16

- The built-in update and maintenance screens are not counted as app screens or taps.
- Crashes are recorded with no setup: an uncaught Objective-C exception or a fatal signal (SIGABRT, SIGSEGV, SIGBUS,
  SIGILL, SIGFPE, SIGTRAP) writes a small file, and the next launch sends it as one `pulse.error` signal of kind `crash`
  with the crash's own time. The crash is then passed on, so the system crash report and any other handler still see it.
- New `Pulse.trackError(_:props:)` for errors you catch: sends the error type, its message and the call stack at the call
  as a `pulse.error` signal of kind `handled`.
- Messages and frames are filtered on the device: emails, URL query strings and fragments, UUIDs, IP addresses, runs of
  six or more digits and directories of absolute paths are removed.
- New options `captureErrors` (default `true`; `false` installs no handler) and `errorDetail` (`.full` or `.typeOnly`).
- At most 10 error signals of one type are sent per session. Opt-out stops recording and deletes a crash that was not
  sent yet.
- A crash right after start is now kept and sent on the next launch.
- Automatic events: `pulse.app_opened` and `pulse.app_backgrounded` (off until the dashboard lists them in `enabledSignals`),
  `pulse.deep_link` (new `Pulse.deepLink(_:)`), `pulse.permission_changed`, `previousScreenSeconds` on screen views, and
  the system keys `launchMs`, `foregroundsToday`, `previousForegroundSeconds`, `notificationPermission` and
  `trackingPermission` (status read only, never requested, never the advertising identifier).
- Quota guards: per session 20 opened, 20 backgrounded, 10 deep links, 5 permission changes, 100 screen views; 300 automatic
  signals per day. Dropped ones are counted and sent once as `droppedAutomatic`. The dashboard can pause types
  (`pausedSignals`).
- Why the app ended: on iOS 14+ and macOS 12+ MetricKit hang, crash, CPU and disk write diagnostics are sent as `pulse.error`
  of kind `exit` (at most 10 per launch, none older than 7 days, never twice).
- Heatmaps of taps and clicks (`pulse.heatmap`), off until the portal switches them on. A passive gesture recognizer on the
  key windows on iOS and a local mouse-up monitor on macOS (no swizzling, never consumes or delays an event; tvOS and
  watchOS capture nothing). Only the screen name, position, kind, width bucket and orientation are sent, at most 200 points
  per signal and 1000 per session; never while the keyboard is visible, on text inputs and secure fields, in the keyboard
  window, or on views marked with `Pulse.heatmapIgnore(_:)` or `.pulseHeatmapIgnore()`. New option `captureHeatmaps`
  (default `true`, can only switch off).
- App Control: update, block and maintenance rules set in the dashboard. After `Pulse.initialize` the SDK reads them in the
  background (never blocking, 3 s and 5 s limits, no retry loop, no identity sent, also when analytics is off) and shows its
  own screens in a window above the app: full screen for a required update, a blocked version and maintenance, an alert for a
  suggested update, a card for announcements and what's new, a strip for upcoming maintenance. New option
  `PulseOptions.control` (`.automatic` default, `.manual`, `.off`) and `Pulse.control` with `state`, `notices`, `onChange`,
  `checkNow()`, `openStore()` and `dismiss()`. Fails open: the last known state stays on any error, locking rules older than
  30 days in the cache are ignored, and a required update becomes a suggestion when there is no way to update. 12 languages,
  Dynamic Type, VoiceOver, light and dark. Never closes the app. No new dependency or asset.
- Debug screenshot for the portal picture: only with the new option `heatmapScreenshots = true` on an install source that is
  not the App Store or TestFlight; one picture per screen, size class, orientation and app version, at most 20 an hour.

## [0.9.6] - 2026-11-16

- A signal that is dropped because its name or value is not valid no longer starts a session or keeps one alive.

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
