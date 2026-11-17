import Foundation

/// How App Control behaves. Set it with ``PulseOptions/control``.
public enum PulseControlMode {
    /// Checks the rules and shows the built-in screens (update, block, maintenance, announcement). The default.
    case automatic
    /// Checks the rules and keeps ``PulseControl/state`` current, but shows nothing. You draw the screens yourself.
    case manual
    /// No App Control at all: no network request, and the state is always ``ControlState/Kind/normal``.
    case off
}

/// What App Control wants the app to show right now.
///
/// The texts are ready to show: the built-in language is chosen from the app's languages, then the system's, and the
/// custom texts from the dashboard replace the defaults.
public struct ControlState: Equatable {
    /// The kind of screen.
    public enum Kind: String, Equatable {
        /// Nothing to show.
        case normal
        /// A newer version is available and the user may continue without it.
        case updateSuggested
        /// This version is too old and must be updated.
        case updateRequired
        /// This exact version is blocked.
        case versionBlocked
        /// The service is down for maintenance.
        case maintenance
        /// A maintenance window starts soon (a banner; it never locks).
        case maintenanceUpcoming
        /// A message from the app owner (a card).
        case announcement
        /// What changed in the version the user just installed (a card).
        case whatsNew
    }

    /// The kind of screen.
    public var kind: Kind { box.kind }
    /// The headline, empty when the kind has none.
    public var title: String { box.title }
    /// The message.
    public var body: String { box.body }
    /// The label of the main button, or `nil` when there is no useful action (for example no store link).
    public var buttonText: String? { box.buttonText }
    /// Where the main button goes: the store page for updates, the link of an announcement, otherwise `nil`.
    public var url: URL? { box.url }
    /// Start of the maintenance window, for maintenance kinds.
    public var startsAt: Date? { box.startsAt }
    /// End of the maintenance window, for maintenance kinds.
    public var endsAt: Date? { box.endsAt }
    /// The app version a ``Kind/whatsNew`` card is about.
    public var version: String? { box.version }
    /// `true` when the user may close the screen (`false` for a screen that blocks the app).
    public var allowContinue: Bool { box.allowContinue }
    /// `true` in a debug build: every blocking screen then shows a "Test build" banner and a Continue button.
    public var isTestBuild: Bool { box.isTestBuild }

    /// The values live in one immutable object: a copy of the state is one reference, not ten fields, which keeps the SDK
    /// small in the app binary (criterion 14). The state stays a value: nothing can change it after it is made.
    private final class Box {
        let kind: Kind, title: String, body: String, buttonText: String?, url: URL?
        let startsAt: Date?, endsAt: Date?, version: String?, allowContinue: Bool, isTestBuild: Bool
        @_optimize(size) init(kind: Kind, title: String, body: String, buttonText: String?, url: URL?, startsAt: Date?, endsAt: Date?,
             version: String?, allowContinue: Bool, isTestBuild: Bool) {
            self.kind = kind; self.title = title; self.body = body; self.buttonText = buttonText; self.url = url
            self.startsAt = startsAt; self.endsAt = endsAt; self.version = version
            self.allowContinue = allowContinue; self.isTestBuild = isTestBuild
        }
    }
    private let box: Box

    @_optimize(size) internal init(kind: Kind, title: String = "", body: String = "", buttonText: String? = nil, url: URL? = nil,
                  startsAt: Date? = nil, endsAt: Date? = nil, version: String? = nil, allowContinue: Bool = true,
                  isTestBuild: Bool = false) {
        box = Box(kind: kind, title: title, body: body, buttonText: buttonText, url: url, startsAt: startsAt, endsAt: endsAt,
                  version: version, allowContinue: allowContinue, isTestBuild: isTestBuild)
    }

    @_optimize(size) public static func == (a: ControlState, b: ControlState) -> Bool {
        let x = a.box, y = b.box
        return x === y || (x.kind == y.kind && x.title == y.title && x.body == y.body && x.buttonText == y.buttonText
                           && x.url == y.url && x.startsAt == y.startsAt && x.endsAt == y.endsAt && x.version == y.version
                           && x.allowContinue == y.allowContinue && x.isTestBuild == y.isTestBuild)
    }

    /// The state when there is nothing to show.
    public static let normal = ControlState(kind: .normal)
}

/// What the built-in screens need besides the state: the other notices and the labels of the small buttons. A final class
/// with a hand written `==` (no value witnesses, no synthesized comparison): smaller in the app binary.
internal final class ControlScreen: Equatable {
    let primary: ControlState
    /// The banner or card that is not the primary state.
    let notices: [ControlState]
    let testBanner: String
    let continueText: String
    let dismissText: String
    let tryAgainText: String

    @_optimize(size) init(primary: ControlState, notices: [ControlState], testBanner: String, continueText: String, dismissText: String,
         tryAgainText: String) {
        self.primary = primary; self.notices = notices; self.testBanner = testBanner
        self.continueText = continueText; self.dismissText = dismissText; self.tryAgainText = tryAgainText
    }

    @_optimize(size) static func == (a: ControlScreen, b: ControlScreen) -> Bool {
        a === b || (a.primary == b.primary && a.notices == b.notices && a.testBanner == b.testBanner
                    && a.continueText == b.continueText && a.dismissText == b.dismissText && a.tryAgainText == b.tryAgainText)
    }
}
