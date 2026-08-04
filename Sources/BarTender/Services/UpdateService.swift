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

    /// Distribution channel inferred from the installed short version.
    enum Channel: Equatable, Sendable {
        case adhoc
        case stable

        static func of(version: String) -> Channel {
            let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.contains("adhoc") {
                return .adhoc
            }
            return .stable
        }
    }

    @Published private(set) var state: State = .idle

    /// Injectable for tests; production uses the shared session.
    nonisolated let session: URLSession
    nonisolated let releasesURL: URL
    /// Info dictionary override for tests (short version / build).
    nonisolated let infoDictionary: [String: Any]?

    nonisolated private static let defaultReleasesURL = URL(
        string: "https://api.github.com/repos/Aforno/Bartender/releases?per_page=30"
    )!

    init(
        session: URLSession = .shared,
        releasesURL: URL = UpdateService.defaultReleasesURL,
        infoDictionary: [String: Any]? = nil
    ) {
        self.session = session
        self.releasesURL = releasesURL
        self.infoDictionary = infoDictionary
    }

    var currentVersion: String {
        let info = infoDictionary ?? Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "Development"
    }

    var currentBuildNumber: String {
        let info = infoDictionary ?? Bundle.main.infoDictionary
        return info?["CFBundleVersion"] as? String ?? "0"
    }

    var channel: Channel {
        Channel.of(version: currentVersion)
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
        let version = currentVersion
        let build = currentBuildNumber
        let channel = self.channel
        let url = releasesURL
        let session = self.session

        do {
            let selection = try await Task.detached(priority: .utility) {
                try await Self.fetchCompatibleRelease(
                    releasesURL: url,
                    session: session,
                    currentVersion: version,
                    currentBuild: build,
                    channel: channel
                )
            }.value

            switch selection {
            case .upToDate:
                state = .current(version)
            case let .update(tag, htmlURL):
                state = .available(version: tag, url: htmlURL)
            case .noneCompatible:
                state = .failed("No compatible release is available for this build channel.")
            }
        } catch let error as UpdateError {
            state = .failed(error.localizedDescription)
        } catch let error as URLError {
            state = .failed("Network failure while checking for updates: \(error.localizedDescription)")
        } catch {
            state = .failed("Update check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pure selection (testable)

    enum Selection: Equatable, Sendable {
        case upToDate
        case update(version: String, url: URL)
        case noneCompatible
    }

    /// Decoded release fields used by the update checker.
    struct Release: Equatable, Sendable {
        var tagName: String
        var htmlURL: String
        var draft: Bool
        var prerelease: Bool
        /// Optional published build number from release metadata (title/name).
        var publishedBuildNumber: Int?
    }

    nonisolated static func fetchCompatibleRelease(
        releasesURL: URL,
        session: URLSession,
        currentVersion: String,
        currentBuild: String,
        channel: Channel
    ) async throws -> Selection {
        var request = URLRequest(url: releasesURL)
        request.setValue("BarTender/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw UpdateError.network(error.localizedDescription)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            break
        case 403, 429:
            throw UpdateError.rateLimited
        case 404:
            throw UpdateError.noCompatibleRelease
        default:
            throw UpdateError.httpStatus(http.statusCode)
        }

        let releases: [Release]
        do {
            releases = try decodeReleases(from: data)
        } catch {
            throw UpdateError.invalidResponse
        }

        return selectRelease(
            from: releases,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            channel: channel
        )
    }

    /// Decodes a GitHub releases list, skipping individual malformed entries.
    nonisolated static func decodeReleases(from data: Data) throws -> [Release] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Single-object payloads are invalid for the list endpoint.
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                throw UpdateError.invalidResponse
            }
            throw UpdateError.invalidResponse
        }

        return root.compactMap { dict -> Release? in
            guard let tagName = dict["tag_name"] as? String,
                  let htmlURL = dict["html_url"] as? String,
                  !tagName.isEmpty,
                  !htmlURL.isEmpty else {
                return nil
            }
            let draft = dict["draft"] as? Bool ?? false
            let prerelease = dict["prerelease"] as? Bool ?? false
            let name = dict["name"] as? String
            let body = dict["body"] as? String
            let build = parseBuildNumber(from: name) ?? parseBuildNumber(from: body)
            return Release(
                tagName: tagName,
                htmlURL: htmlURL,
                draft: draft,
                prerelease: prerelease,
                publishedBuildNumber: build
            )
        }
    }

    nonisolated static func selectRelease(
        from releases: [Release],
        currentVersion: String,
        currentBuild: String,
        channel: Channel
    ) -> Selection {
        let compatible = releases.filter { isCompatible($0, channel: channel) }
        guard !compatible.isEmpty else {
            return .noneCompatible
        }

        let ranked = compatible.sorted { lhs, rhs in
            compareReleases(lhs, rhs) == .orderedDescending
        }
        guard let newest = ranked.first else {
            return .noneCompatible
        }

        let newestVersion = normalizeTag(newest.tagName)
        let currentBuildInt = Int(currentBuild.trimmingCharacters(in: .whitespacesAndNewlines))

        if isRelease(newest, newerThanVersion: currentVersion, currentBuild: currentBuildInt) {
            guard let url = URL(string: newest.htmlURL) else {
                return .noneCompatible
            }
            return .update(version: newestVersion, url: url)
        }
        return .upToDate
    }

    nonisolated static func isCompatible(_ release: Release, channel: Channel) -> Bool {
        if release.draft { return false }
        let version = normalizeTag(release.tagName).lowercased()
        switch channel {
        case .adhoc:
            // Ad-hoc app builds track the ad-hoc prerelease channel only.
            return version.contains("adhoc")
        case .stable:
            return !release.prerelease && !version.contains("adhoc")
        }
    }

    /// True when `release` should be offered as an update over the installed identity.
    nonisolated static func isRelease(
        _ release: Release,
        newerThanVersion currentVersion: String,
        currentBuild: Int?
    ) -> Bool {
        let candidate = normalizeTag(release.tagName)
        if isVersion(candidate, newerThan: currentVersion) {
            return true
        }
        // Same semantic version: prefer a higher published build when available.
        guard versionsEqual(candidate, currentVersion),
              let publishedBuild = release.publishedBuildNumber,
              let currentBuild else {
            return false
        }
        return publishedBuild > currentBuild
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let lhs = SemanticVersion(candidate),
              let rhs = SemanticVersion(current) else { return false }
        return lhs > rhs
    }

    nonisolated static func versionsEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = SemanticVersion(lhs), let right = SemanticVersion(rhs) else {
            return normalizeTag(lhs) == normalizeTag(rhs)
        }
        return left == right
    }

    nonisolated static func normalizeTag(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        return value
    }

    nonisolated static func parseBuildNumber(from text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        // Match "build 12", "build: 12", or "(build 12)" in titles/notes.
        let pattern = #"(?i)\bbuild\s*[:=]?\s*(\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let buildRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[buildRange])
    }

    private nonisolated static func compareReleases(_ lhs: Release, _ rhs: Release) -> ComparisonResult {
        let leftVersion = normalizeTag(lhs.tagName)
        let rightVersion = normalizeTag(rhs.tagName)

        if isVersion(leftVersion, newerThan: rightVersion) {
            return .orderedDescending
        }
        if isVersion(rightVersion, newerThan: leftVersion) {
            return .orderedAscending
        }

        let leftBuild = lhs.publishedBuildNumber ?? 0
        let rightBuild = rhs.publishedBuildNumber ?? 0
        if leftBuild != rightBuild {
            return leftBuild > rightBuild ? .orderedDescending : .orderedAscending
        }
        return .orderedSame
    }

    // MARK: - Semantic version

    struct SemanticVersion: Comparable, Equatable, Sendable {
        private enum Identifier: Equatable, Sendable {
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

enum UpdateError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case network(String)
    case rateLimited
    case noCompatibleRelease

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid release response."
        case .httpStatus(let code):
            return "GitHub returned HTTP \(code)."
        case .network(let detail):
            return "Network failure while checking for updates: \(detail)"
        case .rateLimited:
            return "GitHub rate limited the update check. Try again in a few minutes."
        case .noCompatibleRelease:
            return "No compatible release is available for this build channel."
        }
    }
}
