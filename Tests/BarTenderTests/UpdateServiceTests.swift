import XCTest
@testable import BarTender

final class UpdateServiceTests: XCTestCase {
    func testVersionComparisonOrdersPrereleasesAndFailsClosed() {
        let cases = [
            ("1.0.0-beta.1", "1.0.0", false),
            ("1.0.0", "1.0.0-beta.1", true),
            ("1.0.0-beta.2", "1.0.0-beta.1", true),
            ("1.0.0-rc.1", "1.0.0-beta.9", true),
            ("1.0.0-adhoc", "1.0.0", false),
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

    func testChannelDetection() {
        XCTAssertEqual(UpdateService.Channel.of(version: "1.0.1-adhoc"), .adhoc)
        XCTAssertEqual(UpdateService.Channel.of(version: "1.0.0"), .stable)
        XCTAssertEqual(UpdateService.Channel.of(version: "2.0.0-ADHOC.1"), .adhoc)
    }

    func testAdhocChannelIgnoresDraftsAndStableOnlyReleases() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.2",
                htmlURL: "https://example.com/1.0.2",
                draft: false,
                prerelease: false,
                publishedBuildNumber: 5
            ),
            UpdateService.Release(
                tagName: "v1.0.2-adhoc",
                htmlURL: "https://example.com/1.0.2-adhoc",
                draft: true,
                prerelease: true,
                publishedBuildNumber: 6
            ),
            UpdateService.Release(
                tagName: "v1.0.1-adhoc",
                htmlURL: "https://example.com/1.0.1-adhoc",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 3
            )
        ]

        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.0-adhoc",
            currentBuild: "1",
            channel: .adhoc
        )

        guard case let .update(version, url) = selection else {
            return XCTFail("Expected ad-hoc update, got \(selection)")
        }
        XCTAssertEqual(version, "1.0.1-adhoc")
        XCTAssertEqual(url.absoluteString, "https://example.com/1.0.1-adhoc")
    }

    func testAdhocChannelRequiresPrereleaseFlag() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.9-adhoc",
                htmlURL: "https://example.com/not-prerelease",
                draft: false,
                prerelease: false,
                publishedBuildNumber: 99
            )
        ]

        XCTAssertEqual(
            UpdateService.selectRelease(
                from: releases,
                currentVersion: "1.0.1-adhoc",
                currentBuild: "2",
                channel: .adhoc
            ),
            .noneCompatible
        )
    }

    func testSelectsNewestAdhocWhenMultipleExist() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.1-adhoc",
                htmlURL: "https://example.com/old",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 2
            ),
            UpdateService.Release(
                tagName: "v1.0.3-adhoc",
                htmlURL: "https://example.com/new",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 4
            )
        ]

        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1-adhoc",
            currentBuild: "2",
            channel: .adhoc
        )
        guard case let .update(version, _) = selection else {
            return XCTFail("Expected newer ad-hoc release, got \(selection)")
        }
        XCTAssertEqual(version, "1.0.3-adhoc")
    }

    func testSameVersionNewerBuildIsOffered() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.1-adhoc+build.3",
                htmlURL: "https://example.com/build3",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 3
            )
        ]
        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1-adhoc",
            currentBuild: "2",
            channel: .adhoc
        )
        guard case .update = selection else {
            return XCTFail("Expected build-number update, got \(selection)")
        }
    }

    func testSameVersionSameOrOlderBuildIsCurrent() {
        let releases = [
            UpdateService.Release(
                tagName: "v1.0.1-adhoc+build.2",
                htmlURL: "https://example.com/build2",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 2
            )
        ]
        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1-adhoc",
            currentBuild: "2",
            channel: .adhoc
        )
        XCTAssertEqual(selection, .upToDate)
    }

    func testMalformedHighBuildReleaseCannotHideValidUpdate() {
        let releases = [
            UpdateService.Release(
                tagName: "broken-adhoc",
                htmlURL: "https://example.com/broken",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 999
            ),
            UpdateService.Release(
                tagName: "v1.0.2-adhoc+build.4",
                htmlURL: "https://example.com/valid",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 4
            )
        ]

        let selection = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1-adhoc",
            currentBuild: "2",
            channel: .adhoc
        )
        guard case let .update(version, url) = selection else {
            return XCTFail("Expected the valid update, got \(selection)")
        }
        XCTAssertEqual(version, "1.0.2-adhoc+build.4")
        XCTAssertEqual(url.absoluteString, "https://example.com/valid")
    }

    func testInvalidReleaseURLIsSkipped() {
        let releases = [
            UpdateService.Release(
                tagName: "v9.0.0-adhoc",
                htmlURL: "not a web URL",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 99
            ),
            UpdateService.Release(
                tagName: "v1.0.2-adhoc",
                htmlURL: "https://example.com/valid",
                draft: false,
                prerelease: true,
                publishedBuildNumber: 4
            )
        ]

        guard case let .update(version, _) = UpdateService.selectRelease(
            from: releases,
            currentVersion: "1.0.1-adhoc",
            currentBuild: "2",
            channel: .adhoc
        ) else {
            return XCTFail("Expected valid URL release to be selected")
        }
        XCTAssertEqual(version, "1.0.2-adhoc")
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
            currentVersion: "1.0.1-adhoc",
            currentBuild: "1",
            channel: .adhoc
        )
        XCTAssertEqual(selection, .noneCompatible)
    }

    func testDecodeReleasesSkipsMalformedEntries() throws {
        let json = """
        [
          {"tag_name": "v1.0.1-adhoc", "html_url": "https://example.com/a", "draft": false, "prerelease": true, "name": "Bar Tender 1.0.1-adhoc (build 4, ad-hoc)"},
          {"tag_name": 123, "html_url": "bad"},
          {"html_url": "https://example.com/missing-tag"},
          {"tag_name": "v1.0.0-adhoc", "html_url": "https://example.com/b", "draft": false, "prerelease": true}
        ]
        """.data(using: .utf8)!

        let releases = try UpdateService.decodeReleases(from: json)
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases[0].publishedBuildNumber, 4)
        XCTAssertEqual(releases[0].tagName, "v1.0.1-adhoc")
    }

    func testParseBuildNumberFromTitle() {
        XCTAssertEqual(
            UpdateService.parseBuildNumber(from: "Bar Tender 1.0.1-adhoc (build 12, ad-hoc)"),
            12
        )
        XCTAssertEqual(UpdateService.parseBuildNumber(from: "build: 7"), 7)
        XCTAssertNil(UpdateService.parseBuildNumber(from: "no build here"))
    }

    @MainActor
    func testExposesCurrentVersionAndBuildFromInfoDictionary() {
        let service = UpdateService(
            infoDictionary: [
                "CFBundleShortVersionString": "1.0.1-adhoc",
                "CFBundleVersion": "9"
            ]
        )
        XCTAssertEqual(service.currentVersion, "1.0.1-adhoc")
        XCTAssertEqual(service.currentBuildNumber, "9")
        XCTAssertEqual(service.channel, .adhoc)
    }
}
