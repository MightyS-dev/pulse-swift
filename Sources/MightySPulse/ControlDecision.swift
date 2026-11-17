import Foundation

/// Everything the decision needs besides the rules.
internal struct ControlInput {
    var now: Date
    var platform = "ios"
    var appVersion = ""
    var debug = false
    /// `"<sdkName>@<sdkVersion>"` exactly as the SDK sends it.
    var sdk = ""
    var fromCache = false
    var cacheAgeHours: Double = 0
    var updateReturns = 0
    var playUpdateNotAvailable = false
    var canBuildStoreLink = true
    var suggestDismissedHoursAgo: Double?
    var shownAnnouncements: [String] = []
    var justUpdated = false
    var whatsNewShown = false
}

internal enum ControlMain: String { case normal, updateSuggested, updateRequired, versionBlocked, maintenance }
internal enum ControlBanner: String { case testBuild, maintenanceUpcoming }
internal enum ControlCard: String { case whatsNew, announcement }

/// One main state, whether the screen lets the user continue, banners and at most one card.
internal struct ControlOutcome: Equatable {
    var main: ControlMain
    var allowContinue: Bool
    var banners: [ControlBanner]
    var card: ControlCard?
    static let normal = ControlOutcome(main: .normal, allowContinue: true, banners: [], card: nil)
}

/// The App Control decision. Doubt always means no lock: an incomparable version is never below a minimum and never
/// blocked, locking rules from a cache older than 30 days are ignored, and the loop guard turns a required update into a
/// suggestion whenever there is no way out. Checked by the shared `decision-cases.json`.
internal enum ControlDecision {
    static let cacheLockHours: Double = 30 * 24, cacheMaintenanceHours: Double = 72, suggestQuietHours: Double = 24
    static let updateReturnsLimit = 3

    @_optimize(size) static func decide(_ rules: ControlRules?, _ input: ControlInput) -> ControlOutcome {
        guard let rules = rules, rules.format == 1, !rules.off, !rules.disabledSdkVersions.contains(input.sdk) else { return .normal }
        let staleLocks = input.fromCache && input.cacheAgeHours > cacheLockHours
        let platformRule = rules.update[input.platform]
        let storeVersion = platformRule?.storeVersion
        let aboveStore = storeVersion != nil && ControlVersion.compare(input.appVersion, storeVersion) == 1
        var banners: [ControlBanner] = []
        var main = ControlMain.normal
        var allowContinue = true

        if let m = rules.maintenance, ControlRules.covers(m.platforms, input.platform) {
            let inWindow = m.startsAt <= input.now && input.now < m.endsAt
                && (!input.fromCache || input.now < m.startsAt.addingTimeInterval(cacheMaintenanceHours * 3600))
            if inWindow && !(m.exemptAboveStore && aboveStore) { main = .maintenance; allowContinue = false }
            if input.now < m.startsAt && m.startsAt.addingTimeInterval(-Double(m.headsUpMinutes) * 60) <= input.now {
                banners.append(.maintenanceUpcoming)
            }
        }
        if main == .normal, !staleLocks {
            for entry in rules.blocked where ControlVersion.compare(input.appVersion, entry.version) == 0
                && ControlRules.covers(entry.platforms, input.platform) {
                main = .versionBlocked; allowContinue = entry.allowContinue; break
            }
        }
        if main == .normal, let rule = platformRule, let min = rule.min,
           ControlVersion.compare(input.appVersion, min) == -1, !aboveStore {
            if rule.mode == "required" && !staleLocks {
                let noWayOut = (storeVersion != nil && (ControlVersion.compare(storeVersion, input.appVersion) ?? 1) <= 0)
                    || input.updateReturns >= updateReturnsLimit || input.playUpdateNotAvailable
                    || (rule.storeUrl == nil && !input.canBuildStoreLink)
                if noWayOut { main = .updateSuggested } else { main = .updateRequired; allowContinue = false }
            } else if rule.mode == "suggested" {
                main = .updateSuggested
            }
        }
        if main == .normal, let rule = platformRule, rule.mode == "suggested", let latest = rule.latest,
           ControlVersion.compare(input.appVersion, latest) == -1 { main = .updateSuggested }
        if main == .updateSuggested, let hours = input.suggestDismissedHoursAgo, hours < suggestQuietHours { main = .normal }
        if main == .updateSuggested { allowContinue = true }
        if input.debug, main == .maintenance || main == .versionBlocked || main == .updateRequired {
            banners.append(.testBuild); allowContinue = true
        }
        var card: ControlCard?
        if input.justUpdated, !input.whatsNewShown, let w = rules.whatsNew, ControlVersion.compare(input.appVersion, w.version) == 0 {
            card = .whatsNew
        } else if let a = rules.announcement, input.now < a.until, ControlRules.covers(a.platforms, input.platform),
                  !input.shownAnnouncements.contains(a.id) {
            card = .announcement
        }
        return ControlOutcome(main: main, allowContinue: allowContinue, banners: banners, card: card)
    }
}
