import Foundation
import XCTest
@testable import BarTender

final class UpdateServiceTests: XCTestCase {
    private var mockSession: URLSession!

    override func setUp() {
        super.setUp()
        MockGitHubReleasesURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubReleasesURLProtocol.self]
        mockSession = URLSession(configuration: configuration)
    }

    override func tearDown() {
        MockGitHubReleasesURLProtocol.reset()
        mockSession = nil
        super.tearDown()
    }

    // MARK: - Semantic version / selection (pure)

    func testVersionComparisonOrdersPrereleasesAndFailsClosed() {
        let cases = [
            ("1.0.0-beta.1", "1.0.0", false),
            ("1.0.0", "1.0.0-beta.1", true),
            ("1.0.0-beta.2", "1.0.0-beta.1", true),
            ("1.0.0-rc.1", "1.0.0-beta.9", true),
            ("1.0.0", "1.0.0", false),
            // Semver compares prerelease identifiers in ASCII order: "Beta" < "alpha".
            ("1.0.0-Beta", "1.0.0-alpha", false),
            ("1.0.0-alpha", "1.0.0-Beta", true),
            ("1..0", "1.0.0", false),
            ("release", "1.0.0", false),
            ("1.0.1", "Development", false)
        ]

        for (candidate, current, expected) in cases {
            XCTAssertEqual(UpdateService.isVersion(candidate, newerThan: current), expected, candidate)
        }
    }

    func testChannelDetectionFromBundleMetadata() {
        XCTAssertEqual(
            UpdateService.Channel.of(infoDictionary: [
                UpdateService.Channel.infoDictionaryKey: "prerelease"
            ]),
            .prerelease
        )
        XCTAssertEqual(
            UpdateService.Channel.of(infoDictionary: [
                UpdateService.Channel.infoDictionaryKey: "stable"
            ]),
            .stable
        )
        // Missing or unknown defaults to prerelease (testing feed).
        XCTAssertEqual(UpdateService.Channel.of(infoDictionary: nil), .prerelease)
        XCTAssertEqual(
            UpdateService.Channel.of(infoDictionary: [
                UpdateService.Channel.infoDictionaryKey: "experimental"
            ]),
            .prerelease
        )
        // Version string must not drive the channel.
        XCTAssertEqual(
            UpdateService.Channel.of(infoDictionary: [
                "CFBundleShortVersionString": "1.0.1-adhoc"
            ]),
            .prerelease
        )
    }

    func testPrereleaseChannelIgnoresDraftsAndStableOnlyReleases() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.2",
                htmlURL: "https://example.com/1.0.2",
                draft: false,
                prerelease: false,
                publishedBuildNumber: 5
            ),
            UpdateService.Release(
                tagName: "v1.0.2",
                htmlURL: "https://example.com/1.0.2-draft",
                draft: true,
                prerelease: true,
                publishedBuildNumber: 6
            ),
            UpdateService.Release(
                tagName: "v1.0.1+build.3",
                htmlURL: "https://example.com/1.0.1-build3",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 3
            )
        ]

        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.0",
            currentBuild: "1",
            channel: .prerelease
        )

        guard case let .update(version, url) = selection else {
            return XCTFail("Expected prerelease update, got \(selection)")
        }
        XCTAssertEqual(version, "1.0.1+build.3")
        XCTAssertEqual(url.absoluteString, "https://example.com/1.0.1-build3")
    }

    func testPrereleaseChannelRequiresGitHubPrereleaseFlag() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.9",
                htmlURL: "https://example.com/not-prerelease",
                draft: false,
                prerelease: false,
                publishedBuildNumber: 99
            )
        ]

        XCTAssertEqual(
            UpdateService.selectRelease(
                from: releases,
                currentVersion: "1.0.1",
                currentBuild: "2",
                channel: .prerelease
            ),
            .noneCompatible
        )
    }

    func testStableChannelIgnoresPrereleases() {
        let releases = [
            UpdateService.Release(
                tagName: "v2.0.0",
                htmlURL: "https://example.com/2.0.0-pre",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 1
            ),
            UpdateService.Release(
                tagName: "v1.1.0",
                htmlURL: "https://example.com/1.1.0",
                draft: false,
                prerelease: false,
                publishedBuildNumber: 4
            )
        ]
        guard case let .update(version, _) = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1",
            currentBuild: "2",
            channel: .stable
        ) else {
            return XCTFail("Expected stable update")
        }
        XCTAssertEqual(version, "1.1.0")
    }

    func testSelectsNewestWhenMultipleExist() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.1",
                htmlURL: "https://example.com/old",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 2
            ),
            UpdateService.Release(
                tagName: "v1.0.3",
                htmlURL: "https://example.com/new",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 4
            )
        ]

        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1",
            currentBuild: "2",
            channel: .prerelease
        )
        guard case let .update(version, _) = selection else {
            return XCTFail("Expected newer prerelease, got \(selection)")
        }
        XCTAssertEqual(version, "1.0.3")
    }

    func testSameVersionNewerBuildIsOffered() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.1+build.3",
                htmlURL: "https://example.com/build3",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 3
            )
        ]
        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1",
            currentBuild: "2",
            channel: .prerelease
        )
        guard case .update = selection else {
            return XCTFail("Expected build-number update, got \(selection)")
        }
    }

    func testSameVersionSameOrOlderBuildIsCurrent() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.1+build.2",
                htmlURL: "https://example.com/build2",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 2
            )
        ]
        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1",
            currentBuild: "2",
            channel: .prerelease
        )
        XCTAssertEqual(selection, .upToDate)
    }

    func testMalformedHighBuildReleaseCannotHideValidUpdate() {
        let releases = [
            UpdateService.Release(
                tagName: "broken-tag",
                htmlURL: "https://example.com/broken",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 999
            ),
            UpdateService.Release(
                tagName: "v1.0.2+build.4",
                htmlURL: "https://example.com/valid",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 4
            )
        ]

        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1",
            currentBuild: "2",
            channel: .prerelease
        )
        guard case let .update(version, url) = selection else {
            return XCTFail("Expected the valid update, got \(selection)")
        }
        XCTAssertEqual(version, "1.0.2+build.4")
        XCTAssertEqual(url.absoluteString, "https://example.com/valid")
    }

    func testInvalidReleaseURLIsSkipped() {
        let releases = [
            UpdateService.Release(
                tagName: "v9.0.0",
                htmlURL: "not a web URL",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 99
            ),
            UpdateService.Release(
                tagName: "v1.0.2",
                htmlURL: "https://example.com/valid",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 4
            )
        ]

        guard case let .update(version, _) = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1",
            currentBuild: "2",
            channel: .prerelease
        ) else {
            return XCTFail("Expected valid URL release to be selected")
        }
        XCTAssertEqual(version, "1.0.2")
    }

    func testNoCompatibleRelease() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.2",
                htmlURL: "https://example.com/stable",
                draft: false,
                prerelease: false,
                publishedBuildNumber: 1
            )
        ]
        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1",
            currentBuild: "1",
            channel: .prerelease
        )
        XCTAssertEqual(selection, .noneCompatible)
    }

    func testDecodeReleasesSkipsMalformedEntries() throws {
        let json = """
        [
          {"tag_name": "v1.0.1+build.4", "html_url": "https://example.com/a", "draft": false, "prerelease": true, "name": "Bar Tender 1.0.1 (build 4)"},
          {"tag_name": 123, "html_url": "bad"},
          {"html_url": "https://example.com/missing-tag"},
          {"tag_name": "v1.0.0", "html_url": "https://example.com/b", "draft": false, "prerelease": true}
        ]
        """.data(using: .utf8)!

        let releases = try UpdateService.decodeReleases(from: json)
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases[0].publishedBuildNumber, 4)
        XCTAssertEqual(releases[0].tagName, "v1.0.1+build.4")
    }

    func testParseBuildNumberFromTitle() {
        XCTAssertEqual(
            UpdateService.parseBuildNumber(from: "Bar Tender 1.0.1 (build 12)"),
            12
        )
        XCTAssertEqual(UpdateService.parseBuildNumber(from: "build: 7"), 7)
        XCTAssertNil(UpdateService.parseBuildNumber(from: "no build here"))
    }

    @MainActor
    func testExposesCurrentVersionBuildAndChannelFromInfoDictionary() {
        let service = UpdateService(
            infoDictionary: [
                "CFBundleShortVersionString": "1.0.1",
                "CFBundleVersion": "9",
                UpdateService.Channel.infoDictionaryKey: "prerelease"
            ]
        )
        XCTAssertEqual(service.currentVersion, "1.0.1")
        XCTAssertEqual(service.currentBuildNumber, "9")
        XCTAssertEqual(service.channel, .prerelease)
    }

    func testNextPageURLParsesGitHubLinkHeader() {
        let header = #"<https://api.github.com/repos/Aforno/Bartender/releases?page=2&per_page=100>; rel="next", <https://api.github.com/repos/Aforno/Bartender/releases?page=5&per_page=100>; rel="last""#
        let next = UpdateService.nextPageURL(fromLinkHeader: header)
        XCTAssertEqual(
            next?.absoluteString,
            "https://api.github.com/repos/Aforno/Bartender/releases?page=2&per_page=100"
        )
        XCTAssertNil(UpdateService.nextPageURL(fromLinkHeader: #"<https://example.com>; rel="last""#))
        XCTAssertNil(UpdateService.nextPageURL(fromLinkHeader: ""))
    }

    // MARK: - fetchCompatibleRelease via mocked network

    func testFetchFollowsPaginationWhenFirstPageHasNoCompatibleRelease() async throws {
        let base = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?per_page=100")!
        MockGitHubReleasesURLProtocol.installPages([
            MockGitHubReleasesURLProtocol.Page(
                matching: base,
                statusCode: 200,
                linkHeader: #"<https://api.github.com/repos/Aforno/Bartender/releases?page=2&per_page=100>; rel="next""#,
                body: releaseJSON([
                    ["tag_name": "v9.0.0", "html_url": "https://example.com/stable", "draft": false, "prerelease": false, "name": "Bar Tender 9.0.0 (build 1)"]
                ])
            ),
            MockGitHubReleasesURLProtocol.Page(
                matching: URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?page=2&per_page=100")!,
                statusCode: 200,
                linkHeader: nil,
                body: releaseJSON([
                    ["tag_name": "v1.0.2+build.4", "html_url": "https://example.com/compatible", "draft": false, "prerelease": true, "name": "Bar Tender 1.0.2 (build 4)"]
                ])
            )
        ])

        let selection = try await UpdateService.fetchCompatibleRelease(
            releasesURL: base,
            session: mockSession,
            currentVersion: "1.0.1",
            currentBuild: "2",
            channel: .prerelease
        )

        guard case let .update(version, url) = selection else {
            return XCTFail("Expected update from page 2, got \(selection)")
        }
        XCTAssertEqual(version, "1.0.2+build.4")
        XCTAssertEqual(url.absoluteString, "https://example.com/compatible")
        XCTAssertEqual(MockGitHubReleasesURLProtocol.requestURLs.count, 2)
    }

    func testFetchContinuesPastCompatibleReleaseToFindSemanticallyNewerOne() async throws {
        // Page order is creation-time, not semver: page 1 has an older compatible
        // release; page 2 has a newer one. The old early-stop bug would pick page 1.
        let base = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?per_page=100")!
        MockGitHubReleasesURLProtocol.installPages([
            MockGitHubReleasesURLProtocol.Page(
                matching: base,
                statusCode: 200,
                linkHeader: #"<https://api.github.com/repos/Aforno/Bartender/releases?page=2&per_page=100>; rel="next""#,
                body: releaseJSON([
                    ["tag_name": "v1.0.1+build.5", "html_url": "https://example.com/1.0.1", "draft": false, "prerelease": true, "name": "Bar Tender 1.0.1 (build 5)"]
                ])
            ),
            MockGitHubReleasesURLProtocol.Page(
                matching: URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?page=2&per_page=100")!,
                statusCode: 200,
                linkHeader: nil,
                body: releaseJSON([
                    ["tag_name": "v1.1.0+build.1", "html_url": "https://example.com/1.1.0", "draft": false, "prerelease": true, "name": "Bar Tender 1.1.0 (build 1)"]
                ])
            )
        ])

        let selection = try await UpdateService.fetchCompatibleRelease(
            releasesURL: base,
            session: mockSession,
            currentVersion: "1.0.0",
            currentBuild: "1",
            channel: .prerelease
        )

        guard case let .update(version, url) = selection else {
            return XCTFail("Expected semantically newest update, got \(selection)")
        }
        XCTAssertEqual(version, "1.1.0+build.1")
        XCTAssertEqual(url.absoluteString, "https://example.com/1.1.0")
        XCTAssertEqual(MockGitHubReleasesURLProtocol.requestURLs.count, 2)
    }

    func testFetchFollowsThreeOrMorePagesViaLinkHeader() async throws {
        let page1 = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?per_page=100")!
        let page2 = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?page=2&per_page=100")!
        let page3 = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?page=3&per_page=100")!
        MockGitHubReleasesURLProtocol.installPages([
            .init(
                matching: page1,
                statusCode: 200,
                linkHeader: #"<\#(page2.absoluteString)>; rel="next""#,
                body: releaseJSON([
                    ["tag_name": "v0.9.0", "html_url": "https://example.com/0.9", "draft": false, "prerelease": true, "name": "Bar Tender 0.9.0 (build 1)"]
                ])
            ),
            .init(
                matching: page2,
                statusCode: 200,
                linkHeader: #"<\#(page3.absoluteString)>; rel="next", <\#(page3.absoluteString)>; rel="last""#,
                body: releaseJSON([
                    ["tag_name": "v1.0.0", "html_url": "https://example.com/1.0", "draft": false, "prerelease": true, "name": "Bar Tender 1.0.0 (build 1)"]
                ])
            ),
            .init(
                matching: page3,
                statusCode: 200,
                linkHeader: nil,
                body: releaseJSON([
                    ["tag_name": "v1.2.0+build.7", "html_url": "https://example.com/1.2", "draft": false, "prerelease": true, "name": "Bar Tender 1.2.0 (build 7)"]
                ])
            )
        ])

        let selection = try await UpdateService.fetchCompatibleRelease(
            releasesURL: page1,
            session: mockSession,
            currentVersion: "1.0.0",
            currentBuild: "1",
            channel: .prerelease
        )

        guard case let .update(version, _) = selection else {
            return XCTFail("Expected update after three pages, got \(selection)")
        }
        XCTAssertEqual(version, "1.2.0+build.7")
        XCTAssertEqual(MockGitHubReleasesURLProtocol.requestURLs.count, 3)
        XCTAssertEqual(
            MockGitHubReleasesURLProtocol.requestURLs.map(\.absoluteString),
            [page1, page2, page3].map(\.absoluteString)
        )
    }

    func testFetchStopsWhenNoNextLink() async throws {
        let base = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?per_page=100")!
        MockGitHubReleasesURLProtocol.installPages([
            .init(
                matching: base,
                statusCode: 200,
                linkHeader: #"<https://api.github.com/repos/Aforno/Bartender/releases?page=1&per_page=100>; rel="last""#,
                body: releaseJSON([
                    ["tag_name": "v1.0.1+build.2", "html_url": "https://example.com/current", "draft": false, "prerelease": true, "name": "Bar Tender 1.0.1 (build 2)"]
                ])
            )
        ])

        let selection = try await UpdateService.fetchCompatibleRelease(
            releasesURL: base,
            session: mockSession,
            currentVersion: "1.0.1",
            currentBuild: "2",
            channel: .prerelease
        )

        XCTAssertEqual(selection, .upToDate)
        XCTAssertEqual(MockGitHubReleasesURLProtocol.requestURLs.count, 1)
    }

    func testFetchSurfacesErrorOnLaterPage() async throws {
        let base = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?per_page=100")!
        let page2 = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?page=2&per_page=100")!
        MockGitHubReleasesURLProtocol.installPages([
            .init(
                matching: base,
                statusCode: 200,
                linkHeader: #"<\#(page2.absoluteString)>; rel="next""#,
                body: releaseJSON([
                    ["tag_name": "v1.0.1", "html_url": "https://example.com/1.0.1", "draft": false, "prerelease": true, "name": "Bar Tender 1.0.1 (build 1)"]
                ])
            ),
            .init(
                matching: page2,
                statusCode: 500,
                linkHeader: nil,
                body: Data("{\"message\":\"boom\"}".utf8)
            )
        ])

        do {
            _ = try await UpdateService.fetchCompatibleRelease(
                releasesURL: base,
                session: mockSession,
                currentVersion: "1.0.0",
                currentBuild: "1",
                channel: .prerelease
            )
            XCTFail("Expected HTTP error from page 2")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .httpStatus(500))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(MockGitHubReleasesURLProtocol.requestURLs.count, 2)
    }

    func testFetchRateLimitOnLaterPageIsPreserved() async throws {
        let base = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?per_page=100")!
        let page2 = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?page=2&per_page=100")!
        MockGitHubReleasesURLProtocol.installPages([
            .init(
                matching: base,
                statusCode: 200,
                linkHeader: #"<\#(page2.absoluteString)>; rel="next""#,
                body: releaseJSON([])
            ),
            .init(
                matching: page2,
                statusCode: 403,
                linkHeader: nil,
                body: Data("{\"message\":\"API rate limit exceeded\"}".utf8)
            )
        ])

        do {
            _ = try await UpdateService.fetchCompatibleRelease(
                releasesURL: base,
                session: mockSession,
                currentVersion: "1.0.0",
                currentBuild: "1",
                channel: .prerelease
            )
            XCTFail("Expected rate limit error")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    func testFetchRanksBySemanticVersionAcrossPagesNotPageOrder() async throws {
        // Page 1 created later but older version; page 2 older creation but higher version.
        let base = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?per_page=100")!
        let page2 = URL(string: "https://api.github.com/repos/Aforno/Bartender/releases?page=2&per_page=100")!
        MockGitHubReleasesURLProtocol.installPages([
            .init(
                matching: base,
                statusCode: 200,
                linkHeader: #"<\#(page2.absoluteString)>; rel="next""#,
                body: releaseJSON([
                    ["tag_name": "v1.0.5+build.9", "html_url": "https://example.com/1.0.5", "draft": false, "prerelease": true, "name": "Bar Tender 1.0.5 (build 9)"],
                    ["tag_name": "v1.0.4", "html_url": "https://example.com/1.0.4", "draft": false, "prerelease": true, "name": "Bar Tender 1.0.4 (build 1)"]
                ])
            ),
            .init(
                matching: page2,
                statusCode: 200,
                linkHeader: nil,
                body: releaseJSON([
                    ["tag_name": "v2.0.0+build.1", "html_url": "https://example.com/2.0.0", "draft": false, "prerelease": true, "name": "Bar Tender 2.0.0 (build 1)"],
                    ["tag_name": "v1.9.9", "html_url": "https://example.com/1.9.9", "draft": false, "prerelease": true, "name": "Bar Tender 1.9.9 (build 1)"]
                ])
            )
        ])

        let selection = try await UpdateService.fetchCompatibleRelease(
            releasesURL: base,
            session: mockSession,
            currentVersion: "1.0.0",
            currentBuild: "1",
            channel: .prerelease
        )

        guard case let .update(version, url) = selection else {
            return XCTFail("Expected highest semver across all pages, got \(selection)")
        }
        XCTAssertEqual(version, "2.0.0+build.1")
        XCTAssertEqual(url.absoluteString, "https://example.com/2.0.0")
    }

    // MARK: - Helpers

    private func releaseJSON(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: entries)
    }
}

// MARK: - Mock URLProtocol

private final class MockGitHubReleasesURLProtocol: URLProtocol, @unchecked Sendable {
    struct Page {
        var matching: URL
        var statusCode: Int
        var linkHeader: String?
        var body: Data
    }

    private static let lock = NSLock()
    private static var _pages: [Page] = []
    private static var _requestURLs: [URL] = []

    static var requestURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _requestURLs
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _pages = []
        _requestURLs = []
    }

    static func installPages(_ pages: [Page]) {
        lock.lock(); defer { lock.unlock() }
        _pages = pages
        _requestURLs = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self._requestURLs.append(url)
        let page = Self._pages.first { $0.matching.absoluteString == url.absoluteString }
        Self.lock.unlock()

        guard let page else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        var headers: [String: String] = ["Content-Type": "application/json"]
        if let link = page.linkHeader {
            headers["Link"] = link
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: page.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: page.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
