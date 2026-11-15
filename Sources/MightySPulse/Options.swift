import Foundation
import CoreFoundation

internal enum PulseInfo {
    static let sdkName = "pulse-swift"
    static let version = "0.9.3"
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
    /// Overrides the app version taken from the bundle. Default `nil`.
    public var appVersion: String?
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
    let timestamp: Date
    let session: String
    let userHash: String?
    let type: String
    let value: Double?
    let props: [String: Any]
    /// Fields captured with the signal: session statistics and time zone.
    var extra: [String: String] = [:]
}

internal enum PulseJSON {
    static let maxBodyBytes = 1048576
    static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }
    static func signal(_ input: PulseInput, system: [String: String], debug: Bool) -> Data? {
        guard !input.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.type.utf16.count <= 200, input.value?.isFinite != false else { return nil }
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
