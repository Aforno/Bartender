import XCTest
@testable import BarTender

final class GrokGenerationProgressTests: XCTestCase {
    func testFragmentedStreamReportsStagesWithoutReasoningOrDuplicates() {
        let progress = GrokGenerationProgress()
        XCTAssertEqual(progress.consume("{\"type\":\"sys"), [])
        XCTAssertEqual(progress.consume("tem\"}\n"), ["Grok is preparing the request…"])
        let thought = #"{"type":"stream_event","event":{"delta":{"type":"thinking_delta","thinking":"private reasoning"}}}"# + "\n"
        XCTAssertEqual(progress.consume(thought + thought), ["Grok is thinking…"])
        let text = #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"partial JSON"}}}"# + "\n"
        XCTAssertEqual(progress.consume(text + thought), ["Grok is writing the tool…"])
        XCTAssertEqual(progress.consume("{\"type\":\"assistant\"}\n{\"type\":\"result\"}\n"),
                       ["Grok is finishing the response…", "Checking Grok’s response…"])
    }

    func testMalformedAndOversizedLinesDoNotPreventLaterProgress() {
        let progress = GrokGenerationProgress()
        XCTAssertEqual(progress.consume(String(repeating: "x", count: 70_000)), [])
        XCTAssertEqual(progress.consume("\nnot json\n{\"type\":\"result\"}\n"),
                       ["Checking Grok’s response…"])
    }

    @MainActor
    func testTerminalStreamResultResolvesManifest() throws {
        let stream = #"""
        {"type":"system","subtype":"init"}
        {"type":"stream_event","event":{"delta":{"type":"thinking_delta","thinking":"Not a manifest"}}}
        {"type":"result","subtype":"success","result":"{\"name\":\"Probe\",\"kind\":\"generatedTool\"}"}
        """#
        let result = ProcessResult(exitCode: 0, stdout: stream, stderr: "", timedOut: false, cancelled: false)
        XCTAssertEqual(try AIProviderService.resolveMessage(provider: .grok, result: result, outputFile: nil),
                       #"{"name":"Probe","kind":"generatedTool"}"#)
    }
}
