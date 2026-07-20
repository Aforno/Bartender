import AppKit
import SwiftUI

/// Bar Tender's shared visual language: a warm, bar-inspired palette — copper
/// brand tones, paper-tinted canvas, and hairlines that lean warm instead of
/// stock macOS gray. Flat SaaS-style surfaces, minimal elevation.
enum PremiumStyle {
    /// Radius for the few remaining contained surfaces (previews, code blocks).
    static let cardRadius: CGFloat = 10
    /// Small radius for inline controls and code blocks.
    static let chipRadius: CGFloat = 7

    // MARK: - Spacing

    /// 4pt spacing scale — the only spacing values used across the app.
    static let space2: CGFloat = 2
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32
    static let space40: CGFloat = 40

    /// Shared horizontal margin for the detail page and the composer, so the
    /// page body and the input bar track the same left edge.
    static let contentMargin: CGFloat = 28

    /// Inset for sidebar list containers (workspace menu, search, tool list, footer).
    static let sidebarInset: CGFloat = 6
    /// Horizontal padding inside rows (sidebar rows, property rows, hover rows).
    static let rowInsetH: CGFloat = 8
    /// Vertical padding inside rows.
    static let rowInsetV: CGFloat = 5

    // MARK: - Palette

    /// Adaptive light/dark color.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        })
    }

    /// Signature copper-amber — the house pour. Used for tint, selection,
    /// and brand imagery instead of the stock system blue.
    static var brand: Color {
        adaptive(
            light: NSColor(red: 0.678, green: 0.353, blue: 0.094, alpha: 1), // #AD5A18
            dark: NSColor(red: 0.918, green: 0.631, blue: 0.345, alpha: 1)   // #EAA158
        )
    }

    /// Deeper end of the brand pour, for gradients on brand imagery.
    static var brandDeep: Color {
        adaptive(
            light: NSColor(red: 0.482, green: 0.227, blue: 0.051, alpha: 1), // #7B3A0D
            dark: NSColor(red: 0.761, green: 0.435, blue: 0.176, alpha: 1)   // #C26F2D
        )
    }

    /// Vertical gradient for brand imagery (app mark, hero glyphs).
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [brand, brandDeep],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Warm paper canvas for the detail pane — reads crafted, not stock.
    static var canvas: Color {
        adaptive(
            light: NSColor(red: 0.984, green: 0.965, blue: 0.937, alpha: 1), // #FBF6EF
            dark: NSColor(red: 0.106, green: 0.090, blue: 0.078, alpha: 1)   // #1B1714
        )
    }

    // MARK: - Warm neutrals

    /// Base hue for warm-tinted hairlines and fills.
    private static var warmInk: Color {
        adaptive(
            light: NSColor(red: 0.28, green: 0.20, blue: 0.11, alpha: 1),
            dark: NSColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1)
        )
    }

    /// Hairline stroke used on contained surfaces and fields.
    static var cardStroke: Color { warmInk.opacity(0.10) }
    /// Slightly stronger stroke used for focused or hovered chrome.
    static var chromeStroke: Color { warmInk.opacity(0.17) }

    /// Flat fill for contained surfaces — no material, no elevation.
    static var surfaceFill: Color { warmInk.opacity(0.045) }

    /// Elevated surface for inputs, cards, and floating chrome — paper-bright
    /// in light mode, warm charcoal in dark. The single "lifted" background;
    /// everything else is either `canvas` or `surfaceFill`.
    static var fieldFill: Color {
        adaptive(
            light: NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1),        // white on paper
            dark: NSColor(red: 0.176, green: 0.153, blue: 0.133, alpha: 1)   // #2D2722 warm charcoal
        )
    }

    /// Sidebar selection wash — a pour of brand instead of neutral gray.
    static var selectionFill: Color { brand.opacity(0.16) }
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
    var tint: Color = PremiumStyle.brand

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .padding(.horizontal, PremiumStyle.rowInsetH)
            .padding(.vertical, PremiumStyle.rowInsetV)
            .background(
                hovering ? Color.primary.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: hovering)
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
