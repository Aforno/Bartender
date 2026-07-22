import SwiftUI

struct MenuBarPreviewView: View {
    let manifest: AppletManifest
    let snapshot: AppletSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuBarStrip
            dropdownMenu
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

            // The applet's own menu bar extra, shown "active".
            HStack(spacing: 5) {
                Image(systemName: manifest.iconSystemName)
                    .font(.system(size: 12, weight: .medium))
                Text(snapshot.title)
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
            .accessibilityLabel("Menu bar item: \(manifest.name), \(snapshot.title)")
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
            menuRow(manifest.name, systemImage: manifest.iconSystemName, isHeader: true)

            separator

            ForEach(snapshot.detailLines, id: \.self) { line in
                menuRow(TitleRenderer.shortMenuTitle(line), systemImage: nil)
            }

            if manifest.kind == .timer || manifest.kind == .countdown {
                separator
                menuRow(snapshot.isRunning ? "Pause" : "Start", systemImage: snapshot.isRunning ? "pause.fill" : "play.fill")
                menuRow("Reset", systemImage: "arrow.counterclockwise")
            }

            separator
            menuRow(
                previewStatusTitle,
                systemImage: snapshot.isHealthy ? "checkmark.circle" : "exclamationmark.triangle",
                tint: snapshot.isHealthy ? Color.green : Color.orange
            )

            if let progress = snapshot.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            separator
            HStack {
                Spacer()
                Text("Updated \(snapshot.updatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.inter(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PremiumStyle.fieldFill)
    }

    private var separator: some View {
        Divider()
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    private var previewStatusTitle: String {
        guard !snapshot.isHealthy else { return "Status: OK" }
        let unavailable = (snapshot.statusText + " " + snapshot.title)
            .localizedCaseInsensitiveContains("unavailable")
        return unavailable ? "Status: Unavailable" : "Status: Needs attention"
    }

    private func menuRow(
        _ title: String,
        systemImage: String?,
        isHeader: Bool = false,
        tint: Color = .secondary
    ) -> some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(tint)
            } else {
                Color.clear.frame(width: 16)
            }
            Text(title)
                .font(.inter(size: 13, weight: isHeader ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3.5)
    }
}
