#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
import UIKit

/// Shows the screens in a window of its own, above the app: it works the same for SwiftUI and UIKit apps and never touches
/// the app's view hierarchy. The window goes away when the state is normal, and the app's key window comes back.
internal final class ControlUIKitPresenter: ControlPresenter {
    private var window: ControlWindow?
    private var host: ControlHostViewController?
    private var shown: ControlScreen?
    private weak var anchor: UIWindow?

    @_optimize(size) func show(_ screen: ControlScreen, actions: ControlActions) {
        if shown == screen, window != nil { return }
        guard let scene = Self.activeScene() else { return }
        let wasBlocking = shown.map(Self.blocks) ?? false
        let anchorWindow = anchor ?? scene.windows.first(where: { $0.isKeyWindow && !($0 is ControlWindow) })
            ?? scene.windows.first(where: { !($0 is ControlWindow) })
        anchor = anchorWindow
        let overlay: ControlWindow
        if let existing = window, existing.windowScene === scene { overlay = existing } else {
            window?.isHidden = true
            overlay = ControlWindow(windowScene: scene)
            overlay.windowLevel = UIWindow.Level.alert + 1
            overlay.backgroundColor = .clear
            let controller = ControlHostViewController(anchor: anchorWindow)
            overlay.rootViewController = controller
            window = overlay; host = controller
        }
        if let style = anchorWindow?.overrideUserInterfaceStyle, style != .unspecified { overlay.overrideUserInterfaceStyle = style }
        if let tint = anchorWindow?.tintColor { overlay.tintColor = tint }
        shown = screen
        host?.render(screen, actions: ControlActions(
            update: { [weak self] in actions.update(); self?.afterAlert() },
            dismiss: actions.dismiss, tryAgain: actions.tryAgain))
        let blocks = Self.blocks(screen)
        overlay.isBlocking = blocks
        overlay.isHidden = false
        PulseSdkUi.set(self, visible: true)
        if blocks, !wasBlocking || !overlay.isKeyWindow { overlay.makeKey() }
        UIAccessibility.post(notification: .screenChanged, argument: host?.focusTarget)
    }

    @_optimize(size) func hide() {
        PulseSdkUi.set(self, visible: false)
        guard let overlay = window else { shown = nil; return }
        let restore = overlay.isKeyWindow
        host?.clear()
        overlay.isHidden = true
        window = nil; host = nil; shown = nil
        if restore { anchor?.makeKey() }
    }

    /// A pressed Update closes the alert by itself; forget it so the next foreground shows it again if it still applies.
    @_optimize(size) private func afterAlert() {
        if shown?.primary.kind == .updateSuggested { hide() }
    }

    /// The suggested update is a system alert; announcements and blocks cover the app.
    @_optimize(size) static func blocks(_ screen: ControlScreen) -> Bool { screen.primary.kind != .maintenanceUpcoming }

    @_optimize(size) static func activeScene() -> UIWindowScene? {
        let application = (UIApplication.self as AnyObject).perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? UIApplication
        guard let scenes = application?.connectedScenes else { return nil }
        var inactive: UIWindowScene?
        for case let scene as UIWindowScene in scenes {
            if scene.activationState == .foregroundActive { return scene }
            if inactive == nil, scene.activationState == .foregroundInactive { inactive = scene }
        }
        return inactive
    }
}

/// Lets touches through when only a banner is showing.
internal final class ControlWindow: UIWindow {
    var isBlocking = true
    @_optimize(size) override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === rootViewController?.view && !isBlocking ? nil : hit
    }
}

internal final class ControlHostViewController: UIViewController {
    private weak var anchor: UIWindow?
    private var alert: UIAlertController?
    private(set) var focusTarget: UIView?

    @_optimize(size) init(anchor: UIWindow?) { self.anchor = anchor; super.init(nibName: nil, bundle: nil) }
    @_optimize(size) required init?(coder: NSCoder) { nil }
    @_optimize(size) override func loadView() { view = UIView(); view.backgroundColor = .clear }

    /// The app's own rules for rotation apply to the screens too, so a portrait-only app stays portrait.
    @_optimize(size) override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        anchor?.rootViewController?.supportedInterfaceOrientations ?? .all
    }
    override var shouldAutorotate: Bool { anchor?.rootViewController?.shouldAutorotate ?? true }

    @_optimize(size) func clear() {
        alert?.dismiss(animated: false)
        alert = nil
        view.subviews.forEach { $0.removeFromSuperview() }
        focusTarget = nil
    }

    @_optimize(size) func render(_ screen: ControlScreen, actions: ControlActions) {
        clear()
        let primary = screen.primary
        var banner: String?
        if primary.kind == .maintenanceUpcoming { banner = primary.body }
        else if let upcoming = screen.notices.first(where: { $0.kind == .maintenanceUpcoming }) { banner = upcoming.body }
        switch primary.kind {
        case .updateRequired, .versionBlocked, .maintenance: addFullScreen(screen, actions)
        case .announcement, .whatsNew: addCard(screen, actions)
        case .updateSuggested: presentAlert(screen, actions)
        case .maintenanceUpcoming, .normal: break
        }
        if let text = banner { addBanner(text, screen, actions, dismissible: true) }
        if primary.isTestBuild, [.updateRequired, .versionBlocked, .maintenance].contains(primary.kind) {
            addBanner(screen.testBanner, screen, actions, dismissible: false)
        }
    }

    @_optimize(size) private func addBanner(_ text: String, _ screen: ControlScreen, _ actions: ControlActions, dismissible: Bool) {
        let strip = ControlViews.banner(text, dismissLabel: dismissible ? screen.dismissText : nil, onDismiss: actions.dismiss)
        view.addSubview(strip)
        // The strip's background reaches the top edge; its text starts below the status bar.
        let inset = ControlViews.plain(.systemYellow, in: view)
        view.insertSubview(inset, belowSubview: strip)
        NSLayoutConstraint.activate([strip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                                     inset.topAnchor.constraint(equalTo: view.topAnchor),
                                     inset.bottomAnchor.constraint(equalTo: strip.topAnchor)]
                                    + ControlViews.sides(strip, view) + ControlViews.sides(inset, view))
        if focusTarget == nil { focusTarget = strip }
    }

    @_optimize(size) private func buttons(_ screen: ControlScreen, _ actions: ControlActions) -> [UIView] {
        let primary = screen.primary
        var result: [UIView] = []
        if primary.kind == .maintenance {
            result.append(ControlViews.button(primary.buttonText ?? screen.tryAgainText, prominent: true, action: actions.tryAgain))
        } else if let text = primary.buttonText, primary.url != nil {
            result.append(ControlViews.button(text, prominent: true, action: actions.update))
        }
        if primary.allowContinue {
            result.append(ControlViews.button(screen.continueText, prominent: result.isEmpty, action: actions.dismiss))
        }
        return result
    }

    @_optimize(size) private func addFullScreen(_ screen: ControlScreen, _ actions: ControlActions) {
        let background = ControlViews.plain(.systemBackground, in: view)
        background.accessibilityViewIsModal = true
        NSLayoutConstraint.activate(ControlViews.edges(background, view))
        let title = ControlViews.title(screen.primary.title)
        var views: [UIView] = [title, ControlViews.body(screen.primary.body)]
        views.append(contentsOf: buttons(screen, actions))
        let column = ControlViews.stack(views, spacing: 20)
        column.setCustomSpacing(32, after: views[1])
        let topInset: CGFloat = screen.primary.isTestBuild ? 44 : 0
        _ = ControlViews.scrollingColumn(content: column, in: background, maxWidth: 520, guide: view.safeAreaLayoutGuide,
                                         insets: UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0))
        focusTarget = title
    }

    @_optimize(size) private func addCard(_ screen: ControlScreen, _ actions: ControlActions) {
        let dim = ControlViews.plain(UIColor.black.withAlphaComponent(0.45), in: view)
        dim.accessibilityViewIsModal = true
        let card = ControlViews.plain(.secondarySystemGroupedBackground, in: dim)
        card.layer.cornerRadius = 20
        let primary = screen.primary
        let title = ControlViews.title(primary.title)
        title.font = .preferredFont(forTextStyle: .title2)
        var views: [UIView] = []
        if !primary.title.isEmpty { views.append(title) }
        if !primary.body.isEmpty { views.append(ControlViews.body(primary.body)) }
        let label = primary.buttonText ?? screen.continueText
        let open = primary.url
        views.append(ControlViews.button(label, prominent: true, action: {
            if open != nil { actions.update() }
            actions.dismiss()
        }))
        let column = ControlViews.stack(views, spacing: 16)
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        ControlViews.add(scroll, to: card)
        scroll.addSubview(column)
        let natural = scroll.heightAnchor.constraint(equalTo: scroll.contentLayoutGuide.heightAnchor)
        natural.priority = .defaultHigh
        let wide = card.widthAnchor.constraint(equalToConstant: 420)
        wide.priority = .defaultHigh
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate(ControlViews.edges(dim, view) + [
            card.centerXAnchor.constraint(equalTo: dim.centerXAnchor), card.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),
            card.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: 24),
            card.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -24),
            wide, natural, column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)]
            + ControlViews.edges(scroll, card, 24) + ControlViews.edges(column, guide: scroll.contentLayoutGuide))
        focusTarget = views.first
    }

    @_optimize(size) private func presentAlert(_ screen: ControlScreen, _ actions: ControlActions) {
        let primary = screen.primary
        let controller = UIAlertController(title: primary.title, message: primary.body, preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: screen.dismissText, style: .cancel) { _ in actions.dismiss() })
        if let text = primary.buttonText, primary.url != nil {
            let update = UIAlertAction(title: text, style: .default) { _ in actions.update() }
            controller.addAction(update)
            controller.preferredAction = update
        }
        alert = controller
        // The root view must be in a window before it can present.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.alert === controller, self.view.window != nil else { return }
            self.present(controller, animated: true)
        }
    }
}
#endif
