import AppKit
import SwiftUI

/// Creates one `NSStatusItem` per enabled applet (SwiftUI SceneBuilder cannot ForEach MenuBarExtra).
@MainActor
final class StatusItemManager: ObservableObject {
    static let maximumIndividualItems = 8

    private final class ItemBox {
        let item: NSStatusItem
        var appletID: UUID
        var menu: NSMenu

        init(item: NSStatusItem, appletID: UUID, menu: NSMenu) {
            self.item = item
            self.appletID = appletID
            self.menu = menu
        }
    }

    private weak var model: AppModel?
    private var boxes: [UUID: ItemBox] = [:]

    func attach(model: AppModel) {
        self.model = model
        rebuild()
    }

    /// Rebuilds status items from the enabled applet list.
    ///
    /// Pass the value published by `AppModel.$enabledApplets`: `@Published` emits in
    /// `willSet`, so re-reading `model.enabledApplets` inside the `onReceive` callback
    /// returns the previous list and leaves the status items one toggle behind.
    func rebuild(enabled currentEnabled: [AppletManifest]? = nil) {
        guard let model else { return }
        let enabled = Self.individuallyVisible(from: currentEnabled ?? model.enabledApplets)
        let enabledIDs = Set(enabled.map(\.id))

        for id in boxes.keys where !enabledIDs.contains(id) {
            if let box = boxes.removeValue(forKey: id) {
                NSStatusBar.system.removeStatusItem(box.item)
            }
        }

        for applet in enabled {
            if boxes[applet.id] == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                let menu = NSMenu()
                menu.autoenablesItems = false
                item.menu = menu
                boxes[applet.id] = ItemBox(item: item, appletID: applet.id, menu: menu)
            }
            refresh(appletID: applet.id)
        }
    }

    static func individuallyVisible(from enabled: [AppletManifest]) -> [AppletManifest] {
        Array(enabled.prefix(maximumIndividualItems))
    }

    func refreshAll() {
        for id in boxes.keys {
            refresh(appletID: id)
        }
    }

    /// Uses the value delivered by `@Published` directly. Its publisher emits in
    /// `willSet`, so re-reading `model.runtime.snapshots` in that callback would
    /// refresh every status item with the previous value until the next poll.
    func refreshAll(snapshots: [UUID: AppletSnapshot]) {
        for id in boxes.keys {
            refresh(appletID: id, snapshot: snapshots[id])
        }
    }

    func refresh(appletID: UUID) {
        refresh(appletID: appletID, snapshot: model?.runtime.snapshots[appletID])
    }

    private func refresh(appletID: UUID, snapshot currentSnapshot: AppletSnapshot?) {
        guard let model,
              let box = boxes[appletID],
              let applet = model.store.applet(id: appletID) else { return }

        let snapshot = currentSnapshot ?? .placeholder(for: applet)
        if let button = box.item.button {
            let title = TitleRenderer.shortMenuTitle(snapshot.title)
            let image = NSImage(
                systemSymbolName: applet.iconSystemName,
                accessibilityDescription: applet.name
            )
            image?.isTemplate = true
            button.image = image
            button.title = " " + title
            button.imagePosition = .imageLeading
            button.toolTip = "\(applet.name): \(snapshot.statusText)"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(headerItem(applet.name))
        menu.addItem(disabledItem(TitleRenderer.shortMenuTitle(snapshot.statusText)))
        menu.addItem(.separator())

        for line in snapshot.detailLines.prefix(5) {
            menu.addItem(disabledItem(TitleRenderer.shortMenuTitle(line)))
        }

        if applet.kind == .timer || applet.kind == .countdown {
            menu.addItem(.separator())
            let toggle = NSMenuItem(
                title: snapshot.isRunning ? "Pause" : "Start",
                action: #selector(AppActions.toggleTimer(_:)),
                keyEquivalent: ""
            )
            toggle.target = AppActions.shared
            toggle.representedObject = appletID.uuidString
            menu.addItem(toggle)

            let reset = NSMenuItem(
                title: "Reset",
                action: #selector(AppActions.resetTimer(_:)),
                keyEquivalent: ""
            )
            reset.target = AppActions.shared
            reset.representedObject = appletID.uuidString
            menu.addItem(reset)
        }

        menu.addItem(.separator())

        let open = NSMenuItem(
            title: "Open in Bar Tender",
            action: #selector(AppActions.openApplet(_:)),
            keyEquivalent: ""
        )
        open.target = AppActions.shared
        open.representedObject = appletID.uuidString
        menu.addItem(open)

        let enableTitle = applet.enabled ? "Disable" : "Enable"
        let enable = NSMenuItem(
            title: enableTitle,
            action: #selector(AppActions.toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enable.target = AppActions.shared
        enable.representedObject = appletID.uuidString
        menu.addItem(enable)

        box.menu = menu
        box.item.menu = menu
    }

    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: TitleRenderer.shortMenuTitle(title), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

@MainActor
final class AppActions: NSObject {
    static let shared = AppActions()
    weak var model: AppModel?
    var openWindowAction: (() -> Void)?

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
        guard let id = uuid(from: sender), let model else { return }
        model.selection = id
        NotificationCenter.default.post(name: .barTenderOpenMainWindow, object: id.uuidString)
        openWindowAction?()
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
        }
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
