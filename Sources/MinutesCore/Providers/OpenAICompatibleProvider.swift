import Foundation

/// OpenAI Chat Completions-compatible provider (also used for xAI).
public struct OpenAICompatibleProvider: ChatProvider, Sendable {
    public let kind: ProviderKind
    public let baseURL: URL
    public let apiKey: String
    public let session: URLSession
    public let defaultModels: [String]

    public init(
        kind: ProviderKind,
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared,
        defaultModels: [String]
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.defaultModels = defaultModels
    }

    public func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("models")
        let (data, http) = try await HTTPStreaming.getJSON(
            url: url,
            headers: apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"],
            session: session
        )
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Fall back to curated defaults when listing is unavailable.
            if !defaultModels.isEmpty { return defaultModels }
            throw ChatProviderError.httpStatus(http.statusCode, body)
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = obj["data"] as? [[String: Any]]
        else {
            return defaultModels
        }
        let ids = list.compactMap { $0["id"] as? String }.sorted()
        return ids.isEmpty ? defaultModels : ids
    }

    static func messages(from history: [ChatMessage], systemPrompt: String, keepImages: Int = 3) -> [[String: Any]] {
        let answered = Transcript.answeredToolCallIDs(history)
        let imageIDs = Transcript.imageMessageIDs(history, keep: keepImages)
        var out: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        // Chat Completions tool messages can't carry images, so screenshots follow the tool group as a user message.
        var pendingImages: [(tool: String, images: [ImageAttachment])] = []

        func flushImages() {
            guard !pendingImages.isEmpty else { return }
            var parts: [[String: Any]] = []
            for entry in pendingImages {
                parts.append(["type": "text", "text": "Screenshot from \(entry.tool):"])
                for image in entry.images {
                    parts.append(["type": "image_url", "image_url": ["url": image.dataURL]])
                }
            }
            out.append(["role": "user", "content": parts])
            pendingImages.removeAll()
        }

        for message in history {
            if message.role != .tool { flushImages() }
            switch message.role {
            case .system:
                continue
            case .user:
                if let images = message.images, !images.isEmpty {
                    var parts: [[String: Any]] = [["type": "text", "text": Transcript.userText(message)]]
                    parts += images.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] }
                    out.append(["role": "user", "content": parts])
                } else {
                    out.append(["role": "user", "content": Transcript.userText(message)])
                }
            case .assistant:
                if message.isProactive == true {
                    out.append(["role": "user", "content": Transcript.proactiveText(message)])
                    continue
                }
                var entry: [String: Any] = ["role": "assistant", "content": message.content]
                let calls = (message.toolCalls ?? []).filter { answered.contains($0.id) }
                if !calls.isEmpty {
                    entry["tool_calls"] = calls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.arguments.jsonString]
                        ] as [String: Any]
                    }
                }
                out.append(entry)
            case .tool:
                guard let id = message.toolCallID else { continue }
                var content = message.content
                if let images = message.images, !images.isEmpty {
                    if imageIDs.contains(message.id) {
                        pendingImages.append((message.toolName ?? "tool", images))
                    } else {
                        content += "\n[older screenshot omitted]"
                    }
                }
                out.append(["role": "tool", "tool_call_id": id, "content": content])
            }
        }
        flushImages()
        return out
    }

    public func streamTurn(_ request: AgentRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        let url = baseURL.appendingPathComponent("chat/completions")
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "messages": Self.messages(from: request.messages, systemPrompt: request.systemPrompt)
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { spec in
                [
                    "type": "function",
                    "function": [
                        "name": spec.name,
                        "description": spec.description,
                        "parameters": spec.inputSchema.anyValue
                    ] as [String: Any]
                ] as [String: Any]
            }
        }

        var headers = ["Accept": "text/event-stream"]
        if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        let lines = HTTPStreaming.streamLines(
            url: url,
            headers: headers,
            body: body,
            session: session
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                // Tool calls arrive as fragments keyed by index.
                var pending: [Int: (id: String, name: String, args: String)] = [:]
                var finishReason: String?
                do {
                    for try await line in lines {
                        for payload in SSEParser.dataPayloads(from: line) {
                            guard let data = payload.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let choice = (obj["choices"] as? [[String: Any]])?.first
                            else { continue }
                            if let reason = choice["finish_reason"] as? String { finishReason = reason }
                            guard let delta = choice["delta"] as? [String: Any] else { continue }
                            if let text = delta["content"] as? String, !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            }
                            for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                                let index = fragment["index"] as? Int ?? 0
                                var entry = pending[index] ?? (id: "", name: "", args: "")
                                if let id = fragment["id"] as? String { entry.id = id }
                                if let function = fragment["function"] as? [String: Any] {
                                    if let name = function["name"] as? String {
                                        if entry.name.isEmpty, !name.isEmpty {
                                            continuation.yield(.toolCallStarted(name: name))
                                        }
                                        entry.name += name
                                    }
                                    if let args = function["arguments"] as? String { entry.args += args }
                                }
                                pending[index] = entry
                            }
                        }
                    }
                    for index in pending.keys.sorted() {
                        guard let entry = pending[index], !entry.name.isEmpty else { continue }
                        let trimmed = entry.args.trimmingCharacters(in: .whitespacesAndNewlines)
                        let parsed = trimmed.isEmpty ? JSONValue.object([:]) : JSONValue.parse(trimmed)
                        let arguments = (parsed?.objectValue != nil) ? parsed! : .object(["__invalid_json": .string(entry.args)])
                        continuation.yield(.toolCall(ToolCall(
                            id: entry.id.isEmpty ? "call_\(UUID().uuidString.prefix(12))" : entry.id,
                            name: entry.name,
                            arguments: arguments
                        )))
                    }
                    let stop: TurnStopReason
                    switch finishReason {
                    case "tool_calls": stop = .toolUse
                    case "length": stop = .maxTokens
                    case "content_filter": stop = .refusal
                    default: stop = pending.isEmpty ? .endTurn : .toolUse
                    }
                    continuation.yield(.finished(stop: stop, rawContent: nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
