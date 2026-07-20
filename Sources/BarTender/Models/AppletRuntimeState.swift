import Foundation

struct AppletSnapshot: Equatable, Sendable {
    var statusText: String
    var title: String
    var detailLines: [String]
    var isHealthy: Bool
    var values: [String: String]
    var updatedAt: Date
    var isRunning: Bool
    var progress: Double?

    static func placeholder(for manifest: AppletManifest) -> AppletSnapshot {
        AppletSnapshot(
            statusText: "Idle",
            title: manifest.name,
            detailLines: [manifest.kind.displayName],
            isHealthy: true,
            values: [:],
            updatedAt: .now,
            isRunning: false,
            progress: nil
        )
    }
}

enum AppletRuntimeEvent: Equatable, Sendable {
    case updated(AppletSnapshot)
    case completed(message: String)
    case failed(message: String)
}

enum ToolRunState: Equatable, Sendable {
    case disabled
    case reviewRequired
    case running
    case needsAttention
    case idle

    static func resolve(
        manifest: AppletManifest,
        snapshot: AppletSnapshot?,
        executionApproved: Bool
    ) -> ToolRunState {
        guard manifest.enabled else { return .disabled }
        if manifest.kind == .generatedTool && !executionApproved {
            return .reviewRequired
        }
        guard let snapshot else { return .idle }
        if !snapshot.isHealthy { return .needsAttention }
        return snapshot.isRunning ? .running : .idle
    }

    var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .reviewRequired: return "Review required"
        case .running: return "Live"
        case .needsAttention: return "Needs attention"
        case .idle: return "Idle"
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: return "pause.circle"
        case .reviewRequired: return "lock.fill"
        case .running: return "checkmark.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .idle: return "circle.dotted"
        }
    }
}
