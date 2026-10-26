import AppKit
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
    let goalStore = GoalStore()
    /// Her inner monologue: what she noticed, weighed, and did on her own.
    let thoughts = ThoughtLog()
    private(set) lazy var memoryCurator = MemoryCurator(store: memoryStore)
    let usage = UsageTracker()
    let calendar = CalendarService()
    let keychain = MacKeychainStore(service: "com.minutes.app")
    let speech = SpeechManager.shared
    let voiceInput = VoiceInputManager()
    let wakeWord = WakeWordListener()
    let activityMonitor = ActivityMonitor()
    let tools = ToolRegistry()
    let behavior = BehaviorEngine()
    let computer = ComputerController()
    let coding = CodingAgentRunner()
    private(set) lazy var screenWatcher = ScreenWatcher(computer: computer)
    lazy var apiKeys = KeychainAPIKeyProvider(keychain: keychain)
    private(set) lazy var proactive = ProactiveEngine(
        settings: { [weak self] in self?.settingsStore.settings ?? .default },
        tasks: taskStore,
        reminders: reminderStore,
        usage: usage,
        calendar: calendar
    )
    private(set) lazy var autonomy = AutonomyLoop(
        settings: { [weak self] in self?.settingsStore.settings ?? .default },
        goals: goalStore,
        tasks: taskStore,
        thoughts: thoughts
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

    /// Her read on how the user is doing; sets the tone of replies, the voice, and the body.
    private(set) var mood = MoodTracker()
    /// The user's latest words, for pulling up related memories.
    private var lastUserText: String?

    /// The last message was spoken, so a spoken question back deserves a listening ear.
    private var lastInputWasSpoken = false
    /// She just asked something on her own.
    private var proactiveLinePending = false
    private var nudgeTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var remarkTask: Task<Void, Never>?
    /// Keeps background-job bubbles to one every minute or so, per job.
    private var progressPacers: [Int: ProgressPacer] = [:]

    private init() {
        for publisher in [
            settingsStore.objectWillChange, reminderStore.objectWillChange, taskStore.objectWillChange,
            memoryStore.objectWillChange, speech.objectWillChange, voiceInput.objectWillChange,
            goalStore.objectWillChange, thoughts.objectWillChange
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
        await goalStore.load()
        await thoughts.load()
        await chatService.load()
        await taskStore.pruneCompleted()
        await goalStore.pruneFinished()

        chatService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        calendar.isEnabled = { [weak self] in self?.settingsStore.settings.calendarAccessEnabled ?? false }
        tools.register(CoreTools.all(tasks: taskStore, reminders: reminderStore, memory: memoryStore))
        tools.register(SystemTools.all(usage: usage, calendar: calendar))
        tools.register(WebTools.all())
        tools.register(GoalTools.all(store: goalStore, initiative: { [weak self] in self?.chatService.initiative ?? .user }))
        // Changing outfits when asked; the behavior engine sees the new setting and twirls into it.
        tools.register(AppearanceTools.all(
            current: { [weak self] in self?.settingsStore.settings.avatarLook ?? .signature },
            apply: { [weak self] look in await self?.updateSettings { $0.avatarLook = look } }
        ))

        // Seeing and operating the Mac.
        computer.settings = { [weak self] in self?.settingsStore.settings ?? .default }
        computer.currentRequest = { [weak self] in
            self?.chatService.conversation.messages.last(where: { $0.role == .user })?.content
        }
        tools.register(computer.tools())
        tools.register(WorkTools.all(settings: { [weak self] in self?.settingsStore.settings ?? .default }, coding: coding))
        // A finished build comes back to her for QA, without waiting on the user.
        coding.onFinished = { [weak self] job in
            self?.progressPacers[job.id] = nil
            self?.behavior.react(to: .backgroundJobFinished(success: job.status == 0))
            self?.chatService.continueWork(CodingAgentRunner.followUpNote(for: job))
        }
        // The chat panel and menu bar show every step live; the bubble only gets the occasional update.
        coding.onProgress = { [weak self] job in
            self?.narrateProgress(of: job)
            self?.thinkAboutBackgroundWork()
        }
        chatService.onTurnEnded = { [weak self] in self?.computer.endTask() }
        chatService.onWillSend = { [weak self] in self?.speech.prewarm() }
        chatService.onUserMessage = { [weak self] text in
            self?.mood.observeUserText(text)
            self?.lastUserText = text
        }
        chatService.onExchangeCompleted = { [weak self] userText, reply, toolsUsed in
            if toolsUsed.contains("complete_task") { self?.mood.observe(.taskCompleted) }
            self?.behavior.react(to: .turnCompleted(reply: reply, toolsUsed: toolsUsed))
            self?.updateMemories(userText: userText, reply: reply, toolsUsed: toolsUsed)
        }

        wireBody()
        wireAutonomy()

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
        screenWatcher.onNote = { [weak self] note in self?.proactive.noteScreen(note) }
        screenWatcher.start()

        speech.configure(
            settingsProvider: { [weak self] in self?.settingsStore.settings ?? .default },
            secret: { [weak self] account in self?.secret(account) }
        )
        speech.toneProvider = { [weak self] in self?.currentTone() ?? .steady }
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
                // She'll be answering in a moment: get the model and voice ready while the user talks.
                self.prewarm()
                self.chatService.mood = .listening
            } else if self.chatService.mood == .listening {
                self.chatService.mood = .idle
            }
            if !listening { self.liveTranscript = nil }
            self.wakeWord.refresh()
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
        chatService.acknowledgeSpokenRequests = { [weak self] in self?.settingsStore.settings.voiceEnabled ?? false }
        configureWakeWord()

        activityMonitor.configure(settingsProvider: { [weak self] in
            self?.settingsStore.settings ?? .default
        })
        activityMonitor.usage = usage
        activityMonitor.onEvent = { [weak self] event in
            self?.latestActivitySummary = event.summary
            switch event {
            case .processFinished: self?.mood.observe(.jobFinished)
            case .returnedFromIdle(let minutes) where minutes >= 5: self?.mood.observe(.breakTaken)
            default: break
            }
            self?.proactive.handle(event)
        }
        if settingsStore.settings.activityMonitoringEnabled {
            activityMonitor.start()
        }

        proactive.deliver = { [weak self] prompt, fallback, _ in
            self?.speakUp(prompt: prompt, fallback: fallback)
        }
        proactive.frontWindow = { [weak self] in self?.computer.frontSummary() ?? (nil, nil) }
        proactive.isStressed = { [weak self] in self?.mood.isStressed() ?? false }
        proactive.onMoodSignal = { [weak self] signal in self?.mood.observe(signal) }
        proactive.onSuspectedError = { [weak self] in self?.screenWatcher.glanceSoon() }
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

    // MARK: - Working on her own

    /// Connects the autonomy loop to the agent: her own work is gated by the policy on every tool call, and
    /// each thing she notices, weighs, and does lands in the thought log.
    private func wireAutonomy() {
        chatService.toolPolicy = { [weak self] call, initiative in
            guard let self else { return nil }
            let decision = AutonomyPolicy.decide(call, initiative: initiative, level: self.settingsStore.settings.autonomyLevel,
                                                 userIdleSeconds: SystemIdle.idleSeconds())
            guard case .deny(let reason) = decision else { return nil }
            self.thoughts.add(.heldBack, "Held back from \(call.name) (\(AutonomyPolicy.risk(of: call).label)): \(reason)")
            return reason
        }
        chatService.onSelfDirectedTurnEnded = { [weak self] reply, toolsUsed, error in
            self?.autonomy.workEnded(reply: reply, toolsUsed: toolsUsed, error: error)
        }
        // Her own goals and the user's both show progress in the Mind tab.
        goalStore.onChange = { [weak self] _, line in self?.thoughts.add(.progress, line) }

        autonomy.startWork = { [weak self] note, initiative in
            self?.chatService.continueWork(note, initiative: initiative)
        }
        autonomy.offer = { [weak self] prompt, fallback in
            self?.speakUp(prompt: prompt, fallback: fallback)
        }
        autonomy.isBusy = { [weak self] in
            guard let self else { return true }
            return self.chatService.isStreaming || self.voiceInput.isListening || self.speech.isSpeaking
                || self.coding.jobs.contains(where: \.isRunning)
        }
        autonomy.inMeeting = { [weak self] in self?.proactive.inMeeting ?? false }
        autonomy.frontApp = { [weak self] in self?.usage.frontmostApp }
        autonomy.upcomingEvents = { [weak self] in self?.calendar.upcomingEvents() ?? [] }
        autonomy.appsUsedToday = { [weak self] in Set(self?.usage.today(top: 100).map(\.app) ?? []) }
        autonomy.start()
    }

    /// Hands her a bigger objective from the Mind tab: she plans it as a goal and works it through.
    func pursueGoal(_ objective: String) {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        thoughts.add(.decided, "They gave me a goal: \(trimmed)")
        chatService.send("Take this on as a goal and see it through: \(trimmed)")
    }

    // MARK: - Body language

    /// The last kind of tool she ran this turn (coding work gets the focused look instead of the plain glow).
    private var lastToolKind: BodyDirector.ToolKind?
    private var lastBackgroundThink = Date.distantPast

    /// Lets the agent drive her body: she goes where the work is, gestures with each step, and glows
    /// or focuses while she works.
    private func wireBody() {
        chatService.onToolCall = { [weak self] call in
            self?.lastToolKind = BodyDirector.kind(of: call.name)
            self?.behavior.react(to: .toolStarted(name: call.name))
        }
        chatService.onToolFinished = { [weak self] call, outcome in
            guard let self else { return }
            self.behavior.react(to: .toolFinished(name: call.name, isError: outcome.isError))
            // What she does on her own is logged step by step (the user's own requests show in the chat).
            if self.chatService.initiative == .selfDirected, !outcome.output.hasPrefix("NOT ALLOWED") {
                let what = outcome.summary ?? ChatService.statusLine(for: call).replacingOccurrences(of: "…", with: "")
                self.thoughts.add(.acted, outcome.isError ? "\(what) didn't work: \(outcome.output.prefix(140))" : what)
            }
        }
        chatService.onTurnFailed = { [weak self] in self?.behavior.react(to: .turnFailed) }
        computer.onActionPoint = { [weak self] point in
            self?.behavior.react(to: .actingAt(x: point.x, y: point.y))
        }
        let director = BodyDirector()
        chatService.$mood
            .combineLatest(coding.$jobs.map { $0.filter(\.isRunning).count }.removeDuplicates())
            .sink { [weak self] mood, running in
                guard let self else { return }
                if mood == .idle { self.lastToolKind = nil }
                self.behavior.body.steadyAura = director.steadyAura(mood: mood, backgroundJobsRunning: running, lastToolKind: self.lastToolKind)
            }
            .store(in: &cancellables)
    }

    /// Now and then while a background build runs, a little chin-tap to show she's minding it.
    private func thinkAboutBackgroundWork() {
        guard Date().timeIntervalSince(lastBackgroundThink) > 20, !chatService.isStreaming, !speech.isSpeaking else { return }
        lastBackgroundThink = Date()
        behavior.react(to: .backgroundJobProgress)
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

    // MARK: - "Hey Minute"

    private func configureWakeWord() {
        wakeWord.canListen = { [weak self] in
            guard let self else { return false }
            return self.settingsStore.settings.wakeWordEnabled && !self.speech.isSpeaking
                && !self.voiceInput.isListening && !self.proactive.inMeeting
        }
        wakeWord.onPartial = { [weak self] text in
            guard let self else { return }
            if let text {
                if self.chatService.mood != .listening {
                    self.chatService.mood = .listening
                    self.prewarm()
                }
                self.liveTranscript = text.isEmpty ? "…" : text
            } else {
                self.liveTranscript = nil
                if self.chatService.mood == .listening { self.chatService.mood = .idle }
            }
        }
        wakeWord.onCommand = { [weak self] text, spokeAt in
            guard let self else { return }
            let trace = LatencyTrace.shared
            trace.begin(origin: "wake", at: spokeAt)
            trace.mark(.speechEnded, at: spokeAt)
            trace.mark(.sttFinal)
            self.chatService.send(text, inputMode: "spoken")
        }
        wakeWord.onWakeOnly = { [weak self] in
            guard let self else { return }
            // Just "Hey Minute": a soft chime and the mic opens for the request.
            NSSound(named: "Tink")?.play()
            Task { await self.voiceInput.start(noSpeechTimeout: 6) }
        }
        // She mustn't hear herself: pause while speaking, resume after.
        speech.$isSpeaking
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.wakeWord.refresh() }
            }
            .store(in: &cancellables)
        // Calls starting/ending and settings changes.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.wakeWord.refresh() }
        }
        wakeWord.refresh()
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
        lastModelWarmUp = Date()
        Task { await provider.warmUp(model: settings.model) }
    }

    private var lastModelWarmUp: Date = .distantPast
    private var lastConnectionWarmUp: Date = .distantPast

    /// A reply is likely soon (mic opened, chat opened): make sure nothing is cold when it comes. Reloads an
    /// Ollama model that idled out, opens the TLS connection to a cloud model, and warms the voice.
    func prewarm() {
        speech.prewarm()
        let settings = settingsStore.settings
        if settings.provider == .ollama {
            if Date().timeIntervalSince(lastModelWarmUp) > 60 { warmUpModel() }
            return
        }
        guard Date().timeIntervalSince(lastConnectionWarmUp) > 20, let host = settings.provider.apiHost else { return }
        lastConnectionWarmUp = Date()
        Task {
            var request = URLRequest(url: host)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: request)
        }
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
            goals: goalStore.open,
            memories: memoryStore.contextLines(query: lastUserText),
            inputMode: inputMode,
            moodNote: currentTone(at: now).guidance
        ).render()
    }

    /// How she should come across right now, from the user's recent words and how long they've been at it.
    func currentTone(at now: Date = Date()) -> MoodTone {
        mood.tone(at: now, activeMinutes: usage.continuousActiveMinutes(at: now))
    }

    func toggleChatRequested() {
        if !chatPanelOpen { prewarm() }
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
    /// A short "still on it" line in her bubble while a coding job runs, when nothing else has her attention.
    private func narrateProgress(of job: CodingAgentRunner.Job) {
        guard settingsStore.settings.narrateCodingProgress, job.isRunning, !chatPanelOpen,
              !chatService.isStreaming, !voiceInput.isListening, !speech.isSpeaking else { return }
        var pacer = progressPacers[job.id] ?? ProgressPacer()
        defer { progressPacers[job.id] = pacer }
        guard let step = pacer.next(job.progress.currentStep, startedAt: job.startedAt) else { return }
        onBubble?("Still on \(job.project): \(step.prefix(1).lowercased() + step.dropFirst())…")
    }

    func stopEverything() {
        chatService.cancelStreaming()
        coding.cancelAll()
        progressPacers.removeAll()
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
            // The model looked and decided it's not worth interrupting for.
            let firstWord = line.split(whereSeparator: { !$0.isLetter }).first.map(String.init)
            if firstWord == ProactiveEngine.skipToken { return }
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
