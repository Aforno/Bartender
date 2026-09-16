import SwiftUI

struct ProviderUnavailableBanner: View {
    let onSetup: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Your tools remain available, but creating or updating one needs a ready model provider.")
                .font(BarTenderFont.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Set Up…", action: onSetup)
                .buttonStyle(BarTenderPillButtonStyle())
        }
        .padding(.horizontal, PremiumStyle.space16)
        .padding(.vertical, 9)
        .background(
            PremiumStyle.raisedStrong,
            in: RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, PremiumStyle.space20)
        .frame(maxWidth: 620)
        .accessibilityElement(children: .contain)
    }
}
