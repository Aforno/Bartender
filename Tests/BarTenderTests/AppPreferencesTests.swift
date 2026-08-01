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

    func testAutoApprovalRequiresAnExplicitManualRevisionOfAnApprovedGeneratedTool() {
        let original = generatedManifest(source: "#!/bin/zsh\nprintf original")
        var edited = original
        edited.config.generatedSource = "#!/bin/zsh\nprintf edited"
        var unrelated = edited
        unrelated.id = UUID()
        unrelated.config.generatedSource = "#!/bin/zsh\nprintf unrelated"
        let shell = AppletManifest(
            id: original.id,
            name: "Shell",
            iconSystemName: "terminal",
            kind: .shellCommand,
            titleTemplate: "{{value}}",
            config: AppletConfig(command: "printf shell")
        )

        let cases: [(AppletManifest?, AppletManifest, Bool, Bool, Bool, Bool)] = [
            (original, edited, true, true, false, true),
            (original, edited, false, true, false, false),
            (original, edited, true, false, false, false),
            (original, edited, true, true, true, false),
            (original, original, true, true, false, false),
            (nil, edited, true, true, false, false),
            (original, unrelated, true, true, false, false),
            (shell, shell, true, true, false, false)
        ]

        for (existing, saved, preferenceEnabled, approved, automaticRepair, expected) in cases {
            XCTAssertEqual(
                AppModel.shouldAutoApproveGeneratedToolEdit(
                    replacing: existing,
                    with: saved,
                    preferenceEnabled: preferenceEnabled,
                    previousVersionApproved: approved,
                    isAutomaticRepair: automaticRepair
                ),
                expected
            )
        }
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
