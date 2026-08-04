import Foundation

@MainActor
final class UpdateService: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case current(String)
        case available(version: String, url: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases/latest")!

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    var statusText: String? {
        switch state {
        case .idle: return nil
        case .checking: return "Checking GitHub Releases…"
        case .current(let version): return "Bar Tender \(version) is current."
        case .available(let version, _): return "Bar Tender \(version) is available."
        case .failed(let message): return message
        }
    }

    var availableReleaseURL: URL? {
        guard case .available(_, let url) = state else { return nil }
        return url
    }

    func check() async {
        state = .checking
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("BarTender/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateError.invalidResponse
            }
            if http.statusCode == 404 {
                state = .failed("No published release is available yet.")
                return
            }
            guard (200...299).contains(http.statusCode) else {
                throw UpdateError.httpStatus(http.statusCode)
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard let url = URL(string: release.htmlURL) else {
                throw UpdateError.invalidResponse
            }
            if Self.isVersion(latest, newerThan: currentVersion) {
                state = .available(version: latest, url: url)
            } else {
                state = .current(currentVersion)
            }
        } catch {
            state = .failed("Update check failed: \(error.localizedDescription)")
        }
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let lhs = SemanticVersion(candidate),
              let rhs = SemanticVersion(current) else { return false }
        return lhs > rhs
    }

    private struct SemanticVersion: Comparable {
        private enum Identifier: Equatable {
            case numeric(Int)
            case text(String)
        }

        private let core: [Int]
        private let prerelease: [Identifier]?

        init?(_ rawValue: String) {
            var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.first == "v" || value.first == "V" {
                value.removeFirst()
            }
            value = String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])

            let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let corePart = parts.first, !corePart.isEmpty else { return nil }
            let coreStrings = corePart.split(separator: ".", omittingEmptySubsequences: false)
            guard !coreStrings.isEmpty,
                  coreStrings.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
                return nil
            }
            let parsedCore = coreStrings.compactMap { Int($0) }
            guard parsedCore.count == coreStrings.count else { return nil }
            core = parsedCore

            if parts.count == 1 {
                prerelease = nil
                return
            }

            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            prerelease = identifiers.map { identifier in
                if identifier.allSatisfy(\.isNumber), let number = Int(identifier) {
                    return .numeric(number)
                }
                // Semver compares alphanumeric identifiers in ASCII order — case-sensitive.
                return .text(String(identifier))
            }
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            for index in 0..<max(lhs.core.count, rhs.core.count) {
                let left = index < lhs.core.count ? lhs.core[index] : 0
                let right = index < rhs.core.count ? rhs.core[index] : 0
                if left != right { return left < right }
            }

            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil):
                return false
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case let (.some(left), .some(right)):
                for index in 0..<min(left.count, right.count) {
                    let comparison = compare(left[index], right[index])
                    if comparison != 0 { return comparison < 0 }
                }
                return left.count < right.count
            }
        }

        private static func compare(_ lhs: Identifier, _ rhs: Identifier) -> Int {
            switch (lhs, rhs) {
            case let (.numeric(left), .numeric(right)):
                return left == right ? 0 : (left < right ? -1 : 1)
            case (.numeric, .text):
                return -1
            case (.text, .numeric):
                return 1
            case let (.text(left), .text(right)):
                let result = left.compare(right)
                if result == .orderedSame { return 0 }
                return result == .orderedAscending ? -1 : 1
            }
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an invalid release response."
        case .httpStatus(let code): return "GitHub returned HTTP \(code)."
        }
    }
}
