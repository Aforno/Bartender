import AppKit
import Combine

/// Creates one `NSStatusItem` per enabled applet (SwiftUI SceneBuilder cannot ForEach MenuBarExtra).
@MainActor
final class StatusItemManager: ObservableObject {
    static let maximumIndividualItems = 8

    /// Initial attach defers the first registration to avoid racing Control
    /// Center's teardown of the previous instance (macOS 26). Tests set this
    /// to zero so creation stays synchronous.
    static var initialRegistrationDelay: TimeInterval = 0.75

    private weak var model: AppModel?
    private var items: [UUID: NSStatusItem] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Whether `attach(model:)` has installed store/runtime subscriptions.
    var isAttached: Bool { model != nil && !cancellables.isEmpty }

    /// Live AppKit status items currently managed (tests / diagnostics).
    var managedItemCount: Int { items.count }

    /// Applet IDs that currently have an individual status item.
    var managedAppletIDs: Set<UUID> { Set(items.keys) }

    func attach(model: AppModel) {
        if self.model === model, !cancellables.isEmpty {
            // Already attached: reconcile in place. Destroying and recreating
            // the AppKit items here strands them without a menu-bar slot.
            rebuild(enabled: model.store.enabledApplets)
            refreshAll(snapshots: model.runtime.snapshots)
            return
        }

        self.model = model
        cancellables.removeAll()

        // A lower cap frees menu-bar space; rebuilding here keeps the live
        // items in sync with the preference without touching the main window.
        model.preferences.$maximumMenuBarItems
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let model = self?.model else { return }
                self?.rebuild(enabled: model.store.enabledApplets)
            }
            .store(in: &cancellables)

        model.store.$applets
            .dropFirst()
            .map { $0.filter(\.enabled) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.rebuild(enabled: enabled)
            }
            .store(in: &cancellables)

        model.runtime.$snapshots
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots in
                self?.refreshAll(snapshots: snapshots)
            }
            .store(in: &cancellables)

        // macOS 26 Control Center tears down the previous instance's status
        // displayables asynchronously after the process exits. Registering
        // immediately races that teardown and often lands the item in CC's
        // blocked/offscreen state for the whole session; a short delay lets
        // the system finish before the new host is registered.
        let initialBuild = { [weak self] in
            guard let self, let model = self.model else { return }
            self.rebuild(enabled: model.store.enabledApplets)
            self.refreshAll(snapshots: model.runtime.snapshots)
        }
        let delay = Self.initialRegistrationDelay
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                initialBuild()
            }
        } else {
            initialBuild()
        }
        let enabled = model.store.enabledApplets
        AppLog.menuBar.info(
            "Attached status item manager; \(enabled.count, privacy: .public) of \(model.store.applets.count, privacy: .public) applets enabled, cap \(Self.maximumIndividualItems, privacy: .public)"
        )
    }

    /// Effective per-applet cap, derived from the user preference (clamped).
    private var individualItemLimit: Int {
        guard let model else { return Self.maximumIndividualItems }
        return min(max(model.preferences.maximumMenuBarItems, 1), Self.maximumIndividualItems)
    }

    /// Reconciles the live AppKit items with the exact value emitted by the store.
    /// Consuming the publisher value avoids `@Published`'s `willSet` timing trap.
    func rebuild(enabled currentEnabled: [AppletManifest], recreate: Bool = false) {
        guard model != nil else { return }
        let limit = individualItemLimit
        let enabled = Self.individuallyVisible(from: currentEnabled, limit: limit)
        let enabledIDs = Set(enabled.map(\.id))

        if recreate {
            for id in items.keys {
                if let item = items.removeValue(forKey: id) {
                    NSStatusBar.system.removeStatusItem(item)
                    AppLog.menuBar.info("Removed status item for \(id, privacy: .public)")
                }
            }
        } else {
            for id in items.keys where !enabledIDs.contains(id) {
                if let item = items.removeValue(forKey: id) {
                    NSStatusBar.system.removeStatusItem(item)
                    let name = model?.store.applet(id: id)?.name ?? "removed applet"
                    AppLog.menuBar.info("Removed status item for \(name, privacy: .public)")
                }
            }
        }

        for applet in enabled {
            if items[applet.id] == nil {
                items[applet.id] = makeStatusItem(for: applet.id)
                AppLog.menuBar.info("Created status item for \(applet.name, privacy: .public)")
            }
            // Enabled means present in the menu bar. Reassert after AppKit may
            // restore a prior "removed from menu bar" / overflow identity.
            forceVisible(items[applet.id])
            refresh(appletID: applet.id)
        }

        if enabled.count < currentEnabled.count {
            AppLog.menuBar.info(
                "Menu bar cap (\(limit, privacy: .public)) reached: \(currentEnabled.count - enabled.count, privacy: .public) enabled applet(s) stay in the manager menu only"
            )
        }

        let visibleCount = items.values.lazy.filter(\.isVisible).count
        let zeroSized = items.values.filter { item in
            guard let frame = item.button?.window?.frame else { return true }
            return frame.width < 1 || frame.height < 1
        }.count
        AppLog.menuBar.info(
            "Reconciled \(self.items.count, privacy: .public) status items; \(visibleCount, privacy: .public) visible; \(zeroSized, privacy: .public) zero-sized windows"
        )
    }

    static func individuallyVisible(from enabled: [AppletManifest], limit: Int = maximumIndividualItems) -> [AppletManifest] {
        Array(enabled.prefix(max(0, limit)))
    }

    static func autosaveName(for appletID: UUID) -> String {
        // v2: unique per-applet identity. macOS 26 Control Center persists
        // hidden/blocked state keyed by this name; a fresh name dodges that.
        "io.github.aforno.bartender.v2.applet.\(appletID.uuidString.lowercased())"
    }

    /// Resets persisted “hidden from menu bar” flags for this process’s
    /// status items. Called at launch before creating any `NSStatusItem`s.
    static func clearPoisonedVisibilityDefaults() {
        let defaults = UserDefaults.standard
        let persistent = defaults.dictionaryRepresentation()
        var cleared = 0
        for key in persistent.keys where key.hasPrefix("NSStatusItem Visible") {
            // Only reset entries that hide an item.
            if (persistent[key] as? NSNumber)?.boolValue == false {
                defaults.set(true, forKey: key)
                cleared += 1
            }
        }
        if cleared > 0 {
            AppLog.menuBar.info(
                "Reset \(cleared, privacy: .public) hidden NSStatusItem visibility defaults"
            )
        }
    }

    private func makeStatusItem(for appletID: UUID) -> NSStatusItem {
        // Unique autosave name when owning multiple items. Persisted visibility
        // must be written BEFORE assigning `autosaveName`: AppKit restores the
        // stored state at assignment time, so a stale `false` (user drag-off,
        // menu-bar manager, VisibleCC=0) would otherwise hide the new item.
        let name = Self.autosaveName(for: appletID)
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(name)")
        UserDefaults.standard.set(true, forKey: "NSStatusItem VisibleCC \(name)")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name
        forceVisible(item)
        let menu = NSMenu()
        menu.autoenablesItems = false
        item.menu = menu
        return item
    }

    private func forceVisible(_ item: NSStatusItem?) {
        guard let item else { return }
        item.isVisible = true
        // Re-assert variable length in case AppKit collapsed a restored item to 0.
        if item.length == 0 {
            item.length = NSStatusItem.variableLength
        }
        if let button = item.button {
            button.isHidden = false
            button.alphaValue = 1
            button.isEnabled = true
            button.appearsDisabled = false
            button.needsDisplay = true
            if let window = button.window {
                window.alphaValue = 1
                window.isOpaque = false
                window.orderFrontRegardless()
            }
        }
    }

    /// Uses the value delivered by `@Published` directly. Its publisher emits in
    /// `willSet`, so re-reading `model.runtime.snapshots` in that callback would
    /// refresh every status item with the previous value until the next poll.
    func refreshAll(snapshots: [UUID: AppletSnapshot]) {
        for id in items.keys {
            refresh(appletID: id, snapshot: snapshots[id])
        }
    }

    func refresh(appletID: UUID) {
        refresh(appletID: appletID, snapshot: model?.runtime.snapshots[appletID])
    }

    private func refresh(appletID: UUID, snapshot currentSnapshot: AppletSnapshot?) {
        guard let model,
              let item = items[appletID],
              let applet = model.store.applet(id: appletID) else { return }

        let snapshot = currentSnapshot ?? .placeholder(for: applet)
        forceVisible(item)
        if let button = item.button {
            let runState = ToolRunState.resolve(
                manifest: applet,
                snapshot: currentSnapshot,
                executionApproved: model.isExecutionApproved(applet),
                isValidating: model.isValidatingExecution(applet)
            )
            let title = TitleRenderer.statusItemTitle(snapshot.title, runState: runState)
            let symbolName = applet.iconSystemName
            var image = NSImage(systemSymbolName: symbolName, accessibilityDescription: applet.name)
                ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: applet.name)
            image?.isTemplate = true
            // If AppKit fails to produce a symbol, paint a solid disc so the
            // item never collapses to an empty, undrawable control.
            if image == nil {
                let fallback = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                    NSColor.labelColor.setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                    return true
                }
                fallback.isTemplate = true
                image = fallback
            }
            button.font = NSFont.menuBarFont(ofSize: 0)
            button.image = image
            let label = title.isEmpty ? applet.name : title
            // Leading non-breaking space keeps title from being clipped by the icon.
            button.title = "\u{00A0}\(label)"
            button.imagePosition = .imageLeading
            button.imageHugsTitle = false
            button.toolTip = "\(applet.name): \(snapshot.statusText)"
            button.setAccessibilityLabel(applet.name)
            button.setAccessibilityValue(label)
            button.setAccessibilityHelp(snapshot.statusText)
            // Ensure AppKit allocates a non-zero status-item width after content change.
            item.length = NSStatusItem.variableLength
            forceVisible(item)
        } else {
            AppLog.menuBar.error(
                "Status item button is nil for \(applet.name, privacy: .public); item will not render"
            )
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
                title: "Restart",
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

        item.menu = menu
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
        guard let id = uuid(from: sender) else { return }
        openMainWindow(selecting: id)
    }

    func openMainWindow(selecting id: UUID? = nil) {
        if let id {
            model?.selection = id
        }
        openWindowAction?()
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
