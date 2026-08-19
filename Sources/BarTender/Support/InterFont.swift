import SwiftUI

/// Source-compatible system-font helpers. The AgentNotch redesign uses compact
/// system typography; restore custom-font resolution only if that direction
/// changes.
extension Font {
    static func inter(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func inter(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default).weight(weight)
    }
}
