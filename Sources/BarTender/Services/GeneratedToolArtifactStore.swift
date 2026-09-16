import CryptoKit
import Foundation

struct GeneratedToolArtifactStore: Sendable {
    enum Error: LocalizedError {
        case revisionChanged

        var errorDescription: String? {
            switch self {
            case .revisionChanged:
                return "Generated source changed before it could run. Review and allow the current version."
            }
        }
    }

    private struct ApprovedExecutionCacheEntry {
        var source: String
        var digest: String
        var canonicalURL: URL
        var revisionURL: URL
        var canonicalSize: UInt64
        var canonicalModificationDate: Date
    }

    private final class ApprovedExecutionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [UUID: ApprovedExecutionCacheEntry] = [:]

        func entry(for id: UUID) -> ApprovedExecutionCacheEntry? {
            lock.lock()
            defer { lock.unlock() }
            return entries[id]
        }

        func store(_ entry: ApprovedExecutionCacheEntry, for id: UUID) {
            lock.lock()
            entries[id] = entry
            lock.unlock()
        }

        func remove(_ id: UUID) {
            lock.lock()
            entries.removeValue(forKey: id)
            lock.unlock()
        }

        func removeAll() {
            lock.lock()
            entries.removeAll()
            lock.unlock()
        }
    }

    private static let fileLock = NSLock()

    let rootURL: URL
    private let approvedExecutionCache = ApprovedExecutionCache()

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootURL = appSupport
                .appendingPathComponent("BarTender", isDirectory: true)
                .appendingPathComponent("GeneratedTools", isDirectory: true)
        }
    }

    func install(_ manifest: AppletManifest) throws -> URL {
        try Self.withFileLock {
            approvedExecutionCache.remove(manifest.id)
            let source = try Self.normalizedSource(for: manifest)
            let executable = executableURL(for: manifest)
            try Self.writeExecutable(source, to: executable)
            return executable
        }
    }

    /// Resolves an immutable, content-addressed executable for an approved
    /// revision. The canonical artifact for this UUID must already exist and
    /// contain the exact approved source. This prevents an older approved task
    /// from executing a newer, unapproved replacement at the shared path.
    func prepareApprovedExecution(_ manifest: AppletManifest) throws -> URL {
        try Self.withFileLock {
            let source = try Self.normalizedSource(for: manifest)
            if let cached = approvedExecutionCache.entry(for: manifest.id),
               cached.source == source,
               FileManager.default.fileExists(atPath: cached.revisionURL.path),
               Self.canonicalMatches(cached) {
                return cached.revisionURL
            }

            let canonicalExecutable = executableURL(for: manifest)
            guard (try? String(contentsOf: canonicalExecutable, encoding: .utf8)) == source else {
                throw Error.revisionChanged
            }

            let digest = Self.sha256Hex(source)
            let revisionExecutable = canonicalExecutable
                .deletingLastPathComponent()
                .appendingPathComponent("Revisions", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
                .appendingPathComponent("tool.zsh", isDirectory: false)
            try Self.writeExecutable(source, to: revisionExecutable)
            if let cached = Self.cacheEntry(
                source: source,
                digest: digest,
                canonicalURL: canonicalExecutable,
                revisionURL: revisionExecutable
            ) {
                approvedExecutionCache.store(cached, for: manifest.id)
            }
            return revisionExecutable
        }
    }

    /// Rechecks the shared artifact after any suspension between preparation
    /// and launch. The revision executable itself is content-addressed, so a
    /// replacement after this check can never change what this invocation runs.
    func validateApprovedExecution(_ manifest: AppletManifest, executable: URL) throws {
        try Self.withFileLock {
            let source = try Self.normalizedSource(for: manifest)
            if let cached = approvedExecutionCache.entry(for: manifest.id),
               cached.source == source,
               executable.standardizedFileURL == cached.revisionURL.standardizedFileURL,
               FileManager.default.fileExists(atPath: cached.revisionURL.path),
               Self.canonicalMatches(cached) {
                return
            }

            let canonicalExecutable = executableURL(for: manifest)
            let digest = Self.sha256Hex(source)
            let expectedRevisionExecutable = canonicalExecutable
                .deletingLastPathComponent()
                .appendingPathComponent("Revisions", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
                .appendingPathComponent("tool.zsh", isDirectory: false)

            guard executable.standardizedFileURL == expectedRevisionExecutable.standardizedFileURL,
                  (try? String(contentsOf: canonicalExecutable, encoding: .utf8)) == source,
                  (try? String(contentsOf: executable, encoding: .utf8)) == source else {
                throw Error.revisionChanged
            }
            if let cached = Self.cacheEntry(
                source: source,
                digest: digest,
                canonicalURL: canonicalExecutable,
                revisionURL: expectedRevisionExecutable
            ) {
                approvedExecutionCache.store(cached, for: manifest.id)
            }
        }
    }

    func remove(id: UUID) throws {
        try Self.withFileLock {
            approvedExecutionCache.remove(id)
            let directory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }
    }

    func removeAll() throws {
        try Self.withFileLock {
            approvedExecutionCache.removeAll()
            guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
            try FileManager.default.removeItem(at: rootURL)
        }
    }

    private func executableURL(for manifest: AppletManifest) -> URL {
        rootURL
            .appendingPathComponent(manifest.id.uuidString, isDirectory: true)
            .appendingPathComponent("tool.zsh", isDirectory: false)
    }

    private static func normalizedSource(for manifest: AppletManifest) throws -> String {
        guard manifest.kind == .generatedTool,
              let source = manifest.config.generatedSource else {
            throw ManifestValidationError.missingGeneratedSource
        }
        return source.hasSuffix("\n") ? source : source + "\n"
    }

    private static func writeExecutable(_ source: String, to executable: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = try? String(contentsOf: executable, encoding: .utf8)
        if existing != source {
            try source.write(to: executable, atomically: true, encoding: .utf8)
        }
        let mode = (try? fileManager.attributesOfItem(atPath: executable.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if mode & 0o777 != 0o700 {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: executable.path
            )
        }
    }

    private static func sha256Hex(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalMatches(_ entry: ApprovedExecutionCacheEntry) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: entry.canonicalURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else {
            return false
        }
        return size == entry.canonicalSize && modified == entry.canonicalModificationDate
    }

    private static func cacheEntry(
        source: String,
        digest: String,
        canonicalURL: URL,
        revisionURL: URL
    ) -> ApprovedExecutionCacheEntry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonicalURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return ApprovedExecutionCacheEntry(
            source: source,
            digest: digest,
            canonicalURL: canonicalURL,
            revisionURL: revisionURL,
            canonicalSize: size,
            canonicalModificationDate: modified
        )
    }

    private static func withFileLock<T>(_ operation: () throws -> T) rethrows -> T {
        fileLock.lock()
        defer { fileLock.unlock() }
        return try operation()
    }
}
