import Combine
import Foundation
import MinutesCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settingsStore = SettingsStore()
    let reminderStore = ReminderStore()
    let taskStore = TaskStore()
    let memoryStore = MemoryStore()
    private(set) lazy var memoryCurator = MemoryCurator(store: memoryStore)
    let usage = UsageTracker()
    let calendar = CalendarService()
    let keychain = MacKeychainStore(service: "com.minutes.app")
    let speech = SpeechManager.shared
    let voiceInput = VoiceInputManager()
    let activityMonitor = ActivityMonitor()
    let tools = ToolRegistry()
    let behavior = BehaviorEngine()
    let computer = ComputerController()
    private(set) lazy var screenWatcher = ScreenWatcher(computer: computer)
    lazy var apiKeys = KeychainAPIKeyProvider(keychain: keychain)
    private(set) lazy var proactive = ProactiveEngine(
        settings: { [weak self] in self?.settingsStore.settings ?? .default },
        tasks: taskStore,
        reminders: reminderStore,
        usage: usage,
        calendar: calendar
    )

    @Published var chatPanelOpen = false
    @Published var availableModels: [String] = []
    @Published var modelsError: String?
    @Published var isLoadingModels = false
    @Published var latestActivitySummary: String?
    /// Text heard so far while listening (shown live in the bubble/chat).
    @Published var liveTranscript: String?

    private(set) lazy var chatService: ChatService = {
        ChatService(
            tools: tools,
            settingsProvider: { [weak self] in
                self?.settingsStore.settings ?? .default
            },
            contextProvider: { [weak self] mode in
                self?.lastInputWasSpoken = mode == "spoken"
                self?.proactiveLinePending = false
                return self?.makeContext(inputMode: mode) ?? Persona.timeAwarePrefix()
            },
            providerFactory: { [weak self] in
                guard let self else { throw ChatProviderError.underlying("App not ready") }
                return try self.makeProvider()
            }
        )
    }()

    var onToggleChat: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCharacterPositionChanged: (() -> Void)?
    var onHotKeyChanged: (() -> Void)?
    var onReminderFired: ((Reminder) -> Void)?
    var onProactiveAlert: (() -> Void)?
    /// Show a line in the speech bubble next to Miss Minute.
    var onBubble: ((String) -> Void)?

    /// The last message was spoken, so a spoken question back deserves a listening ear.
    private var lastInputWasSpoken = false
    /// She just asked something on her own.
    private var proactiveLinePending = false
    private var nudgeTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var remarkTask: Task<Void, Never>?

    private init() {
        for publisher in [
            settingsStore.objectWillChange, reminderStore.objectWillChange, taskStore.objectWillChange,
            memoryStore.objectWillChange, speech.objectWillChange, voiceInput.objectWillChange
        ] {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    func bootstrap() async {
        await settingsStore.load()
        var migrated = settingsStore.settings
        migrated.migrateLegacyValues()
        if migrated != settingsStore.settings {
            await settingsStore.update { $0 = migrated }
        }
        await reminderStore.load()
        await taskStore.load()
        await memoryStore.load()
        await usage.load()
        await chatService.load()
        await taskStore.pruneCompleted()

        chatService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        calendar.isEnabled = { [weak self] in self?.settingsStore.settings.calendarAccessEnabled ?? false }
        tools.register(CoreTools.all(tasks: taskStore, reminders: reminderStore, memory: memoryStore))
        tools.register(SystemTools.all(usage: usage, calendar: calendar))
        tools.register(WebTools.all())

        // Seeing and operating the Mac.
        computer.settings = { [weak self] in self?.settingsStore.settings ?? .default }
        computer.currentRequest = { [weak self] in
            self?.chatService.conversation.messages.last(where: { $0.role == .user })?.content
        }
        tools.register(computer.tools())
        chatService.onTurnEnded = { [weak self] in self?.computer.endTask() }
        chatService.onExchangeCompleted = { [weak self] userText, reply, toolsUsed in
            self?.updateMemories(userText: userText, reply: reply, toolsUsed: toolsUsed)
        }

        screenWatcher.settings = { [weak self] in self?.settingsStore.settings ?? .default }
        screenWatcher.makeProvider = { [weak self] in
            guard let self else { throw ChatProviderError.underlying("App not ready") }
            return try self.makeProvider()
        }
        screenWatcher.isBusy = { [weak self] in
            guard let self else { return true }
            return self.chatService.isStreaming || self.voiceInput.isListening || self.speech.isSpeaking || self.proactive.inMeeting
        }
        screenWatcher.onOffer = { [weak self] line in self?.proactive.offer(line) }
        screenWatcher.start()

        speech.configure(
            settingsProvider: { [weak self] in self?.settingsStore.settings ?? .default },
            secret: { [weak self] account in self?.secret(account) }
        )
        speech.onFinishedSpeaking = { [weak self] said in
            self?.listenForAnswerIfAsked(said)
        }

        chatService.onReminderParsed = { [weak self] parsed in
            Task { @MainActor in
                await self?.reminderStore.add(parsed: parsed)
            }
        }
        chatService.onSpeak = { [weak self] text, continuing in
            self?.speech.speak(text, interrupt: !continuing)
        }
        chatService.onReply = { [weak self] text in
            guard let self, !self.chatPanelOpen else { return }
            self.onBubble?(text)
        }
        reminderStore.onFire = { [weak self] reminder in
            guard let self else { return }
            let line = "Tick-tock, sugar! \(reminder.text)"
            self.chatService.announce(line)
            self.onBubble?(line)
            self.onReminderFired?(reminder)
        }

        voiceInput.onStateChange = { [weak self] listening in
            guard let self else { return }
            if listening {
                self.speech.stop()
                self.chatService.mood = .listening
            } else if self.chatService.mood == .listening {
                self.chatService.mood = .idle
            }
            if !listening { self.liveTranscript = nil }
        }
        voiceInput.$transcript
            .sink { [weak self] text in
                guard let self, self.voiceInput.isListening else { return }
                self.liveTranscript = text.isEmpty ? nil : text
            }
            .store(in: &cancellables)
        voiceInput.onFinal = { [weak self] text in
            self?.chatService.send(text, inputMode: "spoken")
        }

        activityMonitor.configure(settingsProvider: { [weak self] in
            self?.settingsStore.settings ?? .default
        })
        activityMonitor.usage = usage
        activityMonitor.onEvent = { [weak self] event in
            self?.latestActivitySummary = event.summary
            self?.proactive.handle(event)
        }
        if settingsStore.settings.activityMonitoringEnabled {
            activityMonitor.start()
        }

        proactive.deliver = { [weak self] prompt, fallback, _ in
            self?.speakUp(prompt: prompt, fallback: fallback)
        }
        let willBrief = proactive.briefingDue
        proactive.start()
        if !willBrief {
            // Already briefed today (or briefings are off): just a quick hello.
            let hello = ActivityCopy.greeting(name: settingsStore.settings.userName)
            speech.speak(hello)
            onBubble?(hello)
        }

        applyLaunchAtLogin()
        restartNudgeTimer()
        await refreshModels()
        warmUpModel()
    }

    // MARK: - Secrets (voice keys)

    func secret(_ account: String) -> String? {
        (try? keychain.getSecret(account: account)).flatMap { $0?.isEmpty == false ? $0 : nil }
    }

    func saveSecret(_ value: String?, account: String) throws {
        if let value, !value.isEmpty {
            try keychain.setSecret(value, account: account)
        } else {
            try keychain.deleteSecret(account: account)
        }
        speech.resetVoiceCache()
    }

    /// Conversation mode: when she asks a question out loud, open the mic briefly for the answer.
    private func listenForAnswerIfAsked(_ said: String) {
        let asked = said.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        let expectsVoice = lastInputWasSpoken || proactiveLinePending
        proactiveLinePending = false
        guard settingsStore.settings.conversationMode, asked, expectsVoice,
              !voiceInput.isListening, !chatService.isStreaming, !proactive.inMeeting else { return }
        Task { await voiceInput.start(noSpeechTimeout: 6) }
    }

    /// Keeps memories current in the background after each conversation turn.
    private func updateMemories(userText: String, reply: String, toolsUsed: [String]) {
        let settings = settingsStore.settings
        // She already handled memory herself this turn.
        let memoryTools: Set<String> = ["remember", "forget"]
        guard settings.autoMemory, !toolsUsed.contains(where: memoryTools.contains),
              let provider = try? makeProvider() else { return }
        memoryCurator.review(userText: userText, reply: reply, provider: provider, model: settings.model)
    }

    /// Loads a local model ahead of time so the first reply starts quickly.
    func warmUpModel() {
        let settings = settingsStore.settings
        guard settings.provider == .ollama, let provider = try? makeProvider() as? OllamaProvider else { return }
        Task { await provider.warmUp(model: settings.model) }
    }

    func makeProvider() throws -> any ChatProvider {
        let settings = settingsStore.settings
        let base = URL(string: settings.ollamaBaseURL) ?? URL(string: "http://localhost:11434")!
        if settings.localOnly, !settings.provider.isLocal {
            throw ChatProviderError.underlying("Local-only mode is on, so \(settings.provider.displayName) is blocked. Pick Ollama or a local server in Settings → Brain, or turn local-only off.")
        }
        let factory = ChatProviderFactory(
            keyProvider: apiKeys,
            ollamaBaseURL: base,
            ollamaContextLength: settings.ollamaContextLength,
            localServerURL: URL(string: settings.localServerURL) ?? URL(string: "http://localhost:1234/v1")!
        )
        return try factory.makeProvider(for: settings.provider)
    }

    /// The `<context>` block attached to each user message.
    func makeContext(inputMode: String) -> String {
        let now = Date()
        let settings = settingsStore.settings
        return AgentContext(
            now: now,
            userName: settings.userName,
            frontmostApp: computer.targetApp?.localizedName ?? usage.frontmostApp,
            frontWindowTitle: computer.frontSummary().title,
            screenNotes: screenWatcher.recentNotes,
            capabilityNotes: capabilityNotes(),
            minutesInApp: usage.minutesInCurrentApp(at: now),
            continuousActiveMinutes: usage.continuousActiveMinutes(at: now),
            usageToday: usage.todaySummary(at: now),
            openTasks: taskStore.openTasks,
            upcomingReminders: reminderStore.upcoming,
            calendarLines: calendar.upcomingLines(),
            memories: memoryStore.contextLines(),
            inputMode: inputMode
        ).render()
    }

    func toggleChatRequested() {
        onToggleChat?()
    }

    func openSettingsRequested() {
        onOpenSettings?()
    }

    func toggleListening() {
        voiceInput.toggle()
    }

    /// Tells the model which abilities are unavailable right now, so it can explain instead of failing.
    private func capabilityNotes() -> [String] {
        let s = settingsStore.settings
        var notes: [String] = []
        if s.computerControl == .off {
            notes.append("Computer control is OFF (you can look but not click/type; the user can enable it in Settings → Computer).")
        }
        if s.screenAwareness == .off {
            notes.append("Screen awareness is OFF: you can't look at or read the screen.")
        } else {
            if !ScreenCapture.hasPermission { notes.append("Screen Recording isn't granted yet; look_at_screen will prompt for it. read_screen works with Accessibility.") }
            if !InputController.hasAccessibility { notes.append("Accessibility isn't granted yet; read_screen and input tools will prompt for it.") }
        }
        if s.provider.isLocal {
            notes.append("You're running locally on \(s.model); use search_web/read_webpage for anything online.")
        }
        return notes
    }

    /// Stops whatever she's doing right now: the agent turn, screen control, and speech.
    func stopEverything() {
        chatService.cancelStreaming()
        computer.endTask()
        speech.stop()
        if voiceInput.isListening { voiceInput.stop(deliver: false) }
    }

    /// One-click local setup: Gemma 4 on Ollama, local-only, always aware.
    func useGemma4() async {
        await updateSettings {
            $0.provider = .ollama
            $0.localOnly = true
            $0.screenAwareness = .continuous
            $0.webSearchEnabled = false
        }
        await refreshModels()
        let gemma = availableModels.filter { $0.lowercased().contains("gemma4") || $0.lowercased().contains("gemma-4") }
        let preference = ["31b", "26b", "latest", "e4b", "e2b"]
        let pick = preference.lazy.compactMap { size in gemma.first { $0.lowercased().contains(size) } }.first ?? gemma.first
        if let pick {
            await updateSettings { $0.model = pick }
            modelsError = nil
        } else {
            await updateSettings { $0.model = "gemma4" }
            modelsError = "Gemma 4 isn't downloaded yet. Install Ollama (ollama.com), then run: ollama pull gemma4  (or gemma4:26b on a Mac with 32 GB+)."
        }
    }

    func briefMeNow() {
        proactive.maybeBriefing(force: true)
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) async {
        let before = settingsStore.settings
        await settingsStore.update(mutate)
        let after = settingsStore.settings

        if before.launchAtLogin != after.launchAtLogin {
            applyLaunchAtLogin()
        }
        if before.provider != after.provider || before.model != after.model {
            warmUpModel()
        }
        if before.characterCorner != after.characterCorner || before.characterSize != after.characterSize {
            onCharacterPositionChanged?()
        }
        if before.hotKey != after.hotKey || before.listenHotKey != after.listenHotKey {
            onHotKeyChanged?()
        }
        if before.activityMonitoringEnabled != after.activityMonitoringEnabled {
            if after.activityMonitoringEnabled {
                activityMonitor.start()
            } else {
                activityMonitor.stop()
            }
        }
        if before.periodicNudgeEnabled != after.periodicNudgeEnabled
            || before.periodicNudgeMinutes != after.periodicNudgeMinutes {
            restartNudgeTimer()
        }
        if before.provider != after.provider || before.ollamaBaseURL != after.ollamaBaseURL {
            await refreshModels()
        }
        if !before.calendarAccessEnabled, after.calendarAccessEnabled {
            _ = await calendar.ensureAccess()
        }
        if !after.voiceEnabled {
            speech.stop()
        }
        if before.voiceEngine != after.voiceEngine || before.elevenLabsVoiceID != after.elevenLabsVoiceID {
            speech.resetVoiceCache()
        }
    }

    func refreshModels() async {
        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }
        do {
            let provider = try makeProvider()
            availableModels = try await provider.listModels()
            if !availableModels.contains(settingsStore.settings.model),
               let first = availableModels.first {
                await updateSettings { $0.model = first }
            }
        } catch {
            availableModels = []
            modelsError = error.localizedDescription
        }
    }

    func saveAPIKey(_ value: String?, for kind: ProviderKind) throws {
        try apiKeys.setAPIKey(value, for: kind)
    }

    func hasAPIKey(for kind: ProviderKind) -> Bool {
        (try? apiKeys.apiKey(for: kind)?.isEmpty == false) ?? false
    }

    // MARK: - Proactive remarks

    /// Speaks up unprompted: an AI-written line when possible, otherwise the fallback.
    private func speakUp(prompt: String?, fallback: String) {
        guard !chatService.isStreaming, !voiceInput.isListening else { return }
        remarkTask?.cancel()
        remarkTask = Task { [weak self] in
            guard let self else { return }
            var line = fallback
            if let prompt, let generated = await self.generateLine(prompt: prompt) {
                line = generated
            }
            guard !Task.isCancelled, !line.isEmpty else { return }
            self.proactiveLinePending = true
            self.chatService.announce(line)
            self.onBubble?(line)
            self.onProactiveAlert?()
        }
    }

    private func generateLine(prompt: String) async -> String? {
        guard let provider = try? makeProvider() else { return nil }
        let settings = settingsStore.settings
        let message = ChatMessage(role: .user, content: prompt, contextNote: makeContext(inputMode: "an automatic trigger, not typed by the user"))
        var assembled = ""
        do {
            let stream = provider.streamChat(
                messages: [message],
                model: settings.model,
                systemPrompt: settings.personaPrompt,
                depth: .snappy
            )
            for try await chunk in stream {
                if Task.isCancelled { return nil }
                assembled += chunk
                if assembled.count > 700 { break }
            }
        } catch {
            return nil
        }
        let line = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    private func applyLaunchAtLogin() {
        let enabled = settingsStore.settings.launchAtLogin
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login update failed: \(error.localizedDescription)")
        }
    }

    private func restartNudgeTimer() {
        nudgeTimer?.invalidate()
        nudgeTimer = nil
        guard settingsStore.settings.periodicNudgeEnabled else { return }
        let minutes = max(5, settingsStore.settings.periodicNudgeMinutes)
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.speakUp(
                    prompt: "Periodic check-in. Look at my tasks and day, then in one or two short spoken sentences suggest the single most useful next step.",
                    fallback: "Just checkin' in, sugar. Want me to line up what's next?"
                )
            }
        }
    }
}
