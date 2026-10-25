import AppKit
import SwiftUI
import MinutesCore

@MainActor
final class CharacterWindowController: NSObject {
    private weak var appModel: AppModel?
    private var window: NSWindow?
    private var hosting: NSHostingView<CharacterRootView>?
    var onCharacterClicked: (() -> Void)?
    private var chatOpen = false

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
    }

    var windowFrame: NSRect? { window?.frame }

    func show() {
        guard let appModel else { return }
        let size = CGFloat(appModel.settingsStore.settings.characterSize)
        let root = CharacterRootView(
            appModel: appModel,
            chatService: appModel.chatService,
            chatOpen: chatOpen,
            onClick: { [weak self] in self?.onCharacterClicked?() },
            onDrag: { [weak self] delta in self?.moveBy(delta) }
        )
        let hostingView = NSHostingView(rootView: root)
        hosting = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size + 20, height: size + 20),
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

    func reposition() {
        guard let window, let appModel else { return }
        let size = CGFloat(appModel.settingsStore.settings.characterSize) + 20
        window.setContentSize(NSSize(width: size, height: size))
        if let hosting {
            hosting.rootView = CharacterRootView(
                appModel: appModel,
                chatService: appModel.chatService,
                chatOpen: chatOpen,
                onClick: { [weak self] in self?.onCharacterClicked?() },
                onDrag: { [weak self] delta in self?.moveBy(delta) }
            )
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        let corner = appModel.settingsStore.settings.characterCorner
        var origin = NSPoint.zero
        switch corner {
        case .bottomTrailing:
            origin = NSPoint(x: visible.maxX - size - margin, y: visible.minY + margin)
        case .bottomLeading:
            origin = NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        case .topTrailing:
            origin = NSPoint(x: visible.maxX - size - margin, y: visible.maxY - size - margin)
        case .topLeading:
            origin = NSPoint(x: visible.minX + margin, y: visible.maxY - size - margin)
        }
        window.setFrameOrigin(origin)
    }

    func setChatOpen(_ open: Bool) {
        chatOpen = open
        refreshRoot()
    }

    func flashAnnounce() {
        refreshRoot()
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
    }

    private func refreshRoot() {
        guard let hosting, let appModel else { return }
        hosting.rootView = CharacterRootView(
            appModel: appModel,
            chatService: appModel.chatService,
            chatOpen: chatOpen,
            onClick: { [weak self] in self?.onCharacterClicked?() },
            onDrag: { [weak self] delta in self?.moveBy(delta) }
        )
    }
}

private struct CharacterRootView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var chatService: ChatService
    var chatOpen: Bool
    var onClick: () -> Void
    var onDrag: (CGSize) -> Void
    @State private var lastDragTranslation: CGSize = .zero

    var body: some View {
        ClockCharacterView(
            mood: chatService.mood,
            size: CGFloat(appModel.settingsStore.settings.characterSize),
            isChatOpen: chatOpen
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let delta = CGSize(
                        width: value.translation.width - lastDragTranslation.width,
                        height: value.translation.height - lastDragTranslation.height
                    )
                    lastDragTranslation = value.translation
                    onDrag(delta)
                }
                .onEnded { _ in
                    lastDragTranslation = .zero
                }
        )
        .onTapGesture {
            onClick()
        }
        .padding(8)
    }
}
