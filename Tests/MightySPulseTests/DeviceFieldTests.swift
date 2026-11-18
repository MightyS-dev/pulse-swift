import Foundation
import XCTest
@testable import MightySPulse

final class DeviceFieldTests: XCTestCase {
    private let allowed: Set<String> = [
        "platform", "osName", "osVersion", "appVersion", "appBuildNumber", "deviceModel", "locale", "bundleId", "deviceType",
        "deviceBrand", "architecture", "appName", "installSource", "isSimulator", "isDebugBuild", "targetEnvironment", "extensionId",
        "language", "preferredLanguage", "region", "layoutDirection"]

    func testStaticContextHasEveryKeyThePlatformCanGiveInTheAllowedFormat() {
        let system = PulseEnvironment.system()
        var required = ["deviceBrand", "architecture", "installSource", "isSimulator", "isDebugBuild",
                        "targetEnvironment", "layoutDirection", "language", "preferredLanguage"]
        #if !(os(iOS) && !targetEnvironment(macCatalyst))
        required.append("deviceType") // On iOS it comes from the live device snapshot (idiom), see the test below.
        #endif
        for key in required {
            XCTAssertFalse((system[key] ?? "").isEmpty, "\(key) is missing")
        }
        XCTAssertEqual(system["deviceBrand"], "Apple")
        XCTAssertTrue(["arm64", "x86_64", "arm64_32", "armv7", "i386"].contains(system["architecture"] ?? ""))
        XCTAssertTrue(["appstore", "testflight", "debug", "other"].contains(system["installSource"] ?? ""))
        XCTAssertTrue(["true", "false"].contains(system["isSimulator"] ?? ""))
        XCTAssertTrue(["native", "simulator", "catalyst", "ios-on-mac"].contains(system["targetEnvironment"] ?? ""))
        XCTAssertTrue(["ltr", "rtl"].contains(system["layoutDirection"] ?? ""))
        XCTAssertNotNil(system["language"]?.range(of: "^[a-z]{2,3}$", options: .regularExpression))
        XCTAssertNotNil(system["preferredLanguage"]?.range(of: "^[a-z]{2,3}$", options: .regularExpression))
        if let region = system["region"] { XCTAssertNotNil(region.range(of: "^[A-Z]{2}$", options: .regularExpression)) }
        #if DEBUG
        XCTAssertEqual(system["isDebugBuild"], "true")
        XCTAssertEqual(system["installSource"], "debug")
        #endif
        #if os(macOS)
        XCTAssertEqual(system["deviceType"], "desktop")
        #endif
        XCTAssertTrue(Set(system.keys).isSubset(of: allowed), "unexpected keys \(Set(system.keys).subtracting(allowed))")
        XCTAssertTrue(system.values.allSatisfy { $0.utf8.count <= 256 })
    }
    func testInstallSourceMapping() {
        let source = PulseEnvironment.installSource
        XCTAssertEqual(source(true, "receipt", true, false), "debug")
        XCTAssertEqual(source(false, "sandboxReceipt", true, false), "testflight")
        XCTAssertEqual(source(false, "sandboxReceipt", true, true), "testflight")
        XCTAssertEqual(source(false, "receipt", true, false), "appstore")
        XCTAssertEqual(source(false, "receipt", true, true), "appstore")
        XCTAssertEqual(source(false, "receipt", false, true), "other")
        XCTAssertEqual(source(false, nil, false, true), "other")
        XCTAssertEqual(source(false, nil, false, false), "appstore")
    }
    func testExtensionIdentifierOnlyInsideAnExtensionBundle() {
        let info: [String: Any] = ["NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]]
        XCTAssertEqual(PulseEnvironment.extensionIdentifier(bundlePath: "/x/W.appex", info: info), "com.apple.widgetkit-extension")
        XCTAssertNil(PulseEnvironment.extensionIdentifier(bundlePath: "/x/App.app", info: info))
        XCTAssertNil(PulseEnvironment.extensionIdentifier(bundlePath: "/x/W.appex", info: nil))
    }
    func testNumberAndLanguageFormats() {
        XCTAssertEqual(PulseEnvironment.number(393), "393")
        XCTAssertEqual(PulseEnvironment.number(1.15), "1.15")
        XCTAssertEqual(PulseEnvironment.number(1.12345), "1.123")
        XCTAssertEqual(PulseEnvironment.number(2.0004), "2")
        XCTAssertEqual(PulseEnvironment.number(-0.5), "-0.5")
        XCTAssertEqual(PulseEnvironment.languagePart("pt-BR"), "pt")
        XCTAssertEqual(PulseEnvironment.languagePart("zh_Hans_CN"), "zh")
        XCTAssertNil(PulseEnvironment.languagePart(""))
        XCTAssertNil(PulseEnvironment.languagePart(nil))
    }
    func testSystemSettingMappings() {
        XCTAssertEqual(PulseDeviceFormat.orientation(width: 393, height: 852), "portrait")
        XCTAssertEqual(PulseDeviceFormat.orientation(width: 852, height: 393), "landscape")
        XCTAssertEqual(PulseDeviceFormat.orientation(width: 500, height: 500), "square")
        XCTAssertEqual(PulseDeviceFormat.categoryName(raw: "UICTContentSizeCategoryL"), "L")
        XCTAssertEqual(PulseDeviceFormat.categoryName(raw: "UICTContentSizeCategoryAccessibilityXXL"), "AccessibilityXXL")
        XCTAssertNil(PulseDeviceFormat.categoryName(raw: "UICTContentSizeCategoryUnspecified"))
        XCTAssertNil(PulseDeviceFormat.categoryName(raw: "other"))
        let expected = ["XS": "0.82", "S": "0.88", "M": "0.94", "L": "1", "XL": "1.12", "XXL": "1.24", "XXXL": "1.35",
                        "AccessibilityM": "1.65", "AccessibilityL": "1.94", "AccessibilityXL": "2.35",
                        "AccessibilityXXL": "2.76", "AccessibilityXXXL": "3.12"]
        for (name, scale) in expected { XCTAssertEqual(PulseDeviceFormat.fontScale(categoryName: name), scale) }
        XCTAssertEqual(PulseDeviceFormat.connection(satisfied: false, wifi: true, cellular: false, wired: false), "none")
        XCTAssertEqual(PulseDeviceFormat.connection(satisfied: true, wifi: true, cellular: true, wired: false), "wifi")
        XCTAssertEqual(PulseDeviceFormat.connection(satisfied: true, wifi: false, cellular: true, wired: false), "cellular")
        XCTAssertEqual(PulseDeviceFormat.connection(satisfied: true, wifi: false, cellular: false, wired: true), "ethernet")
        XCTAssertEqual(PulseDeviceFormat.connection(satisfied: true, wifi: false, cellular: false, wired: false), "other")
    }
    func testTimeFieldsFollowTheZoneAndDate() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Belgrade"))
        let winter = PulseEnvironment.timeFields(zone: zone, at: Date(timeIntervalSince1970: 1794556800))
        XCTAssertEqual(winter["timeZone"], "Europe/Belgrade"); XCTAssertEqual(winter["utcOffsetMinutes"], "60")
        let summer = PulseEnvironment.timeFields(zone: zone, at: Date(timeIntervalSince1970: 1782000000))
        XCTAssertEqual(summer["utcOffsetMinutes"], "120")
        let west = PulseEnvironment.timeFields(zone: try XCTUnwrap(TimeZone(identifier: "America/New_York")), at: Date(timeIntervalSince1970: 1794556800))
        XCTAssertEqual(west["utcOffsetMinutes"], "-300")
    }
    func testLiveDeviceCachesSystemValuesInTheAllowedFormat() {
        let live = PulseLiveDevice()
        live.start(); live.awaitReady(timeout: 2)
        let snapshot = live.snapshot()
        XCTAssertTrue(["true", "false"].contains(snapshot["lowPowerMode"] ?? ""))
        if let connection = snapshot["connectionType"] { XCTAssertTrue(["wifi", "cellular", "ethernet", "none", "other"].contains(connection)) }
        if let scheme = snapshot["colorScheme"] { XCTAssertTrue(["light", "dark"].contains(scheme)) }
        for key in ["reduceMotion", "increaseContrast", "reduceTransparency", "invertColors", "differentiateWithoutColor"] {
            if let flag = snapshot[key] { XCTAssertTrue(["true", "false"].contains(flag), key) }
        }
        for key in ["screenWidth", "screenHeight", "screenWidthPx", "screenHeightPx", "screenCount", "screenScale"] {
            if let number = snapshot[key] { XCTAssertNotNil(number.range(of: "^[0-9]+(\\.[0-9]{1,3})?$", options: .regularExpression), key) }
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        XCTAssertTrue(["phone", "tablet"].contains(snapshot["deviceType"] ?? ""), "iOS deviceType comes from the idiom")
        #endif
        let again = live.snapshot()
        XCTAssertEqual(again["lowPowerMode"], snapshot["lowPowerMode"])
    }
}
