import Foundation
import XCTest
@testable import BarTender

final class ProcessAndProviderTests: XCTestCase {
    func testProcessRunnerSupportsConcurrentInvocations() async throws {
        let runner = ProcessRunner()

        async let first = runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 0.1; printf one"],
            timeout: 2
        )
        async let second = runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 0.1; printf two"],
            timeout: 2
        )

        let (firstResult, secondResult) = try await (first, second)
        XCTAssertEqual(firstResult.stdout, "one")
        XCTAssertEqual(secondResult.stdout, "two")
        XCTAssertFalse(firstResult.cancelled)
        XCTAssertFalse(secondResult.cancelled)
    }

    func testProcessRunnerTimeoutAndCancellation() async throws {
        let runner = ProcessRunner()
        let timedOut = try await runner.run(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.05
        )
        XCTAssertTrue(timedOut.timedOut)

        let task = Task {
            try await runner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 10)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await runner.cancel()
        let cancelled = try await task.value
        XCTAssertTrue(cancelled.cancelled)
    }

    @MainActor
    func testProviderNonzeroExitCannotReturnParseableManifest() {
        let manifest = #"{"name":"Timer","iconSystemName":"timer","kind":"timer","titleTemplate":"{{remaining}}","config":{"durationSeconds":60}}"#
        let result = ProcessResult(
            exitCode: 1,
            stdout: manifest,
            stderr: "authentication failed",
            timedOut: false,
            cancelled: false
        )

        XCTAssertThrowsError(
            try AIProviderService.resolveMessage(provider: .codex, result: result, outputFile: nil)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("exited with code 1"))
            XCTAssertTrue(error.localizedDescription.contains("authentication failed"))
        }
    }

    func testExtractsManifestFromProviderEnvelope() {
        let envelope = #"{"type":"result","result":"{\"name\":\"Timer\",\"kind\":\"timer\",\"iconSystemName\":\"timer\",\"titleTemplate\":\"{{remaining}}\",\"config\":{\"durationSeconds\":60}}"}"#
        let payload = ManifestGenerationSupport.extractMessagePayload(from: envelope)

        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.contains("\"kind\":\"timer\"") == true)
    }

    func testExtractsManifestFromGrokStyleEnvelope() throws {
        // Grok `--output-format json` nests the manifest in `text` (string) and
        // `structuredOutput` (object). The unescaped nested keys must not make
        // the whole envelope look like the manifest itself.
        let envelope = #"{"text":"{\"name\":\"CPU & Memory\",\"iconSystemName\":\"cpu\",\"kind\":\"systemMetrics\",\"titleTemplate\":\"{{cpu}}\",\"config\":{\"metrics\":[\"cpu\"]}}","stopReason":"EndTurn","structuredOutput":{"name":"CPU & Memory","iconSystemName":"cpu","kind":"systemMetrics","titleTemplate":"{{cpu}}","config":{"metrics":["cpu"]}}}"#
        let payload = ManifestGenerationSupport.extractMessagePayload(from: envelope)

        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.contains("\"kind\":\"systemMetrics\"") == true)
        XCTAssertFalse(payload?.contains("structuredOutput") ?? true)
        XCTAssertNoThrow(try ManifestGenerationSupport.makeManifest(from: payload ?? "", sourcePrompt: "test"))
    }

    func testExtractsManifestFromCodexJSONLItem() {
        let manifest = #"{"name":"Timer","iconSystemName":"timer","kind":"timer","titleTemplate":"{{remaining}}","config":{"durationSeconds":60}}"#
        let escaped = manifest.replacingOccurrences(of: "\"", with: "\\\"")
        let jsonl = """
        {"type":"thread.started","thread_id":"abc"}
        {"type":"item.completed","item":{"id":"item_0","type":"assistant_message","text":"\(escaped)"}}
        {"type":"turn.completed","usage":{"input_tokens":1}}
        """
        let payload = ManifestGenerationSupport.extractMessagePayload(from: jsonl)

        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.contains("\"kind\":\"timer\"") == true)
    }

    func testNonManifestJSONReturnsNil() {
        // A non-manifest object must not be mistaken for a payload (and must
        // not recurse forever on single-line input).
        let line = #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}"#
        XCTAssertNil(ManifestGenerationSupport.extractMessagePayload(from: line))
    }

    func testArbitraryProviderTextReturnsNilWithoutRecursion() {
        XCTAssertNil(ManifestGenerationSupport.extractJSONObject(from: "not-json"))
        XCTAssertNil(ManifestGenerationSupport.extractMessagePayload(from: "not-json"))
        XCTAssertNil(ManifestGenerationSupport.extractMessagePayload(from: "progress\nstill working\ndone"))
    }

    func testRevisionPromptIncludesSelectedToolAndCurrentSource() {
        let existing = AppletManifest(
            name: "Current Song",
            iconSystemName: "music.note",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            refreshIntervalSeconds: 15,
            sourcePrompt: "Show the current song",
            config: AppletConfig(
                timeoutSeconds: 5,
                generatedSource: "#!/bin/zsh\nprintf old-source-marker"
            )
        )

        let revision = ManifestGenerationSupport.buildPrompt(
            userRequest: "Make the title shorter",
            existingTool: existing
        )
        let fresh = ManifestGenerationSupport.buildPrompt(
            userRequest: "Build a clock"
        )

        XCTAssertTrue(revision.contains("revising the existing menu bar tool"))
        XCTAssertTrue(revision.contains("Current Song"))
        XCTAssertTrue(revision.contains("old-source-marker"))
        XCTAssertTrue(revision.contains("Make the title shorter"))
        XCTAssertFalse(fresh.contains("CURRENT TOOL:"))
    }

    // MARK: - Shell command dependency check

    private func shellApplet(command: String) -> AppletManifest {
        AppletManifest(
            name: "Temp",
            iconSystemName: "thermometer.medium",
            kind: .shellCommand,
            titleTemplate: "{{value}}",
            config: AppletConfig(command: command)
        )
    }

    func testShellCommandDependencyCheckRejectsMissingTool() {
        let manifest = shellApplet(command: "bartender-no-such-tool-xyz -c")
        XCTAssertThrowsError(
            try ManifestGenerationSupport.requireCommandAvailable(manifest, environment: ["PATH": "/usr/bin:/bin"])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("bartender-no-such-tool-xyz"))
        }
    }

    func testShellCommandDependencyCheckAcceptsAvailableTool() {
        let manifest = shellApplet(command: "uname -a")
        XCTAssertNoThrow(
            try ManifestGenerationSupport.requireCommandAvailable(manifest, environment: ["PATH": "/usr/bin:/bin"])
        )
    }

    func testShellCommandDependencyCheckValidatesPathCommands() {
        let missing = shellApplet(command: "/usr/local/bin/bartender-no-such-tool-xyz --flag")
        XCTAssertThrowsError(
            try ManifestGenerationSupport.requireCommandAvailable(missing, environment: ["PATH": "/usr/bin:/bin"])
        )

        let present = shellApplet(command: "/usr/bin/uname -a")
        XCTAssertNoThrow(
            try ManifestGenerationSupport.requireCommandAvailable(present, environment: ["PATH": "/usr/bin:/bin"])
        )
    }

    func testShellCommandDependencyCheckSkipsCompoundCommands() {
        // Pipelines/assignments hide extra tools; they fail at runtime with the
        // shell's own diagnostics, so creation must not block them.
        for command in [
            "bartender-no-such-tool-xyz -c | cat",
            "FOO=bar bartender-no-such-tool-xyz",
            "echo $(bartender-no-such-tool-xyz)"
        ] {
            XCTAssertNoThrow(
                try ManifestGenerationSupport.requireCommandAvailable(
                    shellApplet(command: command),
                    environment: ["PATH": "/usr/bin:/bin"]
                ),
                "Compound command should skip the dependency check: \(command)"
            )
        }
    }

    func testShellCommandDependencyCheckIgnoresOtherKinds() throws {
        // Non-shell applets never run commands, even if config somehow has one.
        var config = AppletConfig()
        config.durationSeconds = 60
        config.command = "bartender-no-such-tool-xyz"
        let manifest = AppletManifest(
            name: "Timer",
            iconSystemName: "timer",
            kind: .timer,
            titleTemplate: "{{remaining}}",
            config: config
        )
        XCTAssertNoThrow(
            try ManifestGenerationSupport.requireCommandAvailable(manifest, environment: ["PATH": "/usr/bin:/bin"])
        )
    }
}
