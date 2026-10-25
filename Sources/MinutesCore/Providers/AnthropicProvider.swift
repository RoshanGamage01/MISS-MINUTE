import Foundation

public struct AnthropicProvider: ChatProvider, Sendable {
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

    public func listModels() async throws -> [String] {
        [
            "claude-3-5-haiku-latest",
            "claude-3-5-sonnet-latest",
            "claude-sonnet-4-0",
            "claude-opus-4-0"
        ]
    }

    public func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        let url = baseURL.appendingPathComponent("messages")
        let apiMessages: [[String: String]] = messages
            .filter { $0.role != .system }
            .map { ["role": $0.role == .assistant ? "assistant" : "user", "content": $0.content] }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": apiMessages
        ]

        let lines = HTTPStreaming.streamLines(
            url: url,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
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
                            if let text = SSEParser.anthropicDeltaText(from: payload), !text.isEmpty {
                                continuation.yield(text)
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
