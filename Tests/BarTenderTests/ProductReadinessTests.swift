import Foundation
import XCTest
@testable import BarTender

final class ProductReadinessTests: XCTestCase {
    func testBundledProviderIconsExistAndDecode() throws {
        for provider in AIProvider.allCases {
            let url = AppResources.bundle.url(
                forResource: provider.iconResourceName,
                withExtension: "png",
                subdirectory: "ProviderIcons"
            ) ?? AppResources.bundle.url(forResource: provider.iconResourceName, withExtension: "png")
            let resolved = try XCTUnwrap(url, "Missing icon for \(provider.displayName)")
            XCTAssertGreaterThan(try Data(contentsOf: resolved).count, 1_000)
        }
    }

    func testGeneratedToolEnvironmentUsesAnExplicitAllowlist() async {
        let environment = await ShellEnvironment.generatedToolEnvironment()
        let allowed = Set([
            "HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR",
            "LANG", "LC_ALL", "LC_CTYPE", "TERM", "NO_COLOR", "BARTENDER_CLI"
        ])
        XCTAssertTrue(Set(environment.keys).isSubset(of: allowed))
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["GITHUB_TOKEN"])
    }

    func testApprovedCommandAndGitEnvironmentsReuseTheAllowlist() {
        let inherited = [
            "HOME": "/Users/fixture",
            "PATH": "/usr/bin",
            "GITHUB_TOKEN": "secret",
            "OPENAI_API_KEY": "sk-test",
            "GIT_SSH_COMMAND": "ssh -i /tmp/id"
        ]
        let shell = ShellEnvironment.restrict(inherited)
        XCTAssertEqual(shell["HOME"], "/Users/fixture")
        XCTAssertEqual(shell["PATH"], "/usr/bin")
        XCTAssertNil(shell["GITHUB_TOKEN"])
        XCTAssertNil(shell["OPENAI_API_KEY"])
        XCTAssertNil(shell["GIT_SSH_COMMAND"])

        let git = ShellEnvironment.restrict(
            inherited,
            additionalValues: [
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_TERMINAL_PROMPT": "0"
            ]
        )
        XCTAssertEqual(git["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(git["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertNil(git["GITHUB_TOKEN"])
        XCTAssertNil(git["GIT_SSH_COMMAND"])
    }

    @MainActor
    func testLongTitlesAndProviderLogsStayBounded() {
        let title = String(repeating: "Long menu title ", count: 20)
        let shortened = TitleRenderer.shortMenuTitle(title)
        XCTAssertEqual(shortened.count, TitleRenderer.menuBarMaxLength)
        XCTAssertTrue(shortened.hasSuffix("…"))
        XCTAssertEqual(
            TitleRenderer.statusItemTitle(title, runState: .running).count,
            TitleRenderer.statusItemMaxLength
        )
        XCTAssertEqual(TitleRenderer.statusItemTitle(title, runState: .needsAttention), "Issue")

        let session = GenerationSession(prompt: "Long log", provider: .codex)
        for index in 0..<2_500 {
            session.append(stream: .stdout, "line \(index)")
        }
        XCTAssertEqual(session.logs.count, GenerationSession.maximumLogLines)
        XCTAssertEqual(session.logs.first?.text, "line 500")
        XCTAssertEqual(session.logs.last?.text, "line 2499")

        let huge = String(repeating: "x", count: ProviderLogLine.maximumTextCharacters + 500)
        let bounded = ProviderLogLine(stream: .stdout, text: huge)
        XCTAssertLessThanOrEqual(bounded.text.count, ProviderLogLine.maximumTextCharacters + 40)
        XCTAssertTrue(bounded.text.contains("truncated"))
        XCTAssertFalse(bounded.text.count > huge.count)
    }
}
