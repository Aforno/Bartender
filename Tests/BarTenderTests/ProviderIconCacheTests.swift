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

    func testMonochromeIconsAreLightEnoughForTheBlackCanvas() throws {
        for provider in [AIProvider.codex, .grok] {
            let image = ProviderIcon.ProviderIconCache.shared.baseImage(for: provider)
            let stats = try XCTUnwrap(
                opaqueLuminanceStats(image),
                "\(provider.displayName) should have opaque pixels"
            )
            XCTAssertGreaterThan(stats.count, 1_000, "\(provider.displayName) glyph is missing")
            XCTAssertGreaterThan(
                stats.mean,
                0.85,
                "\(provider.displayName) should be a light glyph, not black-on-black"
            )
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

    func testConcurrentFirstRequestsProcessOnlyOnce() {
        let cache = ProviderIcon.ProviderIconCache.shared
        cache.resetForTesting()

        let queue = DispatchQueue(label: "ProviderIconCacheTests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()

        for _ in 0..<12 {
            group.enter()
            queue.async {
                _ = cache.baseImage(for: .grok)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(cache.processingCount, 1)
    }

    func testSizedCopiesDoNotMutateCachedBase() {
        let cache = ProviderIcon.ProviderIconCache.shared
        let base = cache.baseImage(for: .claude)
        let originalSize = base.size

        let copy = ProviderIcon.image(for: .claude, logicalSize: 14)
        copy.size = NSSize(width: 14, height: 14)
        XCTAssertEqual(cache.baseImage(for: .claude).size, originalSize)
    }

    private func opaqueLuminanceStats(_ image: NSImage) -> (count: Int, mean: CGFloat)? {
        let bitmap: NSBitmapImageRep?
        if let existing = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            bitmap = existing
        } else if let tiff = image.tiffRepresentation {
            bitmap = NSBitmapImageRep(data: tiff)
        } else {
            bitmap = nil
        }
        guard let bitmap, bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
            return nil
        }

        var total: CGFloat = 0
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let converted = color.usingColorSpace(.sRGB) ?? color
                guard converted.alphaComponent >= 0.5 else { continue }
                total += 0.2126 * converted.redComponent
                    + 0.7152 * converted.greenComponent
                    + 0.0722 * converted.blueComponent
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (count, total / CGFloat(count))
    }
}
