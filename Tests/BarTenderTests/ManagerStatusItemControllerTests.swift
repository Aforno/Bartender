import AppKit
import Foundation
import XCTest
@testable import BarTender

@MainActor
final class ManagerStatusItemControllerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var controller: ManagerStatusItemController?

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-ManagerStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "BarTender.ManagerStatusTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        StatusItemManager.initialRegistrationDelay = 0
    }

    override func tearDownWithError() throws {
        controller?.uninstall()
        controller = nil
        AppActions.shared.resetForTesting()
        StatusItemManager.initialRegistrationDelay = 0.75
        StatusItemRegistrationTiming.managerInitialDelay = 0
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        defaults = nil
        defaultsSuiteName = nil
        temporaryDirectory = nil
    }

    func testRapidInstallUninstallDoesNotDuplicateManagerItem() {
        let model = makeModel()
        let manager = ManagerStatusItemController(model: model)
        controller = manager

        for _ in 0..<5 {
            manager.install()
            XCTAssertEqual(manager.managedStatusItemCount, 1)
            manager.uninstall()
            XCTAssertEqual(manager.managedStatusItemCount, 0)
        }

        manager.install()
        manager.install()
        XCTAssertEqual(manager.managedStatusItemCount, 1)
        XCTAssertTrue(manager.isInstalled)
    }

    // MARK: - Install idempotency

    func testInstallCreatesExactlyOneManagerStatusItem() {
        let model = makeModel()
        let manager = ManagerStatusItemController(model: model)
        controller = manager

        XCTAssertFalse(manager.isInstalled)
        XCTAssertEqual(manager.managedStatusItemCount, 0)

        manager.install()

        XCTAssertTrue(manager.isInstalled)
        XCTAssertEqual(manager.managedStatusItemCount, 1)
    }

    func testInstallIsIdempotent() {
        let model = makeModel()
        let manager = ManagerStatusItemController(model: model)
        controller = manager

        manager.install()
        manager.install()
        manager.install()

        XCTAssertEqual(manager.managedStatusItemCount, 1)
        XCTAssertTrue(manager.isInstalled)
    }

    func testUninstallClearsManagerItem() {
        let model = makeModel()
        let manager = ManagerStatusItemController(model: model)
        manager.install()
        XCTAssertEqual(manager.managedStatusItemCount, 1)

        manager.uninstall()
        XCTAssertEqual(manager.managedStatusItemCount, 0)
        XCTAssertFalse(manager.isInstalled)

        // Safe to uninstall twice.
        manager.uninstall()
        XCTAssertEqual(manager.managedStatusItemCount, 0)
        controller = nil
    }

    // MARK: - Click classification

    func testLeftMouseUpIsPrimary() {
        let event = mouseEvent(type: .leftMouseUp)
        XCTAssertEqual(ManagerStatusItemClick.classify(event), .primary)
    }

    func testRightMouseUpIsSecondary() {
        let event = mouseEvent(type: .rightMouseUp)
        XCTAssertEqual(ManagerStatusItemClick.classify(event), .secondary)
    }

    func testControlLeftMouseIsSecondary() {
        let event = mouseEvent(type: .leftMouseUp, flags: .control)
        XCTAssertEqual(ManagerStatusItemClick.classify(event), .secondary)
    }

    func testUnrelatedEventIsIgnored() {
        // Key events are not manager status-item interactions.
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )
        XCTAssertNotNil(event)
        XCTAssertNil(ManagerStatusItemClick.classify(event!))
    }

    // MARK: - Context menu blueprint

    func testMenuBlueprintWithZeroRunningTools() {
        let entries = ManagerContextMenuBlueprint.entries(
            enabledApplets: [],
            snapshots: [:]
        )

        XCTAssertEqual(entries.first, .sectionHeader("Running Tools"))
        XCTAssertTrue(entries.contains(.emptyRunningTools))
        XCTAssertTrue(entries.contains(.openBarTender))
        XCTAssertTrue(entries.contains(.providerSetup))
        XCTAssertTrue(entries.contains(.settings))
        XCTAssertEqual(entries.last, .quit)

        // Quit is separated from the app actions block.
        let quitIndex = entries.firstIndex(of: .quit)!
        XCTAssertEqual(entries[quitIndex - 1], .separator)
    }

    func testMenuBlueprintWithOneRunningTool() throws {
        let applet = makeManifest(name: "CPU")
        let snapshot = AppletSnapshot(
            statusText: "OK",
            title: "12%",
            detailLines: [],
            isHealthy: true,
            values: [:],
            updatedAt: Date(),
            isRunning: true,
            progress: nil
        )

        let entries = ManagerContextMenuBlueprint.entries(
            enabledApplets: [applet],
            snapshots: [applet.id: snapshot]
        )

        let appletEntries = entries.compactMap { entry -> (UUID, String)? in
            if case .applet(let id, let title) = entry { return (id, title) }
            return nil
        }
        XCTAssertEqual(appletEntries.count, 1)
        XCTAssertEqual(appletEntries[0].0, applet.id)
        XCTAssertTrue(appletEntries[0].1.contains("CPU"))
        XCTAssertTrue(appletEntries[0].1.contains("12%"))
        XCTAssertFalse(entries.contains(.emptyRunningTools))
    }

    func testMenuBlueprintWithMultipleRunningTools() {
        let first = makeManifest(name: "Alpha")
        let second = makeManifest(name: "Beta")
        let third = makeManifest(name: "Gamma")

        let entries = ManagerContextMenuBlueprint.entries(
            enabledApplets: [first, second, third],
            snapshots: [
                first.id: AppletSnapshot(
                    statusText: "",
                    title: "1",
                    detailLines: [],
                    isHealthy: true,
                    values: [:],
                    updatedAt: Date(),
                    isRunning: true,
                    progress: nil
                ),
                second.id: AppletSnapshot(
                    statusText: "",
                    title: "2",
                    detailLines: [],
                    isHealthy: true,
                    values: [:],
                    updatedAt: Date(),
                    isRunning: true,
                    progress: nil
                )
            ]
        )

        let ids = entries.compactMap { entry -> UUID? in
            if case .applet(let id, _) = entry { return id }
            return nil
        }
        XCTAssertEqual(ids, [first.id, second.id, third.id])

        // Tool without a snapshot still appears by name.
        let gammaTitle = entries.compactMap { entry -> String? in
            if case .applet(let id, let title) = entry, id == third.id { return title }
            return nil
        }.first
        XCTAssertEqual(gammaTitle, "Gamma")
    }

    func testMenuTitleIsConciseWithAndWithoutValue() {
        XCTAssertEqual(
            ManagerContextMenuBlueprint.menuTitle(name: "Clock", value: ""),
            "Clock"
        )
        let combined = ManagerContextMenuBlueprint.menuTitle(name: "Clock", value: "12:00")
        XCTAssertTrue(combined.contains("Clock"))
        XCTAssertTrue(combined.contains("12:00"))
        XCTAssertLessThanOrEqual(combined.count, TitleRenderer.menuBarMaxLength)
    }

    // MARK: - Selection before open

    func testSelectingRunningToolSetsModelSelection() throws {
        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("select.json"))
        let tool = try store.upsert(makeManifest(name: "Selected"))
        let model = makeModel(store: store)
        AppActions.shared.model = model

        var openedWithSelection: UUID?
        AppActions.shared.openWindowAction = {
            openedWithSelection = model.selection
        }

        // Simulate the menu action path used by the controller.
        model.selection = nil
        AppActions.shared.openMainWindow(selecting: tool.id)

        XCTAssertEqual(model.selection, tool.id)
        // openWindowAction runs only when no existing main window is found;
        // either path must leave selection set.
        if let openedWithSelection {
            XCTAssertEqual(openedWithSelection, tool.id)
        }

        AppActions.shared.openWindowAction = nil
        AppActions.shared.model = nil
    }

    // MARK: - No regression to per-applet manager

    func testManagerAndPerAppletStatusItemsAreIndependent() throws {
        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("independent.json"))
        let first = try store.upsert(makeManifest(name: "One"))
        _ = try store.upsert(makeManifest(name: "Two"))
        let model = makeModel(store: store)
        model.preferences.maximumMenuBarItems = 2

        let manager = ManagerStatusItemController(model: model)
        controller = manager
        manager.install()

        let perApplet = StatusItemManager()
        perApplet.attach(model: model)

        XCTAssertEqual(manager.managedStatusItemCount, 1)
        XCTAssertEqual(perApplet.managedItemCount, 2)
        XCTAssertEqual(perApplet.managedAppletIDs, Set(store.enabledApplets.map(\.id)))
        XCTAssertTrue(perApplet.managedAppletIDs.contains(first.id))

        // Re-install manager must not affect per-applet items.
        manager.install()
        XCTAssertEqual(manager.managedStatusItemCount, 1)
        XCTAssertEqual(perApplet.managedItemCount, 2)
    }

    func testControllerRefreshesMenuBlueprintWhenAppletsChange() throws {
        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("refresh.json"))
        let model = makeModel(store: store)
        let manager = ManagerStatusItemController(model: model)
        controller = manager
        manager.install()

        XCTAssertTrue(manager.lastMenuEntries.contains(.emptyRunningTools))

        _ = try store.upsert(makeManifest(name: "Live"))
        // Publisher may deliver asynchronously; pump the run loop briefly.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        let appletEntries = manager.lastMenuEntries.filter {
            if case .applet = $0 { return true }
            return false
        }
        XCTAssertEqual(appletEntries.count, 1)
        XCTAssertFalse(manager.lastMenuEntries.contains(.emptyRunningTools))
    }

    // MARK: - Helpers

    private func makeModel(store: AppletStore? = nil) -> AppModel {
        let store = store ?? AppletStore(
            fileURL: temporaryDirectory.appendingPathComponent("applets-\(UUID().uuidString).json")
        )
        return AppModel(
            store: store,
            preferences: AppPreferences(defaults: defaults),
            shellApprovals: ShellApprovalStore(defaults: defaults, storageKey: "manager-status-approvals"),
            generatedTools: GeneratedToolArtifactStore(
                rootURL: temporaryDirectory.appendingPathComponent("artifacts", isDirectory: true)
            )
        )
    }

    private func makeManifest(name: String, enabled: Bool = true) -> AppletManifest {
        AppletManifest(
            name: name,
            iconSystemName: "gear",
            kind: .systemMetrics,
            titleTemplate: "{{cpu}}",
            enabled: enabled,
            config: AppletConfig(metrics: [.cpu])
        )
    }

    private func mouseEvent(type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        // location/window are irrelevant for classify(); type + modifiers matter.
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
