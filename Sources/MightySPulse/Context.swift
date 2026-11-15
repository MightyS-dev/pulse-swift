import Foundation

/// Values that do not change while the app runs. Everything here is safe to read off the main thread.
/// A key whose value the platform cannot give is left out.
internal extension PulseEnvironment {
    static func cap(_ text: String, _ limit: Int = 64) -> String { String(decoding: text.utf8.prefix(limit), as: UTF8.self) }

    /// Integers without decimals, decimals with "." and at most three decimals.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded() { return String(Int64(rounded)) }
        var text = String(format: "%.3f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// The language part of a language tag: "pt-BR" gives "pt".
    static func languagePart(_ tag: String?) -> String? {
        guard let tag = tag else { return nil }
        let part = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return part.isEmpty ? nil : cap(part.lowercased())
    }

    static func installSource(isDebug: Bool, receiptName: String?, receiptExists: Bool, isMac: Bool) -> String {
        if isDebug { return "debug" }
        if receiptName == "sandboxReceipt" { return "testflight" }
        if isMac && !receiptExists { return "other" }
        return "appstore"
    }

    static func extensionIdentifier(bundlePath: String, info: [String: Any]?) -> String? {
        guard bundlePath.hasSuffix(".appex"),
              let point = (info?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
              !point.isEmpty else { return nil }
        return cap(point)
    }

    static var architecture: String? {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #elseif arch(arm64_32)
        return "arm64_32"
        #elseif arch(arm)
        return "armv7"
        #elseif arch(i386)
        return "i386"
        #else
        return nil
        #endif
    }

    static var isMacLike: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    static var targetEnvironment: String {
        #if targetEnvironment(simulator)
        return "simulator"
        #elseif targetEnvironment(macCatalyst)
        return "catalyst"
        #else
        #if os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac { return "ios-on-mac" }
        #endif
        return "native"
        #endif
    }

    static func staticContext() -> [String: String] {
        var values: [String: String] = [:]
        let bundle = Bundle.main
        let debugBuild = _isDebugAssertConfiguration()
        if let id = bundle.bundleIdentifier, !id.isEmpty { values["bundleId"] = cap(id) }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let name = name { values["appName"] = cap(name) }
        values["deviceBrand"] = "Apple"
        if let arch = architecture { values["architecture"] = arch }
        let receipt = bundle.appStoreReceiptURL
        values["installSource"] = installSource(
            isDebug: debugBuild, receiptName: receipt?.lastPathComponent,
            receiptExists: receipt.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, isMac: isMacLike)
        #if targetEnvironment(simulator)
        values["isSimulator"] = "true"
        #else
        values["isSimulator"] = "false"
        #endif
        values["isDebugBuild"] = PulseDeviceFormat.flag(debugBuild)
        values["targetEnvironment"] = targetEnvironment
        if let id = extensionIdentifier(bundlePath: bundle.bundlePath, info: bundle.infoDictionary) { values["extensionId"] = id }
        #if os(macOS)
        values["deviceType"] = "desktop"
        #elseif os(tvOS)
        values["deviceType"] = "tv"
        #elseif os(watchOS)
        values["deviceType"] = "watch"
        #elseif targetEnvironment(macCatalyst)
        values["deviceType"] = "desktop"
        #endif
        if let language = languagePart(bundle.preferredLocalizations.first) {
            values["language"] = language
            if NSLocale.characterDirection(forLanguage: language) == .rightToLeft { values["layoutDirection"] = "rtl" }
            else { values["layoutDirection"] = "ltr" }
        }
        if let preferred = languagePart(Locale.preferredLanguages.first) { values["preferredLanguage"] = preferred }
        if let region = (Locale.current as NSLocale).object(forKey: .countryCode) as? String, !region.isEmpty {
            values["region"] = cap(region.uppercased())
        }
        return values
    }

    /// Time zone fields at the moment a signal is captured.
    static func timeFields(zone: TimeZone, at date: Date) -> [String: String] {
        ["timeZone": cap(zone.identifier), "utcOffsetMinutes": String(zone.secondsFromGMT(for: date) / 60)]
    }
}
