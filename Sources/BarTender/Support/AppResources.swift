import Foundation

/// Resolves resources from a conventional signed app bundle in distribution,
/// while retaining SwiftPM's generated bundle during development and tests.
enum AppResources {
    static let bundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("BarTender_BarTender.bundle", isDirectory: true),
           let packaged = Bundle(url: resourceURL) {
            return packaged
        }
        return Bundle.module
    }()
}
