import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private weak var appModel: AppModel?
    private var window: NSWindow?

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    func show() {
        guard let appModel else { return }
        if window == nil {
            let root = SettingsRootView().environmentObject(appModel)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Miss Minute Settings"
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        TabView {
            ProviderSettingsView()
                .tabItem { Label("Brain", systemImage: "brain") }
            ComputerSettingsView()
                .tabItem { Label("Computer", systemImage: "desktopcomputer") }
            PersonaSettingsView()
                .tabItem { Label("Persona", systemImage: "person.crop.circle") }
            VoiceSettingsView()
                .tabItem { Label("Voice", systemImage: "waveform") }
            AwarenessSettingsView()
                .tabItem { Label("Awareness", systemImage: "eye") }
            CharacterSettingsView()
                .tabItem { Label("Character", systemImage: "clock") }
            ReminderSettingsView()
                .tabItem { Label("Reminders", systemImage: "bell") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(minWidth: 580, minHeight: 620)
        .environmentObject(appModel)
        .preferredColorScheme(
            MinutesTheme.preferredColorScheme(for: appModel.settingsStore.settings.appearance)
        )
    }
}
