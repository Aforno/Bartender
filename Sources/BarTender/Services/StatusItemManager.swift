import AppKit
import Combine

/// Creates one `NSStatusItem` per enabled applet. The wine-glass manager item
/// is owned separately by `ManagerStatusItemController`.
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
    /// Prevents a second `attach` (e.g. main-window `.task`) from forcing an
    /// immediate rebuild before the delayed first registration completes.
    private var didCompleteInitialRegistration = false

    /// Whether `attach(model:)` has installed store/runtime subscriptions.
    var isAttached: Bool { model != nil && !cancellables.isEmpty }

    /// Live AppKit status items currently managed (tests / diagnostics).
    var managedItemCount: Int { items.count }

    /// Applet IDs that currently have an individual status item.
    var managedAppletIDs: Set<UUID> { Set(items.keys) }

    func attach(model: AppModel) {
        if self.model === model, !cancellables.isEmpty {
            // Already attached: ignore until the delayed first registration
            // finishes, then reconcile in place. Destroying/recreating items
            // here strands them without a menu-bar slot.
            guard didCompleteInitialRegistration else { return }

            rebuild(enabled: model.store.enabledApplets)
            refreshAll(snapshots: model.runtime.snapshots)
            return
        }

        self.model = model
        didCompleteInitialRegistration = false
        cancellables.removeAll()

        // A lower cap frees menu-bar space; rebuilding here keeps the live
        // items in sync with the preference without touching the main window.
        model.preferences.$maximumMenuBarItems
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.didCompleteInitialRegistration, let model = self.model else { return }
                self.rebuild(enabled: model.store.enabledApplets)
            }
            .store(in: &cancellables)

        model.store.$applets
            .dropFirst()
            .map { $0.filter(\.enabled) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self, self.didCompleteInitialRegistration else { return }
                self.rebuild(enabled: enabled)
            }
            .store(in: &cancellables)

        model.runtime.$snapshots
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots in
                guard let self, self.didCompleteInitialRegistration else { return }
                self.refreshAll(snapshots: snapshots)
            }
            .store(in: &cancellables)

        // macOS 26 Control Center tears down the previous instance's status
        // displayables asynchronously after the process exits. Registering
        // immediately races that teardown and often lands the item in CC's
        // blocked/offscreen state for the whole session; a short delay lets
        // the system finish before the new host is registered.
        let delay = Self.initialRegistrationDelay
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let model = self.model else { return }
                self.didCompleteInitialRegistration = true
                self.rebuild(enabled: model.store.enabledApplets)
                self.refreshAll(snapshots: model.runtime.snapshots)
            }
        } else {
            didCompleteInitialRegistration = true
            rebuild(enabled: model.store.enabledApplets)
            refreshAll(snapshots: model.runtime.snapshots)
        }
        let enabled = model.store.enabledApplets
        AppLog.menuBar.info(
            "Attached status item manager; \(enabled.count, privacy: .public) of \(model.store.applets.count, privacy: .public) applets enabled, cap \(model.preferences.maximumMenuBarItems, privacy: .public)"
        )
    }

    /// Effective per-applet cap, derived from the user preference (clamped).
    private var individualItemLimit: Int {
        guard let model else { return 1 }
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

        // Note: `isVisible` is true even when Control Center has clipped the
        // item for lack of menu-bar space — it is not proof the item is painted.
        let reportedVisible = items.values.lazy.filter(\.isVisible).count
        let zeroSized = items.values.filter { item in
            guard let frame = item.button?.window?.frame else { return true }
            return frame.width < 1 || frame.height < 1
        }.count
        AppLog.menuBar.info(
            "Reconciled \(self.items.count, privacy: .public) status items; \(reportedVisible, privacy: .public) isVisible=true (not space-proof); \(zeroSized, privacy: .public) zero-sized windows"
        )
    }

    static func individuallyVisible(from enabled: [AppletManifest], limit: Int = maximumIndividualItems) -> [AppletManifest] {
        Array(enabled.prefix(max(0, limit)))
    }

    static func autosaveName(for appletID: UUID) -> String {
        // Unique per-applet identity. Bundle id v2 + name prefix keep Control
        // Center from reusing a previously blocked host tracking state.
        "io.github.aforno.bartender.v2.applet.\(appletID.uuidString.lowercased())"
    }

    private func makeStatusItem(for appletID: UUID) -> NSStatusItem {
        // The default cap is one item, so a compact icon + live value fits
        // without returning to the previous eight-item clipping problem.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName(for: appletID)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Bar Tender applet"
            )
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.imageHugsTitle = false
        }
        forceVisible(item)
        let menu = NSMenu()
        menu.autoenablesItems = false
        item.menu = menu
        return item
    }

    private func forceVisible(_ item: NSStatusItem?) {
        guard let item else { return }
        item.isVisible = true
        if item.length == 0 {
            item.length = NSStatusItem.variableLength
        }
        if let button = item.button {
            button.isHidden = false
            button.alphaValue = 1
            button.isEnabled = true
            button.appearsDisabled = false
            button.needsLayout = true
            button.needsDisplay = true
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
            let label = title.isEmpty ? applet.name : title
            var image = NSImage(systemSymbolName: applet.iconSystemName, accessibilityDescription: applet.name)
                ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: applet.name)
            image?.isTemplate = true
            if image == nil {
                let fallback = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                    NSColor.labelColor.setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                    return true
                }
                fallback.isTemplate = true
                image = fallback
            }

            let fontSize = NSFont.systemFontSize
            let symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: fontSize,
                weight: .medium
            )
            image = image?.withSymbolConfiguration(symbolConfiguration) ?? image
            image?.isTemplate = true

            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: fontSize,
                weight: .medium
            )
            button.image = image
            button.title = "\u{00A0}\(label)"
            button.imagePosition = .imageLeading
            button.imageHugsTitle = false
            button.toolTip = "\(applet.name): \(snapshot.statusText)"
            button.setAccessibilityLabel(applet.name)
            button.setAccessibilityValue(label)
            button.setAccessibilityHelp(snapshot.statusText)
            item.length = NSStatusItem.variableLength
            button.needsLayout = true
            button.needsDisplay = true
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
    /// Set by the main window when it mounts so a closed window can be recreated.
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
        // Prefer the canonical router (focus existing, else stored OpenWindowAction).
        if MainWindowRouter.openMainWindow() {
            return
        }
        // Fallback when router could not open (should be rare after first launch).
        openWindowAction?()
    }

    /// Opens the SwiftUI `Settings` scene via the standard AppKit selector.
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI Settings scene responds to showSettingsWindow: (macOS 13+).
        let settingsSelector = Selector(("showSettingsWindow:"))
        if NSApp.sendAction(settingsSelector, to: nil, from: nil) {
            return
        }
        // Older spelling used by some system builds.
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
