import Foundation

struct GeneratedToolOutput: Codable, Equatable, Sendable {
    var title: String
    var status: String
    var details: [String]
    var healthy: Bool
    var values: [String: String]

    init(
        title: String,
        status: String,
        details: [String] = [],
        healthy: Bool = true,
        values: [String: String] = [:]
    ) {
        self.title = title
        self.status = status
        self.details = details
        self.healthy = healthy
        self.values = values
    }
}
