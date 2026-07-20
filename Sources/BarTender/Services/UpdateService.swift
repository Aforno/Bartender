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
        let lhs = numericComponents(candidate)
        let rhs = numericComponents(current)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private nonisolated static func numericComponents(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { component in
            let digits = component.prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
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
