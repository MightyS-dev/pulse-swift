import Foundation

/// The last good answer: the body as received, the ETag and the time of the answer. One file per app, named with the first
/// 16 hex characters of the SHA-256 of the app key. Separate from the settings cache of `/api/v1/config`.
internal final class ControlCache {
    let body: Data
    let etag: String?
    let at: Date

    @_optimize(size) init(body: Data, etag: String?, at: Date) { self.body = body; self.etag = etag; self.at = at }

    @_optimize(size) static func fileName(for key: String) -> String { "control-" + String(PulseHash.hex(key).prefix(16)) }

    @_optimize(size) func encoded() -> Data? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        var object: [String: Any] = ["body": text, "at": at.timeIntervalSince1970]
        if let etag = etag { object["etag"] = etag }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    @_optimize(size) static func decode(_ data: Data?) -> ControlCache? {
        guard let data = data, !data.isEmpty, data.count <= 262144,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = object["body"] as? String, let at = (object["at"] as? NSNumber)?.doubleValue, at.isFinite else { return nil }
        return ControlCache(body: Data(text.utf8), etag: object["etag"] as? String, at: Date(timeIntervalSince1970: at))
    }
}

/// What this device remembers about App Control: which cards were shown, a dismissed suggestion, how often the user came
/// back from the store on the same version, and when the app was last updated. Never leaves the device.
internal final class ControlLocal {
    var lastVersion: String?
    var updatedTo: String?
    var updatedAt: Double?
    var whatsNewShown: [String] = []
    var shownAnnouncements: [String] = []
    var dismissedVersion: String?
    var dismissedAt: Double?
    var returnsVersion: String?
    var returns = 0
    var pendingUpdate: String?

    static let justUpdatedDays: Double = 7
    @_optimize(size) static func fileName(for key: String) -> String { "control-local-" + String(PulseHash.hex(key).prefix(16)) }

    /// Plain dictionary coding: much smaller in the binary than a synthesized `Codable`.
    @_optimize(size) static func decode(_ data: Data?) -> ControlLocal {
        let value = ControlLocal()
        guard let data = data, data.count <= 65536,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return value }
        func text(_ key: String) -> String? { object[key] as? String }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        func texts(_ key: String) -> [String] { (object[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
        value.lastVersion = text("lastVersion")
        value.updatedTo = text("updatedTo")
        value.updatedAt = number("updatedAt")
        value.whatsNewShown = texts("whatsNewShown")
        value.shownAnnouncements = texts("shownAnnouncements")
        value.dismissedVersion = text("dismissedVersion")
        value.dismissedAt = number("dismissedAt")
        value.returnsVersion = text("returnsVersion")
        value.returns = (object["returns"] as? NSNumber)?.intValue ?? 0
        value.pendingUpdate = text("pendingUpdate")
        return value
    }
    @_optimize(size) func encoded() -> Data? {
        var object: [String: Any] = ["whatsNewShown": whatsNewShown, "shownAnnouncements": shownAnnouncements, "returns": returns]
        if let v = lastVersion { object["lastVersion"] = v }
        if let v = updatedTo { object["updatedTo"] = v }
        if let v = updatedAt { object["updatedAt"] = v }
        if let v = dismissedVersion { object["dismissedVersion"] = v }
        if let v = dismissedAt { object["dismissedAt"] = v }
        if let v = returnsVersion { object["returnsVersion"] = v }
        if let v = pendingUpdate { object["pendingUpdate"] = v }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Notes the running app version: a change from the last one seen means the app was just updated.
    @_optimize(size) func noteVersion(_ version: String, now: Date) {
        if let last = lastVersion, last != version { updatedTo = version; updatedAt = now.timeIntervalSince1970 }
        lastVersion = version
        if returnsVersion != version { returnsVersion = nil; returns = 0 }
    }
    @_optimize(size) func justUpdated(version: String, now: Date) -> Bool {
        guard updatedTo == version, let at = updatedAt else { return false }
        return now.timeIntervalSince1970 - at < Self.justUpdatedDays * 86400
    }
    @_optimize(size) func updateReturns(version: String) -> Int { returnsVersion == version ? returns : 0 }
    @_optimize(size) func dismissedHoursAgo(version: String, now: Date) -> Double? {
        guard dismissedVersion == version, let at = dismissedAt else { return nil }
        return max(0, (now.timeIntervalSince1970 - at) / 3600)
    }
    @_optimize(size) func markAnnouncement(_ id: String) {
        guard !shownAnnouncements.contains(id) else { return }
        shownAnnouncements.append(id)
        if shownAnnouncements.count > 50 { shownAnnouncements.removeFirst(shownAnnouncements.count - 50) }
    }
    @_optimize(size) func markWhatsNew(_ version: String) {
        guard !whatsNewShown.contains(version) else { return }
        whatsNewShown.append(version)
        if whatsNewShown.count > 20 { whatsNewShown.removeFirst(whatsNewShown.count - 20) }
    }
}
