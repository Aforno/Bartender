import SwiftUI

/// Plain-language disclosure for the app's deliberate trusted power-user model.
struct GeneratedCodeTrustDisclosure: View {
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Approval grants local code execution")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("generated-code-trust-disclosure")
    }

    private var message: String {
        "Bar Tender does not sandbox generated zsh. Approved code runs with your user privileges and can read or change files, use the network, access credentials available to local processes, and launch commands or apps. Static checks are advisory—approve only source you understand."
    }
}
