import Foundation

public enum ChatRole: String, Codable, Sendable, Equatable {
    case system
    case user
    case assistant
    /// Result of a tool call (paired with an assistant message's `toolCalls`).
    case tool
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: ChatRole
    public var content: String
    public var createdAt: Date

    /// Tool calls requested by an assistant message.
    public var toolCalls: [ToolCall]?
    /// For `.tool` messages: the call this result answers.
    public var toolCallID: String?
    /// For `.tool` messages: the tool name (some providers need it).
    public var toolName: String?
    /// For `.tool` messages: whether the tool failed.
    public var isError: Bool?
    /// Short human-readable line shown in the UI for tool activity ("Added task: …").
    public var displaySummary: String?
    /// Situational context captured when a user message was sent (time, frontmost app, memories…).
    /// Sent to the model with the message so history stays append-only.
    public var contextNote: String?
    /// Assistant lines Miss Minute volunteered (reminders, activity reactions), not replies.
    public var isProactive: Bool?
    /// Provider-native assistant content for replay inside the same agent turn. Cleared when the turn ends.
    public var providerContent: JSONValue?
    /// Images the model should see with this message (screenshots from tools). Dropped when the turn ends.
    public var images: [ImageAttachment]?
    /// A note the app sent to the model (e.g. "you said you'd do it but didn't"); never shown in the chat.
    public var isHidden: Bool?

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        createdAt: Date = Date(),
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
        isError: Bool? = nil,
        displaySummary: String? = nil,
        contextNote: String? = nil,
        isProactive: Bool? = nil,
        providerContent: JSONValue? = nil,
        images: [ImageAttachment]? = nil,
        isHidden: Bool? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.isError = isError
        self.displaySummary = displaySummary
        self.contextNote = contextNote
        self.isProactive = isProactive
        self.providerContent = providerContent
        self.images = images
        self.isHidden = isHidden
    }

    public var hasToolCalls: Bool { !(toolCalls ?? []).isEmpty }

    /// A message the user typed or spoke (not a tool result).
    public var isUserTurn: Bool { role == .user }
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
    /// Any OpenAI-compatible server on this Mac: LM Studio, llama.cpp, MLX, vLLM…
    case localServer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .xAI: return "xAI"
        case .ollama: return "Ollama (local)"
        case .localServer: return "Local server (LM Studio, llama.cpp…)"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .ollama, .localServer: return false
        case .openAI, .anthropic, .xAI: return true
        }
    }

    /// Runs entirely on this Mac.
    /// The cloud API host, for opening the connection before the first request (nil for local providers,
    /// whose server URL is user-configured).
    public var apiHost: URL? {
        switch self {
        case .anthropic: return URL(string: "https://api.anthropic.com/")
        case .openAI: return URL(string: "https://api.openai.com/")
        case .xAI: return URL(string: "https://api.x.ai/")
        case .ollama, .localServer: return nil
        }
    }

    public var isLocal: Bool {
        self == .ollama || self == .localServer
    }

    public var keychainAccount: String {
        "minutes.provider.\(rawValue).apiKey"
    }

    public var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-opus-5-5"
        case .xAI: return "grok-2-latest"
        case .ollama: return "gemma4"
        case .localServer: return "local-model"
        }
    }
}
