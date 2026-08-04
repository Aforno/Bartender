import AppKit
import XCTest
@testable import BarTender

final class ProviderIconCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ProviderIcon.ProviderIconCache.shared.resetForTesting()
    }

    override func tearDown() {
        ProviderIcon.ProviderIconCache.shared.resetForTesting()
        super.tearDown()
    }

    func testGrokIsTemplate() {
        let image = ProviderIcon.image(for: .grok, logicalSize: 16)
        XCTAssertTrue(image.isTemplate)
    }

    func testCodexIsTemplate() {
        let image = ProviderIcon.image(for: .codex, logicalSize: 16)
        XCTAssertTrue(image.isTemplate)
    }

    func testColourProvidersAreNotTemplates() {
        for provider in [AIProvider.claude, .gemini, .agy] {
            let image = ProviderIcon.image(for: provider, logicalSize: 16)
            XCTAssertFalse(image.isTemplate, "\(provider.displayName) should be full colour")
        }
    }

    func testRepeatedRequestsDoNotReprocessSource() {
        let cache = ProviderIcon.ProviderIconCache.shared
        cache.resetForTesting()

        _ = cache.baseImage(for: .grok)
        let afterFirst = cache.processingCount
        XCTAssertEqual(afterFirst, 1)

        _ = cache.baseImage(for: .grok)
        _ = ProviderIcon.image(for: .grok, logicalSize: 14)
        _ = ProviderIcon.image(for: .grok, logicalSize: 18)
        XCTAssertEqual(cache.processingCount, 1)

        _ = cache.baseImage(for: .codex)
        XCTAssertEqual(cache.processingCount, 2)
    }

    func testSizedCopiesDoNotMutateCachedBase() {
        let cache = ProviderIcon.ProviderIconCache.shared
        let base = cache.baseImage(for: .claude)
        let originalSize = base.size

        let copy = ProviderIcon.image(for: .claude, logicalSize: 14)
        copy.size = NSSize(width: 14, height: 14)
        XCTAssertEqual(cache.baseImage(for: .claude).size, originalSize)
    }
}
