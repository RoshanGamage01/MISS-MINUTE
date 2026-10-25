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

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { appModel.settingsStore.settings.launchAtLogin },
            set: { newValue in
                Task { await appModel.updateSettings { $0.launchAtLogin = newValue } }
            }
        )
    }
}
