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
    lazy var apiKeys = KeychainAPIKeyProvider(keychain: keychain)

    @Published var chatPanelOpen = false
    @Published var availableModels: [String] = []
    @Published var modelsError: String?
    @Published var isLoadingModels = false

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

    private var nudgeTimer: Timer?
    private var lastNudgeAt: Date?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        settingsStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        reminderStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func bootstrap() async {
        await settingsStore.load()
        await reminderStore.load()
        await chatService.load()

        chatService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        chatService.onReminderParsed = { [weak self] parsed in
            Task { @MainActor in
                await self?.reminderStore.add(parsed: parsed)
            }
        }
        reminderStore.onFire = { [weak self] reminder in
            let line = "Tick-tock — reminder time: \(reminder.text)"
            self?.chatService.announce(line)
            self?.onReminderFired?(reminder)
        }

        applyLaunchAtLogin()
        restartNudgeTimer()
        await refreshModels()
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
        if before.provider != after.provider
            || before.ollamaBaseURL != after.ollamaBaseURL
            || before.periodicNudgeEnabled != after.periodicNudgeEnabled
            || before.periodicNudgeMinutes != after.periodicNudgeMinutes {
            restartNudgeTimer()
        }
        if before.provider != after.provider || before.ollamaBaseURL != after.ollamaBaseURL {
            await refreshModels()
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

    private func applyLaunchAtLogin() {
        let enabled = settingsStore.settings.launchAtLogin
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Launch-at-login requires a proper app bundle; ignore failures in `swift run`.
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
