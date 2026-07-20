import Combine
import Foundation

/// UserDefaults-backed app preferences shared across Settings and the main UI.
@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let showInspectorOnLaunch = "BarTender.showInspectorOnLaunch"
        static let generationTimeoutSeconds = "BarTender.generationTimeoutSeconds"
        static let confirmBeforeDelete = "BarTender.confirmBeforeDelete"
        static let showProviderInComposer = "BarTender.showProviderInComposer"
    }

    /// Whether the inspector pane is shown when the app launches.
    @Published var showInspectorOnLaunch: Bool {
        didSet { defaults.set(showInspectorOnLaunch, forKey: Keys.showInspectorOnLaunch) }
    }

    /// CLI generation timeout in seconds (30…600).
    @Published var generationTimeoutSeconds: Double {
        didSet {
            let clamped = Self.clampTimeout(generationTimeoutSeconds)
            if clamped != generationTimeoutSeconds {
                generationTimeoutSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.generationTimeoutSeconds)
        }
    }

    /// Ask for confirmation before deleting applets from the library.
    @Published var confirmBeforeDelete: Bool {
        didSet { defaults.set(confirmBeforeDelete, forKey: Keys.confirmBeforeDelete) }
    }

    /// Show the model selector inside the ChatGPT-style composer bar.
    @Published var showProviderInComposer: Bool {
        didSet { defaults.set(showProviderInComposer, forKey: Keys.showProviderInComposer) }
    }

    var generationTimeout: TimeInterval {
        generationTimeoutSeconds
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: Keys.showInspectorOnLaunch) == nil {
            showInspectorOnLaunch = true
        } else {
            showInspectorOnLaunch = defaults.bool(forKey: Keys.showInspectorOnLaunch)
        }

        let storedTimeout = defaults.double(forKey: Keys.generationTimeoutSeconds)
        generationTimeoutSeconds = storedTimeout > 0
            ? Self.clampTimeout(storedTimeout)
            : 180

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
    }

    static func clampTimeout(_ value: Double) -> Double {
        min(600, max(30, value.rounded()))
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
