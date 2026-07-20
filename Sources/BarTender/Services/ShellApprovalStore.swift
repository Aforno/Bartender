import CryptoKit
import Foundation

/// Stores execution approval separately from provider-generated and persisted manifests.
/// Approval is bound to the exact command/source and working directory.
@MainActor
final class ShellApprovalStore {
    private let defaults: UserDefaults
    private let storageKey: String
    private var approvals: [String: String]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "BarTender.shellApprovals.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.approvals = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    func isApproved(_ manifest: AppletManifest) -> Bool {
        guard let fingerprint = Self.fingerprint(for: manifest) else {
            return false
        }
        return approvals[manifest.id.uuidString] == fingerprint
    }

    func setApproved(_ approved: Bool, for manifest: AppletManifest) {
        let key = manifest.id.uuidString
        if approved, let fingerprint = Self.fingerprint(for: manifest) {
            approvals[key] = fingerprint
        } else {
            approvals.removeValue(forKey: key)
        }
        persist()
    }

    func revoke(id: UUID) {
        approvals.removeValue(forKey: id.uuidString)
        persist()
    }

    func removeAll() {
        approvals.removeAll()
        persist()
    }

    static func fingerprint(for manifest: AppletManifest) -> String? {
        let executableContent: String
        switch manifest.kind {
        case .shellCommand:
            executableContent = manifest.config.command?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .generatedTool:
            executableContent = manifest.config.generatedSource?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        default:
            return nil
        }
        guard !executableContent.isEmpty else { return nil }

        let directory = manifest.config.workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let canonical = manifest.kind.rawValue + "\u{0}" + executableContent + "\u{0}" + directory
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func persist() {
        defaults.set(approvals, forKey: storageKey)
    }
}
