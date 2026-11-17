import Foundation
import XCTest
@testable import MightySPulse

final class ControlCoreTests: XCTestCase {
    func testVersionTable() throws {
        let cases = try XCTUnwrap(ControlFixtures.json("version-cases") as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 200)
        for row in cases {
            let a = row["a"] as? String, b = row["b"] as? String
            let expected = (row["result"] as? NSNumber)?.intValue
            XCTAssertEqual(ControlVersion.compare(a, b), expected, "\(a ?? "nil") vs \(b ?? "nil")")
        }
    }

    func testDecisionTable() throws {
        let cases = try XCTUnwrap(ControlFixtures.json("decision-cases") as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 60)
        for row in cases {
            let name = row["name"] as! String
            let raw = row["input"] as! [String: Any]
            let rules = (raw["rules"] as? [String: Any]).flatMap { ControlRules.parse(object: $0) }
            let outcome = ControlDecision.decide(rules, ControlFixtures.input(raw))
            let expected = row["expected"] as! [String: Any]
            XCTAssertEqual(outcome.main.rawValue, expected["state"] as? String, name)
            XCTAssertEqual(outcome.allowContinue, expected["allowContinue"] as? Bool, name)
            XCTAssertEqual(outcome.banners.map(\.rawValue), expected["banners"] as? [String], name)
            XCTAssertEqual(outcome.card?.rawValue, expected["card"] as? String, name)
        }
    }

    func testControlIdTable() throws {
        let cases = try XCTUnwrap(ControlFixtures.json("control-id-cases") as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for row in cases {
            let key = row["key"] as! String
            XCTAssertEqual(String(PulseHash.hex(key).prefix(32)), row["controlId"] as? String, row["note"] as? String ?? key)
        }
    }

    func testBuiltInTextsEqualTheSharedTable() throws {
        let table = try XCTUnwrap(ControlFixtures.json("texts") as? [String: Any])
        let languages = try XCTUnwrap(table["languages"] as? [String])
        let texts = try XCTUnwrap(table["texts"] as? [String: [String: String]])
        XCTAssertEqual(languages, ControlTextData.languages)
        XCTAssertEqual(languages.count, 12)
        XCTAssertEqual(texts, ControlTextData.table)
    }

    func testLanguageChoice() {
        XCTAssertEqual(ControlTexts.pick(["de-AT", "en"]), "de")
        XCTAssertEqual(ControlTexts.pick(["pt-PT"]), "pt-BR")
        XCTAssertEqual(ControlTexts.pick(["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(ControlTexts.pick(["zh-Hant-TW", "ja"]), "ja")
        XCTAssertEqual(ControlTexts.pick(["sr-Latn-RS"]), "sr-Latn")
        XCTAssertEqual(ControlTexts.pick(["sr-Cyrl", "fr"]), "fr")
        XCTAssertEqual(ControlTexts.pick(["nl", "xx"]), "en")
        XCTAssertEqual(ControlTexts.pick([]), "en")
    }

    func testPlaceholdersAndTime() {
        let zone = TimeZone(identifier: "UTC")!
        let texts = ControlTexts(preferred: ["en"], appName: "Orchard", locale: Locale(identifier: "en_US_POSIX"), timeZone: zone)
        let now = ControlClock.parse("2026-12-01T10:00:00Z")!
        let later = ControlClock.parse("2026-12-01T14:30:00Z")!
        let tomorrow = ControlClock.parse("2026-12-02T09:05:00Z")!
        let line = texts.render("maintenance.body", endsAt: later, now: now)
        XCTAssertTrue(line.contains("Orchard"), line)
        XCTAssertFalse(line.contains("{"), line)
        XCTAssertTrue(texts.time(later, now: now).contains("2:30"))
        XCTAssertNotEqual(texts.time(tomorrow, now: now), texts.time(tomorrow.addingTimeInterval(0), now: tomorrow))
        XCTAssertEqual(texts.render("whatsNew.title", version: "2.4.0"), "What's new in 2.4.0")
    }

    func testRulesParserRefusesWhatItCannotTrust() throws {
        XCTAssertNil(ControlRules.parse(Data("[]".utf8)))
        XCTAssertNil(ControlRules.parse(Data("nope".utf8)))
        XCTAssertNil(ControlRules.parse(Data(count: 65537)))
        XCTAssertNil(ControlRules.parse(Data(#"{"format":1,"update":"x"}"#.utf8)))
        XCTAssertNil(ControlRules.parse(Data(#"{"format":1,"blocked":{}}"#.utf8)))
        let lenient = try XCTUnwrap(ControlRules.parse(Data(#"{"format":1,"version":"x","future":{"a":1},"update":{"ios":{"min":3,"mode":"required"}},"maintenance":{"startsAt":"bad","endsAt":"bad"}}"#.utf8)))
        XCTAssertEqual(lenient.version, 0)
        XCTAssertNil(lenient.maintenance)
        XCTAssertNil(lenient.update["ios"]?.min)
        let other = try XCTUnwrap(ControlRules.parse(Data(#"{"format":2}"#.utf8)))
        XCTAssertEqual(ControlDecision.decide(other, ControlInput(now: Date())), .normal)
    }
}
