import SwiftUI

/// The build receipt, Notion-style: one calm status line, with the raw
/// provider log tucked behind a "Technical details" toggle.
struct CodexLogView: View {
    @ObservedObject var session: GenerationSession
    @State private var showTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine

            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.inter(.callout))
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
                            .font(.inter(.callout, weight: .medium))
                        Text("· \(session.logs.count) events")
                            .font(.inter(.caption))
                            .foregroundStyle(.tertiary)
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
                Text(session.phase.displayName(for: session.provider))
                    .font(.inter(.callout))
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
                .font(.inter(.callout, weight: .semibold))
                .foregroundStyle(.green)
                Text("· \(sourceLineCount(manifest)) lines · every \(refreshLabel(manifest))" + (elapsedLabel.map { " · \($0)" } ?? ""))
                    .font(.inter(.caption))
                    .foregroundStyle(.tertiary)
            }
        } else if session.errorMessage != nil {
            Label("Build failed", systemImage: "xmark.circle.fill")
                .font(.inter(.callout, weight: .semibold))
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

    private func sourceLineCount(_ manifest: AppletManifest) -> Int {
        max(1, manifest.config.generatedSource?.split(whereSeparator: \.isNewline).count ?? 0)
    }

    private func refreshLabel(_ manifest: AppletManifest) -> String {
        let seconds = Int(manifest.refreshIntervalSeconds ?? manifest.kind.defaultRefreshInterval ?? 30)
        return seconds == 1 ? "second" : "\(seconds) seconds"
    }

    private var elapsedLabel: String? {
        guard let finishedAt = session.finishedAt else { return nil }
        let elapsed = max(0, Int(finishedAt.timeIntervalSince(session.startedAt)))
        return elapsed < 60 ? "took \(elapsed)s" : "took \(elapsed / 60)m"
    }

    private func color(for stream: CodexLogLine.Stream) -> Color {
        switch stream {
        case .stdout: return .secondary
        case .stderr: return .orange
        case .system: return PremiumStyle.brand
        }
    }
}
