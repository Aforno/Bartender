import Foundation
import OSLog

enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.bartender.app"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let codex = Logger(subsystem: subsystem, category: "Codex")
    static let runtime = Logger(subsystem: subsystem, category: "Runtime")
    static let store = Logger(subsystem: subsystem, category: "Store")
    static let menuBar = Logger(subsystem: subsystem, category: "MenuBar")
    static let sidebar = Logger(subsystem: subsystem, category: "Sidebar")
}

extension Notification.Name {
    static let barTenderOpenMainWindow = Notification.Name("BarTenderOpenMainWindow")
}
