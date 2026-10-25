import Foundation

/// Local models through Ollama (e.g. Gemma 4). Supports images, native tool calling, and — for models whose
/// template lacks tool support — a prompted tool protocol parsed out of the text.
public struct OllamaProvider: ChatProvider, Sendable {
    public let kind: ProviderKind = .ollama
    public let baseURL: URL
    public let contextLength: Int
    public let session: URLSession

    /// Models that rejected native tools; they use the prompted protocol from then on.
    private static let promptedModels = LockedSet()
    /// Models that rejected the `think` option.
    private static let noThinkOption = LockedSet()

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        contextLength: Int = 32_768,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.contextLength = contextLength
        self.session = session
    }

    public func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, http) = try await HTTPStreaming.getJSON(url: url, session: session)
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChatProviderError.httpStatus(http.statusCode, body)
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = obj["models"] as? [[String: Any]]
        else {
            throw ChatProviderError.decodingFailed("Ollama /api/tags")
        }
        let names = models.compactMap { $0["name"] as? String }.sorted()
        if names.isEmpty {
            throw ChatProviderError.underlying("No Ollama models installed. Run: ollama pull gemma4")
        }
        return names
    }

    /// Loads the model into memory ahead of the first message so the first reply isn't slowed by a cold start.
    public func warmUp(model: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "messages": [], "keep_alive": "30m"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: request)
    }

    // MARK: - Messages

    static func messages(
        from history: [ChatMessage],
        systemPrompt: String,
        prompted: Bool,
        keepImages: Int = 2
    ) -> [[String: Any]] {
        let answered = Transcript.answeredToolCallIDs(history)
        let imageIDs = Transcript.imageMessageIDs(history, keep: keepImages)
        var out: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        var pendingImages: [String] = []

        func flushImages() {
            guard !pendingImages.isEmpty else { return }
            out.append(["role": "user", "content": "Here is the screenshot from that tool.", "images": pendingImages])
            pendingImages.removeAll()
        }

        for message in history {
            if message.role != .tool || prompted { flushImages() }
            let images = (message.images ?? []).map(\.base64)
            let sendImages = !images.isEmpty && imageIDs.contains(message.id)
            switch message.role {
            case .system:
                continue
            case .user:
                var entry: [String: Any] = ["role": "user", "content": Transcript.userText(message)]
                if !images.isEmpty { entry["images"] = images }
                out.append(entry)
            case .assistant:
                if message.isProactive == true {
                    out.append(["role": "user", "content": Transcript.proactiveText(message)])
                    continue
                }
                let calls = (message.toolCalls ?? []).filter { answered.contains($0.id) }
                if prompted {
                    var text = message.content
                    for call in calls {
                        text += "\n```tool\n" + JSONValue.object(["name": .string(call.name), "arguments": call.arguments]).jsonString + "\n```"
                    }
                    out.append(["role": "assistant", "content": text])
                } else {
                    var entry: [String: Any] = ["role": "assistant", "content": message.content]
                    if !calls.isEmpty {
                        entry["tool_calls"] = calls.map { call in
                            ["function": ["name": call.name, "arguments": call.arguments.anyValue] as [String: Any]]
                        }
                    }
                    out.append(entry)
                }
            case .tool:
                var content = message.content
                if !images.isEmpty && !sendImages { content += "\n[older screenshot omitted]" }
                if prompted {
                    var entry: [String: Any] = ["role": "user", "content": "Result of \(message.toolName ?? "tool"):\n\(content)"]
                    if sendImages { entry["images"] = images }
                    out.append(entry)
                } else {
                    var entry: [String: Any] = ["role": "tool", "content": content]
                    if let name = message.toolName { entry["tool_name"] = name }
                    out.append(entry)
                    if sendImages { pendingImages.append(contentsOf: images) }
                }
            }
        }
        flushImages()
        return out
    }

    /// System prompt addition describing tools for models without native tool calling.
    static func promptedToolInstructions(_ tools: [ToolSpec]) -> String {
        var lines = [
            "",
            "## Tools",
            "You can use tools to act. To call one, write a fenced block exactly like this and nothing after it:",
            "```tool",
            #"{"name": "tool_name", "arguments": {"key": "value"}}"#,
            "```",
            "Call one tool per reply. Its result comes back in the next message; then continue. When no tool is needed, just answer normally.",
            "Available tools:"
        ]
        for tool in tools {
            lines.append("- \(tool.name): \(tool.description)")
            if let props = tool.inputSchema["properties"], props.objectValue?.isEmpty == false {
                lines.append("  arguments: \(props.jsonString)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Streaming

    public func streamTurn(_ request: AgentRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        let model = request.model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let usePrompted = !request.tools.isEmpty && Self.promptedModels.contains(model)
                    do {
                        try await run(request, prompted: usePrompted, continuation: continuation)
                    } catch ChatProviderError.httpStatus(let code, let body)
                        where (400..<500).contains(code) && body.lowercased().contains("think")
                            && !Self.noThinkOption.contains(model) {
                        // This model doesn't take the `think` option; drop it and retry.
                        Self.noThinkOption.insert(model)
                        try await run(request, prompted: usePrompted, continuation: continuation)
                    } catch ChatProviderError.httpStatus(let code, let body)
                        where !usePrompted && !request.tools.isEmpty && (400..<500).contains(code)
                            && body.lowercased().contains("support tools") {
                        // This model's template has no tool support: fall back to the prompted protocol.
                        Self.promptedModels.insert(model)
                        try await run(request, prompted: true, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: AgentRequest,
        prompted: Bool,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async throws {
        let system = prompted ? request.systemPrompt + "\n" + Self.promptedToolInstructions(request.tools) : request.systemPrompt
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "messages": Self.messages(from: request.messages, systemPrompt: system, prompted: prompted),
            "keep_alive": "30m",
            "options": ["num_ctx": contextLength]
        ]
        // Thinking models stay silent until they finish reasoning; for quick replies, skip it so she talks right away.
        if request.depth == .snappy, !Self.noThinkOption.contains(request.model) {
            body["think"] = false
        }
        if !prompted, !request.tools.isEmpty {
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

        let lines = HTTPStreaming.streamLines(
            url: baseURL.appendingPathComponent("api/chat"),
            headers: ["Accept": "application/x-ndjson"],
            body: body,
            session: session
        )

        var sawToolCall = false
        var filter = PromptedToolFilter()
        for try await line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let json = JSONValue.parse(trimmed) else { continue }
            if let error = json["error"]?.stringValue {
                throw ChatProviderError.underlying("Ollama: \(error)")
            }
            if let text = json["message"]?["content"]?.stringValue, !text.isEmpty {
                let visible = prompted ? filter.feed(text) : text
                if !visible.isEmpty { continuation.yield(.textDelta(visible)) }
            }
            for call in json["message"]?["tool_calls"]?.arrayValue ?? [] {
                guard let name = call["function"]?["name"]?.stringValue else { continue }
                var args = call["function"]?["arguments"] ?? .object([:])
                if let s = args.stringValue, let parsed = JSONValue.parse(s) { args = parsed }
                sawToolCall = true
                continuation.yield(.toolCall(ToolCall(
                    id: "ollama_\(UUID().uuidString.prefix(12))",
                    name: name,
                    arguments: args.objectValue != nil ? args : .object([:])
                )))
            }
            if json["done"]?.boolValue == true { break }
        }

        if prompted {
            let (rest, call) = filter.finish()
            if !rest.isEmpty { continuation.yield(.textDelta(rest)) }
            if let call {
                sawToolCall = true
                continuation.yield(.toolCall(call))
            }
        }
        continuation.yield(.finished(stop: sawToolCall ? .toolUse : .endTurn, rawContent: nil))
    }
}

/// Streams visible text while holding back anything that might be a ```tool block, then parses the call.
struct PromptedToolFilter {
    private var full = ""
    private var emitted = 0

    /// Returns the newly visible text.
    mutating func feed(_ chunk: String) -> String {
        full += chunk
        let chars = Array(full)
        var safeEnd: Int
        if let fence = full.range(of: "```") {
            safeEnd = full.distance(from: full.startIndex, to: fence.lowerBound)
        } else {
            // A trailing backtick could be the start of a fence.
            safeEnd = chars.count
            while safeEnd > 0, chars[safeEnd - 1] == "`" { safeEnd -= 1 }
        }
        guard safeEnd > emitted else { return "" }
        let out = String(chars[emitted..<safeEnd])
        emitted = safeEnd
        return out
    }

    /// Remaining visible text and the parsed tool call, if the reply contained one.
    mutating func finish() -> (String, ToolCall?) {
        let chars = Array(full)
        guard let call = Self.parseCall(full) else {
            let rest = emitted < chars.count ? String(chars[emitted...]) : ""
            emitted = chars.count
            return (rest, nil)
        }
        emitted = chars.count
        return ("", call)
    }

    static func parseCall(_ text: String) -> ToolCall? {
        guard let fence = text.range(of: "```") else { return nil }
        let after = text[fence.upperBound...]
        guard let open = after.firstIndex(of: "{"), let close = after.lastIndex(of: "}"), open < close else { return nil }
        guard let json = JSONValue.parse(String(after[open...close])),
              let name = json["name"]?.stringValue ?? json["tool"]?.stringValue else { return nil }
        var args = json["arguments"] ?? json["parameters"] ?? .object([:])
        if let s = args.stringValue, let parsed = JSONValue.parse(s) { args = parsed }
        return ToolCall(
            id: "local_\(UUID().uuidString.prefix(12))",
            name: name,
            arguments: args.objectValue != nil ? args : .object([:])
        )
    }
}

/// A tiny thread-safe string set.
final class LockedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var items = Set<String>()

    func contains(_ item: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items.contains(item)
    }

    func insert(_ item: String) {
        lock.lock(); defer { lock.unlock() }
        items.insert(item)
    }
}
