import Foundation
import XCTest
@testable import MightySPulse

final class SerializationTests: XCTestCase {
    func testContractShapeMatchesFixture() throws {
        let h = Harness()
        h.runtime.setUser("synthetic-user")
        h.send("purchase", value: 4.5, props: ["item": "coins", "amount": 2])
        let url = try XCTUnwrap(Bundle.module.url(forResource: "v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let event = try XCTUnwrap(h.events.first)
        XCTAssertEqual(Set(event.keys), Set(fixture[0].keys))
        let system = try XCTUnwrap(event["system"] as? [String: String])
        XCTAssertEqual(Set(system.keys), Set((fixture[0]["system"] as! [String: Any]).keys))
        XCTAssertEqual(system["sdkName"], "pulse-swift")
        XCTAssertEqual(system["osVersion"], "18.0.0")
        XCTAssertTrue((event["timestamp"] as! String).hasSuffix("Z"))
        XCTAssertEqual(h.transport.requests[0].url.path, "/api/v1/signals")
        XCTAssertEqual(h.transport.requests[0].appKey, "synthetic-key")
        XCTAssertEqual(event["value"] as? Double, 4.5)
    }
    func testEscapesUnicodeBooleansAndFiniteNumbers() throws {
        let h = Harness()
        let text = "quote\" slash\\ newline\n control\u{0001} emoji\u{1F600}"
        h.send(text, value: 1.25, props: ["unicode": "\u{65E5}\u{672C}", "escaped": text, "bool": true,
                                       "fraction": 2.5, "infinity": Double.infinity, "nested": ["x": 1], "array": [1]])
        let event = try XCTUnwrap(h.events.first), props = event["props"] as! [String: Any]
        XCTAssertEqual(event["type"] as? String, text)
        XCTAssertEqual(props["escaped"] as? String, text)
        XCTAssertEqual(props["bool"] as? String, "true")
        XCTAssertEqual(props["fraction"] as? Double, 2.5)
        XCTAssertNil(props["infinity"]); XCTAssertNil(props["nested"]); XCTAssertNil(props["array"])
        XCTAssertTrue(String(decoding: Harness.json(h.transport.requests[0]), as: UTF8.self).contains("1.25"))
    }
    func testLocalContractLimitsAndInvalidInputs() throws {
        let h = Harness()
        h.runtime.track(" "); h.runtime.track(String(repeating: "x", count: 201))
        h.runtime.track(String(repeating: "\u{1F600}", count: 101)); h.runtime.track("nan", value: .nan)
        var props: [String: Any] = [:]
        for i in 0..<40 { props[String(format: "k%02d", i)] = String(repeating: "x", count: 1024) }
        props[String(repeating: "k", count: 129)] = "ignored"
        props["tooLong"] = String(repeating: "v", count: 1025)
        h.send(String(repeating: "\u{1F600}", count: 100), props: props)
        XCTAssertEqual(h.events.count, 1)
        let sent = h.events[0]["props"] as! [String: Any]
        XCTAssertLessThanOrEqual(sent.count, 32)
        XCTAssertLessThanOrEqual(try PulseJSON.encode(sent).count, 8192)
        XCTAssertNil(sent["tooLong"])
    }
    func testSerbianAndGermanNumericInputStillProducesJSONDecimalPoint() throws {
        for identifier in ["sr_RS", "de_DE"] {
            let parser = NumberFormatter()
            parser.locale = Locale(identifier: identifier); parser.numberStyle = .decimal
            let amount = try XCTUnwrap(parser.number(from: "1234,5"))
            let h = Harness()
            h.send("locale", value: amount.doubleValue, props: ["amount": amount])
            let event = try XCTUnwrap(h.events.first)
            XCTAssertEqual(event["value"] as? Double, 1234.5)
            XCTAssertEqual((event["props"] as? [String: Any])?["amount"] as? Double, 1234.5)
            let json = String(decoding: Harness.json(h.transport.requests[0]), as: UTF8.self)
            XCTAssertTrue(json.contains("1234.5")); XCTAssertFalse(json.contains("1234,5"))
        }
    }
    func testHashVectorsAndFallbackAgainstCryptoKit() {
        let vectors = ["": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                       "abc": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]
        for (input, expected) in vectors {
            XCTAssertEqual(PulseHash.hex(input), expected)
            XCTAssertEqual(PulseHash.fallback(Data(input.utf8)).map { String(format: "%02x", $0) }.joined(), expected)
        }
        for count in [55, 56, 63, 64, 65, 1000, 1000000] {
            let data = Data(repeating: 97, count: count)
            XCTAssertEqual(PulseHash.fallback(data), PulseHash.bytes(data))
        }
        let million = PulseHash.fallback(Data(repeating: 97, count: 1000000))
        XCTAssertEqual(million.map { String(format: "%02x", $0) }.joined(),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
    func testGzipIsDeterministicAndRoundTripsAtBounds() {
        for count in [0, 1025, 65536, 1048576] {
            let input = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 31) })
            let gzip = PulseGzip.encode(input)
            XCTAssertNotNil(gzip)
            XCTAssertEqual(gzip, PulseGzip.encode(input))
            XCTAssertEqual(gzip.flatMap(PulseGzip.decode), input)
        }
        XCTAssertNil(PulseGzip.decode(Data("bad gzip".utf8)))
        let valid = PulseGzip.encode(Data(repeating: 97, count: 2048))!
        XCTAssertNil(PulseGzip.decode(Data(valid.dropLast())))
        XCTAssertNil(PulseGzip.encode(Data(repeating: 0, count: 1048577)))
    }
    func testEnvironmentContainsNumericOSVersionAndNoIdentifiers() {
        let environment = PulseEnvironment.system()
        XCTAssertNotNil(environment["osVersion"]?.range(of: "^[0-9]+\\.[0-9]+(\\.[1-9][0-9]*)?$", options: .regularExpression))
        XCTAssertNil(environment["deviceId"]); XCTAssertNil(environment["deviceName"])
        XCTAssertNil(environment["bundleId"]); XCTAssertNil(environment["identifierForVendor"])
    }
    func testDeviceModelIsHardwareIdentifierWithSafeFallbacks() {
        XCTAssertEqual(PulseEnvironment.hardwareModel(machine: "iPhone17,1", simulatorModel: nil, fallback: "Apple mobile device"), "iPhone17,1")
        XCTAssertEqual(PulseEnvironment.hardwareModel(machine: "arm64", simulatorModel: "iPhone18,3", fallback: "Apple mobile device"), "iPhone18,3")
        XCTAssertEqual(PulseEnvironment.hardwareModel(machine: "", simulatorModel: nil, fallback: "Mac"), "Mac")
        XCTAssertEqual(PulseEnvironment.hardwareModel(machine: "Bob's \u{1F600} phone with spaces", simulatorModel: nil, fallback: "Mac"), "Mac")
        XCTAssertEqual(PulseEnvironment.hardwareModel(machine: String(repeating: "a", count: 65), simulatorModel: nil, fallback: "Mac"), "Mac")
        let live = PulseEnvironment.system()["deviceModel"] ?? ""
        XCTAssertFalse(live.isEmpty)
        XCTAssertNotEqual(live, ProcessInfo.processInfo.hostName)
    }
    func testOSVersionIsMajorMinorWithPatchOnlyWhenNotZero() {
        XCTAssertEqual(PulseEnvironment.versionText(major: 26, minor: 5, patch: 0), "26.5")
        XCTAssertEqual(PulseEnvironment.versionText(major: 18, minor: 6, patch: 1), "18.6.1")
        XCTAssertEqual(PulseEnvironment.versionText(major: 27, minor: 0, patch: 0), "27.0")
    }
}
