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

    /// The bundled Grok artwork is white. A plain `CIMaskToAlpha` keeps those
    /// white RGB values, and AppKit menu controls can display them literally
    /// instead of applying the SwiftUI template tint in light appearance.
    /// Build a genuinely monochrome black-alpha image first, then mark it as a
    /// template so AppKit can tint it correctly in both light and dark modes.
    private static func grokTemplateImage(from source: CIImage) -> NSImage? {
        let mask = source.applyingFilter("CIMaskToAlpha")
        let crop = mask.extent.insetBy(
            dx: mask.extent.width * 0.15,
            dy: mask.extent.height * 0.15
        )
        guard !crop.isEmpty else { return nil }

        let croppedMask = mask.cropped(to: crop)
        let black = CIImage(color: .black).cropped(to: crop)
        let blackGlyph = black.applyingFilter(
            "CISourceInCompositing",
            parameters: [kCIInputBackgroundImageKey: croppedMask]
        )
        let normalized = blackGlyph
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        let representation = NSCIImageRep(ciImage: normalized)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        image.isTemplate = true
        return image
    }
}
