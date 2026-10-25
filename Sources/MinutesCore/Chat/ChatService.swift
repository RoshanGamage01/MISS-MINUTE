import Combine
import Foundation

public enum CharacterMood: String, Sendable, Equatable {
    case idle
    case thinking
    case talking
    case announcing
}

@MainActor
public final class ChatService: ObservableObject {
    @Published public private(set) var conversation: Conversation
    @Published public private(set) var streamingText: String = ""
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var lastError: String?
    @Published public var mood: CharacterMood = .idle

    private let store: JSONFileStore<Conversation>
    private var streamTask: Task<Void, Never>?
    private let reminderParser: ReminderParser

    public var onReminderParsed: ((ParsedReminder) -> Void)?
    public var providerFactory: () throws -> any ChatProvider
    public var settingsProvider: () -> AppSettings

    public init(
        store: JSONFileStore<Conversation> = JSONFileStore(url: MinutesPaths.conversationURL),
        reminderParser: ReminderParser = ReminderParser(),
        settingsProvider: @escaping () -> AppSettings = { .default },
        providerFactory: @escaping () throws -> any ChatProvider
    ) {
        self.store = store
        self.reminderParser = reminderParser
        self.settingsProvider = settingsProvider
        self.providerFactory = providerFactory
        self.conversation = Conversation()
    }

    public func load() async {
        do {
            conversation = try await store.load(default: Conversation())
        } catch {
            lastError = error.localizedDescription
            conversation = Conversation()
        }
    }

    public func clearHistory() async {
        conversation = Conversation()
        streamingText = ""
        lastError = nil
        await persist()
    }

    public func send(_ userText: String) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastError = nil

        if let parsed = reminderParser.parse(trimmed) {
            onReminderParsed?(parsed)
            let confirmation = "You got it — I'll nudge you about \"\(parsed.text)\" at \(Self.format(parsed.fireAt))."
            append(role: .user, content: trimmed)
            append(role: .assistant, content: confirmation)
            mood = .announcing
            Task { await persist() }
            return
        }

        append(role: .user, content: trimmed)
        streamAssistantReply()
    }

    public func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        if !streamingText.isEmpty {
            append(role: .assistant, content: streamingText)
            streamingText = ""
        }
        mood = .idle
    }

    public func announce(_ text: String) {
        append(role: .assistant, content: text)
        mood = .announcing
        Task { await persist() }
    }

    private func streamAssistantReply() {
        streamTask?.cancel()
        isStreaming = true
        streamingText = ""
        mood = .thinking

        let settings = settingsProvider()
        let history = conversation.messages.filter { $0.role != .system }
        let system = [
            settings.personaPrompt,
            Persona.timeAwarePrefix()
        ].joined(separator: "\n\n")

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try self.providerFactory()
                self.mood = .talking
                let stream = provider.streamChat(
                    messages: history,
                    model: settings.model,
                    systemPrompt: system
                )
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    self.streamingText += chunk
                }
                if !Task.isCancelled {
                    let finalText = self.streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.streamingText = ""
                    self.isStreaming = false
                    if finalText.isEmpty {
                        self.lastError = ChatProviderError.emptyResponse.localizedDescription
                        self.mood = .idle
                    } else {
                        self.append(role: .assistant, content: finalText)
                        self.mood = .idle
                        await self.persist()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.isStreaming = false
                    self.streamingText = ""
                    self.lastError = error.localizedDescription
                    self.mood = .idle
                }
            }
        }
    }

    private func append(role: ChatRole, content: String) {
        conversation.messages.append(ChatMessage(role: role, content: content))
        conversation.updatedAt = Date()
        if conversation.title == "Chat", role == .user {
            conversation.title = String(content.prefix(48))
        }
    }

    private func persist() async {
        do {
            try await store.save(conversation)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
