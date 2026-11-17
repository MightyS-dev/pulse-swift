import Foundation
#if canImport(MetricKit) && (os(iOS) || os(macOS))
import MetricKit
#endif

/// One diagnostic payload from the system: the JSON the system made and the end of the period it covers.
internal struct PulseExitPayload {
    var json: Data
    var end: Date?
}
/// One reason the app ended: its reason name, the time the system reports and the trace, top frame first.
internal struct PulseExitRecord: Equatable {
    var reason: String
    var time: Date
    var frames: [String]
}

internal protocol PulseExitSource: AnyObject {
    /// Starts delivery. The handler may be called from any thread, now or later.
    func start(_ deliver: @escaping ([PulseExitPayload]) -> Void)
}
internal final class PulseNoExits: PulseExitSource {
    func start(_ deliver: @escaping ([PulseExitPayload]) -> Void) {}
}

internal extension PulseExitPayload {
    static let maxBytes = 4_194_304
    static let maxAge: TimeInterval = 7 * 86400
    static let maxPerSection = 10
    static let maxChain = 200
    private static let sections: [(key: String, reason: String)] = [
        ("crashDiagnostics", "crash"), ("hangDiagnostics", "hang"),
        ("cpuExceptionDiagnostics", "cpu_exception"), ("diskWriteExceptionDiagnostics", "disk_write_exception")]

    static func object(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    /// The records of a payload. Only the reason, the time and the trace are read; the app, the build, the device and
    /// every other field of the diagnostics are ignored. Never throws.
    static func records(json: Data, end: Date) -> [PulseExitRecord] {
        guard let root = object(json) else { return [] }
        var result: [PulseExitRecord] = []
        for section in sections {
            guard let list = root[section.key] as? [Any] else { continue }
            for item in list.prefix(maxPerSection) {
                guard let diagnostic = item as? [String: Any] else { continue }
                result.append(PulseExitRecord(reason: section.reason, time: end, frames: frames(of: diagnostic)))
            }
        }
        return result
    }
    /// The trace of the thread the system blames (or the first one), as `Binary+0xOffset`, top frame first.
    private static func frames(of diagnostic: [String: Any]) -> [String] {
        guard let tree = diagnostic["callStackTree"] as? [String: Any], let stacks = tree["callStacks"] as? [[String: Any]],
              let stack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first else { return [] }
        var node = heaviest(list(stack["callStackRootFrames"]))
        var chain: [String] = []
        while let current = node, chain.count < maxChain {
            if let name = current["binaryName"] as? String, !name.isEmpty,
               let offset = (current["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value {
                chain.append(name + "+0x" + String(offset, radix: 16))
            }
            node = heaviest(list(current["subFrames"]))
        }
        return Array(chain.reversed().prefix(PulseFrames.maxFrames))
    }
    private static func list(_ value: Any?) -> [[String: Any]] {
        if let frames = value as? [[String: Any]] { return frames }
        if let frame = value as? [String: Any] { return [frame] }
        return []
    }
    private static func heaviest(_ frames: [[String: Any]]) -> [String: Any]? {
        frames.max { ($0["sampleCount"] as? NSNumber)?.intValue ?? 0 < ($1["sampleCount"] as? NSNumber)?.intValue ?? 0 }
    }

    /// "2026-11-16 08:00:00" (UTC) as the system writes it, or an ISO 8601 date.
    static func parseTime(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
    /// The end of the period a payload covers: the date the system gave, else the one written in the JSON.
    static func endTime(_ payload: PulseExitPayload) -> Date? {
        if let end = payload.end { return end }
        return (object(payload.json)?["timeStampEnd"] as? String).flatMap(parseTime)
    }
}

/// The end time of the newest payload already handled, so a record is never sent twice.
internal enum PulseExitMarker {
    static let fileName = "exits"
    static func read(_ storage: PulseStorage) -> Date? {
        guard let bytes = try? storage.read(fileName), let text = String(data: bytes, encoding: .utf8),
              let millis = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)), millis > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }
    static func write(_ storage: PulseStorage, _ date: Date) {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        try? storage.replace(fileName, with: Data(String(millis).utf8))
    }
}

#if canImport(MetricKit) && (os(iOS) || os(macOS))
/// Subscribes to MetricKit and hands over the diagnostic payloads (hangs, crashes, CPU and disk write exceptions).
/// The system delivers them about once a day and when the app starts. Metric payloads are ignored.
@available(iOS 14.0, macOS 12.0, *)
internal final class PulseMetricKitSource: NSObject, PulseExitSource, MXMetricManagerSubscriber {
    private let lock = NSLock()
    private var deliver: (([PulseExitPayload]) -> Void)?
    func start(_ handler: @escaping ([PulseExitPayload]) -> Void) {
        lock.lock(); let first = deliver == nil; deliver = handler; lock.unlock()
        if first { MXMetricManager.shared.add(self) }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        lock.lock(); let handler = deliver; lock.unlock()
        handler?(payloads.map { PulseExitPayload(json: $0.jsonRepresentation(), end: $0.timeStampEnd) })
    }
}
#endif

internal enum PulseLiveExits {
    static func make() -> PulseExitSource {
        #if canImport(MetricKit) && (os(iOS) || os(macOS))
        if #available(iOS 14.0, macOS 12.0, *) { return PulseMetricKitSource() }
        #endif
        return PulseNoExits()
    }
}
