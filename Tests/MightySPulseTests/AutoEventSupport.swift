import Foundation
import XCTest
@testable import MightySPulse

/// Status values a test sets by hand. It can only be read: the protocol has no way to ask the user for anything.
final class FakePermissions: PulsePermissionSource {
    private let lock = NSLock()
    private var values: [String: String]
    private var _started = 0, _refreshed = 0
    init(_ values: [String: String] = [:]) { self.values = values }
    func set(_ key: String, _ value: String?) { lock.lock(); values[key] = value; lock.unlock() }
    var started: Int { lock.lock(); defer { lock.unlock() }; return _started }
    var refreshed: Int { lock.lock(); defer { lock.unlock() }; return _refreshed }
    func start() { lock.lock(); _started += 1; lock.unlock() }
    func refresh() { lock.lock(); _refreshed += 1; lock.unlock() }
    func awaitReady(timeout: TimeInterval) {}
    func snapshot() -> [String: String] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Stands in for MetricKit: the test hands the SDK diagnostic payloads whenever it wants.
final class FakeExits: PulseExitSource {
    private let lock = NSLock()
    private var deliver: (([PulseExitPayload]) -> Void)?
    private var _starts = 0
    var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }
    func start(_ handler: @escaping ([PulseExitPayload]) -> Void) {
        lock.lock(); _starts += 1; deliver = handler; lock.unlock()
    }
    func send(_ payloads: [PulseExitPayload]) {
        lock.lock(); let handler = deliver; lock.unlock()
        handler?(payloads)
    }
}

enum AutoFixtures {
    static let optIn = "{\"enabledSignals\":[\"pulse.app_opened\",\"pulse.app_backgrounded\"]}"
    static func storage(config: String?) -> FakeStorage {
        let storage = FakeStorage()
        if let config = config { storage.files["config"] = Data(config.utf8) }
        return storage
    }
    static func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}

extension Harness {
    func eventsOfType(_ type: String) -> [[String: Any]] { events.filter { $0["type"] as? String == type } }
    func types() -> [String] { events.compactMap { $0["type"] as? String } }
    static func props(_ event: [String: Any]) -> [String: Any] { event["props"] as? [String: Any] ?? [:] }
    static func system(_ event: [String: Any]) -> [String: String] { event["system"] as? [String: String] ?? [:] }
    func foreground() { runtime.foreground(); settle() }
    func background() { runtime.noteBackground(); settle() }
}
