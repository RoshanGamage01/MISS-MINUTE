import AppKit
import AVFoundation
import SwiftUI
import MinutesCore

extension AppModel {
    /// Two-way binding to a settings field that persists and applies side effects.
    func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settingsStore.settings[keyPath: keyPath] },
            set: { newValue in
                Task { await self.updateSettings { $0[keyPath: keyPath] = newValue } }
            }
        )
    }
}

private struct APIKeyField: View {
    @EnvironmentObject private var appModel: AppModel
    let kind: ProviderKind
    var onSaved: () -> Void = {}
    @State private var draft = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(
                appModel.hasAPIKey(for: kind) ? "Replace \(kind.displayName) key" : "\(kind.displayName) API key",
                text: $draft
            )
            HStack {
                Button("Save key") {
                    do {
                        try appModel.saveAPIKey(draft.trimmingCharacters(in: .whitespacesAndNewlines), for: kind)
                        draft = ""
                        status = "Saved to Keychain."
                        onSaved()
                    } catch {
                        status = error.localizedDescription
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove") {
                    try? appModel.saveAPIKey(nil, for: kind)
                    status = "Key removed."
                }
                if appModel.hasAPIKey(for: kind) {
                    Label("Saved in Keychain", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: kind) { _, _ in
            draft = ""
            status = nil
        }
    }
}

struct ProviderSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        let settings = appModel.settingsStore.settings
        Form {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gemma 4 on this Mac").font(.headline)
                        Text("Free, private, offline. Sees your screen (vision) and uses tools. Needs Ollama: install from ollama.com, then run `ollama pull gemma4` (or `gemma4:26b` with 32 GB+ RAM).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Use Gemma 4") { Task { await appModel.useGemma4() } }
                        .buttonStyle(.borderedProminent)
                }
                Toggle("Local only (never send chats or speech to cloud AI)", isOn: appModel.setting(\.localOnly))
            } header: {
                Text("Local AI")
            }

            Section("Brain") {
                Picker("Provider", selection: providerBinding) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                if settings.provider == .ollama {
                    TextField("Ollama URL", text: appModel.setting(\.ollamaBaseURL))
                    Stepper("Context window: \(settings.ollamaContextLength / 1024)K tokens",
                            value: appModel.setting(\.ollamaContextLength), in: 8_192...131_072, step: 8_192)
                    Text("Bigger windows remember more of a long task (screenshots and tool results) but use more memory. 32K suits most Macs; models without native tool support automatically use a text-based tool protocol.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if settings.provider == .localServer {
                    TextField("Server URL", text: appModel.setting(\.localServerURL))
                    Text("Any OpenAI-compatible server: LM Studio (http://localhost:1234/v1), llama.cpp, MLX, vLLM. Load Gemma 4 there, then Refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    APIKeyField(kind: settings.provider) {
                        Task { await appModel.refreshModels() }
                    }
                }

                HStack {
                    Picker("Model", selection: appModel.setting(\.model)) {
                        if appModel.availableModels.isEmpty {
                            Text(settings.model).tag(settings.model)
                        } else {
                            ForEach(appModel.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                    Button("Refresh") {
                        Task { await appModel.refreshModels() }
                    }
                    .disabled(appModel.isLoadingModels)
                }
                if let error = appModel.modelsError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Thinking") {
                Picker("Response style", selection: appModel.setting(\.responseDepth)) {
                    ForEach(ResponseDepth.allCases) { depth in
                        Text(depth.displayName).tag(depth)
                    }
                }
                .pickerStyle(.segmented)
                Text("Snappy keeps voice replies quick. Deep thinks harder for planning and tricky questions (Claude only).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Let her search the web (Claude only)", isOn: appModel.setting(\.webSearchEnabled))
            }
        }
        .formStyle(.grouped)
    }

    private var providerBinding: Binding<ProviderKind> {
        Binding(
            get: { appModel.settingsStore.settings.provider },
            set: { newValue in
                Task {
                    await appModel.updateSettings {
                        $0.provider = newValue
                        $0.model = newValue.defaultModel
                    }
                }
            }
        )
    }
}

struct PersonaSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("You") {
                TextField("What should she call you?", text: appModel.setting(\.userName))
            }
            Section("Memory") {
                Toggle("Remember things about me automatically", isOn: appModel.setting(\.autoMemory))
                Text("After you chat, she quietly notes lasting details (people, preferences, routines) and fixes ones that change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appModel.memoryStore.items.isEmpty {
                    Text("Nothing remembered yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.memoryStore.items.reversed()) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.fact)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                Task { await appModel.memoryStore.forget(id: item.id) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Forget this")
                        }
                    }
                }
            }
            Section("Personality") {
                TextEditor(text: appModel.setting(\.personaPrompt))
                    .font(.system(.body, design: .rounded))
                    .frame(minHeight: 260)
                Button("Reset to Miss Minute default") {
                    Task {
                        await appModel.updateSettings { $0.personaPrompt = Persona.defaultPrompt }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Keychain-backed key entry for non-provider secrets (e.g. ElevenLabs).
private struct SecretField: View {
    @EnvironmentObject private var appModel: AppModel
    let title: String
    let account: String
    var onSaved: () -> Void = {}
    @State private var draft = ""
    @State private var status: String?

    var body: some View {
        let saved = appModel.secret(account) != nil
        VStack(alignment: .leading, spacing: 6) {
            SecureField(saved ? "Replace \(title)" : title, text: $draft)
            HStack {
                Button("Save key") {
                    do {
                        try appModel.saveSecret(draft.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
                        draft = ""
                        status = "Saved to Keychain."
                        onSaved()
                    } catch {
                        status = error.localizedDescription
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove") {
                    try? appModel.saveSecret(nil, account: account)
                    status = "Key removed."
                }
                if saved {
                    Label("Saved in Keychain", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct VoiceSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var elevenVoices: [ElevenLabsClient.Voice] = []
    @State private var voicesStatus: String?

    private let neuralVoices = ["coral", "shimmer", "nova", "sage", "ballad", "alloy", "fable", "ash", "echo", "onyx"]

    var body: some View {
        let settings = appModel.settingsStore.settings
        let hasEleven = appModel.secret(SecretAccount.elevenLabs) != nil
        let hasOpenAI = appModel.hasAPIKey(for: .openAI)
        Form {
            Section {
                Toggle("Speak replies and alerts", isOn: appModel.setting(\.voiceEnabled))
                Picker("Voice engine", selection: appModel.setting(\.voiceEngine)) {
                    ForEach(VoiceEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .disabled(!settings.voiceEnabled)
                LabeledContent("Speaking with", value: appModel.speech.activeEngineName)
                Button("Preview voice") {
                    appModel.speech.refreshVoices()
                    appModel.speech.previewCurrentVoice()
                }
                .disabled(!settings.voiceEnabled)
                if let error = appModel.speech.lastEngineError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Speaking")
            }

            Section {
                LabeledContent("Your Mac's system voice", value: SpeechManager.systemVoiceName ?? "Default")
                Text("Siri voices are the most natural voices built into macOS. Apps can't use them directly, but Miss Minute speaks through your system voice, so pick a Siri voice there: System Settings → Accessibility → Spoken Content → System voice → choose a Siri voice (or Manage Voices… → download “Zoe (Premium)” or “Ava (Premium)”). Then click Preview voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Spoken Content settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } header: {
                Text("Free: Siri & Apple voices (built in)")
            }

            Section {
                HStack {
                    Circle()
                        .fill(appModel.speech.localServerReachable ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(appModel.speech.localServerReachable ? "Kokoro server is running" : "Kokoro server not running")
                    Spacer()
                    Button("Check") { appModel.speech.probeLocalServer(force: true) }
                }
                Picker("Voice", selection: appModel.setting(\.localTTSVoice)) {
                    ForEach(Self.kokoroVoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("Server URL", text: appModel.setting(\.localTTSURL))
                    .font(.system(.caption, design: .monospaced))
                Text("Kokoro is a free, open-source neural voice that runs on your Mac and sounds close to a real person. Start it once with ./Scripts/start-kokoro.sh (needs Docker Desktop); Automatic uses it whenever it's running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Free: Local neural voice (Kokoro)")
            }

            Section {
                SecretField(title: "ElevenLabs API key", account: SecretAccount.elevenLabs) {
                    Task { await loadElevenVoices() }
                }
                Text("Get a key at elevenlabs.io → Profile → API Keys. Free tier works to try it out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if hasEleven {
                    HStack {
                        Picker("Voice", selection: appModel.setting(\.elevenLabsVoiceID)) {
                            Text("Automatic (best match for Miss Minute)").tag("")
                            ForEach(elevenVoices) { voice in
                                Text(voice.detail.isEmpty ? voice.name : "\(voice.name) — \(voice.detail)").tag(voice.id)
                            }
                            if !settings.elevenLabsVoiceID.isEmpty, !elevenVoices.contains(where: { $0.id == settings.elevenLabsVoiceID }) {
                                Text("Custom: \(settings.elevenLabsVoiceID)").tag(settings.elevenLabsVoiceID)
                            }
                        }
                        Button("Load voices") { Task { await loadElevenVoices() } }
                    }
                    TextField("…or paste a Voice Library voice ID", text: appModel.setting(\.elevenLabsVoiceID))
                        .font(.system(.caption, design: .monospaced))
                    Picker("Model", selection: appModel.setting(\.elevenLabsModel)) {
                        ForEach(ElevenLabsClient.models, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Text("Tip: in the ElevenLabs Voice Library, search “southern” for a warm Southern woman's voice, add it to your voices, then Load voices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let voicesStatus {
                        Text(voicesStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("ElevenLabs (paid)")
            }

            Section {
                Picker("Voice", selection: appModel.setting(\.neuralVoice)) {
                    ForEach(neuralVoices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                TextField("TTS model", text: appModel.setting(\.neuralVoiceModel))
                Text(hasOpenAI ? "Uses your OpenAI key from Brain, directed to sound like a warm Southern hostess."
                               : "Add an OpenAI key (Brain tab, or switch provider briefly) to use this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("OpenAI voice (paid)")
            }

            Section {
                Picker("macOS voice", selection: appModel.setting(\.voiceIdentifier)) {
                    Text("Automatic (best installed)").tag("")
                    ForEach(appModel.speech.availableVoices, id: \.identifier) { voice in
                        Text(Self.label(for: voice)).tag(voice.identifier)
                    }
                }
                HStack {
                    Text("Pace")
                    Slider(value: appModel.setting(\.speechRate), in: 0.4...0.65, step: 0.01)
                }
                Text("Offline fallback. Premium voices (System Settings → Accessibility → Spoken Content → Manage Voices) sound much better than the defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("macOS voices (offline fallback)")
            }

            Section {
                Toggle("Listen for my answer when she asks me something", isOn: appModel.setting(\.conversationMode))
                Text("Push-to-talk: \(settings.listenHotKey.displayString), the mic in chat, or right-click her. With this on, after she asks you a question out loud the mic opens for a few seconds so you can just answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Conversation")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appModel.speech.refreshVoices()
            if hasEleven { Task { await loadElevenVoices() } }
        }
    }

    static let kokoroVoices: [(String, String)] = [
        ("af_heart", "Heart — warm American woman (best)"),
        ("af_bella", "Bella — bright, expressive"),
        ("af_nicole", "Nicole — soft, close-mic"),
        ("af_sarah", "Sarah — friendly"),
        ("af_sky", "Sky — youthful"),
        ("bf_emma", "Emma — British woman"),
        ("am_michael", "Michael — American man")
    ]

    private func loadElevenVoices() async {
        guard let key = appModel.secret(SecretAccount.elevenLabs) else { return }
        voicesStatus = "Loading voices…"
        do {
            elevenVoices = try await ElevenLabsClient.voices(apiKey: key)
            voicesStatus = elevenVoices.first.map { "\(elevenVoices.count) voices. Best match: \($0.name)." }
        } catch {
            voicesStatus = error.localizedDescription
        }
    }

    private static func label(for voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium: quality = "Premium"
        case .enhanced: quality = "Enhanced"
        default: quality = "Standard"
        }
        return "\(voice.name) · \(voice.language) · \(quality)"
    }
}

struct AwarenessSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        let settings = appModel.settingsStore.settings
        let monitoring = settings.activityMonitoringEnabled
        Form {
            Section("Speaking up") {
                Picker("How often", selection: appModel.setting(\.proactivity)) {
                    ForEach(Proactivity.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Daily briefing on my first activity", isOn: appModel.setting(\.dailyBriefingEnabled))
                Toggle("Suggest breaks", isOn: appModel.setting(\.breakRemindersEnabled))
                Stepper("After \(settings.breakAfterMinutes) minutes without a break",
                        value: appModel.setting(\.breakAfterMinutes), in: 30...240, step: 15)
                    .disabled(!settings.breakRemindersEnabled)
                Toggle("Stay quiet during calls (Zoom, Teams, FaceTime)", isOn: appModel.setting(\.quietDuringMeetings))
                Toggle("Write remarks with AI (uses your provider)", isOn: appModel.setting(\.smartActivityReactions))
            }

            Section("What she watches") {
                Toggle("Notice what I'm doing", isOn: appModel.setting(\.activityMonitoringEnabled))
                Text("App focus time, long builds/commands finishing, idle time, and display wake. No keylogging, no screen capture, nothing leaves your Mac except the context sent with your own messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Announce finished builds & tasks", isOn: appModel.setting(\.announceProcessCompletions))
                    .disabled(!monitoring)
                Toggle("Welcome me back after I've been away", isOn: appModel.setting(\.announceIdleReturn))
                    .disabled(!monitoring)
                Toggle("Comment on app switches", isOn: appModel.setting(\.announceAppSwitches))
                    .disabled(!monitoring)
            }

            Section("Calendar") {
                Toggle("Let her read and add calendar events", isOn: appModel.setting(\.calendarAccessEnabled))
                if settings.calendarAccessEnabled, !appModel.calendar.hasAccess {
                    Text("macOS will ask for permission. If you declined, enable it in System Settings → Privacy & Security → Calendars.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = appModel.latestActivitySummary {
                Section("Last noticed") {
                    Text(summary).foregroundStyle(.secondary)
                    Text("Today: \(appModel.usage.todaySummary())").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct CharacterSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        let settings = appModel.settingsStore.settings
        Form {
            Section("Look") {
                Picker("Skin", selection: appModel.setting(\.characterSkin)) {
                    ForEach(CharacterSkin.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Spacer()
                    MissMinuteView(
                        mood: .idle,
                        size: 120,
                        skin: settings.characterSkin,
                        isHovering: false,
                        mouthLevel: { _ in 0 },
                        gazeTarget: { .zero }
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85))
                    )
                    Spacer()
                }
            }
            Section("Life") {
                Picker("Moving around", selection: appModel.setting(\.liveliness)) {
                    ForEach(Liveliness.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("She wanders, follows your cursor, hops onto your windows, naps when you're away, and wakes when you're back. Hover over her to say hi; drag her anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Placement") {
                Picker("Corner", selection: appModel.setting(\.characterCorner)) {
                    ForEach(CharacterCorner.allCases) { Text($0.displayName).tag($0) }
                }
                HStack {
                    Text("Size")
                    Slider(value: appModel.setting(\.characterSize), in: 100...240, step: 10)
                    Text("\(Int(settings.characterSize))")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Text("Drag her anywhere. Corner resets the position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ReminderSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var newText = ""
    @State private var minutesFromNow = 20.0

    var body: some View {
        let settings = appModel.settingsStore.settings
        Form {
            Section("Upcoming") {
                if appModel.reminderStore.upcoming.isEmpty {
                    Text("No active reminders. Just tell her: “remind me in 20 minutes to stretch.”")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.reminderStore.upcoming) { reminder in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(reminder.text)
                                Text(ToolDates.describe(reminder.fireAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await appModel.reminderStore.remove(id: reminder.id) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section("Add reminder") {
                TextField("Remind me to…", text: $newText)
                HStack {
                    Text("In \(Int(minutesFromNow)) min")
                    Slider(value: $minutesFromNow, in: 1...180, step: 1)
                    Button("Add") {
                        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        let fireAt = Date().addingTimeInterval(minutesFromNow * 60)
                        Task {
                            await appModel.reminderStore.add(text: text, fireAt: fireAt)
                            newText = ""
                        }
                    }
                    .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("Periodic check-in") {
                Toggle("Check in on me periodically", isOn: appModel.setting(\.periodicNudgeEnabled))
                Stepper(
                    "Every \(settings.periodicNudgeMinutes) minutes",
                    value: appModel.setting(\.periodicNudgeMinutes),
                    in: 15...240,
                    step: 15
                )
                .disabled(!settings.periodicNudgeEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        let settings = appModel.settingsStore.settings
        Form {
            Section("Appearance") {
                Picker("Theme", selection: appModel.setting(\.appearance)) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Hotkeys") {
                LabeledContent("Open chat", value: settings.hotKey.displayString)
                LabeledContent("Push to talk", value: settings.listenHotKey.displayString)
                Text("Key codes can be changed in settings.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: appModel.setting(\.launchAtLogin))
            }
            Section("Data") {
                Text("Conversation, tasks, memories, and reminders are stored locally in ~/Library/Application Support/Minutes. API keys live in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([MinutesPaths.applicationSupport])
                }
            }
            Section("About") {
                Text("Miss Minute — a personal fan-made desktop assistant. Miss Minute and the TVA belong to Marvel; this project isn't affiliated with Marvel or Disney and isn't for distribution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

struct ComputerSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var refresh = false

    var body: some View {
        let settings = appModel.settingsStore.settings
        Form {
            Section {
                Picker("See my screen", selection: appModel.setting(\.screenAwareness)) {
                    ForEach(ScreenAwareness.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.screenAwareness == .continuous {
                    Stepper("Glance every \(settings.screenGlanceMinutes) min",
                            value: appModel.setting(\.screenGlanceMinutes), in: 1...30)
                    Text(settings.provider.isLocal
                         ? "Free with a local model. She keeps short notes on what you're doing and offers help when she spots something."
                         : "Each glance sends a small screenshot to \(settings.provider.displayName), which costs a little. With a local model like Gemma 4 it's free.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("“When needed” lets her look only while working on something you asked for.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Seeing")
            }

            Section {
                Picker("Use mouse & keyboard", selection: appModel.setting(\.computerControl)) {
                    ForEach(ComputerControl.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("She clicks, types, uses shortcuts, and drives your browser to get tasks done. “Ask first” asks once per task. She never types passwords or payment details and won't send messages without your OK. Press ⌥Esc to stop her anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Acting")
            }

            Section {
                permissionRow(
                    "Screen Recording",
                    detail: "to take screenshots",
                    granted: ScreenCapture.hasPermission,
                    request: { ScreenCapture.requestPermission() },
                    pane: "Privacy_ScreenCapture"
                )
                permissionRow(
                    "Accessibility",
                    detail: "to read apps and use mouse & keyboard",
                    granted: InputController.hasAccessibility,
                    request: { InputController.requestAccessibility() },
                    pane: "Privacy_Accessibility"
                )
                permissionRow(
                    "Automation",
                    detail: "to control your browser (asked per app on first use)",
                    granted: nil,
                    request: nil,
                    pane: "Privacy_Automation"
                )
                Text("To let her read full web pages, enable “Allow JavaScript from Apple Events” in Chrome (View → Developer) or Safari (Develop menu). Without it she reads pages through Accessibility instead. After granting Screen Recording, macOS may ask you to reopen the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Re-check permissions") { refresh.toggle() }
            } header: {
                Text("Permissions")
            }
            .id(refresh)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionRow(_ name: String, detail: String, granted: Bool?, request: (() -> Void)?, pane: String) -> some View {
        HStack {
            Image(systemName: granted == true ? "checkmark.circle.fill" : (granted == false ? "xmark.circle" : "questionmark.circle"))
                .foregroundStyle(granted == true ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted != true {
                Button("Grant…") {
                    request?()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
