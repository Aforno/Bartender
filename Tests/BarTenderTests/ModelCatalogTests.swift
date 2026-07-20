import Foundation
import XCTest
@testable import BarTender

final class ModelCatalogTests: XCTestCase {
    func testEmptyHomesUseDocumentedNonemptyFallbacks() throws {
        let home = temporaryHome()
        for provider in AIProvider.allCases {
            let models = ModelCatalog.models(for: provider, homeDirectoryURL: home)
            XCTAssertFalse(models.isEmpty, "\(provider.displayName) needs a fallback")
            XCTAssertEqual(models.filter(\.isDefault).count, 1)
            XCTAssertEqual(Set(models.map(\.id)).count, models.count)
            XCTAssertTrue(models.allSatisfy { !$0.modelID.isEmpty })
        }

        let claudeIDs = Set(ModelCatalog.models(for: .claude, homeDirectoryURL: home).map(\.modelID))
        XCTAssertEqual(claudeIDs, Set(["fable", "opus", "sonnet"]))
    }

    func testCodexCacheAcceptsNewModelsAndConfiguredDefaults() throws {
        let home = temporaryHome()
        try write(
            #"{"models":[{"slug":"future-codex","display_name":"Future Codex","visibility":"list"},{"slug":"hidden-model","visibility":"hidden"}]}"#,
            to: home.appendingPathComponent(".codex/models_cache.json")
        )
        try write("model = \"configured-codex\"\n", to: home.appendingPathComponent(".codex/config.toml"))

        let models = ModelCatalog.models(for: .codex, homeDirectoryURL: home)
        XCTAssertTrue(models.contains { $0.modelID == "future-codex" })
        XCTAssertFalse(models.contains { $0.modelID == "hidden-model" })
        XCTAssertEqual(models.first(where: \.isDefault)?.modelID, "configured-codex")
    }

    func testGrokDictionaryCacheAndClaudeConfiguredModelSurviveDrift() throws {
        let home = temporaryHome()
        try write(
            #"{"models":{"future":{"info":{"id":"grok-future","name":"Grok Future"}},"hidden":{"info":{"id":"grok-hidden","hidden":true}}}}"#,
            to: home.appendingPathComponent(".grok/models_cache.json")
        )
        try write("[models]\ndefault = \"grok-future\"\n", to: home.appendingPathComponent(".grok/config.toml"))
        try write(#"{"model":"claude-future-9"}"#, to: home.appendingPathComponent(".claude/settings.json"))

        let grok = ModelCatalog.models(for: .grok, homeDirectoryURL: home)
        XCTAssertEqual(grok.first(where: \.isDefault)?.modelID, "grok-future")
        XCTAssertFalse(grok.contains { $0.modelID == "grok-hidden" })

        let claude = ModelCatalog.models(for: .claude, homeDirectoryURL: home)
        XCTAssertEqual(claude.first(where: \.isDefault)?.modelID, "claude-future-9")
        XCTAssertTrue(claude.contains { $0.modelID == "sonnet" })
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-ModelCatalog-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
