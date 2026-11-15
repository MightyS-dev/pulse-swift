import Foundation
import XCTest
@testable import MightySPulse

final class FakeCancellation: PulseCancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
final class FakeClock: PulseClock {
    private let lock = NSLock()
    private var date: Date
    private var scheduled: [(Date, FakeCancellation, () -> Void)] = []
    init(now: Date = Date(timeIntervalSince1970: 1794556800)) { date = now }
    // A restarted process inherits wall time, never the previous process's scheduled callbacks.
    func fork(advancing seconds: TimeInterval = 0) -> FakeClock { FakeClock(now: now.addingTimeInterval(seconds)) }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> PulseCancellation {
        lock.lock(); defer { lock.unlock() }
        let cancel = FakeCancellation()
        scheduled.append((date.addingTimeInterval(seconds), cancel, action))
        return cancel
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        let ready = scheduled.filter { $0.0 <= date }
        scheduled.removeAll { $0.0 <= date || $0.1.cancelled }
        lock.unlock()
        for item in ready where !item.1.cancelled { item.2() }
    }
}
final class FakeStorage: PulseStorage {
    // The runtime writes from its serial queue while tests read from the main thread.
    private let lock = NSLock()
    private var _files: [String: Data] = [:]
    private var _failReads = false, _failWrites = false, _failPreference = false
    private var _afterReplace: ((String) -> Void)?
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var files: [String: Data] {
        get { locked { _files } }
        set { locked { _files = newValue } }
    }
    var failReads: Bool { get { locked { _failReads } } set { locked { _failReads = newValue } } }
    var failWrites: Bool { get { locked { _failWrites } } set { locked { _failWrites = newValue } } }
    var failPreference: Bool { get { locked { _failPreference } } set { locked { _failPreference = newValue } } }
    var afterReplace: ((String) -> Void)? { get { locked { _afterReplace } } set { locked { _afterReplace = newValue } } }
    func read(_ name: String) throws -> Data? {
        if failReads { throw PulseFailure.unavailable }
        return locked { _files[name] }
    }
    func replace(_ name: String, with data: Data) throws {
        if failWrites || (failPreference && name == "opt-out") { throw PulseFailure.unavailable }
        locked { _files[name] = data }
        afterReplace?(name)
    }
    func remove(_ name: String) throws {
        if failWrites { throw PulseFailure.unavailable }
        _ = locked { _files.removeValue(forKey: name) }
    }
    var queueName: String? { locked { _files.keys.first { $0.hasPrefix("queue-") } } }
}
final class FakeTransport: PulseTransport {
    var requests: [PulseRequest] = []
    var replies: [PulseResponse] = []
    var handler: ((PulseRequest, @escaping (PulseResponse) -> Void) -> Void)?
    var cancellations: [FakeCancellation] = []
    func send(_ request: PulseRequest, completion: @escaping (PulseResponse) -> Void) -> PulseCancellation {
        requests.append(request)
        let cancellation = FakeCancellation(); cancellations.append(cancellation)
        if let handler = handler { handler(request, completion) }
        else { completion(replies.isEmpty ? PulseResponse(status: 202) : replies.removeFirst()) }
        return cancellation
    }
}
final class Harness {
    let clock: FakeClock
    let storage: FakeStorage
    let transport = FakeTransport()
    let runtime: PulseRuntime
    init(options: PulseOptions = PulseOptions(), storage: FakeStorage = FakeStorage(),
         clock: FakeClock = FakeClock(), key: String = "synthetic-key", initialize: Bool = true,
         random: @escaping () -> Double = { 0.5 }) {
        self.storage = storage; self.clock = clock
        runtime = PulseRuntime(clock: clock, transport: transport, storage: storage, environment: {
            ["platform": "mobile", "osName": "iOS", "osVersion": "18.0.0", "appVersion": "1.2.3",
             "appBuildNumber": "42", "deviceModel": "Apple mobile device", "locale": "sr-RS"]
        }, random: random)
        if initialize { runtime.initialize(appKey: key, options: options); settle() }
    }
    func settle(_ passes: Int = 64) { for _ in 0..<passes { runtime.barrier() } }
    func advance(_ seconds: Double) { clock.advance(seconds); settle() }
    func flush() { runtime.flush {}; settle() }
    func send(_ type: String = "event", value: Double? = nil, props: [String: Any]? = nil) {
        runtime.track(type, value: value, props: props); flush()
    }
    var events: [[String: Any]] { transport.requests.flatMap { Self.events($0) } }
    static func json(_ request: PulseRequest) -> Data { request.gzip ? PulseGzip.decode(request.body)! : request.body }
    static func events(_ request: PulseRequest) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: json(request))) as? [[String: Any]] ?? []
    }
}
