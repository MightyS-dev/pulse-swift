# MightyS Pulse for Swift

Privacy-first analytics for iOS, macOS, tvOS and watchOS apps and games. No IDFA, no device IDs, offline queue, privacy manifest included.

Docs: https://pulse.mightys.dev/docs/swift/

Send named signals (events) with an optional number and a
few properties from an iOS, iPadOS, macOS, tvOS or watchOS app, and see them in the MightyS Pulse dashboard. The SDK reads no advertising ID and no device identifier, and sets no cookies.

## Install

**Xcode:** File > Add Package Dependencies, paste `https://github.com/MightyS-dev/pulse-swift`, choose "Up to Next Major
Version" from `0.9.5`, then add the `MightySPulse` library to your app target.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/MightyS-dev/pulse-swift", from: "0.9.5")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "MightySPulse", package: "pulse-swift")
    ])
]
```

## Quick start

```swift
import MightySPulse

Pulse.initialize(appKey: "YOUR_APP_KEY") // your app key from the Pulse dashboard
Pulse.track("level.complete")
Pulse.track("purchase", value: 4.99, props: ["sku": "gems_100", "trial": false])

// Optional: use your own user id instead of the anonymous install id.
Pulse.setUser("your-internal-user-id")
Pulse.setUser(nil)                     // back to the anonymous install id

Task { await Pulse.flush() }           // optional: waits until queued signals are delivered
```

Initialize once, early in app startup; a second call is ignored. Up to 100 calls to `track` made before initialization are
kept and sent afterwards. All calls are thread-safe and none throws. Hashing, disk work and sending run on a background
queue.

## What is sent and what is never sent

Sent with every signal: your signal name, optional number and properties, a UTC timestamp, the debug flag, a random session
id, a hashed user id (see below), and the device, screen, settings, app and usage fields listed here. A value the platform
cannot give is left out, never guessed. iPadOS is reported as `iOS`.

| Group | Fields |
|---|---|
| Device | `platform`, `osName`, `osVersion`, `deviceModel` (hardware model identifier such as `iPhone17,1`, a product line and not a device), `deviceType` (phone, tablet, desktop, tv, watch, vision, car), `deviceBrand`, `architecture`, `isSimulator`, `targetEnvironment` (native, simulator, catalyst, ios-on-mac) |
| Screen | `screenWidth`, `screenHeight` (points), `screenScale`, `screenWidthPx`, `screenHeightPx`, `screenCount`, `orientation` (iOS and iPadOS only) |
| Settings and accessibility | `locale`, `language`, `preferredLanguage`, `region`, `layoutDirection`, `timeZone`, `utcOffsetMinutes`, `colorScheme`, `fontScale`, `contentSizeCategory`, `reduceMotion`, `boldText`, `invertColors`, `increaseContrast`, `reduceTransparency`, `differentiateWithoutColor`, `connectionType` (wifi, cellular, ethernet, none, other), `lowPowerMode` |
| App and install | `appVersion`, `appBuildNumber`, `bundleId`, `appName`, `installSource` (appstore, testflight, debug, other), `isDebugBuild`, `extensionId` (only inside an app extension), `sdkName`, `sdkVersion` |
| Usage statistics | `firstSessionDate`, `totalSessionsCount`, `distinctDaysUsed`, `distinctDaysUsedLastMonth`, `previousSessionSeconds`, `averageSessionSeconds`, `sessionSeconds`, `isNewInstall` (first session only) |

Values that can change (orientation, appearance, text size, accessibility settings, network type, low power mode, screen
size) are read on the main thread, cached, and refreshed when the system reports a change, so a signal never waits for
the main thread. Not every field exists on every platform: for example `orientation` is iOS and iPadOS only, and
`contentSizeCategory` is not sent from app extensions.

Usage statistics are kept in one small file next to the install id, in the app's own storage, and deleted by opt-out.

Automatic signals: the SDK sends three signals itself. `pulse.session_started` is sent when a new session begins (app start,
or the first signal after 30 minutes of inactivity). `pulse.new_install` is sent once, on the first launch after install.
`pulse.app_updated` is sent once when the app version or build differs from the previous launch, with the properties
`previousVersion` and `previousBuild`. They are one per session or rarer, they follow opt-out and the debug flag like any
signal, and there is nothing to set up.

Sessions use a random id that changes after 30 minutes of inactivity.

Anonymous install id: random, created by the SDK on first launch, stored only in the app's own storage, deleted with the
app and replaced after opt-out. It is sent only as a SHA-256 hash, it is not derived from any device identifier and it is
not shared between apps. It is what counts your users, so there is nothing to set up.

User id: optional. If you call `setUser`, the id is hashed with SHA-256 on the device and replaces the install id hash.
The raw id is never stored or sent. The hash is pseudonymous and can link one user's signals.

Never sent: IDFA, IDFV, serial numbers, MAC addresses, device names, location, contacts, email,
cookies, the carrier name or the list of installed apps. The SDK does not use the Keychain or UserDefaults.

IP address: the SDK does not read or send the device's IP address as data. As with any HTTP request, the server sees the
connection address, uses it only to derive a two-letter country code and does not store it.

Do not put personal information in signal names, values, properties or the app version.

## Screen views

On iOS, iPadOS, tvOS and Mac Catalyst (UIKit) the SDK sends a `pulse.screen_view` signal each time a screen appears, with
no code in your screens. Props: `screen` (the view controller's class name without the module prefix, at most 128
characters) and `previousScreen` when known. Never a URL, a title, text from the screen or anything the user typed.
Navigation, tab bar, page and split view controllers, SwiftUI hosting wrappers, controllers embedded inside another
screen and system controllers (alerts, keyboards, pickers) are skipped. The same screen appearing again with no other
screen in between is not repeated. It follows opt-out and the debug flag like any signal and counts toward volume.

The capture replaces `viewDidAppear` once, at `Pulse.initialize`, and calls the original first. To switch it off set
`options.automaticScreenViews = false`: nothing is installed at all.

SwiftUI has no reliable automatic hook, so name each screen with one modifier:

```swift
ContentView().pulseScreen("Home")
```

For any other screen, call `Pulse.screen("Name")` yourself. Both calls work whether or not the automatic capture is on.
macOS (AppKit) apps and watchOS apps have no automatic capture: use the manual calls. The SDK does not touch UIKit in
command line tools or on platforms without it.

## Options

```swift
var options = PulseOptions()
options.appVersion = "1.2.3"
options.debug = false
Pulse.initialize(appKey: "YOUR_APP_KEY", options: options)
```

| Option | Default | Behaviour |
| --- | --- | --- |
| `host` | `https://in.mightys.dev` | Base URL (credentials, query and fragment are rejected). HTTPS is recommended. |
| `flushIntervalSeconds` | 20 | Seconds between batches after the first. Clamped to 0.05 through 3600. |
| `maxBatchSize` | 100 | Signals per request. Clamped to 1 through 1000. |
| `maxQueueSize` | 1000 | Signals kept offline. Clamped to 1 through 10000. The oldest are dropped first. |
| `maxQueueAgeDays` | 7 | Days a queued signal is kept. Capped at 29. |
| `gzip` | true | Compresses bodies larger than 1024 bytes. |
| `debug` | true in a Debug build, false in a Release build | Marks signals as test data and prints short diagnostics, never signal contents. See [Test mode](#test-mode). |
| `automaticScreenViews` | true | Sends `pulse.screen_view` automatically on UIKit. See [Screen views](#screen-views). |
| `automaticSignals` | true | `false` stops `pulse.session_started`, `pulse.new_install` and `pulse.app_updated`. See [Settings from the portal](#settings-from-the-portal). |
| `appVersion` | bundle short version | Overrides the app version. |

## Settings from the portal

The dashboard can switch screen views, the automatic signals and groups of fields (device, screen, settings, network, app, usage) on or off for your app, without a package update. The SDK reads these settings once per launch, in the background, and keeps them in its own storage. A change applies from the next launch of the app and stays the same for the whole run.

- Everything is on by default, and stays on whenever the settings cannot be read (offline, an error, nothing saved yet).
- The dashboard decides. In code you can only switch things off: `automaticScreenViews = false` stops the automatic screen hook (manual `Pulse.screen` still sends), `automaticSignals = false` stops the session, new install and app updated signals. Setting either to `true` never overrides a switch made in the dashboard.
- Fields that are switched off are left out of every signal. The base fields (platform, OS, app version, build, device model, locale, SDK and bundle identifier) are always sent.
- The request carries only your app key. It never delays `track` or `flush`, and opt-out deletes the saved settings with everything else.

## Test mode

Every signal carries a `debug` flag. `debug = true` means test data, and the dashboard's test mode switch chooses whether you see test signals or real ones. You need only one app key per app: the same key serves both.

Unless you set it, `PulseOptions.debug` is `true` when your app is built in the Debug configuration (a run from Xcode) and `false` in a Release build, which includes Archive, TestFlight and the App Store. SwiftPM compiles the package with your app's configuration, and the value is fixed for a given build. If you build an app with a custom configuration, check which one it follows. An explicit `options.debug` always wins, in both directions:

```swift
options.debug = true // force test data
```

## Delivery and offline behaviour

- The first batch after `initialize` is sent at once. Later batches follow the interval, the batch size, an explicit
  `flush()`, or the app moving to the background or terminating.
- Signals are saved to a checksummed file in Application Support (excluded from backups) and survive restarts. Only one
  process should use that directory; app extensions and shared app-group writers are not supported.
- Network errors and server errors (408, 425, 429, 5xx) are retried with exponential backoff from 1 second to 5 minutes.
  `Retry-After` is honoured up to one hour. When the server asks for a pause or a different interval, the SDK follows it.
  A 401 keeps the queue and stops sending until the app restarts.
- Each batch carries an id, so a batch sent again after a lost answer is stored only once.
- Delivery is at least once: after a crash a batch can be sent again. If the OS ends the app abruptly, the last signals
  may be lost. On watchOS, call `flush()` from your own lifecycle code when it matters.
- `flush()` returns once the signals captured so far have left the queue. It respects retry and pause deadlines, can wait
  indefinitely while offline, and ends when its task is cancelled, on opt-out or on a 401. Await it; do not block the main
  thread on it.

## Requirements

| Platform | Minimum |
| --- | --- |
| iOS and iPadOS | 15 |
| macOS | 12 |
| tvOS | 15 |
| watchOS | 8 |
| Swift tools | 5.7 (Xcode 14 or newer) |

No third-party dependencies. The package uses Foundation, URLSession and CryptoKit (with its own SHA-256 fallback), plus a
small C bridge to the system zlib.

## Opt-out

`Pulse.optOut = true` stops collection, clears the queue, and is remembered across launches. Requests
already sent cannot be recalled. `Pulse.optOut = false` resumes collection. The value is readable at any time, also before
`initialize`. If the stored choice cannot be read, the SDK counts as opted out.

## Licence

MIT. See `LICENSE.md`. Changes are listed in `CHANGELOG.md`.

## Reference

**Signal rules.** The value must be finite. The name needs non-whitespace content and at most 200 UTF-16 code units. Props
accept strings, booleans (sent as `"true"` or `"false"`) and finite numbers; arrays, objects and non-finite numbers are
dropped. At most 32 props are kept (keys sorted first), with keys up to 128 and string values up to 1024 UTF-16 units,
within 8192 bytes serialized. Invalid signals are ignored.

**Privacy manifest.** The package ships `PrivacyInfo.xcprivacy`: tracking is false, there are no tracking domains and no
required-reason API use, and the collected data types are Product Interaction, User ID and Other Data Types (linked, for the
analytics purpose) and Device ID (not linked to the user's identity, for the analytics purpose), none used for tracking.
These entries cover the user hash, the anonymous install id hash and the metadata above;
review your app's own privacy report and App Store Connect answers, which depend on the whole app. See
[App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).
