import XCTest
@testable import MinutesCore

final class LocalModelTests: XCTestCase {
    private let shot = ImageAttachment(base64: "AAAA", width: 10, height: 10)

    func testPromptedFilterHidesToolBlockAndParsesCall() {
        var filter = PromptedToolFilter()
        var visible = ""
        for chunk in ["Let me look", " at your screen. `", "``tool\n{\"name\": \"look_at_screen\", ", "\"arguments\": {\"detail\": \"high\"}}\n```"] {
            visible += filter.feed(chunk)
        }
        let (rest, call) = filter.finish()
        XCTAssertEqual(visible + rest, "Let me look at your screen. ")
        XCTAssertEqual(call?.name, "look_at_screen")
        XCTAssertEqual(call?.arguments["detail"]?.stringValue, "high")
    }

    func testPromptedFilterPassesPlainTextThrough() {
        var filter = PromptedToolFilter()
        let visible = filter.feed("No tools needed, sugar.")
        let (rest, call) = filter.finish()
        XCTAssertEqual(visible + rest, "No tools needed, sugar.")
        XCTAssertNil(call)
    }

    func testOllamaPromptedHistoryRoundTripsToolCalls() {
        let call = ToolCall(id: "c1", name: "look_at_screen", arguments: [:])
        let history = [
            ChatMessage(role: .user, content: "what am I doing?"),
            ChatMessage(role: .assistant, content: "Looking.", toolCalls: [call]),
            ChatMessage(role: .tool, content: "Screenshot 10×10 px.", toolCallID: "c1", toolName: "look_at_screen", images: [shot])
        ]
        let prompted = OllamaProvider.messages(from: history, systemPrompt: "sys", prompted: true)
        XCTAssertTrue((prompted[2]["content"] as? String ?? "").contains("```tool"))
        XCTAssertEqual(prompted[3]["role"] as? String, "user")
        XCTAssertEqual((prompted[3]["images"] as? [String])?.first, "AAAA")

        let native = OllamaProvider.messages(from: history, systemPrompt: "sys", prompted: false)
        XCTAssertEqual(native[3]["role"] as? String, "tool")
        XCTAssertEqual(native.last?["role"] as? String, "user", "screenshot follows the tool result")
        XCTAssertEqual((native.last?["images"] as? [String])?.count, 1)
    }

    func testOnlyRecentScreenshotsAreSentToLocalModels() {
        var history: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        for i in 0..<5 {
            history.append(ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c\(i)", name: "look_at_screen", arguments: [:])]))
            history.append(ChatMessage(role: .tool, content: "shot \(i)", toolCallID: "c\(i)", toolName: "look_at_screen", images: [shot]))
        }
        let messages = OllamaProvider.messages(from: history, systemPrompt: "s", prompted: false, keepImages: 2)
        let withImages = messages.filter { $0["images"] != nil }
        XCTAssertEqual(withImages.count, 2)
        let omitted = messages.filter { ($0["content"] as? String ?? "").contains("older screenshot omitted") }
        XCTAssertEqual(omitted.count, 3)
    }

    func testOpenAIImagesFollowToolGroup() {
        let history = [
            ChatMessage(role: .user, content: "look"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "look_at_screen", arguments: [:])]),
            ChatMessage(role: .tool, content: "shot", toolCallID: "c1", toolName: "look_at_screen", images: [shot])
        ]
        let messages = OpenAICompatibleProvider.messages(from: history, systemPrompt: "s")
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "user"])
        let parts = messages.last?["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
    }

    func testAnthropicToolResultCarriesImage() {
        let history = [
            ChatMessage(role: .user, content: "look"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "look_at_screen", arguments: [:])]),
            ChatMessage(role: .tool, content: "shot", toolCallID: "c1", toolName: "look_at_screen", images: [shot])
        ]
        let messages = AnthropicProvider.messages(from: history)
        let result = (messages.last?["content"] as? [[String: Any]])?.first
        let content = result?["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image"])
    }

    func testDuckDuckGoParsing() {
        let html = """
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&amp;rut=x">Example &amp; Co</a>
        <a class="result__snippet" href="#">An <b>example</b> snippet.</a>
        """
        let results = WebTools.parseResults(html)
        XCTAssertEqual(results.first?.title, "Example & Co")
        XCTAssertEqual(results.first?.url, "https://example.com/page")
        XCTAssertEqual(results.first?.snippet, "An example snippet.")
    }

    func testPlainTextStripsScripts() {
        let text = WebTools.plainText("<html><script>var x=1</script><h1>Usage</h1><p>42% used&#33;</p></html>")
        XCTAssertFalse(text.contains("var x"))
        XCTAssertTrue(text.contains("Usage"))
        XCTAssertTrue(text.contains("42% used!"))
    }

    func testLocalOnlyKindsAndGemmaDefault() {
        XCTAssertTrue(ProviderKind.ollama.isLocal)
        XCTAssertTrue(ProviderKind.localServer.isLocal)
        XCTAssertFalse(ProviderKind.anthropic.isLocal)
        XCTAssertEqual(ProviderKind.ollama.defaultModel, "gemma4")
    }

    func testTurnEndDropsScreenshots() async {
        let provider = ScriptedProvider([
            [.toolCall(ToolCall(id: "c1", name: "snap", arguments: [:])), .finished(stop: .toolUse, rawContent: nil)],
            [.textDelta("You're writing code."), .finished(stop: .endTurn, rawContent: nil)]
        ])
        let registry = await ToolRegistry()
        await registry.register(AgentTool(spec: .object("snap", "x")) { _ in
            .ok("shot", images: [ImageAttachment(base64: "AAAA", width: 1, height: 1)])
        })
        let chat = await ChatService(
            store: JSONFileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID()).json")),
            tools: registry,
            providerFactory: { provider }
        )
        let done = expectation(description: "turn")
        await MainActor.run {
            chat.onTurnEnded = { done.fulfill() }
            chat.send("what am I doing?")
        }
        await fulfillment(of: [done], timeout: 5)
        // The screenshot reached the model during the turn…
        XCTAssertEqual(provider.requests[1].messages.last?.images?.count, 1)
        // …and is gone from stored history afterwards.
        let stored = await MainActor.run { chat.conversation.messages.first { $0.role == .tool } }
        XCTAssertNil(stored?.images)
        XCTAssertTrue(stored?.content.contains("screenshot") == true)
    }
}
