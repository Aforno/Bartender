import AppKit
import Combine
import SwiftUI

// MARK: - Click classification (testable without AppKit event delivery)

/// Classifies status-item mouse events into primary (left) vs secondary (right).
enum ManagerStatusItemClick: Equatable, Sendable {
    case primary
    case secondary

    /// Maps a mouse event to the manager interaction. Control-left counts as secondary.
    static func classify(_ event: NSEvent) -> ManagerStatusItemClick? {
        switch event.type {
        case .rightMouseUp, .rightMouseDown:
            return .secondary
        case .leftMouseUp, .leftMouseDown:
            if event.modifierFlags.contains(.control) {
                return .secondary
            }
            return .primary
        default:
            return nil
        }
    }
}

// MARK: - Right-click menu blueprint (pure, testable)

/// Declarative description of the manager context menu. Built into an `NSMenu` at click time.
enum ManagerContextMenuBlueprint {
    enum Entry: Equatable {
        case sectionHeader(String)
        case applet(id: UUID, title: String)
        case emptyRunningTools
        case separator
        case openBarTender
        case providerSetup
        case settings
        case quit
    }

    /// Builds the ordered menu entries for the current library/runtime state.
    static func entries(
        enabledApplets: [AppletManifest],
        snapshots: [UUID: AppletSnapshot]
    ) -> [Entry] {
        var result: [Entry] = [.sectionHeader("Running Tools")]

        if enabledApplets.isEmpty {
            result.append(.emptyRunningTools)
        } else {
            for applet in enabledApplets {
                let value = snapshots[applet.id]?.title ?? ""
                let title = menuTitle(name: applet.name, value: value)
                result.append(.applet(id: applet.id, title: title))
            }
        }

        result.append(.separator)
        result.append(.openBarTender)
        result.append(.providerSetup)
        result.append(.settings)
        result.append(.separator)
        result.append(.quit)
        return result
    }

    /// Concise row label: name alone, or "Name  shortValue" when a value is available.
    static func menuTitle(name: String, value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            return TitleRenderer.shortMenuTitle(name)
        }
        return TitleRenderer.shortMenuTitle("\(name)  \(trimmedValue)")
    }
}

// MARK: - Controller

/// Owns the permanent wine-glass manager `NSStatusItem`: left-click composer popover,
/// right-click native menu. Independent of the main window and of per-applet items.
@MainActor
final class ManagerStatusItemController: NSObject {
    static let autosaveName = "io.github.aforno.bartender.v2.manager"
    static let tooltip = "Click to create · Right-click for options"

    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<ManagerComposerRoot>?
    private var cancellables = Set<AnyCancellable>()
    private var generationCancellables = Set<AnyCancellable>()
    private var resizeWorkItem: DispatchWorkItem?
    private var didInstall = false

    /// Snapshot of the last menu blueprint used for refresh bookkeeping / tests.
    private(set) var lastMenuEntries: [ManagerContextMenuBlueprint.Entry] = []

    /// Whether `install()` has completed successfully.
    var isInstalled: Bool { didInstall && statusItem != nil }

    /// Number of manager status items owned (0 or 1).
    var managedStatusItemCount: Int { statusItem == nil ? 0 : 1 }

    /// Whether the manager button has a non-empty title or a template image.
    var hasVisibleTitleOrImage: Bool {
        guard let button = statusItem?.button else { return false }
        let hasImage = button.image != nil
        let hasTitle = !(button.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return hasImage || hasTitle
    }

    /// Live window geometry used by packaged-app diagnostics.
    var frameDiagnostic: MenuBarDiagnosticsSnapshot.StatusItemFrameDiagnostic {
        .capture(button: statusItem?.button)
    }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Creates the status item and subscriptions once. Subsequent calls are no-ops.
    func install() {
        guard !didInstall else {
            AppLog.menuBar.debug("Manager status item already installed; ignoring re-install")
            return
        }
        didInstall = true

        let delay = StatusItemRegistrationTiming.managerInitialDelay
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.performInstall()
            }
        } else {
            performInstall()
        }
    }

    private func performInstall() {
        // Re-check in case uninstall raced a delayed install.
        guard didInstall, statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "wineglass",
                accessibilityDescription: "Bar Tender"
            )
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = Self.tooltip
            button.setAccessibilityLabel("Bar Tender")
            button.setAccessibilityHelp(Self.tooltip)
            button.target = self
            button.action = #selector(statusItemActivated(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        item.isVisible = true
        statusItem = item

        let hosting = NSHostingController(rootView: ManagerComposerRoot(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        hostingController = hosting

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = hosting
        pop.delegate = self
        // Compact default before first layout.
        pop.contentSize = CGSize(
            width: ManagerPopoverSizing.minimumWidth,
            height: ManagerPopoverSizing.defaultCompactHeight
        )
        popover = pop

        installSubscriptions()
        observeGenerationSession(model.generation)
        refreshMenuBlueprint()

        let frame = item.button?.window?.frame
        StatusItemRegistrationTiming.logManagerInstall(
            createdAt: Date(),
            autosaveName: Self.autosaveName,
            frame: frame
        )
        AppLog.menuBar.info("Installed manager status item (wineglass)")
    }

    /// Removes the manager item and tears down popover/subscriptions (tests / shutdown).
    func uninstall() {
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        cancellables.removeAll()
        generationCancellables.removeAll()
        popover?.performClose(nil)
        popover?.delegate = nil
        popover = nil
        hostingController = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        didInstall = false
        lastMenuEntries = []
    }

    // MARK: - Event handling

    @objc private func statusItemActivated(_ sender: Any?) {
        guard let event = NSApp.currentEvent,
              let click = ManagerStatusItemClick.classify(event) else { return }
        handle(click)
    }

    /// Routes a classified click. Exposed for tests without synthesizing NSEvents.
    func handle(_ click: ManagerStatusItemClick) {
        switch click {
        case .primary:
            togglePopover()
        case .secondary:
            showContextMenu()
        }
    }

    private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        syncPopoverSize()
        // Composer interaction needs activation even after a silent login launch.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Size after SwiftUI completes the first layout pass.
        schedulePopoverResize(immediate: true)
        AppLog.menuBar.info("Opened manager composer popover")
    }

    private func closePopover() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        closePopover()
        refreshMenuBlueprint()
        let menu = makeNSMenu(from: lastMenuEntries)
        // Position just below the status item button.
        let location = NSPoint(x: 0, y: button.bounds.height + 2)
        menu.popUp(positioning: nil, at: location, in: button)
        AppLog.menuBar.info("Opened manager context menu (\(self.lastMenuEntries.count, privacy: .public) entries)")
    }

    private func syncPopoverSize() {
        guard let hosting = hostingController, let popover else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let screenHeight = statusItem?.button?.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
        let size = ManagerPopoverSizing.contentSize(
            fitting: fitting,
            screenVisibleHeight: screenHeight
        )
        // Apply only when the size actually changes to avoid layout thrash.
        if abs(popover.contentSize.width - size.width) > 0.5
            || abs(popover.contentSize.height - size.height) > 0.5 {
            popover.contentSize = size
        }
    }

    /// Debounces rapid streaming updates; uses an immediate async hop so layout
    /// has finished before measuring.
    private func schedulePopoverResize(immediate: Bool = false) {
        guard popover?.isShown == true else { return }
        resizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.syncPopoverSize()
        }
        resizeWorkItem = work
        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            let delay = DispatchTimeInterval.nanoseconds(Int(ManagerPopoverSizing.resizeDebounceNanoseconds))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: - Menu construction

    private func installSubscriptions() {
        // Rebuild the blueprint when tools, snapshots, or generation-related
        // provider readiness change — not on every SwiftUI frame.
        model.store.$applets
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuBlueprint() }
            .store(in: &cancellables)

        model.runtime.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuBlueprint() }
            .store(in: &cancellables)

        model.providers.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuBlueprint() }
            .store(in: &cancellables)

        // Replace generation child subscriptions when the session object changes.
        model.$generation
            .receive(on: RunLoop.main)
            .sink { [weak self] session in
                guard let self else { return }
                self.observeGenerationSession(session)
                self.schedulePopoverResize()
            }
            .store(in: &cancellables)

        // Model selector visibility changes composer height.
        model.preferences.$showProviderInComposer
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.schedulePopoverResize() }
            .store(in: &cancellables)
    }

    /// Observe phase / error / result / completion on the current session.
    /// Replaces any previous session subscriptions to avoid duplicates and leaks.
    private func observeGenerationSession(_ session: GenerationSession?) {
        generationCancellables.removeAll()
        guard let session else {
            schedulePopoverResize()
            return
        }

        Publishers.Merge4(
            session.$phase.map { _ in () },
            session.$errorMessage.map { _ in () },
            session.$resultManifest.map { _ in () },
            session.$finishedAt.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.schedulePopoverResize()
        }
        .store(in: &generationCancellables)
    }

    private func refreshMenuBlueprint() {
        let entries = ManagerContextMenuBlueprint.entries(
            enabledApplets: model.store.enabledApplets,
            snapshots: model.runtime.snapshots
        )
        lastMenuEntries = entries
    }

    private func makeNSMenu(from entries: [ManagerContextMenuBlueprint.Entry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for entry in entries {
            switch entry {
            case .sectionHeader(let title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)

            case .applet(let id, let title):
                let item = NSMenuItem(
                    title: title,
                    action: #selector(openAppletFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = id.uuidString
                item.isEnabled = true
                menu.addItem(item)

            case .emptyRunningTools:
                let item = NSMenuItem(title: "No tools running", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)

            case .separator:
                menu.addItem(.separator())

            case .openBarTender:
                let item = NSMenuItem(
                    title: "Open Bar Tender",
                    action: #selector(openBarTenderFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)

            case .providerSetup:
                let item = NSMenuItem(
                    title: "Provider Setup…",
                    action: #selector(openProviderSetupFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)

            case .settings:
                let item = NSMenuItem(
                    title: "Settings…",
                    action: #selector(openSettingsFromMenu(_:)),
                    keyEquivalent: ","
                )
                item.keyEquivalentModifierMask = [.command]
                item.target = self
                menu.addItem(item)

            case .quit:
                let item = NSMenuItem(
                    title: "Quit and Stop Tools",
                    action: #selector(quitFromMenu(_:)),
                    keyEquivalent: "q"
                )
                item.keyEquivalentModifierMask = [.command]
                item.target = self
                menu.addItem(item)
            }
        }

        return menu
    }

    // MARK: - Menu actions

    @objc private func openAppletFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        model.selection = id
        AppActions.shared.openMainWindow(selecting: id)
    }

    @objc private func openBarTenderFromMenu(_ sender: Any?) {
        AppActions.shared.openMainWindow()
    }

    @objc private func openProviderSetupFromMenu(_ sender: Any?) {
        model.showingProviderSetup = true
        AppActions.shared.openMainWindow()
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        AppActions.shared.openSettings()
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        AppDelegate.requestQuit()
    }
}

// MARK: - NSPopoverDelegate

extension ManagerStatusItemController: NSPopoverDelegate {
    nonisolated func popoverDidClose(_ notification: Notification) {
        // No-op: transient popover; size is recalculated on next open.
    }
}

// MARK: - SwiftUI root for the hosting controller

/// Environment-injected wrapper so the hosting controller has a stable root type.
struct ManagerComposerRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ManagerComposerView()
            .environmentObject(model)
            .environmentObject(model.store)
            .environmentObject(model.providers)
            .environmentObject(model.runtime)
            .environmentObject(model.preferences)
            .tint(PremiumStyle.brand)
            .font(.inter(.body))
    }
}
