import Foundation
import XCTest
@testable import BarTender

@MainActor
final class ShellApprovalStoreTests: XCTestCase {
    func testApprovalIsBoundToExactCommandAndDirectory() {
        let defaults = makeDefaults()
        let store = ShellApprovalStore(defaults: defaults, storageKey: "approvals")
        let manifest = shellManifest(command: "echo safe", directory: "~/Projects")

        store.setApproved(true, for: manifest)
        XCTAssertTrue(store.isApproved(manifest))

        var changedCommand = manifest
        changedCommand.config.command = "echo changed"
        XCTAssertFalse(store.isApproved(changedCommand))

        var changedDirectory = manifest
        changedDirectory.config.workingDirectory = "~/Other"
        XCTAssertFalse(store.isApproved(changedDirectory))
    }

    func testApprovalPersistsSeparatelyFromManifest() {
        let defaults = makeDefaults()
        let manifest = shellManifest(command: "printf ok", directory: nil)

        ShellApprovalStore(defaults: defaults, storageKey: "approvals").setApproved(true, for: manifest)
        let reloaded = ShellApprovalStore(defaults: defaults, storageKey: "approvals")

        XCTAssertTrue(reloaded.isApproved(manifest))
        reloaded.revoke(id: manifest.id)
        XCTAssertFalse(reloaded.isApproved(manifest))
    }

    func testLegacyManifestApprovalFieldCannotAuthorizeExecution() throws {
        let manifest = shellManifest(command: "echo legacy", directory: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(manifest)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var config = try XCTUnwrap(object["config"] as? [String: Any])
        config["shellApproved"] = true
        object["config"] = config

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppletManifest.self, from: legacyData)
        let approvals = ShellApprovalStore(defaults: makeDefaults(), storageKey: "approvals")

        XCTAssertFalse(approvals.isApproved(decoded))
    }

    func testGeneratedToolApprovalIsBoundToExactSource() {
        let store = ShellApprovalStore(defaults: makeDefaults(), storageKey: "generated-approvals")
        let manifest = AppletManifest(
            name: "Generated",
            iconSystemName: "wand.and.sparkles",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            config: AppletConfig(generatedSource: "#!/bin/zsh\nprintf original")
        )

        store.setApproved(true, for: manifest)
        XCTAssertTrue(store.isApproved(manifest))

        var edited = manifest
        edited.config.generatedSource = "#!/bin/zsh\nprintf changed"
        XCTAssertFalse(store.isApproved(edited))
    }

    func testCreateReviewApproveRunReviseRevokeAndReapprove() async throws {
        let defaults = makeDefaults()
        let approvals = ShellApprovalStore(defaults: defaults, storageKey: "lifecycle-approvals")
        let artifacts = GeneratedToolArtifactStore(rootURL: temporaryDirectory())
        var manifest = generatedManifest(title: "Original")

        let review = await GeneratedToolRunner.run(
            manifest: manifest,
            approved: approvals.isApproved(manifest),
            artifactStore: artifacts
        )
        XCTAssertFalse(review.approved)
        XCTAssertNil(review.output)

        approvals.setApproved(true, for: manifest)
        let firstRun = await GeneratedToolRunner.run(
            manifest: manifest,
            approved: approvals.isApproved(manifest),
            artifactStore: artifacts
        )
        XCTAssertEqual(firstRun.output?.title, "Original", firstRun.message)

        manifest.config.generatedSource = generatedManifest(title: "Revised").config.generatedSource
        XCTAssertFalse(approvals.isApproved(manifest), "Editing source must revoke the prior fingerprint")
        let revisedReview = await GeneratedToolRunner.run(
            manifest: manifest,
            approved: approvals.isApproved(manifest),
            artifactStore: artifacts
        )
        XCTAssertFalse(revisedReview.approved)
        XCTAssertNil(revisedReview.output)

        approvals.revoke(id: manifest.id)
        XCTAssertFalse(approvals.isApproved(manifest))
        approvals.setApproved(true, for: manifest)
        let revisedRun = await GeneratedToolRunner.run(
            manifest: manifest,
            approved: approvals.isApproved(manifest),
            artifactStore: artifacts
        )
        XCTAssertEqual(revisedRun.output?.title, "Revised", revisedRun.message)
    }

    private func shellManifest(command: String, directory: String?) -> AppletManifest {
        AppletManifest(
            name: "Shell",
            iconSystemName: "terminal",
            kind: .shellCommand,
            titleTemplate: "{{value}}",
            refreshIntervalSeconds: 30,
            config: AppletConfig(command: command, workingDirectory: directory)
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "BarTenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func generatedManifest(title: String) -> AppletManifest {
        let payload = #"{"title":"\#(title)","status":"OK","details":[],"healthy":true,"values":{"value":"OK"}}"#
        return AppletManifest(
            name: title,
            iconSystemName: "wand.and.sparkles",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            config: AppletConfig(
                timeoutSeconds: 5,
                generatedSource: "#!/bin/zsh\nprintf '%s\\n' '\(payload)'"
            )
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-ApprovalLifecycle-\(UUID().uuidString)", isDirectory: true)
    }
}
