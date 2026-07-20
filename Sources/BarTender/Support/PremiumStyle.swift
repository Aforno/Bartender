import SwiftUI

/// Bar Tender's shared visual language: flat SaaS-style surfaces separated by
/// hairlines, restrained status indicators, and minimal elevation.
enum PremiumStyle {
    /// Radius for the few remaining contained surfaces (previews, code blocks).
    static let cardRadius: CGFloat = 10
    /// Small radius for inline controls and code blocks.
    static let chipRadius: CGFloat = 7

    /// Hairline stroke used on contained surfaces and fields.
    static var cardStroke: Color { Color.primary.opacity(0.09) }
    /// Slightly stronger stroke used for focused or hovered chrome.
    static var chromeStroke: Color { Color.primary.opacity(0.16) }

    /// Flat fill for contained surfaces — no material, no elevation.
    static var surfaceFill: Color { Color.primary.opacity(0.035) }
}

// MARK: - Bordered container

private struct BorderedContainer: ViewModifier {
    var cornerRadius: CGFloat = PremiumStyle.cardRadius

    func body(content: Content) -> some View {
        content
            .background(
                PremiumStyle.surfaceFill,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PremiumStyle.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    /// Flat hairline-bordered surface — the only container style; no material, no shadow.
    func borderedContainer(cornerRadius: CGFloat = PremiumStyle.cardRadius) -> some View {
        modifier(BorderedContainer(cornerRadius: cornerRadius))
    }
}

// MARK: - Status label

/// Inline status indicator: a small tinted dot next to medium-weight text.
/// Replaces capsule badges — reads like a Linear/Vercel status, not a pill.
struct StatusLabel: View {
    let title: String
    var tint: Color

    init(_ title: String, tint: Color) {
        self.title = title
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

// MARK: - Section label

/// Consistent label used above sections in the detail pane.
struct CardSectionLabel: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Icon tile

/// Flat tinted tile for applet and brand imagery — no stroke, no elevation.
struct IconTile: View {
    let systemName: String
    var size: CGFloat = 44
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(0.10),
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
    }
}

// MARK: - Hover-aware row

/// Native-feeling interactive row: highlights on hover like a menu item.
struct HoverRow<Content: View>: View {
    var cornerRadius: CGFloat = 7
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                hovering ? Color.primary.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.12), value: hovering)
    }
}

// MARK: - Glowing status dot

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.55), radius: size * 0.45)
    }
}
