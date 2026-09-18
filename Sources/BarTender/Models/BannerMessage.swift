import Foundation

/// A transient message shown at the top of the main and settings windows.
/// Info banners dismiss themselves; errors stay until the user dismisses them.
struct BannerMessage: Equatable, Identifiable {
    enum Severity {
        case info
        case error
    }

    let id = UUID()
    let text: String
    let severity: Severity

    static func info(_ text: String) -> BannerMessage {
        BannerMessage(text: text, severity: .info)
    }

    static func error(_ text: String) -> BannerMessage {
        BannerMessage(text: text, severity: .error)
    }
}
