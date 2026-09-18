import SwiftUI

struct GenerationLogView: View {
    @ObservedObject var session: GenerationSession
    @State private var showTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine

            if let error = session.errorMessage, session.phase != .cancelled {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(BarTenderFont.body)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !session.logs.isEmpty {
                DisclosureGroup(isExpanded: $showTechnicalDetails) {
                    technicalLog
                        .padding(.top, PremiumStyle.space8)
                } label: {
                    HStack(spacing: 5) {
                        Text("Technical details")
                            .font(BarTenderFont.bodyEmphasis)
                        Text("· \(session.logs.count) events")
                            .font(BarTenderFont.caption)
                            .foregroundStyle(PremiumStyle.tertiaryText)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if session.phase.isActive {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text(session.phase == .running
                     ? session.logs.last(where: { $0.stream == .progress })?.text
                        ?? session.phase.displayName(for: session.provider)
                     : session.phase.displayName(for: session.provider))
                    .font(BarTenderFont.body)
                Spacer()
            }
        } else if let manifest = session.resultManifest {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(
                    session.isRevision
                        ? "Updated with \(session.provider.displayName)"
                        : "Built with \(session.provider.displayName)"
                )
                .font(BarTenderFont.body.weight(.semibold))
                .foregroundStyle(.green)
                Text("· \(successMetadata(for: manifest))")
                    .font(BarTenderFont.caption)
                    .foregroundStyle(PremiumStyle.tertiaryText)
            }
        } else if session.phase == .cancelled {
            Label("Build cancelled", systemImage: "stop.circle.fill")
                .font(BarTenderFont.body.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if session.errorMessage != nil {
            Label("Build failed", systemImage: "xmark.circle.fill")
                .font(BarTenderFont.body.weight(.semibold))
                .foregroundStyle(.red)
        }
    }

    private var technicalLog: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(session.logs) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.stream.rawValue.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(color(for: line.stream))
                            .frame(width: 52, alignment: .leading)

                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.82))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(PremiumStyle.space12)
        }
        .frame(minHeight: 100, maxHeight: 220)
        .borderedContainer(cornerRadius: PremiumStyle.chipRadius)
    }

    private func successMetadata(for manifest: AppletManifest) -> String {
        var details = [artifactLabel(for: manifest), manifest.refreshDescription.lowercased()]
        if let elapsedLabel {
            details.append(elapsedLabel)
        }
        return details.joined(separator: " · ")
    }

    private func artifactLabel(for manifest: AppletManifest) -> String {
        guard manifest.kind == .generatedTool else {
            return "\(manifest.kind.displayName) configuration"
        }
        let count = manifest.generatedSourceLineCount
        return "\(count) \(count == 1 ? "line" : "lines") of zsh"
    }

    private var elapsedLabel: String? {
        guard let finishedAt = session.finishedAt else { return nil }
        let elapsed = max(0, Int(finishedAt.timeIntervalSince(session.startedAt)))
        return elapsed < 60 ? "took \(elapsed)s" : "took \(elapsed / 60)m"
    }

    private func color(for stream: ProviderLogLine.Stream) -> Color {
        switch stream {
        case .stdout: return .secondary
        case .stderr: return .orange
        case .system, .progress: return PremiumStyle.brand
        }
    }
}
