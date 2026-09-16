import AppKit
import CoreImage
import SwiftUI

/// The provider's official product artwork, bundled so the UI never depends on the network.
struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 18

    @ViewBuilder
    var body: some View {
        if usesFullColorIcon {
            sourceImage
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .accessibilityHidden(true)
        } else {
            // Monochrome marks are pre-rendered white. Draw the bitmap as-is so
            // SwiftUI/AppKit cannot re-tint them with `.primary` / label color,
            // which is black when the Mac is in light appearance.
            sourceImage
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(size * (provider == .codex ? 0.10 : 0))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// Claude, Gemini, and Antigravity ship multicolor product artwork; Codex/Grok are monochrome glyphs.
    private var usesFullColorIcon: Bool {
        switch provider {
        case .claude, .gemini, .agy:
            return true
        case .codex, .grok:
            return false
        }
    }

    private var sourceImage: Image {
        let nsImage = Self.image(for: provider, logicalSize: size)
        if !usesFullColorIcon {
            nsImage.isTemplate = false
        }
        return Image(nsImage: nsImage)
    }

    /// Returns a sized **copy** of the cached base image so AppKit controls can
    /// mutate logical size without affecting other views.
    static func image(for provider: AIProvider, logicalSize: CGFloat) -> NSImage {
        let base = ProviderIconCache.shared.baseImage(for: provider)
        let copy = (base.copy() as? NSImage) ?? base
        copy.size = NSSize(width: logicalSize, height: logicalSize)
        copy.isTemplate = base.isTemplate
        return copy
    }

    final class ProviderIconCache: @unchecked Sendable {
        static let shared = ProviderIconCache()

        private let lock = NSLock()
        private var images: [AIProvider: NSImage] = [:]
        private var processingRuns = 0

        /// Test-only count of base image processing runs.
        var processingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return processingRuns
        }

        func baseImage(for provider: AIProvider) -> NSImage {
            // Keep cache population inside one critical section. Icon processing
            // happens once per provider and is small enough that avoiding duplicate
            // Core Image work is more valuable than parallel first-load decoding.
            lock.lock()
            defer { lock.unlock() }

            if let cached = images[provider] {
                return cached
            }

            let processed = processBaseImage(for: provider)
            images[provider] = processed
            processingRuns += 1
            return processed
        }

        /// Resets cache state. Intended for unit tests only.
        func resetForTesting() {
            lock.lock()
            images.removeAll()
            processingRuns = 0
            lock.unlock()
        }

        private func processBaseImage(for provider: AIProvider) -> NSImage {
            let name = provider.iconResourceName
            let url = AppResources.bundle.url(
                forResource: name,
                withExtension: "png",
                subdirectory: "ProviderIcons"
            ) ?? AppResources.bundle.url(forResource: name, withExtension: "png")

            guard let url else {
                preconditionFailure("Missing bundled provider icon: \(name).png")
            }

            switch provider {
            case .codex, .grok:
                if let source = CIImage(contentsOf: url),
                   let glyph = lightGlyphImage(from: source, for: provider) {
                    return glyph
                }
                if let source = NSImage(contentsOf: url),
                   let tiff = source.tiffRepresentation,
                   let ciImage = CIImage(data: tiff),
                   let glyph = lightGlyphImage(from: ciImage, for: provider) {
                    return glyph
                }
                preconditionFailure("Could not decode bundled provider icon: \(name).png")
            case .claude, .gemini, .agy:
                guard let source = NSImage(contentsOf: url),
                      let copy = source.copy() as? NSImage else {
                    preconditionFailure("Could not decode bundled provider icon: \(name).png")
                }
                copy.isTemplate = false
                return copy
            }
        }

        /// Codex is a black blossom on transparency; Grok is a white mark on an
        /// opaque black square. Both become white-on-transparent bitmaps so they
        /// stay visible on Bar Tender's black canvas when template tinting is skipped.
        private func lightGlyphImage(from source: CIImage, for provider: AIProvider) -> NSImage? {
            let mask: CIImage
            switch provider {
            case .grok:
                let luminanceMask = source.applyingFilter("CIMaskToAlpha")
                // The source PNG includes generous canvas whitespace. Cropping 20% on
                // each edge gives Grok the same apparent scale as the other provider
                // marks while retaining enough breathing room around the glyph.
                let cropInsetFraction: CGFloat = 0.20
                let crop = luminanceMask.extent.insetBy(
                    dx: luminanceMask.extent.width * cropInsetFraction,
                    dy: luminanceMask.extent.height * cropInsetFraction
                )
                guard !crop.isEmpty else { return nil }
                mask = luminanceMask.cropped(to: crop)
            case .codex:
                mask = source
            case .claude, .gemini, .agy:
                return nil
            }

            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                .cropped(to: mask.extent)
            let glyph = white.applyingFilter(
                "CISourceInCompositing",
                parameters: [kCIInputBackgroundImageKey: mask]
            )
            let normalized = glyph
                .cropped(to: mask.extent)
                .transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            let extent = normalized.extent.integral
            let context = CIContext(options: [.cacheIntermediates: false])

            guard let cgImage = context.createCGImage(normalized, from: extent) else {
                return nil
            }

            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: extent.width, height: extent.height)
            )
            image.isTemplate = true
            return image
        }
    }
}
