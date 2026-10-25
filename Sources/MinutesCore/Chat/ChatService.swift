import Combine
import Foundation

public enum CharacterMood: String, Sendable, Equatable {
    case idle
    case listening
    case thinking
    /// Running tools.
    case working
    case talking
    case announcing
    case concerned
}

/// Runs Miss Minute's agent loop: user turn → model → tools → model … → spoken reply.
@MainActor
public final class ChatService: ObservableObject {
    @Published public private(set) var conversation: Conversation
    @Published public private(set) var streamingText: String = ""
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var lastError: String?
    /// Live status line while working ("Checking your calendar…").
    @Published public private(set) var activityStatus: String?
    @Published public var mood: CharacterMood = .idle

    /// Computer-use tasks take many observe/act steps.
    public static let maxStepsPerTurn = 40

    private let store: JSONFileStore<Conversation>
    private var turnTask: Task<Void, Never>?
    private let reminderParser: ReminderParser
    private var pendingAnnouncements: [ChatMessage] = []

    /// Offline fallback when no model is reachable and the text is a plain reminder request.
    public var onReminderParsed: ((ParsedReminder) -> Void)?
    /// Assistant text to voice. `continuing` is true for later parts of the same turn (queue, don't interrupt).
    public var onSpeak: ((_ text: String, _ continuing: Bool) -> Void)?
    /// A completed reply (for the speech bubble).
    public var onReply: ((String) -> Void)?
    /// About to run a tool (lets the app get out of the way of screen actions).
    public var onToolCall: ((ToolCall) -> Void)?
    /// The agent turn finished, failed, or was cancelled.
    public var onTurnEnded: (() -> Void)?
    /// A turn completed normally: the user's words, her full reply, and the names of tools she used.
    public var onExchangeCompleted: ((_ userText: String, _ reply: String, _ toolsUsed: [String]) -> Void)?
    public var providerFactory: () throws -> any ChatProvider
    public var settingsProvider: () -> AppSettings
    /// Builds the `<context>` note for a new user message. Argument: "typed" or "spoken".
    public var contextProvider: (String) -> String
    public var tools: ToolRegistry

    public init(
        store: JSONFileStore<Conversation> = JSONFileStore(url: MinutesPaths.conversationURL),
        reminderParser: ReminderParser = ReminderParser(),
        tools: ToolRegistry? = nil,
        settingsProvider: @escaping () -> AppSettings = { .default },
        contextProvider: @escaping (String) -> String = { _ in Persona.timeAwarePrefix() },
        providerFactory: @escaping () throws -> any ChatProvider
    ) {
        self.store = store
        self.reminderParser = reminderParser
        self.tools = tools ?? ToolRegistry()
        self.settingsProvider = settingsProvider
        self.contextProvider = contextProvider
        self.providerFactory = providerFactory
        self.conversation = Conversation()
    }

    public func load() async {
        do {
            conversation = try await store.load(default: Conversation())
            repairInterruptedTurn()
        } catch {
            lastError = error.localizedDescription
            conversation = Conversation()
        }
    }

    public func clearHistory() async {
        cancelStreaming()
        conversation = Conversation()
        streamingText = ""
        lastError = nil
        await persist()
    }

    /// Messages shown in the UI (tool results render as compact activity chips).
    public var visibleMessages: [ChatMessage] {
        conversation.messages.filter { message in
            switch message.role {
            case .system: return false
            case .tool: return message.displaySummary != nil
            case .assistant: return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .user: return true
            }
        }
    }

    public func send(_ userText: String, inputMode: String = "typed") {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isStreaming { cancelStreaming() }
        lastError = nil

        // No reachable model? Still handle plain reminder phrases locally.
        if (try? providerFactory()) == nil, let parsed = reminderParser.parse(trimmed) {
            onReminderParsed?(parsed)
            let confirmation = "You got it, sugar — I'll nudge you about \"\(parsed.text)\" at \(Self.format(parsed.fireAt))."
            append(ChatMessage(role: .user, content: trimmed))
            append(ChatMessage(role: .assistant, content: confirmation))
            mood = .announcing
            onSpeak?(confirmation, false)
            onReply?(confirmation)
            Task { await persist() }
            return
        }

        append(ChatMessage(role: .user, content: trimmed, contextNote: contextProvider(inputMode)))
        runTurn()
    }

    public func cancelStreaming() {
        turnTask?.cancel()
        turnTask = nil
        if !streamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(ChatMessage(role: .assistant, content: streamingText))
        }
        streamingText = ""
        repairInterruptedTurn()
        endTurn()
        mood = .idle
    }

    /// Something Miss Minute says on her own (reminder fired, build finished…).
    public func announce(_ text: String, speak: Bool = true) {
        let message = ChatMessage(role: .assistant, content: text, isProactive: true)
        if isStreaming {
            // Never splice into a running tool loop; add it once the turn ends.
            pendingAnnouncements.append(message)
        } else {
            append(message)
            Task { await persist() }
        }
        if speak { onSpeak?(text, isStreaming) }
        if !isStreaming {
            mood = .announcing
            Task {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                if self.mood == .announcing { self.mood = .idle }
            }
        }
    }

    // MARK: - Agent loop

    private func runTurn() {
        turnTask?.cancel()
        isStreaming = true
        streamingText = ""
        activityStatus = nil
        mood = .thinking

        let settings = settingsProvider()

        turnTask = Task { [weak self] in
            guard let self else { return }
            var spokeSomething = false
            var replyParts: [String] = []
            var toolsUsed: [String] = []
            let userText = self.conversation.messages.last(where: { $0.role == .user })?.content ?? ""
            // Voice each sentence as soon as it's complete; the first one interrupts, the rest queue.
            let speak: (String) -> Void = { sentence in
                self.onSpeak?(sentence, spokeSomething)
                spokeSomething = true
            }
            do {
                let provider = try self.providerFactory()
                let allowSearch = settings.webSearchEnabled && provider.kind == .anthropic
                // Fix the history window for the whole turn: shifting it between steps would change the
                // prefix and invalidate thinking blocks being replayed inside the tool loop.
                let windowStart = Transcript.window(self.conversation.messages, limit: 60).first?.id

                for _ in 0..<Self.maxStepsPerTurn {
                    let all = self.conversation.messages.filter { $0.role != .system }
                    let startIndex = windowStart.flatMap { id in all.firstIndex { $0.id == id } } ?? 0
                    let request = AgentRequest(
                        messages: Array(all[startIndex...]),
                        model: settings.model,
                        systemPrompt: settings.personaPrompt,
                        tools: self.tools.specs,
                        depth: settings.responseDepth,
                        allowWebSearch: allowSearch
                    )

                    var calls: [ToolCall] = []
                    var stop: TurnStopReason = .other
                    var raw: JSONValue?
                    // The first spoken chunk can break at a comma so her voice starts as early as possible.
                    var chunker = SentenceChunker(firstClauseLength: spokeSomething ? nil : 28)
                    self.streamingText = ""
                    for try await event in provider.streamTurn(request) {
                        try Task.checkCancellation()
                        switch event {
                        case .textDelta(let text):
                            self.streamingText += text
                            if self.mood != .talking { self.mood = .talking }
                            chunker.feed(text).forEach(speak)
                        case .toolCall(let call):
                            calls.append(call)
                        case .status(let status):
                            self.activityStatus = status
                            self.mood = .working
                        case .finished(let reason, let content):
                            stop = reason
                            raw = content
                        }
                    }
                    try Task.checkCancellation()
                    if let rest = chunker.flush() { speak(rest) }

                    var text = self.streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.streamingText = ""
                    if stop == .refusal, text.isEmpty {
                        text = "Sorry, sugar — that's one I can't help with."
                        speak(text)
                    } else if stop == .maxTokens {
                        let note = text.isEmpty ? "I ran out of room on that one — ask me to keep going?" : " …"
                        text += note
                        if note.count > 3 { speak(note) }
                    }
                    if text.isEmpty && calls.isEmpty && stop != .pauseTurn {
                        if replyParts.isEmpty { throw ChatProviderError.emptyResponse }
                        break
                    }

                    self.append(ChatMessage(
                        role: .assistant,
                        content: text,
                        toolCalls: calls.isEmpty ? nil : calls,
                        providerContent: raw
                    ))
                    if !text.isEmpty {
                        replyParts.append(text)
                    }

                    if stop == .refusal { break }
                    if stop == .pauseTurn { continue }
                    if calls.isEmpty { break }

                    self.mood = .working
                    for call in calls {
                        try Task.checkCancellation()
                        self.activityStatus = Self.statusLine(for: call)
                        self.onToolCall?(call)
                        toolsUsed.append(call.name)
                        let outcome = await self.tools.execute(call)
                        self.append(ChatMessage(
                            role: .tool,
                            content: outcome.output,
                            toolCallID: call.id,
                            toolName: call.name,
                            isError: outcome.isError ? true : nil,
                            displaySummary: outcome.isError ? nil : outcome.summary,
                            images: outcome.images.isEmpty ? nil : outcome.images
                        ))
                    }
                    self.activityStatus = nil
                    self.mood = .thinking
                    await self.persist()
                }

                guard !Task.isCancelled else { return }
                let reply = replyParts.joined(separator: " ")
                if !reply.isEmpty { self.onReply?(reply) }
                self.endTurn()
                self.onExchangeCompleted?(userText, reply, toolsUsed)
                self.mood = .talking
                await self.persist()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled, self.mood == .talking { self.mood = .idle }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                if let providerError = error as? ChatProviderError, providerError == .cancelled { return }
                self.streamingText = ""
                self.repairInterruptedTurn()
                self.lastError = error.localizedDescription
                self.endTurn()
                self.mood = .concerned
                await self.persist()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.mood == .concerned { self.mood = .idle }
            }
        }
    }

    private func endTurn() {
        let wasStreaming = isStreaming
        isStreaming = false
        activityStatus = nil
        // Provider-native blocks and screenshots only matter inside a turn; drop them to keep history small.
        for index in conversation.messages.indices {
            if conversation.messages[index].providerContent != nil {
                conversation.messages[index].providerContent = nil
            }
            if let images = conversation.messages[index].images, !images.isEmpty {
                conversation.messages[index].images = nil
                conversation.messages[index].content += "\n[\(images.count) screenshot(s) were shown here; take a new one if needed]"
            }
        }
        if wasStreaming { onTurnEnded?() }
        if !pendingAnnouncements.isEmpty {
            conversation.messages.append(contentsOf: pendingAnnouncements)
            pendingAnnouncements.removeAll()
        }
    }

    /// Every tool call must have a result, or providers reject the history.
    private func repairInterruptedTurn() {
        let answered = Transcript.answeredToolCallIDs(conversation.messages)
        var insertions: [(Int, [ChatMessage])] = []
        for (index, message) in conversation.messages.enumerated() {
            let missing = (message.toolCalls ?? []).filter { !answered.contains($0.id) }
            guard !missing.isEmpty else { continue }
            let results = missing.map {
                ChatMessage(role: .tool, content: "Cancelled before it ran.", toolCallID: $0.id, toolName: $0.name, isError: true)
            }
            insertions.append((index + 1, results))
        }
        for (index, results) in insertions.reversed() {
            conversation.messages.insert(contentsOf: results, at: index)
        }
    }

    private func append(_ message: ChatMessage) {
        conversation.messages.append(message)
        conversation.updatedAt = Date()
        if conversation.title == "Chat", message.role == .user {
            conversation.title = String(message.content.prefix(48))
        }
        // Cap stored history.
        if conversation.messages.count > 400 {
            conversation.messages = Transcript.window(conversation.messages, limit: 300)
        }
    }

    private func persist() async {
        do {
            try await store.save(conversation)
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func statusLine(for call: ToolCall) -> String {
        switch call.name {
        case "add_task", "update_task", "complete_task", "delete_task", "list_tasks": return "Updating your tasks…"
        case "set_reminder", "list_reminders", "cancel_reminder": return "Setting things on the timeline…"
        case "start_timer": return "Starting the clock…"
        case "remember", "recall", "forget": return "Checking my notes…"
        case "get_calendar_events", "create_calendar_event": return "Checking your calendar…"
        case "open_app", "open_url": return "Opening that for you…"
        case "run_shortcut": return "Running your shortcut…"
        case "get_activity_summary", "get_system_status": return "Taking a look around…"
        default: return "Working on it…"
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
