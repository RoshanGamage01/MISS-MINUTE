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
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Minutes Settings"
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
                .tabItem { Label("Provider", systemImage: "cpu") }
            PersonaSettingsView()
                .tabItem { Label("Persona", systemImage: "text.bubble") }
            CharacterSettingsView()
                .tabItem { Label("Character", systemImage: "clock") }
            ReminderSettingsView()
                .tabItem { Label("Reminders", systemImage: "bell") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 520)
        .environmentObject(appModel)
    }
}
