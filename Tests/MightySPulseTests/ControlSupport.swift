import Foundation
import XCTest
@testable import MightySPulse

/// A scripted App Control server for the fake transport. Mutable between steps of a test.
final class ControlServer {
    enum Reply { case rules(Data), notModified, status(Int), body(Data), hang }
    var reply: Reply
    private(set) var requests: [PulseRequest] = []
    init(_ reply: Reply = .status(500)) { self.reply = reply }
    func handle(_ request: PulseRequest, _ completion: @escaping (PulseResponse) -> Void) {
        requests.append(request)
        switch reply {
        case .rules(let data): completion(PulseResponse(status: 200, body: data))
        case .notModified: completion(PulseResponse(status: 304))
        case .status(let code): completion(PulseResponse(status: code))
        case .body(let data): completion(PulseResponse(status: 200, body: data))
        case .hang: break
        }
    }
}

enum ControlRulesBuilder {
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: date)
    }
    /// Empty rules with the given top-level keys replaced.
    static func make(version: Int = 7, _ overrides: [String: Any] = [:]) -> Data {
        var object: [String: Any] = ["format": 1, "version": version, "off": false, "update": [String: Any](), "blocked": [Any](),
                                     "maintenance": NSNull(), "announcement": NSNull(), "whatsNew": NSNull(),
                                     "texts": ["custom": [String: Any]()], "disabledSdkVersions": [Any]()]
        for (key, value) in overrides { object[key] = value }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    static func required(min: String = "9.0.0", storeVersion: String? = nil, url: String? = "https://apps.apple.com/app/id1") -> Data {
        make(["update": ["ios": ["min": min, "latest": min, "mode": "required",
                                 "storeVersion": storeVersion as Any, "storeUrl": url as Any]]])
    }
    static func maintenance(from start: Date, to end: Date, headsUp: Int = 0) -> Data {
        make(["maintenance": ["startsAt": iso(start), "endsAt": iso(end), "headsUpMinutes": headsUp,
                              "exemptAboveStore": false, "platforms": NSNull()]])
    }
}

extension Harness {
    /// A runtime whose App Control server is `server`, started and settled. The app version is 1.2.3.
    static func control(_ server: ControlServer, options: PulseOptions = PulseOptions(), storage: FakeStorage = FakeStorage(),
                        clock: FakeClock = FakeClock(), environment: ControlEnvironment = .test()) -> Harness {
        let h = Harness(options: options, storage: storage, clock: clock, initialize: false, controlEnvironment: environment)
        h.controlTransport.handler = { server.handle($0, $1) }
        h.runtime.initialize(appKey: "synthetic-key", options: options)
        h.settle()
        return h
    }
    var control: ControlEngine { runtime.control }
    var primary: ControlState { control.snapshot.primary }
    func foregroundControl() { control.foreground(); settle() }
    func checkControl() { control.checkNow(); settle() }
}
