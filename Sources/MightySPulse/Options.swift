import Foundation
import CoreFoundation

internal enum PulseInfo {
    static let sdkName = "pulse-swift"
    static let version = "0.9.7"
}

/// Settings passed to ``Pulse/initialize(appKey:options:)``.
///
/// Create a value, change what you need and pass it in. Out-of-range numbers are clamped.
///
/// ```swift
/// var options = PulseOptions()
/// options.appVersion = "1.2.3"
/// Pulse.initialize(appKey: "YOUR_APP_KEY", options: options)
/// ```
public struct PulseOptions {
    /// Base URL of the ingest host. Use HTTPS. The default is the Pulse ingest host.
    public var host = "https://in.mightys.dev"
    /// Seconds between batches after the first one. Default 20; clamped to 0.05 through 3600.
    public var flushIntervalSeconds: TimeInterval = 20
    /// Signals per batch. Default 100; clamped to 1 through 1000.
    public var maxBatchSize = 100
    /// Most signals kept in the queue; the oldest are dropped first. Default 1000; clamped to 1 through 10000.
    public var maxQueueSize = 1000
    /// Days a queued signal is kept before it expires. Default 7; capped at 29.
    public var maxQueueAgeDays: Double = 7
    /// Compresses request bodies larger than 1024 bytes. Default `true`.
    public var gzip = true
    /// Marks signals as test data and enables fixed diagnostic messages. Defaults to `true` in debug builds and `false` in release builds.
    public var debug: Bool = _isDebugAssertConfiguration()
    /// Sends a `pulse.screen_view` signal whenever a UIKit screen appears, with no code in your screens. Default `true`.
    ///
    /// The screen name is the view controller's class name. Containers (navigation, tab bar, page and split view
    /// controllers), SwiftUI hosting wrappers and system controllers are skipped. Set it to `false` to install no
    /// automatic capture at all (the dashboard can also switch it off, and `true` never overrides it); ``Pulse/screen(_:)`` and the SwiftUI `pulseScreen(_:)` modifier still work.
    /// On macOS (AppKit) nothing is captured automatically; use the manual calls.
    public var automaticScreenViews = true
    /// Sends the automatic signals `pulse.session_started`, `pulse.new_install`, `pulse.app_updated` and
    /// `pulse.screen_view`. Default `true`.
    ///
    /// The dashboard's setting decides (everything is on when it cannot be read). `false` here switches the
    /// session, new install and app updated signals off whatever the dashboard says; `true` never overrides the dashboard.
    public var automaticSignals = true
    /// Overrides the app version taken from the bundle. Default `nil`.
    public var appVersion: String?
    /// Records crashes (uncaught Objective-C exceptions and fatal signals) and sends each one as a `pulse.error`
    /// signal on the next launch. Default `true`. Set it to `false` to install no handler at all;
    /// ``Pulse/trackError(_:props:)`` still works.
    public var captureErrors = true
    /// How much of an error is sent. Default ``PulseErrorDetail/full``.
    public var errorDetail = PulseErrorDetail.full
    /// Follows the dashboard for heatmaps of taps and clicks (`pulse.heatmap`). Default `true`.
    ///
    /// Heatmaps are off until the owner switches them on in the dashboard. `false` here turns them off for good;
    /// `true` never forces them on over the dashboard. They also stop when automatic signals are off. On tvOS and
    /// watchOS nothing is captured. See ``Pulse/heatmapIgnore(_:)`` to keep a view out.
    public var captureHeatmaps = true
    /// Lets debug builds upload one screenshot per screen for the heatmap picture. Default `false`.
    ///
    /// A binary package cannot see your app's debug flag, so this is your explicit yes. Even then nothing is sent from a
    /// build installed from the App Store or TestFlight, and nothing is sent unless heatmaps are on. Never set it from
    /// code that ships to users.
    public var heatmapScreenshots = false
    /// What App Control does: ``PulseControlMode/automatic`` (the default) checks the update, block and maintenance rules set
    /// in the dashboard and shows the built-in screens, ``PulseControlMode/manual`` only keeps ``Pulse/control`` current, and
    /// ``PulseControlMode/off`` sends no request at all.
    ///
    /// The check never blocks ``Pulse/initialize(appKey:options:)``, sends no user or device identity and works also when
    /// ``Pulse/optOut`` is on. If the rules cannot be read, the app keeps running as before.
    public var control = PulseControlMode.automatic
    /// Creates options with the default values.
    public init() {}

    internal func normalized() -> PulseOptions {
        var copy = self
        copy.flushIntervalSeconds = flushIntervalSeconds.isFinite && flushIntervalSeconds > 0 ? max(0.05, min(3600, flushIntervalSeconds)) : 20
        copy.maxBatchSize = max(1, min(1000, maxBatchSize))
        copy.maxQueueSize = max(1, min(10000, maxQueueSize))
        copy.maxQueueAgeDays = maxQueueAgeDays.isFinite && maxQueueAgeDays > 0 ? min(29, maxQueueAgeDays) : 7
        return copy
    }
}

/// How much of an error ``Pulse`` sends with a `pulse.error` signal.
public enum PulseErrorDetail {
    /// The error type, the filtered message and the stack frames.
    case full
    /// Only the error type: no message and no frames.
    case typeOnly
}

internal protocol PulseCancellation: AnyObject { func cancel() }
internal protocol PulseClock: AnyObject {
    var now: Date { get }
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> PulseCancellation
}
internal struct PulseRequest {
    let url: URL
    let appKey: String
    let body: Data
    let gzip: Bool
    var method = "POST"
    var ifNoneMatch: String?
    var timeout: TimeInterval?
    /// App Control: no app key and no other identity header, only Accept, User-Agent and If-None-Match.
    var anonymous = false
    var batchId: String?
    /// Content-Type of the body. Nil means application/json (batches). Set for the heatmap screenshot upload.
    var contentType: String?
}
internal struct PulseResponse {
    var status: Int
    var body = Data()
    var retryAfter: String?
}
internal protocol PulseTransport: AnyObject {
    func send(_ request: PulseRequest, completion: @escaping (PulseResponse) -> Void) -> PulseCancellation
}
internal protocol PulseStorage: AnyObject {
    // Missing file is nil. Unreadable storage MUST throw, including privacy preference reads.
    func read(_ name: String) throws -> Data?
    func replace(_ name: String, with data: Data) throws
    func remove(_ name: String) throws
}
internal enum PulseFailure: Error { case corrupt, unavailable }

internal struct PulseInput {
    var timestamp: Date
    let session: String
    let userHash: String?
    let type: String
    let value: Double?
    let props: [String: Any]
    /// Fields captured with the signal: session statistics and time zone.
    var extra: [String: String] = [:]
    /// The `error` object of a `pulse.error` signal.
    var error: [String: Any]?
    /// System keys that belong to this one signal only, such as `launchMs`.
    var automaticFields: [String: String] = [:]
    /// The `heatmap` object of a `pulse.heatmap` signal.
    var heatmap: [String: Any]?
}

internal enum PulseJSON {
    static let maxBodyBytes = 1048576
    static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }
    /// A signal needs a type with some text in it (at most 200 characters) and a finite value, if it has one.
    static func isValid(type: String, value: Double?) -> Bool {
        !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && type.utf16.count <= 200 && value?.isFinite != false
    }
    static func signal(_ input: PulseInput, system: [String: String], debug: Bool) -> Data? {
        guard isValid(type: input.type, value: input.value) else { return nil }
        var props: [String: Any] = [:]
        // Swift Dictionary has no insertion-order contract. Sort to make local retention deterministic.
        for key in input.props.keys.sorted() {
            guard key.utf16.count <= 128, props.count < 32, let raw = input.props[key] else { continue }
            let value: Any
            if let string = raw as? String { value = string }
            else if let number = raw as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { value = number.boolValue ? "true" : "false" }
                else if number.doubleValue.isFinite { value = number }
                else { continue }
            } else { continue }
            if let string = value as? String, string.utf16.count > 1024 { continue }
            var candidate = props
            candidate[key] = value
            guard let bytes = try? encode(candidate), bytes.count <= 8192 else { continue }
            props = candidate
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var object: [String: Any] = ["timestamp": formatter.string(from: input.timestamp),
            "sessionId": input.session, "type": input.type, "debug": debug, "system": system, "props": props]
        if let value = input.value { object["value"] = value }
        if let hash = input.userHash { object["userHash"] = hash }
        if let error = input.error { object["error"] = error }
        if let heatmap = input.heatmap { object["heatmap"] = heatmap }
        guard let data = try? encode(object), data.count + 2 <= maxBodyBytes else { return nil }
        return data
    }
    static func batch(_ entries: [PulseEntry]) -> Data {
        var result = Data([91])
        for (index, entry) in entries.enumerated() {
            if index > 0 { result.append(44) }
            result.append(entry.json)
        }
        result.append(93)
        return result
    }
}
