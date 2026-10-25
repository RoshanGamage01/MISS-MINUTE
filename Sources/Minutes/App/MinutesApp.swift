import AppKit
import SwiftUI
import MinutesCore

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Accessory app: no Dock icon; windows are created manually.
        Settings {
            SettingsRootView()
                .environmentObject(AppModel.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var characterController: CharacterWindowController?
    private var chatController: ChatPanelController?
    private var settingsController: SettingsWindowController?
    private var hotKeyMonitor: HotKeyMonitor?
    private var notificationManager: NotificationManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let model = AppModel.shared
        Task {
            await model.bootstrap()
        }

        notificationManager = NotificationManager(appModel: model)
        notificationManager?.requestAuthorization()

        characterController = CharacterWindowController(appModel: model)
        characterController?.show()

        chatController = ChatPanelController(appModel: model)
        settingsController = SettingsWindowController(appModel: model)

        statusItemController = StatusItemController(
            onOpenChat: { [weak self] in self?.toggleChat() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )

        hotKeyMonitor = HotKeyMonitor(settings: { AppModel.shared.settingsStore.settings.hotKey }) {
            Task { @MainActor in
                AppModel.shared.toggleChatRequested()
            }
        }
        hotKeyMonitor?.register()

        model.onToggleChat = { [weak self] in
            self?.toggleChat()
        }
        model.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        model.onCharacterPositionChanged = { [weak self] in
            self?.characterController?.reposition()
        }
        model.onHotKeyChanged = { [weak self] in
            self?.hotKeyMonitor?.register()
        }
        model.onReminderFired = { [weak self] reminder in
            self?.notificationManager?.deliver(reminder: reminder)
            self?.characterController?.flashAnnounce()
        }

        characterController?.onCharacterClicked = { [weak self] in
            self?.toggleChat()
        }
    }

    private func toggleChat() {
        chatController?.toggle(near: characterController?.windowFrame)
        characterController?.setChatOpen(chatController?.isVisible ?? false)
    }

    private func openSettings() {
        settingsController?.show()
        NSApp.activate(ignoringOtherApps: true)
    }
}
