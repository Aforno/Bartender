import AppKit
import CoreImage
import SwiftUI

/// The provider's official product artwork, bundled so the UI never depends on the network.
struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 18

    @ViewBuilder
    var body: some View {
        if provider == .claude {
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
           let source = CIImage(contentsOf: url)?.applyingFilter("CIMaskToAlpha") {
            let crop = source.extent.insetBy(
                dx: source.extent.width * 0.15,
                dy: source.extent.height * 0.15
            )
            let cropped = source
                .cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            let representation = NSCIImageRep(ciImage: cropped)
            image = NSImage(size: representation.size)
            image.addRepresentation(representation)
            image.isTemplate = true
        } else if let source = NSImage(contentsOf: url),
                  let copy = source.copy() as? NSImage {
            image = copy
            image.isTemplate = provider == .codex
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
}
