import Foundation
import Combine
import XCTest
@testable import BarTender

@MainActor
final class AppModelSafetyTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "BarTender.AppModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        defaults = nil
        defaultsSuiteName = nil
        temporaryDirectory = nil
    }

    func testArtifactInstallFailureDoesNotPublishGhostManifest() throws {
        let blockedRoot = temporaryDirectory.appendingPathComponent("blocked-artifact-root")
        try Data("not a directory".utf8).write(to: blockedRoot)

        let store = AppletStore(fileURL: temporaryDirectory.appendingPathComponent("applets.json"))
        let approvals = ShellApprovalStore(defaults: defaults, storageKey: "approvals")
        let artifacts = GeneratedToolArtifactStore(rootURL: blockedRoot)
        let model = AppModel(
            store: store,
            preferences: AppPreferences(defaults: defaults),
            shellApprovals: approvals,
            generatedTools: artifacts
        )
        let manifest = AppletManifest(
            name: "Should Not Persist",
            iconSystemName: "hammer",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            refreshIntervalSeconds: 30,
            enabled: false,
            sourcePrompt: "test",
            config: AppletConfig(
                timeoutSeconds: 5,
                generatedSource: "#!/bin/zsh\nprintf '{\"title\":\"OK\",\"status\":\"OK\",\"details\":[],\"healthy\":true,\"values\":{}}'\n"
            )
        )

        model.saveEdits(manifest)

        XCTAssertNil(store.applet(id: manifest.id))
        XCTAssertTrue(store.applets.isEmpty)
        XCTAssertNotNil(model.bannerMessage)
    }

    func testCancelDoesNotRewriteCompletedSession() {
        let model = makeModel()
        let session = GenerationSession(prompt: "done", provider: .codex)
        session.phase = .succeeded
        session.finishedAt = .now
        model.generation = session

        model.cancelGeneration()

        XCTAssertEqual(session.phase, .succeeded)
        XCTAssertTrue(session.logs.isEmpty)
    }

    func testGenerationSessionChangesInvalidateAppModelObservers() {
        let model = makeModel()
        let session = GenerationSession(prompt: "forward updates", provider: .codex)
        model.generation = session
        var updateCount = 0
        let cancellable = model.objectWillChange.sink {
            updateCount += 1
        }

        session.phase = .running

        XCTAssertEqual(updateCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testCancellingFirstRunDoesNotPersistGeneratedToolApproval() throws {
        let store = AppletStore(
            fileURL: temporaryDirectory.appendingPathComponent("approval-applets.json")
        )
        let approvals = ShellApprovalStore(
            defaults: defaults,
            storageKey: "provisional-approvals"
        )
        let artifacts = GeneratedToolArtifactStore(
            rootURL: temporaryDirectory.appendingPathComponent("approval-artifacts", isDirectory: true)
        )
        let model = AppModel(
            store: store,
            preferences: AppPreferences(defaults: defaults),
            shellApprovals: approvals,
            generatedTools: artifacts
        )
        defer { model.shutdown() }

        let manifest = AppletManifest(
            name: "Provisional Approval",
            iconSystemName: "checkmark.shield",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            refreshIntervalSeconds: 30,
            config: AppletConfig(
                generatedSource: """
                #!/bin/zsh
                printf '%s\n' '{"title":"Ready","status":"Ready","details":[],"healthy":true,"values":{}}'
                """
            )
        )
        let saved = try store.upsert(manifest)
        _ = try artifacts.install(saved)

        model.setExecutionApproval(true, for: saved)
        XCTAssertEqual(model.bannerMessage, "Testing “\(saved.name)” before putting it live…")
        model.setEnabled(saved, enabled: false)

        XCTAssertFalse(approvals.isApproved(saved))
    }

    private func makeModel() -> AppModel {
        AppModel(
            store: AppletStore(fileURL: temporaryDirectory.appendingPathComponent("secondary-applets.json")),
            preferences: AppPreferences(defaults: defaults),
            shellApprovals: ShellApprovalStore(defaults: defaults, storageKey: "secondary-approvals"),
            generatedTools: GeneratedToolArtifactStore(
                rootURL: temporaryDirectory.appendingPathComponent("secondary-artifacts", isDirectory: true)
            )
        )
    }
}
