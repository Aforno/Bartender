import SwiftUI

struct MenuBarPreviewView: View {
    let manifest: AppletManifest
    let snapshot: AppletSnapshot
    let runState: ToolRunState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuBarStrip
            if runState == .disabled {
                disabledMessage
            } else {
                dropdownMenu
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
                .strokeBorder(PremiumStyle.cardStroke, lineWidth: 1)
        )
    }

    // MARK: - Simulated menu bar

    private var menuBarStrip: some View {
        HStack(spacing: 0) {
            Spacer()

            // Faux system extras to ground the preview in the real menu bar.
            HStack(spacing: 14) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
                Image(systemName: "switch.2")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary.opacity(0.7))
            .accessibilityHidden(true)

            if runState != .disabled {
                // The applet's own menu bar extra, shown "active".
                HStack(spacing: 5) {
                    Image(systemName: manifest.iconSystemName)
                        .font(.system(size: 12, weight: .medium))
                    Text(displayTitle)
                        .font(.inter(size: 13, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(PremiumStyle.brand.opacity(0.20), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Menu bar item: \(manifest.name), \(displayTitle)")
            } else {
                Spacer()
                    .frame(width: 12)
            }
        }
        .frame(height: 26)
        .background(PremiumStyle.fieldFill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PremiumStyle.cardStroke)
                .frame(height: 1)
        }
    }

    // MARK: - Simulated dropdown menu

    private var dropdownMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow(TitleRenderer.shortMenuTitle(manifest.name), isHeader: true)
            menuRow(TitleRenderer.shortMenuTitle(displayStatus))

            separator

            ForEach(Array(displayDetails.prefix(5).enumerated()), id: \.offset) { _, line in
                menuRow(TitleRenderer.shortMenuTitle(line))
            }

            if manifest.kind == .timer || manifest.kind == .countdown {
                separator
                menuRow(snapshot.isRunning ? "Pause" : "Start", isAction: true)
                menuRow("Restart", isAction: true)
            }

            separator
            menuRow("Open in Bar Tender", isAction: true)
            menuRow("Disable", isAction: true)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PremiumStyle.fieldFill)
    }

    private var disabledMessage: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hidden while disabled")
                    .font(.inter(.callout, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Enable this tool to add its item back to the menu bar.")
                    .font(.inter(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(PremiumStyle.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PremiumStyle.fieldFill)
    }

    private var separator: some View {
        Divider()
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    private var displayTitle: String {
        TitleRenderer.statusItemTitle(snapshot.title, runState: runState)
    }

    private var displayStatus: String {
        if runState == .validating {
            return "Running the first-run check for this exact generated source."
        }
        if runState == .reviewRequired {
            return manifest.kind == .shellCommand
                ? "Shell command not approved. Review and allow it on the tool’s page."
                : "Ready to run — review and allow the generated code."
        }
        return snapshot.statusText
    }

    private var displayDetails: [String] {
        if runState == .validating {
            return [
                "Approval is still provisional",
                "The tool will go live only after a healthy result",
            ]
        }
        if runState == .reviewRequired {
            if manifest.kind == .shellCommand {
                return [
                    manifest.config.command ?? "No command configured",
                    "Awaiting approval",
                ]
            }
            return [
                "Generated code is installed",
                "Open Bar Tender to review and allow it",
            ]
        }
        return snapshot.detailLines
    }

    private func menuRow(
        _ title: String,
        isHeader: Bool = false,
        isAction: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.inter(size: 13, weight: isHeader ? .semibold : .regular))
                .foregroundStyle(isHeader || isAction ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3.5)
        .accessibilityAddTraits(isHeader ? .isHeader : [])
    }
}
