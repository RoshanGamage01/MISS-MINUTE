import Foundation

public enum ChatRole: String, Codable, Sendable, Equatable {
    case system
    case user
    case assistant
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: ChatRole
    public var content: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct Conversation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "Chat",
        messages: [ChatMessage] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
    }
}

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case openAI
    case anthropic
    case xAI
    case ollama

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .xAI: return "xAI"
        case .ollama: return "Ollama (local)"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        case .openAI, .anthropic, .xAI: return true
        }
    }

    public var keychainAccount: String {
        "minutes.provider.\(rawValue).apiKey"
    }

    public var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-3-5-haiku-latest"
        case .xAI: return "grok-2-latest"
        case .ollama: return "llama3.2"
        }
    }
}
