import Foundation

/// Shared rules for turning stored conversation history into what a provider sees.
///
/// History is append-only from the model's point of view: per-message context is stored on the
/// message itself, and the system prompt never changes between requests. That keeps prompt caching
/// effective and keeps Anthropic thinking blocks valid inside a tool loop.
public enum Transcript {
    /// Most recent messages, starting on a user turn so tool calls are never split from their results.
    public static func window(_ messages: [ChatMessage], limit: Int = 40) -> [ChatMessage] {
        let usable = messages.filter { $0.role != .system }
        guard usable.count > limit else { return usable }
        var start = usable.count - limit
        while start < usable.count, usable[start].role != .user {
            start += 1
        }
        if start >= usable.count {
            // No user turn in range; fall back to the last user turn we can find.
            start = usable.lastIndex(where: { $0.role == .user }) ?? 0
        }
        return Array(usable[start...])
    }

    /// Index of the last user turn (the start of the in-flight agent turn).
    public static func currentTurnStart(_ messages: [ChatMessage]) -> Int {
        messages.lastIndex(where: { $0.role == .user }) ?? -1
    }

    /// The text a provider receives for a user message.
    public static func userText(_ message: ChatMessage) -> String {
        guard let note = message.contextNote, !note.isEmpty else { return message.content }
        return "<context>\n\(note)\n</context>\n\n\(message.content)"
    }

    /// Proactive lines are shown to the model as notes on the user side, so turn order stays valid.
    public static func proactiveText(_ message: ChatMessage) -> String {
        "<note>Earlier, you said this on your own initiative: \"\(message.content)\"</note>"
    }

    /// IDs of the messages whose images should still be sent (the most recent `keep` image-bearing messages).
    /// Small local models can't hold dozens of screenshots; older ones become a text note.
    public static func imageMessageIDs(_ messages: [ChatMessage], keep: Int) -> Set<UUID> {
        Set(messages.filter { !($0.images ?? []).isEmpty }.suffix(keep).map(\.id))
    }

    /// Tool call IDs that have a recorded result.
    public static func answeredToolCallIDs(_ messages: [ChatMessage]) -> Set<String> {
        Set(messages.compactMap { $0.role == .tool ? $0.toolCallID : nil })
    }
}
