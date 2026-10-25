import Foundation

public struct OllamaProvider: ChatProvider, Sendable {
    public let kind: ProviderKind = .ollama
    public let baseURL: URL
    public let session: URLSession

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, session: URLSession = .shared) {
        self.baseURL = baseURL
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
            throw ChatProviderError.underlying(
                "No Ollama models installed. Run: ollama pull llama3.2"
            )
        }
        return names
    }

    public func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        let url = baseURL.appendingPathComponent("api/chat")
        var apiMessages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        apiMessages += messages.map { ["role": $0.role.rawValue, "content": $0.content] }

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": apiMessages
        ]

        let lines = HTTPStreaming.streamLines(
            url: url,
            headers: ["Accept": "application/x-ndjson"],
            body: body,
            session: session
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        if let parsed = SSEParser.ollamaMessageContent(from: trimmed) {
                            if !parsed.content.isEmpty {
                                continuation.yield(parsed.content)
                            }
                            if parsed.done { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
