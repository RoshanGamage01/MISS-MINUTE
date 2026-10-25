import AppKit
import SwiftUI

@MainActor
final class ChatPanelController {
    private weak var appModel: AppModel?
    private var window: NSWindow?
    private var closeDelegate: CloseDelegate?
    private(set) var isVisible = false

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    func toggle(near characterFrame: NSRect?) {
        if isVisible {
            hide()
        } else {
            show(near: characterFrame)
        }
    }

    func show(near characterFrame: NSRect?) {
        guard let appModel else { return }
        if window == nil {
            let root = ChatPanelView().environmentObject(appModel)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Minutes"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = hosting
            let delegate = CloseDelegate { [weak self] in
                self?.isVisible = false
                self?.appModel?.chatPanelOpen = false
            }
            closeDelegate = delegate
            window.delegate = delegate
            self.window = window
        }

        position(near: characterFrame)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
        appModel.chatPanelOpen = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
        appModel?.chatPanelOpen = false
    }

    private func position(near characterFrame: NSRect?) {
        guard let window else { return }
        let size = window.frame.size
        if let characterFrame {
            var origin = NSPoint(
                x: characterFrame.midX - size.width / 2,
                y: characterFrame.maxY + 8
            )
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                if origin.y + size.height > visible.maxY {
                    origin.y = characterFrame.minY - size.height - 8
                }
                origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            }
            window.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(
                NSPoint(
                    x: visible.maxX - size.width - 24,
                    y: visible.minY + 180
                )
            )
        }
    }
}

private final class CloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
