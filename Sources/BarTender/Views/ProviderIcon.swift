import AppKit
import SwiftUI

/// The provider's official product artwork, bundled so the UI never depends on the network.
struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: Self.image(for: provider, logicalSize: size))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(provider == .codex ? size * 0.14 : 0)
            .frame(width: size, height: size)
            .background(provider == .codex ? Color.white : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }

    private static func image(for provider: AIProvider, logicalSize: CGFloat) -> NSImage {
        let name = provider.iconResourceName
        let url = AppResources.bundle.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "ProviderIcons"
        ) ?? AppResources.bundle.url(forResource: name, withExtension: "png")

        guard let url, let source = NSImage(contentsOf: url),
              let image = source.copy() as? NSImage else {
            preconditionFailure("Missing bundled provider icon: \(name).png")
        }
        // AppKit-backed Menu controls may extract an NSImage from a SwiftUI
        // label and ignore its surrounding frame. Give the image a bounded
        // logical size as well as a SwiftUI frame so it cannot expand to its
        // source artwork dimensions in the composer.
        image.size = NSSize(width: logicalSize, height: logicalSize)
        return image
    }
}
