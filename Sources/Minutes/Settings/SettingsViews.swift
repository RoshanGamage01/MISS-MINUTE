import SwiftUI
import MinutesCore

struct ProviderSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var apiKeyDraft = ""
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("AI backend") {
                Picker("Provider", selection: providerBinding) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                if appModel.settingsStore.settings.provider == .ollama {
                    TextField("Ollama URL", text: ollamaURLBinding)
                    Text("Default: http://localhost:11434")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField(
                        appModel.hasAPIKey(for: appModel.settingsStore.settings.provider)
                            ? "Replace API key (stored in Keychain)"
                            : "API key (stored in Keychain)",
                        text: $apiKeyDraft
                    )
                    HStack {
                        Button("Save key") { saveKey() }
                            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Clear key") { clearKey() }
                        if appModel.hasAPIKey(for: appModel.settingsStore.settings.provider) {
                            Label("Key saved in Keychain", systemImage: "checkmark.seal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Picker("Model", selection: modelBinding) {
                        if appModel.availableModels.isEmpty {
                            Text(appModel.settingsStore.settings.model)
                                .tag(appModel.settingsStore.settings.model)
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
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: appModel.settingsStore.settings.provider) { _ in
            apiKeyDraft = ""
            statusMessage = nil
        }
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

    private var modelBinding: Binding<String> {
        Binding(
            get: { appModel.settingsStore.settings.model },
            set: { newValue in
                Task { await appModel.updateSettings { $0.model = newValue } }
            }
        )
    }

    private var ollamaURLBinding: Binding<String> {
        Binding(
            get: { appModel.settingsStore.settings.ollamaBaseURL },
            set: { newValue in
                Task { await appModel.updateSettings { $0.ollamaBaseURL = newValue } }
            }
        )
    }

    private func saveKey() {
        let kind = appModel.settingsStore.settings.provider
        do {
            try appModel.saveAPIKey(apiKeyDraft, for: kind)
            apiKeyDraft = ""
            statusMessage = "API key saved to Keychain."
            Task { await appModel.refreshModels() }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func clearKey() {
        let kind = appModel.settingsStore.settings.provider
        do {
            try appModel.saveAPIKey(nil, for: kind)
            statusMessage = "API key removed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

struct PersonaSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("System persona") {
                TextEditor(text: personaBinding)
                    .font(.system(.body, design: .rounded))
                    .frame(minHeight: 220)
                Button("Reset to default") {
                    Task {
                        await appModel.updateSettings { $0.personaPrompt = Persona.defaultPrompt }
                    }
                }
            }
        }
    }

    private var personaBinding: Binding<String> {
        Binding(
            get: { appModel.settingsStore.settings.personaPrompt },
            set: { newValue in
                Task { await appModel.updateSettings { $0.personaPrompt = newValue } }
            }
        )
    }
}

struct VoiceSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Speech") {
                Toggle("Speak replies and alerts", isOn: voiceEnabledBinding)
                Text("Uses macOS enhanced/premium voices when installed (System Settings → Accessibility → Spoken Content).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Voice", selection: voiceIDBinding) {
                    Text("Automatic (best available)").tag("")
                    ForEach(appModel.speech.availableVoices, id: \.identifier) { voice in
                        Text(Self.label(for: voice)).tag(voice.identifier)
                    }
                }
                .disabled(!appModel.settingsStore.settings.voiceEnabled)
                HStack {
                    Text("Pace")
                    Slider(value: rateBinding, in: 0.4...0.65, step: 0.01)
                }
                .disabled(!appModel.settingsStore.settings.voiceEnabled)
                Button("Preview voice") {
                    appModel.speech.refreshVoices()
                    appModel.speech.previewCurrentVoice()
                }
                .disabled(!appModel.settingsStore.settings.voiceEnabled)
            }
        }
        .onAppear { appModel.speech.refreshVoices() }
    }

    private var voiceEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.settingsStore.settings.voiceEnabled },
            set: { newValue in
                Task { await appModel.updateSettings { $0.voiceEnabled = newValue } }
            }
        )
    }

    private var voiceIDBinding: Binding<String> {
        Binding(
            get: { appModel.settingsStore.settings.voiceIdentifier },
            set: { newValue in
                Task { await appModel.updateSettings { $0.voiceIdentifier = newValue } }
            }
        )
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { appModel.settingsStore.settings.speechRate },
            set: { newValue in
                Task { await appModel.updateSettings { $0.speechRate = newValue } }
            }
        )
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

import AVFoundation

struct AwarenessSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Background awareness") {
                Toggle("Watch what I'm doing", isOn: monitoringBinding)
                Text("Minutes notices app switches, long builds/commands finishing, idle return, and display wake—then speaks up. No keylogging or screen capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Announce app switches", isOn: appSwitchBinding)
                    .disabled(!appModel.settingsStore.settings.activityMonitoringEnabled)
                Toggle("Announce finished builds & tasks", isOn: processBinding)
                    .disabled(!appModel.settingsStore.settings.activityMonitoringEnabled)
                Toggle("Welcome me back after idle", isOn: idleBinding)
                    .disabled(!appModel.settingsStore.settings.activityMonitoringEnabled)
                Toggle("Smart AI reactions (uses your provider)", isOn: smartBinding)
                    .disabled(!appModel.settingsStore.settings.activityMonitoringEnabled)
            }
            if let summary = appModel.latestActivitySummary {
                Section("Last noticed") {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var monitoringBinding: Binding<Bool> {
        Binding(
            get: { appModel.settingsStore.settings.activityMonitoringEnabled },
            set: { newValue in
                Task { await appModel.updateSettings { $0.activityMonitoringEnabled = newValue } }
            }
        )
    }

    private var appSwitchBinding: Binding<Bool> {
        Binding(
            get: { appModel.settingsStore.settings.announceAppSwitches },
            set: { newValue in
                Task { await appModel.updateSettings { $0.announceAppSwitches = newValue } }
            }
        )
    }

    private var processBinding: Binding<Bool> {
        Binding(
            get: { appModel.settingsStore.settings.announceProcessCompletions },
            set: { newValue in
                Task { await appModel.updateSettings { $0.announceProcessCompletions = newValue } }
            }
        )
    }

    private var idleBinding: Binding<Bool> {
        Binding(
            get: { appModel.settingsStore.settings.announceIdleReturn },
            set: { newValue in
                Task { await appModel.updateSettings { $0.announceIdleReturn = newValue } }
            }
        )
    }

    private var smartBinding: Binding<Bool> {
        Binding(
            get: { appModel.settingsStore.settings.smartActivityReactions },
            set: { newValue in
                Task { await appModel.updateSettings { $0.smartActivityReactions = newValue } }
            }
        )
    }
}

struct CharacterSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Floating character") {
                Picker("Corner", selection: cornerBinding) {
                    ForEach(CharacterCorner.allCases) { corner in
                        Text(corner.displayName).tag(corner)
                    }
                }
                HStack {
                    Text("Size")
                    Slider(value: sizeBinding, in: 100...220, step: 10)
                    Text("\(Int(appModel.settingsStore.settings.characterSize))")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Text("Original Minutes clock art — not affiliated with Marvel or Disney.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cornerBinding: Binding<CharacterCorner> {
        Binding(
            get: { appModel.settingsStore.settings.characterCorner },
            set: { newValue in
                Task { await appModel.updateSettings { $0.characterCorner = newValue } }
            }
        )
    }

    private var sizeBinding: Binding<Double> {
        Binding(
            get: { appModel.settingsStore.settings.characterSize },
            set: { newValue in
                Task { await appModel.updateSettings { $0.characterSize = newValue } }
            }
        )
    }
}

struct ReminderSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var newText = ""
    @State private var minutesFromNow = 20.0

    var body: some View {
        Form {
            Section("Upcoming") {
                if appModel.reminderStore.reminders.filter({ !$0.isFired }).isEmpty {
                    Text("No active reminders. Try: “remind me in 20 minutes to stretch.”")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.reminderStore.reminders.filter { !$0.isFired }) { reminder in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(reminder.text)
                                Text(reminder.fireAt.formatted(date: .omitted, time: .shortened))
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
                Toggle("Nudge me periodically", isOn: nudgeEnabledBinding)
                Stepper(
                    "Every \(appModel.settingsStore.settings.periodicNudgeMinutes) minutes",
                    value: nudgeMinutesBinding,
                    in: 15...240,
                    step: 15
                )
                .disabled(!appModel.settingsStore.settings.periodicNudgeEnabled)
            }
        }
    }

    private var nudgeEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.settingsStore.settings.periodicNudgeEnabled },
            set: { newValue in
                Task { await appModel.updateSettings { $0.periodicNudgeEnabled = newValue } }
            }
        )
    }

    private var nudgeMinutesBinding: Binding<Int> {
        Binding(
            get: { appModel.settingsStore.settings.periodicNudgeMinutes },
            set: { newValue in
                Task { await appModel.updateSettings { $0.periodicNudgeMinutes = newValue } }
            }
        )
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: appearanceBinding) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Hotkey") {
                Text("Toggle chat: \(appModel.settingsStore.settings.hotKey.displayString)")
                Text("Default is ⌥Space. Change key codes in settings.json if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: launchBinding)
                Text("Uses SMAppService. Requires a proper .app bundle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                Text("Minutes")
                    .font(.headline)
                Text("A cheerful desktop helper with an original cartoon clock. Not affiliated with Marvel or Disney.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { appModel.settingsStore.settings.appearance },
            set: { newValue in
                Task { await appModel.updateSettings { $0.appearance = newValue } }
            }
        )
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { appModel.settingsStore.settings.launchAtLogin },
            set: { newValue in
                Task { await appModel.updateSettings { $0.launchAtLogin = newValue } }
            }
        )
    }
}
