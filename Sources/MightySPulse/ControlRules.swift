import Foundation

/// The rules of App Control format 1, as the server sends them. Parsing never throws: a body that is not a JSON object,
/// that is too large, or that holds a container of an unknown type gives nil; unknown keys are ignored and a scalar of the
/// wrong type is treated as missing, so doubt never turns into a lock.
internal final class ControlRules {
    static let maxBytes = 65536

    // Final classes, not structs, each read straight from its JSON object: a class needs no value witness functions and no
    // field by field copies, which keeps the SDK small in the app binary (criterion 14). Read once, never changed.
    final class UpdateRule {
        let min: String?, latest: String?, mode: String?, storeVersion: String?, storeUrl: String?
        @_optimize(size) fileprivate init(_ item: [String: Any]) {
            min = text(item["min"]); latest = text(item["latest"]); mode = text(item["mode"])
            storeVersion = text(item["storeVersion"]); storeUrl = text(item["storeUrl"])
        }
    }
    /// The update rules by platform key, read when asked (one platform is ever asked for).
    struct UpdateRules {
        fileprivate let raw: [String: Any]
        subscript(platform: String) -> UpdateRule? { dict(raw[platform]).map(UpdateRule.init) }
    }
    final class Blocked {
        let version: String, platforms: [String]?, allowContinue: Bool
        @_optimize(size) fileprivate init?(_ item: [String: Any]) {
            guard let version = text(item["version"]) else { return nil }
            self.version = version; platforms = platformList(item["platforms"]); allowContinue = bool(item["allowContinue"])
        }
    }
    final class Maintenance {
        let startsAt: Date, endsAt: Date, headsUpMinutes: Int, exemptAboveStore: Bool, platforms: [String]?
        @_optimize(size) fileprivate init?(_ item: [String: Any]) {
            guard let start = time(item["startsAt"]), let end = time(item["endsAt"]) else { return nil }
            startsAt = start; endsAt = end; headsUpMinutes = max(0, integer(item["headsUpMinutes"]) ?? 0)
            exemptAboveStore = bool(item["exemptAboveStore"]); platforms = platformList(item["platforms"])
        }
    }
    final class Announcement {
        let id: String, title: String, body: String, url: String?, buttonText: String?, until: Date, platforms: [String]?
        @_optimize(size) fileprivate init?(_ item: [String: Any]) {
            guard let id = text(item["id"]), let until = time(item["until"]) else { return nil }
            self.id = id; self.until = until; title = text(item["title"]) ?? ""; body = text(item["body"]) ?? ""
            url = text(item["url"]); buttonText = text(item["buttonText"]); platforms = platformList(item["platforms"])
        }
    }
    final class WhatsNew {
        let version: String, body: String
        @_optimize(size) fileprivate init?(_ item: [String: Any]) {
            guard let version = text(item["version"]) else { return nil }
            self.version = version; body = text(item["body"]) ?? ""
        }
    }

    private(set) var format = 1
    private(set) var version = 0
    private(set) var off = false
    private(set) var update = UpdateRules(raw: [:])
    private(set) var blocked: [Blocked] = []
    private(set) var maintenance: Maintenance?
    private(set) var announcement: Announcement?
    private(set) var whatsNew: WhatsNew?
    /// The dashboard's custom texts: kind to an object with `title`, `body` and `buttonText`.
    private var customTexts: [String: Any] = [:]
    private(set) var disabledSdkVersions: [String] = []

    private init() {}

    /// The dashboard's custom text for a kind (`updateRequired`, ...) and field (`title`, `body`, `buttonText`), if set.
    @_optimize(size) func customText(_ kind: String, _ field: String) -> String? { text(dict(customTexts[kind])?[field]) }

    @_optimize(size) static func parse(_ data: Data?) -> ControlRules? {
        guard let data = data, !data.isEmpty, data.count <= maxBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(object: object)
    }

    @_optimize(size) static func parse(object: [String: Any]) -> ControlRules? {
        let rules = ControlRules()
        guard let format = integer(object["format"]) else { return nil }
        rules.format = format
        rules.version = integer(object["version"]) ?? 0
        rules.off = bool(object["off"])
        // A container of the wrong type means the body is not format 1 as we know it: keep the last known state.
        for key in ["update", "texts", "maintenance", "announcement", "whatsNew"] where !isMissing(object[key]) && dict(object[key]) == nil { return nil }
        for key in ["blocked", "disabledSdkVersions"] where !isMissing(object[key]) && list(object[key]) == nil { return nil }
        rules.update = UpdateRules(raw: dict(object["update"]) ?? [:])
        rules.blocked = (list(object["blocked"]) ?? []).compactMap { dict($0).flatMap(Blocked.init) }
        rules.maintenance = dict(object["maintenance"]).flatMap(Maintenance.init)
        rules.announcement = dict(object["announcement"]).flatMap(Announcement.init)
        rules.whatsNew = dict(object["whatsNew"]).flatMap(WhatsNew.init)
        rules.customTexts = dict(dict(object["texts"])?["custom"]) ?? [:]
        rules.disabledSdkVersions = (list(object["disabledSdkVersions"]) ?? []).compactMap { text($0) }
        return rules
    }

    /// Whether a rule limited to `platforms` (nil means every platform) covers `platform`.
    @_optimize(size) static func covers(_ platforms: [String]?, _ platform: String) -> Bool { platforms?.contains(platform) ?? true }
}

// MARK: Scalars (small, never inlined: the SDK stays light)

@_optimize(size) @inline(never) fileprivate func isMissing(_ value: Any?) -> Bool { value == nil || value is NSNull }
@_optimize(size) @inline(never) fileprivate func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
@_optimize(size) @inline(never) fileprivate func list(_ value: Any?) -> [Any]? { value as? [Any] }
@_optimize(size) @inline(never) fileprivate func isBool(_ value: Any?) -> Bool { (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
@_optimize(size) @inline(never) fileprivate func bool(_ value: Any?) -> Bool { isBool(value) ? (value as? NSNumber)?.boolValue ?? false : false }
@_optimize(size) @inline(never) fileprivate func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !isBool(value), number.doubleValue.isFinite,
          number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e9 else { return nil }
    return number.intValue
}
@_optimize(size) @inline(never) fileprivate func text(_ value: Any?) -> String? { value as? String }
@_optimize(size) @inline(never) fileprivate func platformList(_ value: Any?) -> [String]? { list(value)?.compactMap { text($0) } }
@_optimize(size) @inline(never) fileprivate func time(_ value: Any?) -> Date? { (value as? String).flatMap(ControlClock.parse) }

internal enum ControlClock {
    @_optimize(size) static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
