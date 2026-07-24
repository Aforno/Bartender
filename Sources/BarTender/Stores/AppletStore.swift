import Combine
import Foundation

enum AppletStoreError: LocalizedError {
    case invalidLibraryFormat
    case unsupportedArchiveVersion(Int)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidLibraryFormat:
            return "The selected file is not a Bar Tender library archive."
        case .unsupportedArchiveVersion(let version):
            return "This library uses unsupported archive format \(version)."
        case .persistenceFailed(let detail):
            return "Could not save the applet library: \(detail)"
        }
    }
}

struct AppletLibraryArchive: Codable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var exportedAt: Date
    var applets: [AppletManifest]

    init(applets: [AppletManifest], exportedAt: Date = .now) {
        formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.applets = applets
    }
}

enum AppletImportMode: Equatable {
    case merge
    case replace
}

@MainActor
final class AppletStore: ObservableObject {
    @Published private(set) var applets: [AppletManifest] = []
    @Published private(set) var loadIssue: String?

    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let directory = appSupport.appendingPathComponent("BarTender", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("applets.json")
        }
        load()
    }

    var enabledApplets: [AppletManifest] {
        applets.filter(\.enabled)
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            applets = []
            loadIssue = nil
            AppLog.store.info("No saved applets yet")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            guard let objects = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw AppletStoreError.invalidLibraryFormat
            }

            var valid: [AppletManifest] = []
            var rejected: [Any] = []
            for object in objects {
                do {
                    let entryData = try JSONSerialization.data(withJSONObject: object)
                    let decoded = try decoder.decode(AppletManifest.self, from: entryData)
                    valid.append(try ManifestValidator.normalizedAndValidated(decoded))
                } catch {
                    rejected.append(object)
                    AppLog.store.error("Rejected invalid applet: \(error.localizedDescription, privacy: .public)")
                }
            }

            applets = valid
            if rejected.isEmpty {
                loadIssue = nil
            } else {
                let recovery = recoveryURL(named: "applets-rejected.json")
                let recoveryMessage: String
                do {
                    try ensureStorageDirectory()
                    let rejectedData = try JSONSerialization.data(
                        withJSONObject: rejected,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    try rejectedData.write(to: recovery, options: [.atomic])
                    recoveryMessage = " A recovery copy was saved to \(recovery.path)."
                } catch {
                    recoveryMessage = " The recovery copy could not be written: \(error.localizedDescription)"
                }
                loadIssue = "Ignored \(rejected.count) invalid applet\(rejected.count == 1 ? "" : "s").\(recoveryMessage)"
            }
            AppLog.store.info("Loaded \(self.applets.count, privacy: .public) valid applets")
        } catch {
            let recovery = recoveryURL(named: "applets-corrupt.json")
            var message = "Could not load the applet library: \(error.localizedDescription)."
            if let data = try? Data(contentsOf: fileURL) {
                do {
                    try ensureStorageDirectory()
                    try data.write(to: recovery, options: [.atomic])
                    message += " A recovery copy was saved to \(recovery.path)."
                } catch {
                    message += " The recovery copy could not be written: \(error.localizedDescription)"
                }
            }
            loadIssue = message
            AppLog.store.error("Failed to load applets: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func upsert(_ manifest: AppletManifest) throws -> AppletManifest {
        var copy = try ManifestValidator.normalizedAndValidated(manifest)
        copy.updatedAt = .now

        var next = applets
        if let index = next.firstIndex(where: { $0.id == copy.id }) {
            next[index] = copy
        } else {
            next.insert(copy, at: 0)
        }
        try commit(next)
        return copy
    }

    func delete(id: UUID) throws {
        var next = applets
        next.removeAll { $0.id == id }
        try commit(next)
    }

    @discardableResult
    func setEnabled(id: UUID, enabled: Bool) throws -> AppletManifest? {
        guard let index = applets.firstIndex(where: { $0.id == id }) else { return nil }
        var next = applets
        next[index].enabled = enabled
        next[index].updatedAt = .now
        try commit(next)
        return next[index]
    }

    func update(_ id: UUID, mutate: (inout AppletManifest) -> Void) throws {
        guard let index = applets.firstIndex(where: { $0.id == id }) else { return }
        var next = applets
        mutate(&next[index])
        next[index] = try ManifestValidator.normalizedAndValidated(next[index])
        next[index].updatedAt = .now
        try commit(next)
    }

    func applet(id: UUID?) -> AppletManifest? {
        guard let id else { return nil }
        return applets.first { $0.id == id }
    }

    /// Removes every applet and persists an empty library.
    func removeAll() throws {
        try commit([])
    }

    func exportArchiveData() throws -> Data {
        try encoder.encode(AppletLibraryArchive(applets: applets))
    }

    /// Decodes and validates an archive without mutating the on-disk library.
    func validatedManifests(from data: Data) throws -> [AppletManifest] {
        let archive: AppletLibraryArchive
        do {
            archive = try decoder.decode(AppletLibraryArchive.self, from: data)
        } catch {
            throw AppletStoreError.invalidLibraryFormat
        }
        guard archive.formatVersion == AppletLibraryArchive.currentFormatVersion else {
            throw AppletStoreError.unsupportedArchiveVersion(archive.formatVersion)
        }
        return try archive.applets.map(ManifestValidator.normalizedAndValidated)
    }

    /// Imports only manifests. Approval fingerprints and executable artifacts
    /// are deliberately outside the archive and are handled by AppModel.
    @discardableResult
    func importArchiveData(_ data: Data, mode: AppletImportMode) throws -> [AppletManifest] {
        let imported = try validatedManifests(from: data)
        try applyImport(imported, mode: mode)
        return imported
    }

    /// Commits a previously validated import set (see `validatedManifests(from:)`).
    func applyImport(_ imported: [AppletManifest], mode: AppletImportMode) throws {
        var next = mode == .replace ? [] : applets
        for manifest in imported.reversed() {
            if let index = next.firstIndex(where: { $0.id == manifest.id }) {
                next[index] = manifest
            } else {
                next.insert(manifest, at: 0)
            }
        }
        try commit(next)
    }

    /// Replaces the entire library (used to roll back a failed import).
    func replaceAll(_ manifests: [AppletManifest]) throws {
        try commit(manifests)
    }

    /// On-disk location of the library file (for Settings “Reveal in Finder”).
    var storageURL: URL { fileURL }

    private func commit(_ next: [AppletManifest]) throws {
        do {
            try ensureStorageDirectory()
            let data = try encoder.encode(next)
            try data.write(to: fileURL, options: [.atomic])
            applets = next
        } catch {
            AppLog.store.error("Failed to save applets: \(error.localizedDescription, privacy: .public)")
            throw AppletStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    private func ensureStorageDirectory() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func recoveryURL(named name: String) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }
}
