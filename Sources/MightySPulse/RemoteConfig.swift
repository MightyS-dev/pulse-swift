import Foundation

/// Settings read from the Pulse dashboard. Everything is on unless the dashboard switched it off.
internal struct PulseRemoteConfig: Equatable {
    static let fileName = "config"
    static let maxBytes = 65536
    static let automaticTypes: Set<String> = ["pulse.session_started", "pulse.new_install", "pulse.app_updated", "pulse.screen_view",
                                              PulseAutoTypes.appOpened, PulseAutoTypes.appBackgrounded,
                                              PulseAutoTypes.deepLink, PulseAutoTypes.permissionChanged,
                                              PulseHeatmapMath.signalType]
    /// Types that are sent only when the portal lists them in `enabledSignals`.
    static let optInTypes: Set<String> = [PulseAutoTypes.appOpened, PulseAutoTypes.appBackgrounded]
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
                  "previousSessionSeconds", "averageSessionSeconds", "sessionSeconds", "foregroundsToday",
                  "previousForegroundSeconds"],
        "permissions": ["notificationPermission", "trackingPermission"]
    ]

    var version: Int?
    var screenViews = true
    var automaticSignals = true
    /// The portal switched heatmaps on for this app. Off when the key is missing, so no cache or a failed read means off.
    var heatmaps = false
    var groups: [String: Bool] = [:]
    var disabledSignals: Set<String> = []
    /// Opt-in types the portal switched on. Empty when the key is missing: they stay off on doubt.
    var enabledSignals: Set<String> = []
    /// Automatic types the portal paused (for example at 90% of the plan).
    var pausedSignals: Set<String> = []

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
        if let number = object["heatmaps"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { config.heatmaps = number.boolValue }
        if let groups = object["groups"] as? [String: Any] {
            for name in groupKeys.keys { config.groups[name] = flag(groups[name]) }
        }
        if let list = object["disabledSignals"] as? [Any] {
            config.disabledSignals = Set(list.compactMap { $0 as? String }.filter { automaticTypes.contains($0) })
        }
        if let list = object["enabledSignals"] as? [Any] {
            config.enabledSignals = Set(list.compactMap { $0 as? String }.filter { optInTypes.contains($0) })
        }
        if let list = object["pausedSignals"] as? [Any] {
            config.pausedSignals = Set(list.compactMap { $0 as? String }.filter { automaticTypes.contains($0) })
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
    let codeHeatmaps: Bool
    let portalHeatmaps: Bool
    let disabledSignals: Set<String>
    let enabledSignals: Set<String>
    let pausedSignals: Set<String>
    let removedKeys: Set<String>

    init(options: PulseOptions, remote: PulseRemoteConfig) {
        portalScreenViews = remote.screenViews
        portalAutomatic = remote.automaticSignals
        codeScreenHook = options.automaticScreenViews
        codeAutomaticSignals = options.automaticSignals
        codeHeatmaps = options.captureHeatmaps
        portalHeatmaps = remote.heatmaps
        disabledSignals = remote.disabledSignals
        enabledSignals = remote.enabledSignals
        pausedSignals = remote.pausedSignals
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
        if disabledSignals.contains(type) || pausedSignals.contains(type) { return false }
        if type == PulseHeatmapMath.signalType { return heatmapsAllowed }
        if PulseRemoteConfig.optInTypes.contains(type) { return enabledSignals.contains(type) && portalAutomatic && codeAutomaticSignals }
        if type == PulseRemoteConfig.screenViewType { return portalAllowsScreenViews }
        if PulseRemoteConfig.automaticTypes.contains(type) { return portalAutomatic && codeAutomaticSignals }
        return true
    }
    /// Heatmaps need the portal switch, the code option, automatic signals on both sides and screen views the portal allows.
    var heatmapsAllowed: Bool { portalHeatmaps && codeHeatmaps && portalAutomatic && codeAutomaticSignals && portalAllowsScreenViews }
    /// Whether the automatic screen hook should be installed.
    var capturesScreens: Bool { codeScreenHook && portalAllowsScreenViews }
}

/// Signal types added by the automatic events.
internal enum PulseAutoTypes {
    static let appOpened = "pulse.app_opened"
    static let appBackgrounded = "pulse.app_backgrounded"
    static let deepLink = "pulse.deep_link"
    static let permissionChanged = "pulse.permission_changed"
}
