import AppKit
import ObjectiveC

@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?

    init(
        onOpenChat: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.makeClockImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Minutes"
        }

        let menu = NSMenu()
        let openChat = menu.addItem(withTitle: "Open Chat", action: nil, keyEquivalent: "")
        openChat.setHandler(onOpenChat)
        let settings = menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
        settings.setHandler(onOpenSettings)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Minutes", action: nil, keyEquivalent: "q")
        quit.setHandler(onQuit)
        item.menu = menu
        statusItem = item
    }

    private static func makeClockImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            NSColor.labelColor.setStroke()
            let circle = NSBezierPath(ovalIn: inset)
            circle.lineWidth = 1.5
            circle.stroke()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let hand = NSBezierPath()
            hand.move(to: center)
            hand.line(to: CGPoint(x: center.x, y: inset.maxY - 2))
            hand.lineWidth = 1.5
            hand.lineCapStyle = .round
            hand.stroke()
            let minute = NSBezierPath()
            minute.move(to: center)
            minute.line(to: CGPoint(x: inset.maxX - 3, y: center.y + 2))
            minute.lineWidth = 1.2
            minute.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private final class MenuHandler: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

private var menuHandlerKey: UInt8 = 0

private extension NSMenuItem {
    func setHandler(_ handler: @escaping () -> Void) {
        let target = MenuHandler(handler)
        objc_setAssociatedObject(self, &menuHandlerKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        self.target = target
        self.action = #selector(MenuHandler.invoke)
    }
}
