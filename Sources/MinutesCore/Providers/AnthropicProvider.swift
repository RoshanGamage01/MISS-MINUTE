import Foundation

/// Claude via the Messages API (raw HTTP + SSE; there is no official Swift SDK).
public struct AnthropicProvider: ChatProvider, Sendable {
    public static let apiVersion = "2026-10-21"
    public static let curatedModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    public let kind: ProviderKind = .anthropic
    public let apiKey: String
    public let session: URLSession
    public let baseURL: URL

    public init(
        apiKey: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!
    ) {
        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
    }

    private var baseHeaders: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": Self.apiVersion]
    }

    public func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("models")
        guard let result = try? await HTTPStreaming.getJSON(url: url, headers: baseHeaders, session: session),
              case let (data, http) = result,
              (200...299).contains(http.statusCode),
              let json = JSONValue.parse(String(decoding: data, as: UTF8.self)),
              let list = json["data"]?.arrayValue
        else {
            return Self.curatedModels
        }
        let ids = list.compactMap { $0["id"]?.stringValue }
        guard !ids.isEmpty else { return Self.curatedModels }
        // Current models first, in curated order, then the rest as listed.
        let curated = Self.curatedModels.filter(ids.contains)
        return curated + ids.filter { !curated.contains($0) }
    }

    // MARK: - Request building

    func requestBody(for request: AgentRequest) -> (body: [String: Any], betas: [String]) {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": 32_000,
            "stream": true,
            "system": request.systemPrompt,
            "messages": Self.messages(from: request.messages),
            // Auto-place a cache breakpoint on the stable prefix (system + history).
            "cache_control": ["type": "ephemeral"]
        ]
        var betas: [String] = []

        var tools: [[String: Any]] = request.tools.map { spec in
            [
                "name": spec.name,
                "description": spec.description,
                "input_schema": spec.inputSchema.anyValue,
                "eager_input_streaming": true
            ]
        }
        if request.allowWebSearch {
            tools.append([
                "type": Self.supportsDynamicWebSearch(request.model) ? "web_search_20260209" : "web_search_20250305",
                "name": "web_search",
                "max_uses": 4
            ])
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }
        if Self.supportsEffort(request.model) {
            body["output_config"] = ["effort": request.depth.anthropicEffort]
        }
        if Self.supportsServerFallback(request.model) {
            body["fallbacks"] = "default"
            betas.append("server-side-fallback-2026-07-01")
        }
        return (body, betas)
    }

    static func messages(from history: [ChatMessage]) -> [[String: Any]] {
        let currentTurn = Transcript.currentTurnStart(history)
        let answered = Transcript.answeredToolCallIDs(history)
        var out: [[String: Any]] = []

        func append(role: String, blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if var last = out.last, last["role"] as? String == role,
               var existing = last["content"] as? [[String: Any]] {
                existing.append(contentsOf: blocks)
                last["content"] = existing
                out[out.count - 1] = last
            } else {
                out.append(["role": role, "content": blocks])
            }
        }

        for (index, message) in history.enumerated() {
            switch message.role {
            case .system:
                continue
            case .user:
                var blocks: [[String: Any]] = (message.images ?? []).map { image in
                    ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.base64]]
                }
                blocks.append(["type": "text", "text": Transcript.userText(message)])
                append(role: "user", blocks: blocks)
            case .assistant:
                if message.isProactive == true {
                    append(role: "user", blocks: [["type": "text", "text": Transcript.proactiveText(message)]])
                    continue
                }
                // Inside the in-flight turn, replay the exact blocks (thinking signatures, hosted search
                // results). Earlier turns are rebuilt without thinking so trimming history stays valid.
                if index > currentTurn, let raw = message.providerContent?.arrayValue, !raw.isEmpty {
                    append(role: "assistant", blocks: raw.compactMap { $0.anyValue as? [String: Any] })
                    continue
                }
                var blocks: [[String: Any]] = []
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                for call in message.toolCalls ?? [] where answered.contains(call.id) {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": call.arguments.objectValue.map { JSONValue.object($0).anyValue } ?? [String: Any]()
                    ])
                }
                append(role: "assistant", blocks: blocks)
            case .tool:
                guard let id = message.toolCallID else { continue }
                let text = message.content.isEmpty ? "(no output)" : message.content
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": text]
                if let images = message.images, !images.isEmpty {
                    var content: [[String: Any]] = [["type": "text", "text": text]]
                    for image in images {
                        content.append([
                            "type": "image",
                            "source": ["type": "base64", "media_type": image.mediaType, "data": image.base64]
                        ])
                    }
                    block["content"] = content
                }
                if message.isError == true { block["is_error"] = true }
                append(role: "user", blocks: [block])
            }
        }

        if let first = out.first, first["role"] as? String == "assistant" {
            out.insert(["role": "user", "content": [["type": "text", "text": "(conversation resumed)"]]], at: 0)
        }
        return out
    }

    // MARK: - Model capability gates

    static func supportsEffort(_ model: String) -> Bool {
        let markers = ["opus-4-5", "opus-4-6", "opus-4-7", "opus-4-8", "opus-5", "sonnet-4-6", "sonnet-5", "haiku-5", "fable", "mythos"]
        return markers.contains { model.contains($0) }
    }

    static func supportsServerFallback(_ model: String) -> Bool {
        let markers = ["claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1"]
        return markers.contains { model.hasPrefix($0) }
    }

    static func supportsDynamicWebSearch(_ model: String) -> Bool {
        let markers = ["opus-4-6", "opus-4-7", "opus-4-8", "opus-5", "sonnet-4-6", "sonnet-5"]
        return markers.contains { model.contains($0) }
    }

    // MARK: - Streaming

    public func streamTurn(_ request: AgentRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        let url = baseURL.appendingPathComponent("messages")
        let (body, betas) = requestBody(for: request)
        var headers = baseHeaders
        headers["Accept"] = "text/event-stream"
        if !betas.isEmpty {
            headers["anthropic-beta"] = betas.joined(separator: ",")
        }
        let lines = HTTPStreaming.streamLines(url: url, headers: headers, body: body, session: session)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var assembler = AnthropicStreamAssembler()
                do {
                    for try await line in lines {
                        for payload in SSEParser.dataPayloads(from: line) {
                            for event in try assembler.consume(payload) {
                                continuation.yield(event)
                            }
                        }
                    }
                    continuation.yield(assembler.finish())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Rebuilds complete content blocks from Messages API stream events.
struct AnthropicStreamAssembler {
    private var blocks: [Int: [String: Any]] = [:]
    private var order: [Int] = []
    private var partialJSON: [Int: String] = [:]
    private var stopReason: String?
    private var refusalCategory: String?

    mutating func consume(_ payload: String) throws -> [ProviderEvent] {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }

        switch type {
        case "content_block_start":
            guard let index = obj["index"] as? Int,
                  var block = obj["content_block"] as? [String: Any] else { return [] }
            let blockType = block["type"] as? String ?? ""
            if blockType == "tool_use" || blockType == "server_tool_use" {
                partialJSON[index] = ""
                block["input"] = [String: Any]()
            }
            blocks[index] = block
            if !order.contains(index) { order.append(index) }
            return []

        case "content_block_delta":
            guard let index = obj["index"] as? Int,
                  let delta = obj["delta"] as? [String: Any],
                  var block = blocks[index] else { return [] }
            var events: [ProviderEvent] = []
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                block["text"] = (block["text"] as? String ?? "") + text
                if !text.isEmpty { events.append(.textDelta(text)) }
            case "thinking_delta":
                block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                block["signature"] = delta["signature"] as? String ?? ""
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            case "citations_delta":
                if let citation = delta["citation"] {
                    var citations = block["citations"] as? [Any] ?? []
                    citations.append(citation)
                    block["citations"] = citations
                }
            default:
                break
            }
            blocks[index] = block
            return events

        case "content_block_stop":
            guard let index = obj["index"] as? Int, var block = blocks[index] else { return [] }
            guard let raw = partialJSON.removeValue(forKey: index) else { return [] }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed: JSONValue? = trimmed.isEmpty ? .object([:]) : JSONValue.parse(trimmed)
            let input: JSONValue = parsed.flatMap { $0.objectValue != nil ? $0 : nil } ?? .object([:])
            block["input"] = input.anyValue
            blocks[index] = block

            let name = block["name"] as? String ?? ""
            if block["type"] as? String == "tool_use" {
                let id = block["id"] as? String ?? UUID().uuidString
                // Inputs stream unvalidated (eager streaming); flag malformed JSON so the tool layer rejects it.
                let arguments: JSONValue = (parsed?.objectValue != nil) ? input : .object(["__invalid_json": .string(raw)])
                return [.toolCall(ToolCall(id: id, name: name, arguments: arguments))]
            }
            if name == "web_search", let query = input["query"]?.stringValue {
                return [.status("Searching the web for “\(query)”")]
            }
            return []

        case "message_delta":
            if let delta = obj["delta"] as? [String: Any] {
                if let reason = delta["stop_reason"] as? String { stopReason = reason }
                if let details = delta["stop_details"] as? [String: Any] {
                    refusalCategory = details["category"] as? String
                }
            }
            return []

        case "error":
            let error = obj["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Stream error"
            if error?["type"] as? String == "overloaded_error" {
                throw ChatProviderError.httpStatus(529, message)
            }
            throw ChatProviderError.underlying(message)

        default:
            return []
        }
    }

    func finish() -> ProviderEvent {
        let content = order.compactMap { blocks[$0] }.map { JSONValue(any: $0) }
        let stop: TurnStopReason
        switch stopReason {
        case "end_turn", "stop_sequence": stop = .endTurn
        case "tool_use": stop = .toolUse
        case "pause_turn": stop = .pauseTurn
        case "max_tokens": stop = .maxTokens
        case "refusal": stop = .refusal
        default: stop = .other
        }
        return .finished(stop: stop, rawContent: .array(content))
    }

    var lastRefusalCategory: String? { refusalCategory }
}
