import Combine
import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    static let maximumMenuBarItemsBound = StatusItemManager.maximumIndividualItems

    private enum Keys {
        static let confirmBeforeDelete = "BarTender.confirmBeforeDelete"
        static let showProviderInComposer = "BarTender.showProviderInComposer"
        static let autoApproveGeneratedToolEdits = "BarTender.autoApproveGeneratedToolEdits"
        static let maximumMenuBarItems = "BarTender.maximumMenuBarItems"
    }

    @Published var confirmBeforeDelete: Bool {
        didSet { defaults.set(confirmBeforeDelete, forKey: Keys.confirmBeforeDelete) }
    }

    @Published var showProviderInComposer: Bool {
        didSet { defaults.set(showProviderInComposer, forKey: Keys.showProviderInComposer) }
    }

    @Published var autoApproveGeneratedToolEdits: Bool {
        didSet {
            defaults.set(autoApproveGeneratedToolEdits, forKey: Keys.autoApproveGeneratedToolEdits)
        }
    }

    static let defaultMaximumMenuBarItems = StatusItemManager.maximumIndividualItems

    @Published var maximumMenuBarItems: Int {
        didSet {
            let clamped = min(max(maximumMenuBarItems, 1), Self.maximumMenuBarItemsBound)
            guard clamped != maximumMenuBarItems else {
                defaults.set(maximumMenuBarItems, forKey: Keys.maximumMenuBarItems)
                return
            }
            maximumMenuBarItems = clamped
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

        // Unset means the user has not opted into a lower cap: give every
        // enabled applet an individual item up to the hard maximum.
        if defaults.object(forKey: Keys.maximumMenuBarItems) == nil {
            maximumMenuBarItems = Self.defaultMaximumMenuBarItems
        } else {
            maximumMenuBarItems = min(
                max(defaults.integer(forKey: Keys.maximumMenuBarItems), 1),
                Self.maximumMenuBarItemsBound
            )
        }
    }
}
