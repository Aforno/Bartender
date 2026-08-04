import Foundation
import XCTest
@testable import BarTender

@MainActor
final class StatusItemManagerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-StatusItemTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "BarTender.StatusItemTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        StatusItemManager.initialRegistrationDelay = 0
    }

    override func tearDownWithError() throws {
        StatusItemManager.initialRegistrationDelay = 0.75
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        defaults = nil
        defaultsSuiteName = nil
        temporaryDirectory = nil
    }

    func testAttachCreatesStatusItemsForEnabledAppletsWithoutMainWindow() throws {
        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("applets.json"))
        let first = try store.upsert(makeManifest(name: "Alpha"))
        let second = try store.upsert(makeManifest(name: "Beta"))
        _ = try store.upsert(makeManifest(name: "Disabled", enabled: false))

        let model = makeModel(store: store)
        // Default cap is 1; raise so both enabled tools get individual items.
        model.preferences.maximumMenuBarItems = 2
        let manager = StatusItemManager()

        XCTAssertFalse(manager.isAttached)
        XCTAssertEqual(manager.managedItemCount, 0)

        manager.attach(model: model)

        XCTAssertTrue(manager.isAttached)
        XCTAssertEqual(manager.managedItemCount, 2)
        XCTAssertEqual(manager.managedAppletIDs, [first.id, second.id])
    }

    func testDefaultPreferenceCreatesOnlyOneIndividualItem() throws {
        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("default-one.json"))
        _ = try store.upsert(makeManifest(name: "One"))
        _ = try store.upsert(makeManifest(name: "Two"))
        _ = try store.upsert(makeManifest(name: "Three"))

        let model = makeModel(store: store)
        XCTAssertEqual(model.preferences.maximumMenuBarItems, 1)

        let manager = StatusItemManager()
        manager.attach(model: model)

        XCTAssertEqual(manager.managedItemCount, 1)
        XCTAssertEqual(manager.managedAppletIDs, Set([store.enabledApplets[0].id]))
    }

    func testReattachIsIdempotentAndRebuildsFromStore() throws {
        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("reattach.json"))
        let tool = try store.upsert(makeManifest(name: "Only"))
        let model = makeModel(store: store)
        let manager = StatusItemManager()

        manager.attach(model: model)
        manager.attach(model: model)

        XCTAssertTrue(manager.isAttached)
        XCTAssertEqual(manager.managedItemCount, 1)
        XCTAssertEqual(manager.managedAppletIDs, [tool.id])
    }

    func testReattachWhileInitialRegistrationPendingIsIgnored() throws {
        StatusItemManager.initialRegistrationDelay = 10

        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("pending.json"))
        _ = try store.upsert(makeManifest(name: "Pending"))
        let model = makeModel(store: store)
        let manager = StatusItemManager()

        manager.attach(model: model)
        XCTAssertTrue(manager.isAttached)
        XCTAssertEqual(manager.managedItemCount, 0, "items must not register before the delay")

        manager.attach(model: model)
        XCTAssertEqual(manager.managedItemCount, 0, "reattach must not force an early rebuild")
    }

    func testRebuildRemovesStatusItemWhenToolDisabled() throws {
        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("toggle.json"))
        let tool = try store.upsert(makeManifest(name: "Toggle Me"))
        let model = makeModel(store: store)
        let manager = StatusItemManager()
        manager.attach(model: model)
        XCTAssertEqual(manager.managedItemCount, 1)

        manager.rebuild(enabled: [])
        XCTAssertEqual(manager.managedItemCount, 0)
        XCTAssertTrue(manager.managedAppletIDs.isEmpty)

        manager.rebuild(enabled: [tool])
        XCTAssertEqual(manager.managedItemCount, 1)
        XCTAssertEqual(manager.managedAppletIDs, [tool.id])
    }

    func testRebuildRespectsMaximumIndividualItemsCap() throws {
        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("cap.json"))
        for index in 0..<(StatusItemManager.maximumIndividualItems + 3) {
            _ = try store.upsert(makeManifest(name: "Cap \(index)"))
        }
        let model = makeModel(store: store)
        model.preferences.maximumMenuBarItems = StatusItemManager.maximumIndividualItems
        let manager = StatusItemManager()
        manager.attach(model: model)

        let visible = StatusItemManager.individuallyVisible(
            from: store.enabledApplets,
            limit: StatusItemManager.maximumIndividualItems
        )
        XCTAssertEqual(store.enabledApplets.count, StatusItemManager.maximumIndividualItems + 3)
        XCTAssertEqual(visible.count, StatusItemManager.maximumIndividualItems)
        XCTAssertEqual(manager.managedItemCount, StatusItemManager.maximumIndividualItems)
        XCTAssertEqual(manager.managedAppletIDs, Set(visible.map(\.id)))
    }

    func testRebuildUsesConfigurableMenuBarItemLimitPreference() throws {
        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("configurable-cap.json"))
        for index in 0..<4 {
            _ = try store.upsert(makeManifest(name: "Cap \(index)"))
        }
        let model = makeModel(store: store)
        model.preferences.maximumMenuBarItems = 2

        let manager = StatusItemManager()
        manager.attach(model: model)

        XCTAssertEqual(manager.managedItemCount, 2)
        XCTAssertEqual(manager.managedAppletIDs, Set(store.enabledApplets.prefix(2).map(\.id)))
    }

    func testPreferenceChangeRebuildsLiveStatusItems() throws {
        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("pref-rebuild.json"))
        for index in 0..<3 {
            _ = try store.upsert(makeManifest(name: "Pref \(index)"))
        }
        let model = makeModel(store: store)
        model.preferences.maximumMenuBarItems = 3
        let manager = StatusItemManager()
        manager.attach(model: model)
        XCTAssertEqual(manager.managedItemCount, 3)

        model.preferences.maximumMenuBarItems = 1
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(manager.managedItemCount, 1)
        XCTAssertEqual(manager.managedAppletIDs, Set([store.enabledApplets[0].id]))
    }

    func testPreferencesClampMenuBarItemLimitToManagerCap() {
        let model = makeModel(store: AppletStore(
            fileURL: temporaryDirectory.appendingPathComponent("clamp.json")
        ))

        model.preferences.maximumMenuBarItems = -3
        XCTAssertEqual(model.preferences.maximumMenuBarItems, 1)

        model.preferences.maximumMenuBarItems = 99
        XCTAssertEqual(model.preferences.maximumMenuBarItems, StatusItemManager.maximumIndividualItems)
    }

    func testAutosaveNamesAreStableAndUnique() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let firstName = StatusItemManager.autosaveName(for: firstID)
        let secondName = StatusItemManager.autosaveName(for: secondID)

        XCTAssertEqual(firstName, StatusItemManager.autosaveName(for: firstID))
        XCTAssertNotEqual(firstName, secondName)
        XCTAssertTrue(firstName.contains(firstID.uuidString.lowercased()))
        XCTAssertTrue(firstName.hasPrefix("io.github.aforno.bartender.v2.applet."))
    }

    private func makeModel(store: AppletStore) -> AppModel {
        AppModel(
            store: store,
            preferences: AppPreferences(defaults: defaults),
            shellApprovals: ShellApprovalStore(defaults: defaults, storageKey: "status-item-approvals"),
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
}
