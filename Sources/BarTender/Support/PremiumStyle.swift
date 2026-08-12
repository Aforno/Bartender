import AppKit
import SwiftUI

/// Bar Tender's window vocabulary, intentionally aligned with AgentNotch:
/// deep black, compact system typography, translucent raised surfaces, and a
/// restrained white-opacity hierarchy. State colour is reserved for meaning.
enum PremiumStyle {
    static let cardRadius: CGFloat = 9
    static let chipRadius: CGFloat = 7
    static let controlRadius: CGFloat = 8

    // MARK: - Spacing

    static let space2: CGFloat = 2
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32
    static let space40: CGFloat = 40

    static let contentMargin: CGFloat = 20
    static let sidebarInset: CGFloat = 10
    static let rowInsetH: CGFloat = 10
    static let rowInsetV: CGFloat = 6

    // MARK: - Palette

    static let canvas = Color.black
    static let sidebarBackground = Color.black
    static let raised = Color.white.opacity(0.055)
    static let raisedStrong = Color.white.opacity(0.10)
    static let raisedPressed = Color.white.opacity(0.135)
    static let fieldFill = Color.white.opacity(0.075)
    static let surfaceFill = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.08)
    static let chromeStroke = Color.white.opacity(0.14)
    static let selectionFill = Color.white.opacity(0.10)

    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.34)

    /// AgentNotch uses colour to communicate active state. Bar Tender follows
    /// that rule with system blue for active/building controls.
    static let brand = Color.blue
    static let brandDeep = Color.blue.opacity(0.76)
    static let brandGradient = LinearGradient(
        colors: [Color.white.opacity(0.92), Color.white.opacity(0.62)],
        startPoint: .top,
        endPoint: .bottom
    )
}

enum BarTenderFont {
    static let display = Font.system(size: 17, weight: .semibold)
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 12, weight: .regular)
    static let bodyEmphasis = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11, weight: .regular)
    static let footnote = Font.system(size: 10, weight: .regular)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    static let control = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 10, weight: .regular, design: .monospaced)
}

private struct BorderedContainer: ViewModifier {
    var cornerRadius: CGFloat = PremiumStyle.cardRadius

    func body(content: Content) -> some View {
        content
            .background(
                PremiumStyle.surfaceFill,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

private struct DeepBlackWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenAttached(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWhenAttached(nsView)
    }

    private func configureWhenAttached(_ view: NSView) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.isOpaque = true
            if window.styleMask.contains(.titled) {
                window.styleMask.insert([.miniaturizable, .resizable])
            }
        }
    }
}

extension View {
    /// AgentNotch-style raised surface. Panels are separated by fill and
    /// spacing; borders are reserved for interactive controls.
    func borderedContainer(cornerRadius: CGFloat = PremiumStyle.cardRadius) -> some View {
        modifier(BorderedContainer(cornerRadius: cornerRadius))
    }

    func deepBlackWindowSurface() -> some View {
        background(PremiumStyle.canvas)
            .background(DeepBlackWindowConfigurator())
            .preferredColorScheme(.dark)
    }
}

struct BarTenderHairline: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(PremiumStyle.cardStroke)
            .frame(height: 0.6)
            .padding(.leading, leadingInset)
    }
}

struct BarTenderPillButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BarTenderFont.control)
            .foregroundStyle(
                destructive
                    ? Color.red.opacity(configuration.isPressed ? 0.70 : 0.88)
                    : Color.white.opacity(configuration.isPressed ? 0.62 : 0.82)
            )
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                configuration.isPressed ? PremiumStyle.raisedPressed : PremiumStyle.raisedStrong,
                in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
                    .strokeBorder(PremiumStyle.cardStroke, lineWidth: 1)
            )
    }
}

struct BarTenderIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.55 : 0.72))
            .frame(width: 26, height: 26)
            .background(
                configuration.isPressed ? PremiumStyle.raisedPressed : PremiumStyle.raisedStrong,
                in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
                    .strokeBorder(PremiumStyle.cardStroke, lineWidth: 1)
            )
    }
}
