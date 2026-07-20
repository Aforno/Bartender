import Foundation

enum TitleRenderer {
    /// Caps menu bar titles to keep MenuBarExtra labels readable.
    static let menuBarMaxLength = 30

    static func render(template: String, values: [String: String], fallback: String) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        // Strip any unresolved placeholders.
        if let regex = try? NSRegularExpression(pattern: #"\{\{[^}]+\}\}"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        result = result
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty {
            result = fallback
        }
        return shortMenuTitle(result)
    }

    static func shortMenuTitle(_ title: String) -> String {
        if title.count <= menuBarMaxLength {
            return title
        }
        return String(title.prefix(menuBarMaxLength - 1)) + "…"
    }

    static func formatDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let h = clamped / 3600
        let m = (clamped % 3600) / 60
        let s = clamped % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", value.clamped(to: 0...100))
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
