import Foundation

public enum ChatProviderError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidURL(String)
    case httpStatus(Int, String)
    case decodingFailed(String)
    case emptyResponse
    case cancelled
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is missing. Add it in Settings (stored in Keychain)."
        case .invalidURL(let value):
            return "Invalid URL: \(value)"
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body)"
        case .decodingFailed(let detail):
            return "Failed to decode response: \(detail)"
        case .emptyResponse:
            return "The provider returned an empty response."
        case .cancelled:
            return "Request cancelled."
        case .underlying(let message):
            return message
        }
    }
}

/// Pluggable streaming chat backend. Add new providers by conforming to this protocol
/// and registering them in `ChatProviderFactory`.
public protocol ChatProvider: Sendable {
    var kind: ProviderKind { get }
    func listModels() async throws -> [String]
    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error>
}

public protocol APIKeyProviding: Sendable {
    func apiKey(for kind: ProviderKind) throws -> String?
}

public struct ChatProviderFactory: Sendable {
    public var keyProvider: any APIKeyProviding
    public var ollamaBaseURL: URL
    public var session: URLSession

    public init(
        keyProvider: any APIKeyProviding,
        ollamaBaseURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession = .shared
    ) {
        self.keyProvider = keyProvider
        self.ollamaBaseURL = ollamaBaseURL
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
                defaultModels: ["grok-2-latest", "grok-2-vision-latest", "grok-3-mini"]
            )
        case .anthropic:
            guard let key = try keyProvider.apiKey(for: .anthropic), !key.isEmpty else {
                throw ChatProviderError.missingAPIKey
            }
            return AnthropicProvider(apiKey: key, session: session)
        case .ollama:
            return OllamaProvider(baseURL: ollamaBaseURL, session: session)
        }
    }
}
