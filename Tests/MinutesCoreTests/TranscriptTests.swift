import XCTest
@testable import MinutesCore

final class TranscriptTests: XCTestCase {
    private func toolTurn() -> [ChatMessage] {
        let call = ToolCall(id: "toolu_1", name: "add_task", arguments: ["title": "Ship it"])
        return [
            ChatMessage(role: .user, content: "Earlier question"),
            ChatMessage(role: .assistant, content: "Earlier answer",
                        providerContent: [["type": "thinking", "thinking": "", "signature": "old"], ["type": "text", "text": "Earlier answer"]]),
            ChatMessage(role: .assistant, content: "Build finished!", isProactive: true),
            ChatMessage(role: .user, content: "Track shipping", contextNote: "Current local time: now"),
            ChatMessage(role: .assistant, content: "On it.", toolCalls: [call],
                        providerContent: [
                            ["type": "thinking", "thinking": "", "signature": "sig"],
                            ["type": "text", "text": "On it."],
                            ["type": "tool_use", "id": "toolu_1", "name": "add_task", "input": ["title": "Ship it"]]
                        ]),
            ChatMessage(role: .tool, content: "Added task.", toolCallID: "toolu_1", toolName: "add_task")
        ]
    }

    func testAnthropicMessagesAlternateAndPairTools() {
        let messages = AnthropicProvider.messages(from: toolTurn())
        let roles = messages.compactMap { $0["role"] as? String }
        XCTAssertEqual(roles, ["user", "assistant", "user", "assistant", "user"])

        // Proactive line is merged into the following user turn as a note, and context is attached.
        let thirdBlocks = messages[2]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(thirdBlocks.count, 2)
        XCTAssertTrue((thirdBlocks[0]["text"] as? String ?? "").contains("on your own initiative"))
        XCTAssertTrue((thirdBlocks[1]["text"] as? String ?? "").hasPrefix("<context>"))

        // The final user message carries the tool result.
        let last = messages[4]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(last.first?["type"] as? String, "tool_result")
        XCTAssertEqual(last.first?["tool_use_id"] as? String, "toolu_1")
    }

    func testThinkingReplayedOnlyInsideCurrentTurn() {
        let messages = AnthropicProvider.messages(from: toolTurn())
        let earlier = messages[1]["content"] as? [[String: Any]] ?? []
        XCTAssertFalse(earlier.contains { $0["type"] as? String == "thinking" }, "old turns are rebuilt without thinking")
        let current = messages[3]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(current.first?["type"] as? String, "thinking")
        XCTAssertEqual(current.first?["signature"] as? String, "sig")
    }

    func testUnansweredToolCallsAreDropped() {
        var history = toolTurn()
        history.removeLast() // no tool result
        history[4].providerContent = nil
        let messages = AnthropicProvider.messages(from: history)
        let assistantMessage = messages.last(where: { $0["role"] as? String == "assistant" })
        let assistant = assistantMessage?["content"] as? [[String: Any]] ?? []
        XCTAssertFalse(assistant.contains { $0["type"] as? String == "tool_use" })
    }

    func testOpenAIMessagesIncludeToolCalls() {
        let messages = OpenAICompatibleProvider.messages(from: toolTurn(), systemPrompt: "sys")
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let assistant = messages.first(where: { ($0["tool_calls"] as? [[String: Any]]) != nil })
        let call = (assistant?["tool_calls"] as? [[String: Any]])?.first
        XCTAssertEqual(call?["id"] as? String, "toolu_1")
        XCTAssertEqual(messages.last?["role"] as? String, "tool")
    }

    func testWindowStartsOnUserTurn() {
        var messages: [ChatMessage] = []
        for i in 0..<30 {
            messages.append(ChatMessage(role: .user, content: "q\(i)"))
            messages.append(ChatMessage(role: .assistant, content: "a\(i)", toolCalls: [ToolCall(id: "c\(i)", name: "x", arguments: [:])]))
            messages.append(ChatMessage(role: .tool, content: "r", toolCallID: "c\(i)"))
        }
        let window = Transcript.window(messages, limit: 10)
        XCTAssertEqual(window.first?.role, .user)
        XCTAssertLessThanOrEqual(window.count, 10)
    }

    func testRequestBodyGatesFeaturesByModel() {
        let provider = AnthropicProvider(apiKey: "k")
        let tools = [ToolSpec.object("add_task", "Add", properties: ["title": ["type": "string"]], required: ["title"])]
        let opus = provider.requestBody(for: AgentRequest(messages: [], model: "claude-opus-5-5", systemPrompt: "s", tools: tools, depth: .snappy, allowWebSearch: true))
        XCTAssertEqual(opus.betas, ["server-side-fallback-2026-07-01"])
        XCTAssertEqual(opus.body["fallbacks"] as? String, "default")
        XCTAssertEqual((opus.body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        let sentTools = opus.body["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(sentTools.first?["eager_input_streaming"] as? Bool, true)
        XCTAssertEqual(sentTools.last?["type"] as? String, "web_search_20260209")

        let haiku = provider.requestBody(for: AgentRequest(messages: [], model: "claude-haiku-5-5", systemPrompt: "s"))
        XCTAssertTrue(haiku.betas.isEmpty, "Haiku has no server-side fallback")
        XCTAssertNil(haiku.body["tools"])
    }
}

final class AnthropicStreamAssemblerTests: XCTestCase {
    func testAssemblesTextThinkingAndToolUse() throws {
        var assembler = AnthropicStreamAssembler()
        let payloads = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"On it, "}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"sugar."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_9","name":"add_task","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"title\": \"Ca"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"ll mom\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#
        ]
        var events: [ProviderEvent] = []
        for payload in payloads { events += try assembler.consume(payload) }
        events.append(assembler.finish())

        let text = events.compactMap { (event: ProviderEvent) -> String? in
            if case .textDelta(let t) = event { return t }
            return nil
        }.joined()
        XCTAssertEqual(text, "On it, sugar.")
        let call = events.compactMap { (event: ProviderEvent) -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }.first
        XCTAssertEqual(call?.id, "toolu_9")
        XCTAssertEqual(call?.arguments["title"]?.stringValue, "Call mom")

        guard case .finished(let stop, let raw)? = events.last else { return XCTFail("missing finish") }
        XCTAssertEqual(stop, .toolUse)
        let blocks = raw?.arrayValue ?? []
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0]["signature"]?.stringValue, "abc")
        XCTAssertEqual(blocks[2]["input"]?["title"]?.stringValue, "Call mom")
    }

    func testMalformedToolJSONIsFlagged() throws {
        var assembler = AnthropicStreamAssembler()
        _ = try assembler.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"add_task","input":{}}}"#)
        _ = try assembler.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"title\": "}}"#)
        let events = try assembler.consume(#"{"type":"content_block_stop","index":0}"#)
        guard case .toolCall(let call)? = events.first else { return XCTFail("no call") }
        XCTAssertNotNil(call.arguments["__invalid_json"])
    }

    func testOverloadedErrorThrows() {
        var assembler = AnthropicStreamAssembler()
        XCTAssertThrowsError(try assembler.consume(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
    }
}
