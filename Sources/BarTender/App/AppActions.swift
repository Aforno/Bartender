import AppKit

@MainActor
final class AppActions: NSObject {
    static let shared = AppActions()
    weak var model: AppModel?
    /// Set by the main window when it mounts so a closed window can be recreated.
    var openWindowAction: (() -> Void)?

    func installOpenWindowAction(_ action: @escaping () -> Void) {
        openWindowAction = action
    }

    /// Clears process-wide action state between tests.
    func resetForTesting() {
        model = nil
        openWindowAction = nil
    }

    @objc func toggleTimer(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender),
              let model,
              let applet = model.store.applet(id: id) else { return }
        model.runtime.toggleTimer(id: id, manifest: applet)
    }

    @objc func resetTimer(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender),
              let model,
              let applet = model.store.applet(id: id) else { return }
        model.runtime.resetTimer(id: id, manifest: applet)
    }

    @objc func openApplet(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        openMainWindow(selecting: id)
    }

    func openMainWindow(selecting id: UUID? = nil) {
        if let id {
            model?.selection = id
        }
        AppDelegate.prepareForMainWindow()
        if MainWindowRouter.openMainWindow() {
            return
        }
        if let openWindowAction {
            openWindowAction()
            return
        }
        NotificationCenter.default.post(name: .bartenderOpenMainWindow, object: nil)
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let settingsSelector = Selector(("showSettingsWindow:"))
        if NSApp.sendAction(settingsSelector, to: nil, from: nil) {
            return
        }
        let prefsSelector = Selector(("showPreferencesWindow:"))
        _ = NSApp.sendAction(prefsSelector, to: nil, from: nil)
    }

    @objc func toggleEnabled(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender),
              let model,
              let applet = model.store.applet(id: id) else { return }
        model.toggleEnabled(applet)
    }

    private func uuid(from sender: NSMenuItem) -> UUID? {
        guard let raw = sender.representedObject as? String else { return nil }
        return UUID(uuidString: raw)
    }
}
