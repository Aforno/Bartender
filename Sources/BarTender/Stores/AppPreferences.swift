import Combine
import Foundation

/// UserDefaults-backed app preferences shared across Settings and the main UI.
@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let confirmBeforeDelete = "BarTender.confirmBeforeDelete"
        static let showProviderInComposer = "BarTender.showProviderInComposer"
        static let autoApproveGeneratedToolEdits = "BarTender.autoApproveGeneratedToolEdits"
    }

    /// Ask for confirmation before deleting applets from the library.
    @Published var confirmBeforeDelete: Bool {
        didSet { defaults.set(confirmBeforeDelete, forKey: Keys.confirmBeforeDelete) }
    }

    /// Show the model selector inside the ChatGPT-style composer bar.
    @Published var showProviderInComposer: Bool {
        didSet { defaults.set(showProviderInComposer, forKey: Keys.showProviderInComposer) }
    }

    /// Approve provider-written revisions after the tool has been approved once.
    @Published var autoApproveGeneratedToolEdits: Bool {
        didSet {
            defaults.set(autoApproveGeneratedToolEdits, forKey: Keys.autoApproveGeneratedToolEdits)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: Keys.confirmBeforeDelete) == nil {
            confirmBeforeDelete = true
        } else {
            confirmBeforeDelete = defaults.bool(forKey: Keys.confirmBeforeDelete)
        }

        if defaults.object(forKey: Keys.showProviderInComposer) == nil {
            showProviderInComposer = true
        } else {
            showProviderInComposer = defaults.bool(forKey: Keys.showProviderInComposer)
        }

        if defaults.object(forKey: Keys.autoApproveGeneratedToolEdits) == nil {
            autoApproveGeneratedToolEdits = false
        } else {
            autoApproveGeneratedToolEdits = defaults.bool(forKey: Keys.autoApproveGeneratedToolEdits)
        }
    }

    /// Directory where applet manifests are stored.
    var libraryDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("BarTender", isDirectory: true)
    }

    var libraryFileURL: URL {
        libraryDirectoryURL.appendingPathComponent("applets.json")
    }
}
