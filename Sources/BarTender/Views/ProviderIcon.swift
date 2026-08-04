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
            sourceImage
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(.primary)
                .padding(size * (provider == .codex ? 0.10 : 0))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// Claude, Gemini, and Antigravity ship multicolor product artwork; Codex/Grok are monochrome templates.
    private var usesFullColorIcon: Bool {
        switch provider {
        case .claude, .gemini, .agy:
            return true
        case .codex, .grok:
            return false
        }
    }

    private var sourceImage: Image {
        Image(nsImage: Self.image(for: provider, logicalSize: size))
    }

    private static func image(for provider: AIProvider, logicalSize: CGFloat) -> NSImage {
        let name = provider.iconResourceName
        let url = AppResources.bundle.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "ProviderIcons"
        ) ?? AppResources.bundle.url(forResource: name, withExtension: "png")

        guard let url else {
            preconditionFailure("Missing bundled provider icon: \(name).png")
        }

        let image: NSImage
        if provider == .grok,
           let source = CIImage(contentsOf: url),
           let template = grokTemplateImage(from: source) {
            image = template
        } else if let source = NSImage(contentsOf: url),
                  let copy = source.copy() as? NSImage {
            image = copy
            switch provider {
            case .codex:
                image.isTemplate = true
            case .claude, .grok, .gemini, .agy:
                image.isTemplate = false
            }
        } else {
            preconditionFailure("Could not decode bundled provider icon: \(name).png")
        }

        // AppKit-backed Menu controls may extract an NSImage from a SwiftUI
        // label and ignore its surrounding frame. Give the image a bounded
        // logical size as well as a SwiftUI frame so it cannot expand to its
        // source artwork dimensions in the composer.
        image.size = NSSize(width: logicalSize, height: logicalSize)
        return image
    }

    /// The bundled Grok artwork is white. Build a black alpha-mask and then
    /// rasterize it into a bitmap-backed NSImage before marking it as a template.
    /// Native AppKit Menu controls can bypass SwiftUI's rendering modifiers and
    /// display an NSCIImageRep's original white pixels literally in light mode;
    /// a bitmap template is reliably tinted with the current label color.
    private static func grokTemplateImage(from source: CIImage) -> NSImage? {
        let mask = source.applyingFilter("CIMaskToAlpha")
        // The source PNG includes generous canvas whitespace. Cropping 20% on
        // each edge gives Grok the same apparent scale as the other provider
        // marks while retaining enough breathing room around the glyph.
        let cropInsetFraction: CGFloat = 0.20
        let crop = mask.extent.insetBy(
            dx: mask.extent.width * cropInsetFraction,
            dy: mask.extent.height * cropInsetFraction
        )
        guard !crop.isEmpty else { return nil }

        let croppedMask = mask.cropped(to: crop)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: crop)
        let blackGlyph = black.applyingFilter(
            "CISourceInCompositing",
            parameters: [kCIInputBackgroundImageKey: croppedMask]
        )
        let normalized = blackGlyph
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
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
