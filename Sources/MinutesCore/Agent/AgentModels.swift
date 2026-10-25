import Foundation

/// A function the model may call. `inputSchema` is a JSON Schema object.
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// Convenience for the common `{"type":"object","properties":…,"required":…}` shape.
    public static func object(
        _ name: String,
        _ description: String,
        properties: [String: JSONValue] = [:],
        required: [String] = []
    ) -> ToolSpec {
        ToolSpec(
            name: name,
            description: description,
            inputSchema: .object([
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) })
            ])
        )
    }
}

public struct ToolCall: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// How hard the model should think. Mapped to provider-specific knobs where supported.
public enum ResponseDepth: String, Codable, CaseIterable, Sendable, Identifiable {
    case snappy
    case balanced
    case deep

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .snappy: return "Snappy"
        case .balanced: return "Balanced"
        case .deep: return "Deep"
        }
    }

    /// Anthropic `output_config.effort` value.
    public var anthropicEffort: String {
        switch self {
        case .snappy: return "low"
        case .balanced: return "medium"
        case .deep: return "high"
        }
    }
}

public struct AgentRequest: Sendable {
    public var messages: [ChatMessage]
    public var model: String
    public var systemPrompt: String
    public var tools: [ToolSpec]
    public var depth: ResponseDepth
    /// Lets providers with hosted search (Anthropic) attach it.
    public var allowWebSearch: Bool

    public init(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String,
        tools: [ToolSpec] = [],
        depth: ResponseDepth = .balanced,
        allowWebSearch: Bool = false
    ) {
        self.messages = messages
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.depth = depth
        self.allowWebSearch = allowWebSearch
    }
}

public enum TurnStopReason: String, Sendable, Equatable {
    case endTurn
    case toolUse
    /// A hosted tool paused mid-turn; resend to continue.
    case pauseTurn
    case maxTokens
    case refusal
    case other
}

/// Incremental output from one model call.
public enum ProviderEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCall(ToolCall)
    /// The model began writing a tool call (its arguments are still streaming). Lets the app speak a quick
    /// acknowledgement before anything runs.
    case toolCallStarted(name: String)
    /// Hosted tool activity worth surfacing (e.g. "Searching the web for …").
    case status(String)
    /// Emitted once, last. `rawContent` is the provider's own assistant content
    /// (e.g. Anthropic blocks incl. thinking signatures) to replay verbatim within the same turn.
    case finished(stop: TurnStopReason, rawContent: JSONValue?)
}
