import AppKit
import Combine
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
    private var bubbleController: SpeechBubbleController?
    private var chatController: ChatPanelController?
    private var settingsController: SettingsWindowController?
    private let hotKeyMonitor = HotKeyMonitor()
    private var notificationManager: NotificationManager?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build tooling: `Minutes --export-icon <dir>` renders the app icon set and quits.
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--export-icon"), flag + 1 < args.count {
            do {
                try AppIconExporter.export(to: URL(fileURLWithPath: args[flag + 1]))
            } catch {
                FileHandle.standardError.write(Data("Icon export failed: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
            return
        }
        // Dev tooling: `Minutes --snapshot-voice-settings <png>` renders the Voice settings tab offscreen and quits.
        if let flag = args.firstIndex(of: "--snapshot-voice-settings"), flag + 1 < args.count {
            let path = args[flag + 1]
            let host = NSHostingView(rootView: VoiceSettingsView().environmentObject(AppModel.shared).frame(width: 640, height: 2_600))
            let window = NSWindow(contentRect: NSRect(x: -4_000, y: 0, width: 640, height: 2_600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(.accessory)

        let model = AppModel.shared

        notificationManager = NotificationManager(appModel: model)
        notificationManager?.requestAuthorization()

        characterController = CharacterWindowController(appModel: model)
        characterController?.show()

        let bubble = SpeechBubbleController()
        bubble.anchorFrame = { [weak self] in self?.characterController?.windowFrame }
        bubble.onClick = { [weak self] in self?.showChat() }
        bubbleController = bubble
        characterController?.onMoved = { [weak bubble] in bubble?.layout() }

        // Her own life: wandering, perching on windows, napping, reacting.
        let behavior = model.behavior
        behavior.frame = { [weak self] in self?.characterController?.windowFrame }
        behavior.setOrigin = { [weak self] origin in self?.characterController?.setOrigin(origin) }
        behavior.characterSize = { CGFloat(model.settingsStore.settings.characterSize) }
        behavior.settings = { model.settingsStore.settings }
        behavior.tone = { model.currentTone() }
        behavior.isEngaged = { [weak self] in
            (self?.chatController?.isVisible ?? false)
                || model.chatService.isStreaming
                || model.voiceInput.isListening
                || model.speech.isSpeaking
        }
        behavior.onRemark = { [weak self] line, speak in
            self?.bubbleController?.show(line)
            if speak { model.speech.speak(line) }
        }
        characterController?.onDragBegan = { behavior.dragBegan() }
        characterController?.onDragEnded = { behavior.dragEnded() }
        characterController?.onHover = { behavior.hoverChanged($0) }
        behavior.start()

        chatController = ChatPanelController(appModel: model)
        settingsController = SettingsWindowController(appModel: model)

        statusItemController = StatusItemController(
            onOpenChat: { [weak self] in self?.toggleChat() },
            onTalk: { AppModel.shared.toggleListening() },
            onBrief: { AppModel.shared.briefMeNow() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            currentLook: { AppModel.shared.settingsStore.settings.avatarLook },
            onChooseLook: { look in Task { await AppModel.shared.updateSettings { $0.avatarLook = look } } },
            onQuit: { NSApp.terminate(nil) }
        )

        hotKeyMonitor.add(id: 1, setting: { AppModel.shared.settingsStore.settings.hotKey }) {
            AppModel.shared.toggleChatRequested()
        }
        hotKeyMonitor.add(id: 2, setting: { AppModel.shared.settingsStore.settings.listenHotKey }) {
            AppModel.shared.toggleListening()
        }
        // ⌥Esc: emergency stop for anything she's doing on screen.
        hotKeyMonitor.add(id: 3, setting: { HotKeySetting(keyCode: 53, modifiers: 2048) }) {
            AppModel.shared.stopEverything()
        }

        // While she drives the mouse and keyboard, get her own windows out of the way.
        model.computer.onBeginActing = { [weak self] in self?.setActingMode(true) }
        model.computer.onEndActing = { [weak self] in self?.setActingMode(false) }

        model.onToggleChat = { [weak self] in
            self?.toggleChat()
        }
        model.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        model.onCharacterPositionChanged = { [weak self] in
            self?.characterController?.reposition()
            model.behavior.resetHome()
        }
        model.onHotKeyChanged = { [weak self] in
            self?.hotKeyMonitor.register()
        }
        model.onReminderFired = { [weak self] reminder in
            self?.notificationManager?.deliver(reminder: reminder)
            self?.characterController?.flashAnnounce()
        }
        model.onProactiveAlert = { [weak self] in
            self?.characterController?.flashAnnounce()
        }
        model.onBubble = { [weak self] text in
            self?.bubbleController?.show(text)
        }
        // Background coding jobs, live in the menu bar (at most once a second so it never flickers).
        // Open goals are listed under them.
        model.coding.$jobs
            .combineLatest(model.goalStore.$goals)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] jobs, goals in
                let lines = jobs.filter(\.isRunning).map { job in
                    "#\(job.id) \(job.project): \(job.progress.currentStep ?? "Starting…")"
                }
                let goalLines = goals.filter(\.isOpen).prefix(3).map { goal in
                    "◎ \(goal.objective) (\(goal.settledCount)/\(goal.steps.count))"
                }
                let log = jobs.last(where: { $0.logURL != nil })?.logURL
                self?.statusItemController?.showBackgroundWork(lines, logURL: log, goals: Array(goalLines))
            }
            .store(in: &cancellables)
        model.$liveTranscript
            .removeDuplicates()
            .sink { [weak self] text in self?.bubbleController?.showListening(text) }
            .store(in: &cancellables)

        characterController?.onCharacterClicked = { [weak self] in
            model.behavior.clicked()
            self?.toggleChat()
        }

        Task {
            await model.bootstrap()
            // Hotkeys read settings, so register after they're loaded.
            self.hotKeyMonitor.register()
        }
    }

    private var chatWasOpenBeforeActing = false

    private func setActingMode(_ acting: Bool) {
        characterController?.setClickThrough(acting)
        bubbleController?.setClickThrough(acting)
        if acting {
            chatWasOpenBeforeActing = chatController?.isVisible ?? false
            if chatWasOpenBeforeActing { chatController?.hide() }
            bubbleController?.show("On it — I'm usin' your Mac now. Press ⌥Esc to stop me.")
        } else if chatWasOpenBeforeActing {
            chatWasOpenBeforeActing = false
            chatController?.show(near: characterController?.windowFrame)
        }
    }

    private func toggleChat() {
        bubbleController?.hide()
        chatController?.toggle(near: characterController?.windowFrame)
    }

    private func showChat() {
        guard chatController?.isVisible != true else { return }
        toggleChat()
    }

    private func openSettings() {
        settingsController?.show()
        NSApp.activate(ignoringOtherApps: true)
    }
}
