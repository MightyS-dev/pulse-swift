# MightyS Pulse for Swift

Privacy-first analytics for iOS, macOS, tvOS and watchOS apps and games. No IDFA, no device IDs, offline queue, privacy manifest included.

Docs: https://pulse.mightys.dev/docs/swift/

Send named signals (events) with an optional number and a
few properties from an iOS, iPadOS, macOS, tvOS or watchOS app, and see them in the MightyS Pulse dashboard. The SDK reads no advertising ID and no device identifier, and sets no cookies.

## Install

**Xcode:** File > Add Package Dependencies, paste `https://github.com/MightyS-dev/pulse-swift`, choose "Up to Next Major
Version" from `0.9.2`, then add the `MightySPulse` library to your app target.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/MightyS-dev/pulse-swift", from: "0.9.2")
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
id, platform, numeric OS version, app version and build, hardware model identifier (for example `iPhone17,1`, which names a
product line and not a device), locale, and the SDK name and version. iPadOS is reported as `iOS`.

Sessions use a random id that changes after 30 minutes of inactivity.

Anonymous install id: random, created by the SDK on first launch, stored only in the app's own storage, deleted with the
app and replaced after opt-out. It is sent only as a SHA-256 hash, it is not derived from any device identifier and it is
not shared between apps. It is what counts your users, so there is nothing to set up.

User id: optional. If you call `setUser`, the id is hashed with SHA-256 on the device and replaces the install id hash.
The raw id is never stored or sent. The hash is pseudonymous and can link one user's signals.

Never sent: IDFA, IDFV, serial numbers, MAC addresses, device names, location, contacts, email,
cookies, or the app's bundle identifier. The SDK does not use the Keychain or UserDefaults.

IP address: the SDK does not read or send the device's IP address as data. As with any HTTP request, the server sees the
connection address, uses it only to derive a two-letter country code and does not store it.

Do not put personal information in signal names, values, properties or the app version.

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
| `appVersion` | bundle short version | Overrides the app version. |

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
