import XCTest
@testable import MinutesCore

final class VoiceLatencyTests: XCTestCase {
    // MARK: - First chunk

    func testFirstChunkGoesOutAtFirstPunctuation() {
        var chunker = SentenceChunker(firstChunkWords: 4)
        XCTAssertEqual(chunker.feed("Sure thing"), [])
        XCTAssertEqual(chunker.feed("! Let me look at your calendar for today. Then"), ["Sure thing!", "Let me look at your calendar for today."])
        XCTAssertEqual(chunker.flush(), "Then")
    }

    func testFirstChunkGoesOutAfterAFewWordsWithoutPunctuation() {
        var chunker = SentenceChunker(firstChunkWords: 4)
        XCTAssertEqual(chunker.feed("Okay so the thing"), [])
        XCTAssertEqual(chunker.feed(" about your meeting is that"), ["Okay so the thing"])
        // After the first chunk, whole sentences again.
        XCTAssertEqual(chunker.feed(" it moved. "), ["about your meeting is that it moved."])
    }

    func testFirstChunkSkipsAbbreviationsAndNumbers() {
        var chunker = SentenceChunker(firstChunkWords: 6)
        XCTAssertEqual(chunker.feed("Dr. Lee moved it to 3.5 hours "), ["Dr. Lee moved it to 3.5"])
    }

    func testSecondChunkCanEndAtAClauseSoTheVoiceDoesNotStall() {
        var chunker = SentenceChunker.streaming(firstChunkWords: 4)
        XCTAssertEqual(chunker.feed("Sure thing! "), ["Sure thing!"])
        XCTAssertEqual(chunker.feed("I looked at your calendar for the whole week, and "), ["I looked at your calendar for the whole week,"])
        // Third chunk onward: whole sentences again.
        XCTAssertEqual(chunker.feed("Tuesday looks busy, but Friday is open. "), ["and Tuesday looks busy, but Friday is open."])
    }

    func testRunOnSentenceIsCutAtTheLimit() {
        var chunker = SentenceChunker(maximumLength: 70)
        let runOn = "First we open the project and then we check the build settings, then we look at signing and provisioning and finally"
        let out = chunker.feed(runOn)
        XCTAssertEqual(out.first, "First we open the project and then we check the build settings,")
        XCTAssertTrue(out.allSatisfy { $0.count <= 70 }, "\(out)")
        XCTAssertFalse(SentenceChunker(maximumLength: 60).feedingCopy("`a, very, long, code, span, that, should, never, be, split, anywhere, at, all, okay`").contains { $0.contains("`") && $0.filter { $0 == "`" }.count == 1 })
    }

    // MARK: - PCM

    func testPCMDecoderHandlesSplitSamples() {
        var decoder = PCMStreamDecoder()
        // 0x4000 = 16384 → 0.5, 0xC000 = -16384 → -0.5; split the second sample across chunks.
        XCTAssertEqual(decoder.feed(Data([0x00, 0x40, 0x00])), [0.5])
        XCTAssertEqual(decoder.feed(Data([0xC0])), [-0.5])
        XCTAssertEqual(PCMStreamDecoder.level([0, 0]), 0)
        XCTAssertGreaterThan(PCMStreamDecoder.level([0.2, -0.2]), 0.5)
    }

    // MARK: - Trace

    @MainActor
    func testTraceReportsStagesInOrder() {
        let trace = LatencyTrace()
        var clock: TimeInterval = 100
        trace.now = { clock }
        var reports: [LatencyTrace.Report] = []
        trace.sink = { reports.append($0) }

        trace.begin(origin: "spoken", at: 99.2)
        trace.mark(.speechEnded, at: 99.2)
        trace.mark(.sttFinal)
        clock = 100.4; trace.mark(.firstToken)
        trace.mark(.firstToken) // only the first counts
        clock = 100.45; trace.mark(.firstChunk)
        clock = 100.7; trace.finish(engine: "Test")

        XCTAssertEqual(reports.count, 1)
        let report = reports[0]
        XCTAssertEqual(report.marks.map(\.stage), [.speechEnded, .sttFinal, .firstToken, .firstChunk, .firstAudio])
        XCTAssertEqual(report.ms(.sttFinal), 800)
        XCTAssertEqual(report.totalMs, 1500)
        XCTAssertTrue(report.line.contains("firstToken +400"))
        XCTAssertFalse(trace.isActive)
        trace.mark(.firstAudio) // ignored once finished
        XCTAssertEqual(reports.count, 1)
    }

    // MARK: - Acknowledgement before tools

    private func tempStore<T>() -> JSONFileStore<T> {
        JSONFileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString).json"))
    }

    @MainActor
    private func runTurn(_ scripts: [[ProviderEvent]], toolName: String) async -> [String] {
        var log: [String] = []
        let registry = ToolRegistry()
        registry.register(AgentTool(spec: .object(toolName, "test")) { _ in
            log.append("ran:\(toolName)")
            return .ok("done")
        })
        let chat = ChatService(store: tempStore(), tools: registry, providerFactory: { ScriptedProvider(scripts) })
        chat.onSpeak = { text, _ in log.append("say:\(text)") }
        let replied = expectation(description: "reply")
        chat.onReply = { _ in replied.fulfill() }
        chat.send("check my screen")
        await fulfillment(of: [replied], timeout: 5)
        return log
    }

    @MainActor
    func testAcknowledgesBeforeSlowToolRuns() async {
        let log = await runTurn([
            [
                .toolCallStarted(name: "look_at_screen"),
                .toolCall(ToolCall(id: "1", name: "look_at_screen", arguments: [:])),
                .finished(stop: .toolUse, rawContent: nil)
            ],
            [.textDelta("You're in Xcode, hon."), .finished(stop: .endTurn, rawContent: nil)]
        ], toolName: "look_at_screen")
        XCTAssertEqual(log.first, "say:\(ChatService.acknowledgements[0])")
        XCTAssertEqual(log.dropFirst().first, "ran:look_at_screen")
        XCTAssertEqual(log.filter { $0.hasPrefix("say:") }.count, 2)
    }

    @MainActor
    func testNoAcknowledgementForInstantTools() async {
        let log = await runTurn([
            [.toolCall(ToolCall(id: "1", name: "add_task", arguments: [:])), .finished(stop: .toolUse, rawContent: nil)],
            [.textDelta("Added!"), .finished(stop: .endTurn, rawContent: nil)]
        ], toolName: "add_task")
        XCTAssertEqual(log, ["ran:add_task", "say:Added!"])
    }

    @MainActor
    func testPendingTextIsSpokenBeforeToolWithoutExtraAcknowledgement() async {
        let log = await runTurn([
            [
                .textDelta("One sec"), // no punctuation: would sit in the chunker until the stream ended
                .toolCallStarted(name: "read_screen"),
                .toolCall(ToolCall(id: "1", name: "read_screen", arguments: [:])),
                .finished(stop: .toolUse, rawContent: nil)
            ],
            [.textDelta("Got it."), .finished(stop: .endTurn, rawContent: nil)]
        ], toolName: "read_screen")
        XCTAssertEqual(log, ["say:One sec", "ran:read_screen", "say:Got it."])
    }

    func testAnthropicReportsToolStartBeforeArguments() throws {
        var assembler = AnthropicStreamAssembler()
        let start = try assembler.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"look_at_screen","input":{}}}"#)
        XCTAssertEqual(start, [.toolCallStarted(name: "look_at_screen")])
    }

    // MARK: - Ollama / Gemma

    func testPromptedFilterAnnouncesToolNameEarly() {
        var filter = PromptedToolFilter()
        XCTAssertEqual(filter.feed("Sure, one sec!\n```tool\n{\"na"), "Sure, one sec!\n")
        XCTAssertNil(filter.startedToolName())
        _ = filter.feed("me\": \"look_at_screen\", \"argu")
        XCTAssertEqual(filter.startedToolName(), "look_at_screen")
        XCTAssertNil(filter.startedToolName(), "reported once")
    }

    func testOllamaNativeToolCallIsAnnouncedAndThinkingIsOffForSnappy() async throws {
        let session = StubOllama.session(responses: [
            .init(status: 200, body: [
                #"{"message":{"content":"On it!"},"done":false}"#,
                #"{"message":{"content":"","tool_calls":[{"function":{"name":"look_at_screen","arguments":{}}}]},"done":true}"#
            ])
        ])
        let provider = OllamaProvider(session: session)
        let events = try await collect(provider, model: "gemma4-native")
        XCTAssertEqual(events.map(Self.kind), ["text:On it!", "started:look_at_screen", "call:look_at_screen", "finished"])
        XCTAssertEqual(StubOllama.lastBodies.first?["think"] as? Bool, false)
    }

    func testOllamaRetriesWithoutThinkOptionWhenRejected() async throws {
        let session = StubOllama.session(responses: [
            .init(status: 400, body: [#"{"error":"\"gemma-old\" does not support thinking"}"#]),
            .init(status: 200, body: [#"{"message":{"content":"Hi there!"},"done":true}"#])
        ])
        let events = try await collect(OllamaProvider(session: session), model: "gemma-old")
        XCTAssertEqual(events.map(Self.kind), ["text:Hi there!", "finished"])
        XCTAssertEqual(StubOllama.lastBodies.count, 2)
        XCTAssertNil(StubOllama.lastBodies[1]["think"])
    }

    func testOllamaPromptedToolCallIsAnnouncedBeforeItFinishes() async throws {
        let session = StubOllama.session(responses: [
            .init(status: 400, body: [#"{"error":"gemma-prompted does not support tools"}"#]),
            .init(status: 200, body: [
                #"{"message":{"content":"Let me look!\n```tool\n{\"name\": \"look_at_screen\""},"done":false}"#,
                #"{"message":{"content":", \"arguments\": {}}\n```"},"done":true}"#
            ])
        ])
        let events = try await collect(OllamaProvider(session: session), model: "gemma-prompted")
        XCTAssertEqual(events.map(Self.kind), ["text:Let me look!\n", "started:look_at_screen", "call:look_at_screen", "finished"])
    }

    private func collect(_ provider: OllamaProvider, model: String) async throws -> [ProviderEvent] {
        let request = AgentRequest(
            messages: [ChatMessage(role: .user, content: "hi")],
            model: model,
            systemPrompt: "s",
            tools: [ToolSpec.object("look_at_screen", "look")],
            depth: .snappy
        )
        var events: [ProviderEvent] = []
        for try await event in provider.streamTurn(request) { events.append(event) }
        return events
    }

    private static func kind(_ event: ProviderEvent) -> String {
        switch event {
        case .textDelta(let text): return "text:\(text)"
        case .toolCallStarted(let name): return "started:\(name)"
        case .toolCall(let call): return "call:\(call.name)"
        case .status(let status): return "status:\(status)"
        case .finished: return "finished"
        }
    }

    // MARK: - Benchmark: time from first token to first spoken chunk

    /// Replays replies token by token at a fixed model speed and reports when each chunker hands its first
    /// chunk to the voice. Deterministic, so it doubles as a regression check.
    func testFirstChunkLatencyBenchmark() {
        let replies = [
            "Well hey there, sugar, let me take a quick look at your calendar for this afternoon.",
            "Sure thing! I'll set that reminder for three o'clock.",
            "Okay so the thing about your nine o'clock is that it moved to ten, so you've got a little breathing room.",
            "Your build finished without errors, and the tests all passed.",
            "Hmm, that error means the file couldn't be found."
        ]
        let msPerToken = 1000.0 / 50 // ~50 tokens/s, typical for Claude Opus or Gemma on Apple silicon
        func firstChunkMs(_ make: () -> SentenceChunker, _ reply: String) -> Double {
            var chunker = make()
            var tokens: [String] = []
            var current = ""
            for char in reply {
                current.append(char)
                if current.count >= 4 || char == " " { tokens.append(current); current = "" }
            }
            if !current.isEmpty { tokens.append(current) }
            for (index, token) in tokens.enumerated() where !chunker.feed(token).isEmpty {
                return Double(index) * msPerToken
            }
            return Double(tokens.count) * msPerToken // only at the end of the stream
        }
        let configs: [(String, () -> SentenceChunker)] = [
            ("v2.0 sentence", { SentenceChunker() }),
            ("v2.1 clause≥28", { SentenceChunker(firstClauseLength: 28) }),
            ("v2.2 first words", { SentenceChunker(firstChunkWords: ChatService.firstChunkWords) })
        ]
        var averages: [Double] = []
        for (label, make) in configs {
            let times = replies.map { firstChunkMs(make, $0) }
            let average = times.reduce(0, +) / Double(times.count)
            averages.append(average)
            print("first-chunk benchmark \(label): avg \(Int(average)) ms, worst \(Int(times.max()!)) ms " + times.map { "\(Int($0))" }.joined(separator: "/"))
        }
        XCTAssertLessThan(averages[2], averages[1])
        XCTAssertLessThan(averages[1], averages[0])
        XCTAssertLessThanOrEqual(averages[2], 200, "first chunk within ~10 tokens on average")
    }
}

/// Serves canned NDJSON responses to OllamaProvider, one per request, and records request bodies.
final class StubOllama: URLProtocol {
    struct Response { var status: Int; var body: [String] }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var lastBodies: [[String: Any]] = []
    private static let lock = NSLock()

    static func session(responses: [Response]) -> URLSession {
        lock.lock(); queue = responses; lastBodies = []; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubOllama.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            bodyData = data
        }
        Self.lock.lock()
        if let bodyData, let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            Self.lastBodies.append(json)
        }
        let response = Self.queue.isEmpty ? Response(status: 500, body: ["{}"]) : Self.queue.removeFirst()
        Self.lock.unlock()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((response.body.joined(separator: "\n") + "\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension SentenceChunker {
    func feedingCopy(_ text: String) -> [String] {
        var copy = self
        return copy.feed(text)
    }
}
