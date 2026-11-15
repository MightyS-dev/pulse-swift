# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
