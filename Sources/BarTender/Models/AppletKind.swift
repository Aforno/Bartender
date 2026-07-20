import Foundation

enum AppletKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case generatedTool
    case timer
    case countdown
    case httpMonitor
    case portMonitor
    case systemMetrics
    case gitStatus
    case shellCommand

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .generatedTool: return "Generated Tool"
        case .timer: return "Timer"
        case .countdown: return "Countdown"
        case .httpMonitor: return "HTTP Monitor"
        case .portMonitor: return "Port Monitor"
        case .systemMetrics: return "System Metrics"
        case .gitStatus: return "Git Status"
        case .shellCommand: return "Shell Command"
        }
    }

    var defaultIcon: String {
        switch self {
        case .generatedTool: return "wand.and.sparkles"
        case .timer: return "timer"
        case .countdown: return "hourglass"
        case .httpMonitor: return "globe"
        case .portMonitor: return "network"
        case .systemMetrics: return "cpu"
        case .gitStatus: return "arrow.triangle.branch"
        case .shellCommand: return "terminal"
        }
    }

    var defaultRefreshInterval: Double? {
        switch self {
        case .generatedTool:
            return 30
        case .timer, .countdown:
            return nil
        case .httpMonitor, .portMonitor:
            return 10
        case .systemMetrics:
            return 2
        case .gitStatus:
            return 15
        case .shellCommand:
            return 30
        }
    }
}
