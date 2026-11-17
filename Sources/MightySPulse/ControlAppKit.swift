import Foundation
#if os(macOS)
import AppKit

/// macOS screens: a suggested update is an `NSAlert`; blocks, maintenance and cards are a panel that sits as a sheet on the
/// main window (or floats when there is no window). It has no close button and no Exit.
internal final class ControlAppKitPresenter: ControlPresenter {
    private var panel: NSPanel?
    private var sheetParent: NSWindow?
    private var alert: NSAlert?
    private var buttonTarget: AnyObject?
    private var shown: ControlScreen?

    @_optimize(size) func show(_ screen: ControlScreen, actions: ControlActions) {
        if shown == screen, panel != nil || alert != nil { return }
        hide()
        shown = screen
        let primary = screen.primary
        PulseSdkUi.set(self, visible: primary.kind != .normal && primary.kind != .maintenanceUpcoming)
        switch primary.kind {
        case .updateSuggested: showAlert(screen, actions)
        case .normal, .maintenanceUpcoming: break
        default: showPanel(screen, actions)
        }
    }

    @_optimize(size) func hide() {
        if let parent = sheetParent, let panel = panel { parent.endSheet(panel) }
        panel?.orderOut(nil)
        if let window = alert?.window {
            if let parent = window.sheetParent { parent.endSheet(window) } else { NSApp.abortModal() }
        }
        panel = nil; sheetParent = nil; alert = nil; shown = nil; buttonTarget = nil
        PulseSdkUi.set(self, visible: false)
    }

    @_optimize(size) private var parentWindow: NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    }

    @_optimize(size) private func showAlert(_ screen: ControlScreen, _ actions: ControlActions) {
        let primary = screen.primary
        let alert = NSAlert()
        alert.messageText = primary.title
        alert.informativeText = primary.body
        if let text = primary.buttonText, primary.url != nil { alert.addButton(withTitle: text) }
        alert.addButton(withTitle: screen.dismissText)
        self.alert = alert
        let hasUpdate = primary.buttonText != nil && primary.url != nil
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.alert = nil; self?.shown = nil
            if let me = self { PulseSdkUi.set(me, visible: false) }
            if hasUpdate && response == .alertFirstButtonReturn { actions.update() } else { actions.dismiss() }
        }
        if let parent = parentWindow { alert.beginSheetModal(for: parent, completionHandler: finish) }
        else { DispatchQueue.main.async { finish(alert.runModal()) } }
    }

    @_optimize(size) private func showPanel(_ screen: ControlScreen, _ actions: ControlActions) {
        let primary = screen.primary
        let panel = ControlPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 10), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.level = .modalPanel
        let title = NSTextField(wrappingLabelWithString: primary.title)
        title.font = .boldSystemFont(ofSize: 20); title.alignment = .center
        let body = NSTextField(wrappingLabelWithString: primary.body)
        body.alignment = .center; body.textColor = .secondaryLabelColor
        var views: [NSView] = []
        if screen.primary.isTestBuild { let banner = NSTextField(labelWithString: screen.testBanner); banner.alignment = .center; views.append(banner) }
        views += [title, body]
        let target = ControlButtonTarget()
        if primary.kind == .maintenance { views.append(target.button(primary.buttonText ?? screen.tryAgainText, actions.tryAgain)) }
        else if let text = primary.buttonText, primary.url != nil {
            let open = primary.url
            views.append(target.button(text, { actions.update(); if primary.kind == .announcement || primary.kind == .whatsNew, open != nil { actions.dismiss() } }))
        } else if primary.kind == .announcement || primary.kind == .whatsNew {
            views.append(target.button(primary.buttonText ?? screen.continueText, actions.dismiss))
        }
        if primary.allowContinue, primary.kind != .announcement, primary.kind != .whatsNew { views.append(target.button(screen.continueText, actions.dismiss)) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.spacing = 14; stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 28, right: 28)
        stack.setHuggingPriority(.required, for: .vertical)
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 440)])
        buttonTarget = target
        panel.contentView = content
        self.panel = panel
        if let parent = parentWindow { sheetParent = parent; parent.beginSheet(panel, completionHandler: nil) }
        else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }
}

/// The panel of the macOS screens; a named class so that clicks on it are recognized as the SDK's own.
internal final class ControlPanel: NSPanel {}

/// Keeps the actions of the panel's buttons alive for as long as the panel.
private final class ControlButtonTarget: NSObject {
    private var handlers: [() -> Void] = []
    @_optimize(size) func button(_ title: String, _ handler: @escaping () -> Void) -> NSButton {
        handlers.append(handler)
        let button = NSButton(title: title, target: self, action: #selector(fire(_:)))
        button.tag = handlers.count - 1
        button.bezelStyle = .rounded
        return button
    }
    @objc private func fire(_ sender: NSButton) { handlers[sender.tag]() }
}
#else
internal final class ControlAppKitPresenter: ControlPresenter {
    @_optimize(size) func show(_ screen: ControlScreen, actions: ControlActions) {}
    @_optimize(size) func hide() {}
}
#endif
