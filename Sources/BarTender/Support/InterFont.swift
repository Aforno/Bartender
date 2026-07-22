import AppKit
import CoreText
import SwiftUI

/// The app's typeface. Inter is bundled under `Resources/Fonts` and registered
/// with CoreText at launch; SwiftUI then resolves faces by PostScript name.
enum InterFont {
    /// Bundled faces, one file per weight (upright only).
    private static let faceNames = [
        "Inter-Thin",
        "Inter-ExtraLight",
        "Inter-Light",
        "Inter-Regular",
        "Inter-Medium",
        "Inter-SemiBold",
        "Inter-Bold",
        "Inter-ExtraBold",
        "Inter-Black",
    ]

    private static let registration: Void = {
        for name in faceNames {
            // SwiftPM keeps the Resources/Fonts subdirectory in the resource
            // bundle; the packaged app flattens nothing either, but fall back
            // to a bare lookup in case the layout changes.
            let url = AppResources.bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? AppResources.bundle.url(forResource: name, withExtension: "ttf")
            guard let url else {
                AppLog.app.error("Missing bundled font: \(name, privacy: .public)")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let description = error?.takeRetainedValue().localizedDescription ?? "unknown error"
                AppLog.app.error("Failed to register font \(name, privacy: .public): \(description, privacy: .public)")
            }
        }
    }()

    /// Idempotent registration; call once before any view renders.
    static func registerIfNeeded() { registration }
}

extension Font.Weight {
    /// PostScript name of the bundled Inter face matching this weight.
    var interFaceName: String {
        switch self {
        case .ultraLight: return "Inter-Thin"
        case .thin: return "Inter-ExtraLight"
        case .light: return "Inter-Light"
        case .regular: return "Inter-Regular"
        case .medium: return "Inter-Medium"
        case .semibold: return "Inter-SemiBold"
        case .bold: return "Inter-Bold"
        case .heavy: return "Inter-ExtraBold"
        case .black: return "Inter-Black"
        default: return "Inter-Regular"
        }
    }
}

extension Font {
    /// Inter at an explicit point size.
    static func inter(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight.interFaceName, size: size)
    }

    /// Inter matching a SwiftUI text style, keeping Dynamic Type scaling.
    /// Weight is baked into the face because `.weight(_:)` is ignored for
    /// custom fonts.
    static func inter(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(weight.interFaceName, size: style.interBaseSize, relativeTo: style)
    }
}

private extension Font.TextStyle {
    /// Default point size for the style, resolved from AppKit so it tracks
    /// platform conventions instead of hardcoded numbers.
    var interBaseSize: CGFloat {
        NSFont.preferredFont(forTextStyle: nsTextStyle).pointSize
    }

    var nsTextStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }
}
