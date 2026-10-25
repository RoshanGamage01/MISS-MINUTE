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
            headers: ["Authorization": "Bearer \(apiKey)"],
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

    public func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        let url = baseURL.appendingPathComponent("chat/completions")
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
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "text/event-stream"
            ],
            body: body,
            session: session
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        for payload in SSEParser.dataPayloads(from: line) {
                            if let content = SSEParser.openAIDeltaContent(from: payload), !content.isEmpty {
                                continuation.yield(content)
                            }
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
