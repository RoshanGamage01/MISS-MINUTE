import XCTest
@testable import MinutesCore

final class SSEParserTests: XCTestCase {
    func testDataPayloadsSkipsDone() {
        let chunk = """
        data: {"choices":[{"delta":{"content":"Hi"}}]}

        data: [DONE]
        """
        let payloads = SSEParser.dataPayloads(from: chunk)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertTrue(payloads[0].contains("Hi"))
    }

    func testOpenAIDeltaContent() {
        let json = #"{"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(SSEParser.openAIDeltaContent(from: json), "Hello")
    }

    func testAnthropicDeltaText() {
        let json = #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Howdy"}}"#
        XCTAssertEqual(SSEParser.anthropicDeltaText(from: json), "Howdy")
    }

    func testOllamaMessageContent() {
        let json = #"{"message":{"role":"assistant","content":"Tick"},"done":false}"#
        let parsed = SSEParser.ollamaMessageContent(from: json)
        XCTAssertEqual(parsed?.content, "Tick")
        XCTAssertEqual(parsed?.done, false)
    }
}
