import Foundation

/// Turns a decision into the public states, with the texts in place.
internal final class ControlStates {
    private let rules: ControlRules?
    private let texts: ControlTexts
    private let platform: String
    private let now: Date
    /// iOS opens store links with the `itms-apps` scheme.
    private let openable: Bool

    @_optimize(size) init(rules: ControlRules?, texts: ControlTexts, platform: String, now: Date, openable: Bool) {
        self.rules = rules; self.texts = texts; self.platform = platform; self.now = now; self.openable = openable
    }

    @_optimize(size) func screen(for outcome: ControlOutcome) -> ControlScreen {
        let test = outcome.banners.contains(.testBuild)
        let main = mainState(outcome.main, allowContinue: outcome.allowContinue, test: test)
        let upcoming = outcome.banners.contains(.maintenanceUpcoming) ? upcomingState() : nil
        let card = outcome.card.flatMap(cardState)
        var primary = main, notices: [ControlState] = []
        if main.kind != .normal {
            notices = [card, upcoming].compactMap { $0 }
        } else if let card = card {
            primary = card; notices = [upcoming].compactMap { $0 }
        } else if let upcoming = upcoming {
            primary = upcoming
        }
        return ControlScreen(primary: primary, notices: notices, testBanner: texts.text("testBuild.banner"),
                             continueText: texts.text("continue"), dismissText: texts.text("updateSuggested.dismiss"),
                             tryAgainText: texts.text("maintenance.button"))
    }

    private var updateRule: ControlRules.UpdateRule? { rules?.update[platform] }

    @_optimize(size) private func storeURL() -> URL? {
        guard let text = updateRule?.storeUrl, let url = URL(string: text), let scheme = url.scheme,
              scheme == "https" || scheme == "http" || scheme.hasPrefix("itms") || scheme == "macappstore" else { return nil }
        if openable, scheme == "https", let host = url.host, host == "apps.apple.com" || host == "itunes.apple.com",
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.scheme = "itms-apps"
            return parts.url ?? url
        }
        return url
    }

    /// A text: the dashboard's custom text for the kind when set, else the built-in one.
    @_optimize(size) private func text(_ kind: String, _ field: String, window: ControlRules.Maintenance? = nil, version: String? = nil,
                      builtIn: String? = nil) -> String {
        let override = rules?.customText(kind, field == "button" ? "buttonText" : field)
        let template = override ?? builtIn ?? texts.text(kind + "." + field)
        return texts.fill(template, version: version, startsAt: window?.startsAt, endsAt: window?.endsAt, now: now)
    }

    /// One state of a kind that has the built-in title, body and button. `button` is false when there is nothing to press.
    @_optimize(size) private func make(_ kind: ControlState.Kind, _ key: String, url: URL? = nil, button: Bool, allow: Bool, test: Bool,
                      window: ControlRules.Maintenance? = nil, bodyKey: String? = nil) -> ControlState {
        let builtIn = bodyKey.map { texts.text($0) }
        return ControlState(kind: kind, title: text(key, "title"), body: text(key, "body", window: window, builtIn: builtIn),
                            buttonText: button ? text(key, "button") : nil, url: url, startsAt: window?.startsAt, endsAt: window?.endsAt,
                            allowContinue: allow, isTestBuild: test)
    }

    @_optimize(size) private func mainState(_ main: ControlMain, allowContinue: Bool, test: Bool) -> ControlState {
        let url = storeURL()
        switch main {
        case .normal: return .normal
        case .updateSuggested: return make(.updateSuggested, "updateSuggested", url: url, button: url != nil, allow: true, test: test)
        case .updateRequired: return make(.updateRequired, "updateRequired", url: url, button: url != nil, allow: allowContinue, test: test)
        case .versionBlocked:
            return make(.versionBlocked, "versionBlocked", url: url, button: url != nil, allow: allowContinue, test: test,
                        bodyKey: url == nil ? "versionBlocked.bodyNoUpdate" : nil)
        case .maintenance:
            return make(.maintenance, "maintenance", button: true, allow: allowContinue, test: test, window: rules?.maintenance)
        }
    }

    @_optimize(size) private func upcomingState() -> ControlState? {
        guard let window = rules?.maintenance else { return nil }
        return ControlState(kind: .maintenanceUpcoming, body: text("maintenanceUpcoming", "body", window: window,
                                                                    builtIn: texts.text("maintenanceUpcoming.banner")),
                            startsAt: window.startsAt, endsAt: window.endsAt)
    }

    @_optimize(size) private func cardState(_ card: ControlCard) -> ControlState? {
        switch card {
        case .announcement:
            guard let item = rules?.announcement else { return nil }
            let url = item.url.flatMap { URL(string: $0) }.flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil }
            return ControlState(kind: .announcement, title: texts.fill(item.title, now: now), body: texts.fill(item.body, now: now),
                                buttonText: texts.fill(item.buttonText ?? texts.text("announcement.button"), now: now), url: url)
        case .whatsNew:
            guard let item = rules?.whatsNew else { return nil }
            return ControlState(kind: .whatsNew, title: text("whatsNew", "title", version: item.version),
                                body: text("whatsNew", "body", version: item.version, builtIn: item.body),
                                buttonText: text("whatsNew", "button"), version: item.version)
        }
    }
}
