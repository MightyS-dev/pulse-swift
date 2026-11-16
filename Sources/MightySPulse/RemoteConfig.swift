import Foundation

/// Settings read from the Pulse dashboard. Everything is on unless the dashboard switched it off.
internal struct PulseRemoteConfig: Equatable {
    static let fileName = "config"
    static let maxBytes = 65536
    static let automaticTypes: Set<String> = ["pulse.session_started", "pulse.new_install", "pulse.app_updated", "pulse.screen_view"]
    static let screenViewType = "pulse.screen_view"
    /// Field groups and the keys each one controls. The base fields (platform, OS, app version, build, device model,
    /// locale, SDK and bundle identifier) are in no group and are always sent.
    static let groupKeys: [String: Set<String>] = [
        "device": ["deviceType", "deviceBrand", "architecture", "osApiLevel", "runtimeVersion", "scriptingBackend",
                   "isSimulator", "targetEnvironment", "extensionId"],
        "screen": ["screenWidth", "screenHeight", "screenScale", "screenWidthPx", "screenHeightPx", "screenDpi",
                   "screenCount", "orientation"],
        "settings": ["colorScheme", "layoutDirection", "timeZone", "utcOffsetMinutes", "language", "preferredLanguage",
                     "region", "fontScale", "contentSizeCategory", "reduceMotion", "boldText", "invertColors",
                     "increaseContrast", "reduceTransparency", "differentiateWithoutColor", "fontWeightAdjustment"],
        "network": ["connectionType", "lowPowerMode"],
        "app": ["appName", "installSource", "isDebugBuild"],
        "usage": ["isNewInstall", "firstSessionDate", "totalSessionsCount", "distinctDaysUsed", "distinctDaysUsedLastMonth",
                  "previousSessionSeconds", "averageSessionSeconds", "sessionSeconds"]
    ]

    var version: Int?
    var screenViews = true
    var automaticSignals = true
    var groups: [String: Bool] = [:]
    var disabledSignals: Set<String> = []

    static let allOn = PulseRemoteConfig()

    /// Parses a response body. Anything that is not a JSON object gives nil; inside an object, unknown keys are
    /// ignored and missing or wrongly typed values mean on. Never throws.
    static func parse(_ data: Data?) -> PulseRemoteConfig? {
        guard let data = data, !data.isEmpty, data.count <= maxBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var config = PulseRemoteConfig()
        if let number = object["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue < 1e9,
           number.doubleValue == number.doubleValue.rounded() { config.version = number.intValue }
        config.screenViews = flag(object["screenViews"])
        config.automaticSignals = flag(object["automaticSignals"])
        if let groups = object["groups"] as? [String: Any] {
            for name in groupKeys.keys { config.groups[name] = flag(groups[name]) }
        }
        if let list = object["disabledSignals"] as? [Any] {
            config.disabledSignals = Set(list.compactMap { $0 as? String }.filter { automaticTypes.contains($0) })
        }
        return config
    }
    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return true }
        return number.boolValue
    }
    var etag: String? { version.map { "\"\($0)\"" } }
}

/// The settings used for one run. The dashboard decides; a code option can only switch things off.
internal struct PulseEffectiveConfig {
    let portalScreenViews: Bool
    let portalAutomatic: Bool
    let codeScreenHook: Bool
    let codeAutomaticSignals: Bool
    let disabledSignals: Set<String>
    let removedKeys: Set<String>

    init(options: PulseOptions, remote: PulseRemoteConfig) {
        portalScreenViews = remote.screenViews
        portalAutomatic = remote.automaticSignals
        codeScreenHook = options.automaticScreenViews
        codeAutomaticSignals = options.automaticSignals
        disabledSignals = remote.disabledSignals
        var keys = Set<String>()
        for (name, enabled) in remote.groups where !enabled { keys.formUnion(PulseRemoteConfig.groupKeys[name] ?? []) }
        removedKeys = keys
    }
    static let allOn = PulseEffectiveConfig(options: PulseOptions(), remote: .allOn)

    /// Whether the portal allows screen views at all. Manual calls follow this alone.
    private var portalAllowsScreenViews: Bool {
        portalScreenViews && portalAutomatic && !disabledSignals.contains(PulseRemoteConfig.screenViewType)
    }
    func sends(_ type: String) -> Bool {
        if disabledSignals.contains(type) { return false }
        if type == PulseRemoteConfig.screenViewType { return portalAllowsScreenViews }
        if PulseRemoteConfig.automaticTypes.contains(type) { return portalAutomatic && codeAutomaticSignals }
        return true
    }
    /// Whether the automatic screen hook should be installed.
    var capturesScreens: Bool { codeScreenHook && portalAllowsScreenViews }
}
