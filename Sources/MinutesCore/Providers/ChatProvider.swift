import Foundation

public enum ChatProviderError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidURL(String)
    case httpStatus(Int, String)
    case decodingFailed(String)
    case emptyResponse
    case cancelled
    case refused(String?)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key yet. Add one in Settings → Brain (it's stored in your Keychain)."
        case .invalidURL(let value):
            return "Invalid URL: \(value)"
        case .httpStatus(let code, let body):
            return Self.describeHTTP(code: code, body: body)
        case .decodingFailed(let detail):
            return "Failed to decode response: \(detail)"
        case .emptyResponse:
            return "The model returned an empty response."
        case .cancelled:
            return "Request cancelled."
        case .refused(let category):
            if let category { return "The model declined this request (\(category))." }
            return "The model declined this request."
        case .underlying(let message):
            return message
        }
    }

    private static func describeHTTP(code: Int, body: String) -> String {
        // Surface the provider's own error message when it sent JSON.
        var message = body
        if let json = JSONValue.parse(body) {
            if let m = json["error"]?["message"]?.stringValue {
                message = m
            } else if let m = json["error"]?.stringValue {
                message = m
            } else if let m = json["message"]?.stringValue {
                message = m
            }
        }
        switch code {
        case 401, 403: return "The provider rejected the API key (\(code)). \(message)"
        case 404: return "Model or endpoint not found (404). \(message)"
        case 429: return "Rate limited (429). Give it a moment. \(message)"
        case 529: return "The provider is overloaded right now (529). Try again shortly."
        default: return "HTTP \(code): \(message)"
        }
    }
}

/// Pluggable streaming agent backend. Add new providers by conforming to this protocol
/// and registering them in `ChatProviderFactory`.
public protocol ChatProvider: Sendable {
    var kind: ProviderKind { get }
    func listModels() async throws -> [String]
    /// One model call: streams text, emits tool calls, and finishes with a stop reason.
    func streamTurn(_ request: AgentRequest) -> AsyncThrowingStream<ProviderEvent, Error>
}

extension ChatProvider {
    /// Plain text completion with no tools (used for short one-off lines).
    public func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String,
        depth: ResponseDepth = .snappy
    ) -> AsyncThrowingStream<String, Error> {
        let events = streamTurn(AgentRequest(
            messages: messages,
            model: model,
            systemPrompt: systemPrompt,
            tools: [],
            depth: depth
        ))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case .textDelta(let text) = event { continuation.yield(text) }
                        if case .finished(let stop, _) = event, stop == .refusal {
                            throw ChatProviderError.refused(nil)
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

public protocol APIKeyProviding: Sendable {
    func apiKey(for kind: ProviderKind) throws -> String?
}

public struct ChatProviderFactory: Sendable {
    public var keyProvider: any APIKeyProviding
    public var ollamaBaseURL: URL
    public var ollamaContextLength: Int
    public var localServerURL: URL
    public var session: URLSession

    public init(
        keyProvider: any APIKeyProviding,
        ollamaBaseURL: URL = URL(string: "http://localhost:11434")!,
        ollamaContextLength: Int = 32_768,
        localServerURL: URL = URL(string: "http://localhost:1234/v1")!,
        session: URLSession = .shared
    ) {
        self.keyProvider = keyProvider
        self.ollamaBaseURL = ollamaBaseURL
        self.ollamaContextLength = ollamaContextLength
        self.localServerURL = localServerURL
        self.session = session
    }

    public func makeProvider(for kind: ProviderKind) throws -> any ChatProvider {
        switch kind {
        case .openAI:
            guard let key = try keyProvider.apiKey(for: .openAI), !key.isEmpty else {
                throw ChatProviderError.missingAPIKey
            }
            return OpenAICompatibleProvider(
                kind: .openAI,
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: key,
                session: session,
                defaultModels: ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "o4-mini"]
            )
        case .xAI:
            guard let key = try keyProvider.apiKey(for: .xAI), !key.isEmpty else {
                throw ChatProviderError.missingAPIKey
            }
            return OpenAICompatibleProvider(
                kind: .xAI,
                baseURL: URL(string: "https://api.x.ai/v1")!,
                apiKey: key,
                session: session,
                defaultModels: ["grok-2-latest", "grok-3-mini"]
            )
        case .anthropic:
            guard let key = try keyProvider.apiKey(for: .anthropic), !key.isEmpty else {
                throw ChatProviderError.missingAPIKey
            }
            return AnthropicProvider(apiKey: key, session: session)
        case .ollama:
            return OllamaProvider(baseURL: ollamaBaseURL, contextLength: ollamaContextLength, session: session)
        case .localServer:
            return OpenAICompatibleProvider(
                kind: .localServer,
                baseURL: localServerURL,
                apiKey: (try? keyProvider.apiKey(for: .localServer)) ?? "",
                session: session,
                defaultModels: []
            )
        }
    }
}
