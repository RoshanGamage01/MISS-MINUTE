import AppKit
import SwiftUI
import MinutesCore

@MainActor
final class CharacterWindowController: NSObject {
    private weak var appModel: AppModel?
    private var window: NSWindow?
    var onCharacterClicked: (() -> Void)?
    var onMoved: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
    }

    var windowFrame: NSRect? { window?.frame }

    func show() {
        guard let appModel else { return }
        let root = CharacterRootView(
            chatService: appModel.chatService,
            settingsStore: appModel.settingsStore,
            speech: appModel.speech,
            bodyState: appModel.behavior.body,
            gaze: { [weak self] in self?.gazeVector() ?? .zero },
            onClick: { [weak self] in self?.onCharacterClicked?() },
            onDrag: { [weak self] delta in self?.moveBy(delta) },
            onDragBegan: { [weak self] in self?.onDragBegan?() },
            onDragEnded: { [weak self] in self?.onDragEnded?() },
            onHover: { [weak self] hovering in self?.onHover?(hovering) },
            onMenu: { [weak appModel] action in
                switch action {
                case .talk: appModel?.toggleListening()
                case .chat: appModel?.toggleChatRequested()
                case .brief: appModel?.briefMeNow()
                case .settings: appModel?.openSettingsRequested()
                }
            }
        )
        let hostingView = NSHostingView(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.contentView = hostingView
        window.ignoresMouseEvents = false
        self.window = window
        reposition()
        window.orderFrontRegardless()
    }

    private var contentSize: NSSize {
        let size = CGFloat(appModel?.settingsStore.settings.characterSize ?? 150)
        let canvas = MissMinuteView.canvasSize(for: size)
        return NSSize(width: canvas.width, height: canvas.height)
    }

    func reposition() {
        guard let window, let appModel else { return }
        let size = contentSize
        window.setContentSize(size)
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        var origin = NSPoint.zero
        switch appModel.settingsStore.settings.characterCorner {
        case .bottomTrailing:
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
        case .bottomLeading:
            origin = NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        case .topTrailing:
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        case .topLeading:
            origin = NSPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
        }
        window.setFrameOrigin(origin)
        onMoved?()
    }

    /// While she operates the Mac, clicks pass through her so they reach the apps underneath.
    func setClickThrough(_ enabled: Bool) {
        window?.ignoresMouseEvents = enabled
    }

    /// Moves her window (used by the behavior engine).
    func setOrigin(_ origin: NSPoint) {
        window?.setFrameOrigin(origin)
        onMoved?()
    }

    func flashAnnounce() {
        window?.orderFrontRegardless()
    }

    /// Where the cursor is relative to her eyes, normalized to -1…1 (y down).
    private func gazeVector() -> CGPoint {
        guard let frame = window?.frame else { return .zero }
        let mouse = NSEvent.mouseLocation
        let eyes = CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.63)
        let dx = (mouse.x - eyes.x) / 260
        let dy = -(mouse.y - eyes.y) / 260
        return CGPoint(x: max(-1, min(1, dx)), y: max(-1, min(1, dy)))
    }

    private func moveBy(_ delta: CGSize) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.x += delta.width
        frame.origin.y -= delta.height
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrameOrigin(frame.origin)
        onMoved?()
    }
}

enum CharacterMenuAction {
    case talk, chat, brief, settings
}

private struct CharacterRootView: View {
    @ObservedObject var chatService: ChatService
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var speech: SpeechManager
    let bodyState: BodyState
    var gaze: () -> CGPoint
    var onClick: () -> Void
    var onDrag: (CGSize) -> Void
    var onDragBegan: () -> Void
    var onDragEnded: () -> Void
    var onHover: (Bool) -> Void
    var onMenu: (CharacterMenuAction) -> Void
    @State private var lastDragTranslation: CGSize = .zero
    @State private var dragging = false
    @State private var hovering = false

    /// While her voice is playing she gestures, even for lines she volunteered.
    private var effectiveMood: CharacterMood {
        if speech.isSpeaking, chatService.mood == .idle || chatService.mood == .announcing { return .talking }
        return chatService.mood
    }

    var body: some View {
        let settings = settingsStore.settings
        MissMinuteView(
            mood: effectiveMood,
            size: CGFloat(settings.characterSize),
            skin: settings.characterSkin,
            isHovering: hovering,
            mouthLevel: { [speech] t in speech.mouthOpenness(at: t) },
            gazeTarget: gaze,
            bodyState: bodyState
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        onDragBegan()
                    }
                    let delta = CGSize(
                        width: value.translation.width - lastDragTranslation.width,
                        height: value.translation.height - lastDragTranslation.height
                    )
                    lastDragTranslation = value.translation
                    onDrag(delta)
                }
                .onEnded { _ in
                    lastDragTranslation = .zero
                    dragging = false
                    onDragEnded()
                }
        )
        .onTapGesture(perform: onClick)
        .contextMenu {
            Button("Talk to Miss Minute  \(settings.listenHotKey.displayString)") { onMenu(.talk) }
            Button("Open Chat  \(settings.hotKey.displayString)") { onMenu(.chat) }
            Button("Brief Me") { onMenu(.brief) }
            Divider()
            Button("Settings…") { onMenu(.settings) }
        }
        .help("Click to chat · Right-click for more · Drag to move")
    }
}
