import Foundation
import XCTest
@testable import BarTender

@MainActor
final class AppletStoreTests: XCTestCase {
    func testLoadKeepsValidEntriesAndQuarantinesInvalidEntries() throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("applets.json")
        let valid = AppletManifest(
            name: "Valid",
            iconSystemName: "network",
            kind: .portMonitor,
            titleTemplate: "{{status}}",
            refreshIntervalSeconds: 5,
            config: AppletConfig(timeoutSeconds: 2, host: "localhost", port: 3000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(valid)) as? [String: Any]
        )
        var invalidObject = validObject
        invalidObject["id"] = UUID().uuidString
        invalidObject["name"] = "Invalid"
        var invalidConfig = try XCTUnwrap(invalidObject["config"] as? [String: Any])
        invalidConfig["port"] = 70000
        invalidObject["config"] = invalidConfig
        let library = try JSONSerialization.data(
            withJSONObject: [validObject, invalidObject],
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try library.write(to: fileURL)

        let store = AppletStore(fileURL: fileURL)

        XCTAssertEqual(store.applets.map(\.name), ["Valid"])
        XCTAssertNotNil(store.loadIssue)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("applets-rejected.json").path
        ))
    }

    func testFailedWriteDoesNotPublishInMemoryMutation() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockingFile = directory.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        let store = AppletStore(fileURL: blockingFile.appendingPathComponent("applets.json"))
        let manifest = AppletManifest(
            name: "Timer",
            iconSystemName: "timer",
            kind: .timer,
            titleTemplate: "{{remaining}}",
            config: AppletConfig(durationSeconds: 60)
        )

        XCTAssertThrowsError(try store.upsert(manifest))
        XCTAssertTrue(store.applets.isEmpty)
    }

    func testUpsertNormalizesBeforePersisting() throws {
        let fileURL = temporaryDirectory().appendingPathComponent("applets.json")
        let store = AppletStore(fileURL: fileURL)
        let manifest = AppletManifest(
            name: "  Timer  ",
            iconSystemName: "  timer  ",
            kind: .timer,
            titleTemplate: "  {{remaining}}  ",
            config: AppletConfig(durationSeconds: 60)
        )

        let saved = try store.upsert(manifest)

        XCTAssertEqual(saved.name, "Timer")
        XCTAssertEqual(store.applets.first?.iconSystemName, "timer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRevisionReplacesSelectedToolWithoutCreatingDuplicate() throws {
        let fileURL = temporaryDirectory().appendingPathComponent("applets.json")
        let store = AppletStore(fileURL: fileURL)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = AppletManifest(
            name: "Original",
            iconSystemName: "circle",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            enabled: false,
            createdAt: createdAt,
            sourcePrompt: "Original request",
            config: AppletConfig(generatedSource: "#!/bin/zsh\nprintf original")
        )
        try store.upsert(existing)
        let generated = AppletManifest(
            name: "Improved",
            iconSystemName: "sparkles",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            enabled: true,
            sourcePrompt: "Make it better",
            config: AppletConfig(generatedSource: "#!/bin/zsh\nprintf improved")
        )

        let replacement = ManifestGenerationSupport.replacing(
            generated,
            existingTool: existing
        )
        let saved = try store.upsert(replacement)

        XCTAssertEqual(store.applets.count, 1)
        XCTAssertEqual(saved.id, existing.id)
        XCTAssertEqual(saved.createdAt, createdAt)
        XCTAssertFalse(saved.enabled)
        XCTAssertEqual(saved.name, "Improved")
        XCTAssertEqual(saved.sourcePrompt, "Original request")
        XCTAssertTrue(saved.config.generatedSource?.contains("improved") == true)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTenderTests-\(UUID().uuidString)", isDirectory: true)
    }
}
