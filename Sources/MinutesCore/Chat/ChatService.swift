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

    /// Computer-use and build tasks take many observe/act steps.
    public static let maxStepsPerTurn = 100
    /// Work she starts herself gets a shorter leash.
    public static let maxStepsPerSelfDirectedTurn = 30
    /// Who started the turn that's running (or last ran).
    @Published public private(set) var initiative: Initiative = .user
    /// Words in the first spoken chunk when no punctuation comes sooner.
    public static let firstChunkWords = 4
    /// Tools that finish in milliseconds; the real reply follows right away, so no "one sec" first.
    public static let instantTools: Set<String> = [
        "add_task", "update_task", "complete_task", "delete_task", "list_tasks",
        "set_reminder", "list_reminders", "cancel_reminder", "start_timer",
        "remember", "recall", "forget", "start_goal", "update_goal", "list_goals", "finish_goal"
    ]
    /// Spoken the moment a slower tool starts, if she hasn't said anything yet.
    public static let acknowledgements = ["Sure thing, one sec!", "On it, sugar!", "One moment, hon!", "Let me take a look!"]
    private var acknowledgementIndex = 0
    /// An instant acknowledgement was spoken for the message about to run (so the model's reply queues after it).
    private var acknowledgedThisTurn = false
    /// Whether to speak an instant "On it!" the moment a spoken request arrives (voice on).
    public var acknowledgeSpokenRequests: () -> Bool = { true }

    private let store: JSONFileStore<Conversation>
    private var turnTask: Task<Void, Never>?
    private let reminderParser: ReminderParser
    private var pendingAnnouncements: [ChatMessage] = []
    /// Background work that finished mid-turn; she picks it up once the current turn ends.
    private var pendingContinuations: [(note: String, initiative: Initiative)] = []

    /// Offline fallback when no model is reachable and the text is a plain reminder request.
    public var onReminderParsed: ((ParsedReminder) -> Void)?
    /// Assistant text to voice. `continuing` is true for later parts of the same turn (queue, don't interrupt).
    public var onSpeak: ((_ text: String, _ continuing: Bool) -> Void)?
    /// A completed reply (for the speech bubble).
    public var onReply: ((String) -> Void)?
    /// About to run a tool (lets the app get out of the way of screen actions).
    public var onToolCall: ((ToolCall) -> Void)?
    /// A tool finished (her body reacts: thumbs up, shrug, a jump to the app that just opened).
    public var onToolFinished: ((ToolCall, ToolOutcome) -> Void)?
    /// The turn failed with an error.
    public var onTurnFailed: (() -> Void)?
    /// A message is about to go to the model (warm up the voice while it thinks).
    public var onWillSend: (() -> Void)?
    /// The user's words, just before the context block is built (mood tracking, memory lookup).
    public var onUserMessage: ((String) -> Void)?
    /// The agent turn finished, failed, or was cancelled.
    public var onTurnEnded: (() -> Void)?
    /// A turn completed normally: the user's words, her full reply, and the names of tools she used.
    public var onExchangeCompleted: ((_ userText: String, _ reply: String, _ toolsUsed: [String]) -> Void)?
    /// Checked before every tool call; a non-nil reason blocks it (the reason goes back to the model).
    public var toolPolicy: ((ToolCall, Initiative) -> String?)?
    /// A self-directed turn ended: her reply (nil when she decided it wasn't worth it) and the tools she used.
    public var onSelfDirectedTurnEnded: ((_ reply: String?, _ toolsUsed: [String], _ error: String?) -> Void)?
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
            case .assistant: return message.isHidden != true && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .user: return message.isHidden != true
            }
        }
    }

    public func send(_ userText: String, inputMode: String = "typed") {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isStreaming { cancelTurn() }
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

        let trace = LatencyTrace.shared
        // Voice input starts the clock itself, backdated to when the user stopped talking.
        if inputMode != "spoken" || !trace.isActive { trace.begin(origin: inputMode) }
        trace.mark(.send)
        onWillSend?()
        onUserMessage?(trimmed)
        var note = contextProvider(inputMode)
        acknowledgedThisTurn = false
        // Say something the instant they finish talking; the model's answer follows it.
        if inputMode == "spoken", acknowledgeSpokenRequests(),
           let ack = InstantAck.line(for: trimmed, index: acknowledgementIndex) {
            acknowledgementIndex += 1
            acknowledgedThisTurn = true
            trace.mark(.firstChunk)
            onSpeak?(ack, false)
            note += "\n(You already said “\(ack)” out loud the moment they finished, so don't open with another acknowledgement.)"
        }
        append(ChatMessage(role: .user, content: trimmed, contextNote: note))
        runTurn(initiative: .user)
    }

    /// Stops the current turn and drops any queued background follow-ups.
    public func cancelStreaming() {
        pendingContinuations.removeAll()
        cancelTurn()
    }

    /// Picks a task back up without the user (a coding job finished, say). `note` goes to the model as a hidden
    /// message; if she's busy, it waits until the current turn ends. Pass `.selfDirected` for work she started
    /// herself: it's held to the autonomy policy and stays quiet unless she has something to report.
    public func continueWork(_ note: String, initiative: Initiative = .user) {
        if isStreaming {
            // Her own ideas never queue behind (or interrupt) a conversation; the loop will try again later.
            if initiative == .user { pendingContinuations.append((note, initiative)) }
            return
        }
        lastError = nil
        LatencyTrace.shared.begin(origin: initiative == .selfDirected ? "initiative" : "background")
        append(ChatMessage(role: .user, content: note,
                           contextNote: contextProvider(initiative == .selfDirected ? "your own initiative (the user didn't ask)" : "background"),
                           isHidden: true))
        runTurn(initiative: initiative)
    }

    private func runPendingContinuation() {
        guard !isStreaming, !pendingContinuations.isEmpty else { return }
        let next = pendingContinuations.removeFirst()
        continueWork(next.note, initiative: next.initiative)
    }

    private func cancelTurn() {
        if isStreaming, initiative == .selfDirected {
            onSelfDirectedTurnEnded?(nil, [], "Paused so the user comes first.")
        }
        LatencyTrace.shared.cancel()
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

    private func runTurn(initiative: Initiative) {
        turnTask?.cancel()
        self.initiative = initiative
        let selfDirected = initiative == .selfDirected
        isStreaming = true
        streamingText = ""
        activityStatus = nil
        mood = .thinking

        let settings = settingsProvider()

        turnTask = Task { [weak self] in
            guard let self else { return }
            // Her own work stays quiet (no "one sec!") until there's a result worth saying.
            var spokeSomething = self.acknowledgedThisTurn || selfDirected
            var nudged = false
            var pushedToChoose = false
            var checkedWork = false
            var replyParts: [String] = []
            var toolsUsed: [String] = []
            let userText = self.conversation.messages.last(where: { $0.role == .user && $0.isHidden != true })?.content ?? ""
            // Voice each sentence as soon as it's complete; the first one interrupts, the rest queue.
            let speak: (String) -> Void = { sentence in
                guard !selfDirected else { return }
                LatencyTrace.shared.mark(.firstChunk)
                self.onSpeak?(sentence, spokeSomething)
                spokeSomething = true
            }
            do {
                let provider = try self.providerFactory()
                let allowSearch = settings.webSearchEnabled && provider.kind == .anthropic
                // Fix the history window for the whole turn: shifting it between steps would change the
                // prefix and invalidate thinking blocks being replayed inside the tool loop.
                let windowStart = Transcript.window(self.conversation.messages, limit: 60).first?.id

                for _ in 0..<(selfDirected ? Self.maxStepsPerSelfDirectedTurn : Self.maxStepsPerTurn) {
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
                    // Until she's said something, the first few words go to the voice straight away.
                    // (Once something is playing — e.g. the instant "On it!" — whole sentences sound smoother.)
                    var chunker = SentenceChunker.streaming(firstChunkWords: spokeSomething ? nil : Self.firstChunkWords)
                    self.streamingText = ""
                    LatencyTrace.shared.mark(.requestSent)
                    // A tool is about to run: say whatever is pending now, or a quick "one sec" if she hasn't
                    // spoken yet and the tool isn't instant.
                    let beforeTool: (String) -> Void = { name in
                        LatencyTrace.shared.mark(.toolStarted)
                        if let pending = chunker.flush() { speak(pending) }
                        if !spokeSomething, !Self.instantTools.contains(name) {
                            speak(self.nextAcknowledgement())
                        }
                        chunker = SentenceChunker.streaming(firstChunkWords: nil)
                    }
                    for try await event in provider.streamTurn(request) {
                        try Task.checkCancellation()
                        switch event {
                        case .textDelta(let text):
                            LatencyTrace.shared.mark(.firstToken)
                            self.streamingText += text
                            if self.mood != .talking { self.mood = .talking }
                            chunker.feed(text).forEach(speak)
                        case .toolCallStarted(let name):
                            beforeTool(name)
                            self.mood = .working
                        case .toolCall(let call):
                            // Providers that only report finished calls (Ollama) still get the acknowledgement.
                            if calls.isEmpty { beforeTool(call.name) }
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
                        isProactive: selfDirected ? true : nil,
                        providerContent: raw,
                        isHidden: selfDirected && Self.isSkip(text) ? true : nil
                    ))
                    if !text.isEmpty {
                        replyParts.append(text)
                    }

                    if stop == .refusal { break }
                    if stop == .pauseTurn { continue }
                    // Promised or claimed an action without doing it: nudge once to actually do it.
                    if calls.isEmpty, !nudged, toolsUsed.isEmpty, !self.tools.specs.isEmpty,
                       let gap = FollowThrough.gap(in: text) {
                        nudged = true
                        self.append(ChatMessage(role: .user, content: FollowThrough.nudge(for: gap), isHidden: true))
                        self.mood = .working
                        continue
                    }
                    // Asked them to pick ("what should I play?") when they'd asked her to just do it.
                    if calls.isEmpty, !pushedToChoose, !selfDirected, !self.tools.specs.isEmpty,
                       Autonomy.handedBack(reply: text, request: userText) {
                        pushedToChoose = true
                        self.append(ChatMessage(role: .user, content: Autonomy.chooseNudge, isHidden: true))
                        self.mood = .working
                        continue
                    }
                    // Acted but never looked: check the result before calling it done.
                    if calls.isEmpty, !checkedWork, Autonomy.needsCheck(toolsUsed: toolsUsed) {
                        checkedWork = true
                        self.append(ChatMessage(role: .user, content: Autonomy.checkNudge, isHidden: true))
                        self.mood = .working
                        continue
                    }
                    if calls.isEmpty { break }

                    self.mood = .working
                    for call in calls {
                        try Task.checkCancellation()
                        self.activityStatus = Self.statusLine(for: call)
                        self.onToolCall?(call)
                        toolsUsed.append(call.name)
                        let outcome: ToolOutcome
                        if let reason = self.toolPolicy?(call, initiative) {
                            outcome = .failure("NOT ALLOWED: \(reason)")
                        } else {
                            outcome = await self.tools.execute(call)
                        }
                        self.onToolFinished?(call, outcome)
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
                var reply = replyParts.joined(separator: " ")
                if selfDirected {
                    // Decided it wasn't worth it: no bubble, no voice.
                    let skipped = reply.isEmpty || Self.isSkip(reply) || replyParts.last.map(Self.isSkip) == true
                    if skipped { reply = "" }
                    self.onSelfDirectedTurnEnded?(skipped ? nil : reply, toolsUsed, nil)
                    if !reply.isEmpty { self.onSpeak?(reply, false) }
                }
                if !reply.isEmpty { self.onReply?(reply) }
                self.endTurn()
                if !selfDirected { self.onExchangeCompleted?(userText, reply, toolsUsed) }
                self.mood = .talking
                await self.persist()
                self.runPendingContinuation()
                guard !self.isStreaming else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled, self.mood == .talking { self.mood = .idle }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                if let providerError = error as? ChatProviderError, providerError == .cancelled { return }
                self.streamingText = ""
                self.repairInterruptedTurn()
                if selfDirected {
                    // Her own work failing isn't the user's problem; it goes to her log, not the chat.
                    self.onSelfDirectedTurnEnded?(nil, toolsUsed, error.localizedDescription)
                    self.endTurn()
                    self.mood = .idle
                    await self.persist()
                    self.runPendingContinuation()
                    return
                }
                self.lastError = error.localizedDescription
                self.endTurn()
                self.mood = .concerned
                self.onTurnFailed?()
                await self.persist()
                self.runPendingContinuation()
                guard !self.isStreaming else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.mood == .concerned { self.mood = .idle }
            }
        }
    }

    /// She looked closer and decided her own idea wasn't worth doing.
    nonisolated static func isSkip(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased() == InitiativeNotes.skipToken
    }

    private func nextAcknowledgement() -> String {
        defer { acknowledgementIndex += 1 }
        return Self.acknowledgements[acknowledgementIndex % Self.acknowledgements.count]
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
        if wasStreaming {
            LatencyTrace.shared.turnEnded()
            onTurnEnded?()
        }
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

    public static func statusLine(for call: ToolCall) -> String {
        switch call.name {
        case "add_task", "update_task", "complete_task", "delete_task", "list_tasks": return "Updating your tasks…"
        case "set_reminder", "list_reminders", "cancel_reminder": return "Setting things on the timeline…"
        case "start_timer": return "Starting the clock…"
        case "remember", "recall", "forget": return "Checking my notes…"
        case "get_calendar_events", "create_calendar_event": return "Checking your calendar…"
        case "open_app", "open_url": return "Opening that for you…"
        case "run_shortcut": return "Running your shortcut…"
        case "get_activity_summary", "get_system_status": return "Taking a look around…"
        case "play_youtube": return "Finding something to play…"
        case "run_shell": return "Running a command…"
        case "start_coding_agent": return "Handing the build to the coding agent…"
        case "coding_job_status": return "Checking on the build…"
        case "change_look": return "Changing my look…"
        case "start_goal": return "Planning it out…"
        case "update_goal", "list_goals", "finish_goal": return "Ticking off steps…"
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
