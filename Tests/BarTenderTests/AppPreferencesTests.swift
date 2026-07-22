import Foundation
import XCTest
@testable import BarTender

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testAutoApproveGeneratedToolEditsDefaultsOffAndPersists() {
        let suite = "BarTenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.autoApproveGeneratedToolEdits)

        preferences.autoApproveGeneratedToolEdits = true

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.autoApproveGeneratedToolEdits)
    }

    func testAutoApprovalRequiresAChangedPreviouslyApprovedGeneratedTool() {
        let original = generatedManifest(source: "#!/bin/zsh\nprintf original")
        var edited = original
        edited.config.generatedSource = "#!/bin/zsh\nprintf edited"

        XCTAssertTrue(AppModel.shouldAutoApproveGeneratedToolEdit(
            replacing: original,
            with: edited,
            preferenceEnabled: true,
            previousVersionApproved: true,
            isAutomaticRepair: false
        ))
        XCTAssertFalse(AppModel.shouldAutoApproveGeneratedToolEdit(
            replacing: original,
            with: edited,
            preferenceEnabled: false,
            previousVersionApproved: true,
            isAutomaticRepair: false
        ))
        XCTAssertFalse(AppModel.shouldAutoApproveGeneratedToolEdit(
            replacing: original,
            with: edited,
            preferenceEnabled: true,
            previousVersionApproved: false,
            isAutomaticRepair: false
        ))
        XCTAssertFalse(AppModel.shouldAutoApproveGeneratedToolEdit(
            replacing: original,
            with: edited,
            preferenceEnabled: true,
            previousVersionApproved: true,
            isAutomaticRepair: true
        ))
        XCTAssertFalse(AppModel.shouldAutoApproveGeneratedToolEdit(
            replacing: original,
            with: original,
            preferenceEnabled: true,
            previousVersionApproved: true,
            isAutomaticRepair: false
        ))
    }

    func testAutoApprovalDoesNotApplyToNewImportedOrNonGeneratedTools() {
        let generated = generatedManifest(source: "#!/bin/zsh\nprintf generated")
        var unrelated = generated
        unrelated.id = UUID()
        unrelated.config.generatedSource = "#!/bin/zsh\nprintf unrelated"
        let shell = AppletManifest(
            id: generated.id,
            name: "Shell",
            iconSystemName: "terminal",
            kind: .shellCommand,
            titleTemplate: "{{value}}",
            config: AppletConfig(command: "printf shell")
        )

        XCTAssertFalse(AppModel.shouldAutoApproveGeneratedToolEdit(
            replacing: nil,
            with: generated,
            preferenceEnabled: true,
            previousVersionApproved: true,
            isAutomaticRepair: false
        ))
        XCTAssertFalse(AppModel.shouldAutoApproveGeneratedToolEdit(
            replacing: generated,
            with: unrelated,
            preferenceEnabled: true,
            previousVersionApproved: true,
            isAutomaticRepair: false
        ))
        XCTAssertFalse(AppModel.shouldAutoApproveGeneratedToolEdit(
            replacing: shell,
            with: shell,
            preferenceEnabled: true,
            previousVersionApproved: true,
            isAutomaticRepair: false
        ))
    }

    private func generatedManifest(source: String) -> AppletManifest {
        AppletManifest(
            name: "Generated",
            iconSystemName: "wand.and.sparkles",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            config: AppletConfig(generatedSource: source)
        )
    }
}
