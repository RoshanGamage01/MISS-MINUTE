import Combine
import Foundation
import MinutesCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settingsStore = SettingsStore()
    let reminderStore = ReminderStore()
    let keychain = MacKeychainStore(service: "com.minutes.app")
    let speech = SpeechManager.shared
    let activityMonitor = ActivityMonitor()
    lazy var apiKeys = KeychainAPIKeyProvider(keychain: keychain)

    @Published var chatPanelOpen = false
    @Published var availableModels: [String] = []
    @Published var modelsError: String?
    @Published var isLoadingModels = false
    @Published var latestActivitySummary: String?

    private(set) lazy var chatService: ChatService = {
        ChatService(
            settingsProvider: { [weak self] in
                self?.settingsStore.settings ?? .default
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

    private var nudgeTimer: Timer?
    private var lastNudgeAt: Date?
    private var lastProactiveAt: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()
    private var smartReactionTask: Task<Void, Never>?

    private init() {
        settingsStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        reminderStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        speech.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func bootstrap() async {
        await settingsStore.load()
        await reminderStore.load()
        await chatService.load()
        migrateLegacyPersonaIfNeeded()

        chatService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        speech.configure(settingsProvider: { [weak self] in
            self?.settingsStore.settings ?? .default
        })

        chatService.onReminderParsed = { [weak self] parsed in
            Task { @MainActor in
                await self?.reminderStore.add(parsed: parsed)
            }
        }
        chatService.onSpeak = { [weak self] text in
            self?.speech.speak(text)
        }
        reminderStore.onFire = { [weak self] reminder in
            let line = "Tick-tock — reminder time: \(reminder.text)"
            self?.chatService.announce(line)
            self?.onReminderFired?(reminder)
        }

        activityMonitor.configure(settingsProvider: { [weak self] in
            self?.settingsStore.settings ?? .default
        })
        activityMonitor.onEvent = { [weak self] event in
            self?.handleActivity(event)
        }
        if settingsStore.settings.activityMonitoringEnabled {
            activityMonitor.start()
        }

        applyLaunchAtLogin()
        restartNudgeTimer()
        await refreshModels()

        // Warm greeting once per launch (spoken, not chatty).
        let hour = Calendar.current.component(.hour, from: Date())
        let hello: String
        switch hour {
        case 5..<12: hello = "Mornin'! Minutes here—I'll keep an eye on things."
        case 12..<17: hello = "Afternoon. I'm watchin' your Mac—holler if you need me."
        case 17..<22: hello = "Evenin'. I'll pipe up when something finishes."
        default: hello = "Still tickin'. I'll keep watch while you work."
        }
        speech.speak(hello)
    }

    func makeProvider() throws -> any ChatProvider {
        let settings = settingsStore.settings
        let base = URL(string: settings.ollamaBaseURL) ?? URL(string: "http://localhost:11434")!
        let factory = ChatProviderFactory(
            keyProvider: apiKeys,
            ollamaBaseURL: base
        )
        return try factory.makeProvider(for: settings.provider)
    }

    func toggleChatRequested() {
        onToggleChat?()
    }

    func openSettingsRequested() {
        onOpenSettings?()
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) async {
        let before = settingsStore.settings
        await settingsStore.update(mutate)
        let after = settingsStore.settings

        if before.launchAtLogin != after.launchAtLogin {
            applyLaunchAtLogin()
        }
        if before.characterCorner != after.characterCorner || before.characterSize != after.characterSize {
            onCharacterPositionChanged?()
        }
        if before.hotKey != after.hotKey {
            onHotKeyChanged?()
        }
        if before.activityMonitoringEnabled != after.activityMonitoringEnabled {
            if after.activityMonitoringEnabled {
                activityMonitor.start()
            } else {
                activityMonitor.stop()
            }
        }
        if before.provider != after.provider
            || before.ollamaBaseURL != after.ollamaBaseURL
            || before.periodicNudgeEnabled != after.periodicNudgeEnabled
            || before.periodicNudgeMinutes != after.periodicNudgeMinutes {
            restartNudgeTimer()
        }
        if before.provider != after.provider || before.ollamaBaseURL != after.ollamaBaseURL {
            await refreshModels()
        }
        if !after.voiceEnabled {
            speech.stop()
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

    func handleActivity(_ event: ActivityEvent) {
        // Avoid stacking alerts.
        guard Date().timeIntervalSince(lastProactiveAt) > 12 else { return }

        // Sleep can stay silent in chat; wake/process/idle/app matter more.
        if case .screenDidSleep = event { return }

        lastProactiveAt = Date()
        latestActivitySummary = event.summary

        let settings = settingsStore.settings
        if settings.smartActivityReactions {
            smartReactionTask?.cancel()
            smartReactionTask = Task { [weak self] in
                await self?.speakSmartReaction(for: event)
            }
        } else {
            let line = ActivityCopy.line(for: event)
            chatService.announce(line)
            onProactiveAlert?()
        }
    }

    private func speakSmartReaction(for event: ActivityEvent) async {
        let fallback = ActivityCopy.line(for: event)
        do {
            let provider = try makeProvider()
            let settings = settingsStore.settings
            let prompt = """
            \(settings.personaPrompt)

            \(Persona.timeAwarePrefix())

            Desktop event: \(event.summary)
            Reply with ONE short spoken line (max 22 words). No quotes, no markdown.
            """
            var assembled = ""
            let stream = provider.streamChat(
                messages: [ChatMessage(role: .user, content: "React to that desktop event.")],
                model: settings.model,
                systemPrompt: prompt
            )
            for try await chunk in stream {
                if Task.isCancelled { return }
                assembled += chunk
                if assembled.count > 160 { break }
            }
            let line = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalLine = line.isEmpty ? fallback : line
            guard !Task.isCancelled else { return }
            chatService.announce(finalLine)
            onProactiveAlert?()
        } catch {
            chatService.announce(fallback)
            onProactiveAlert?()
        }
    }

    private func migrateLegacyPersonaIfNeeded() {
        let current = settingsStore.settings.personaPrompt
        // If the user never customized persona, refresh to the proactive default.
        if current.contains("You are Minutes, a cheerful desktop helper with a light Southern charm") {
            Task {
                await updateSettings { $0.personaPrompt = Persona.defaultPrompt }
            }
        }
    }

    private func applyLaunchAtLogin() {
        let enabled = settingsStore.settings.launchAtLogin
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
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
                self?.firePeriodicNudge()
            }
        }
    }

    private func firePeriodicNudge() {
        lastNudgeAt = Date()
        let hour = Calendar.current.component(.hour, from: Date())
        let line: String
        switch hour {
        case 5..<12:
            line = "Mornin'! Just checking in — anything I can help tidy up?"
        case 12..<17:
            line = "Afternoon check-in: need a reminder, a plan, or a quick answer?"
        case 17..<21:
            line = "Evenin' nudge — want me to line up anything before the day winds down?"
        default:
            line = "Still tickin' over here. Need a hand with something?"
        }
        chatService.announce(line)
        chatPanelOpen = true
        onToggleChat?()
    }
}
