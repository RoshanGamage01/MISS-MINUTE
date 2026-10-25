import AppKit
import ObjectiveC

@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?

    init(
        onOpenChat: @escaping () -> Void,
        onTalk: @escaping () -> Void,
        onBrief: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.makeClockImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Miss Minute"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Talk to Miss Minute", action: nil, keyEquivalent: "").setHandler(onTalk)
        menu.addItem(withTitle: "Open Chat", action: nil, keyEquivalent: "").setHandler(onOpenChat)
        menu.addItem(withTitle: "Brief Me", action: nil, keyEquivalent: "").setHandler(onBrief)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",").setHandler(onOpenSettings)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Miss Minute", action: nil, keyEquivalent: "q").setHandler(onQuit)
        item.menu = menu
        statusItem = item
    }

    private static func makeClockImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()
            // Face
            let face = rect.insetBy(dx: 2, dy: 2).offsetBy(dx: 0, dy: -1)
            let circle = NSBezierPath(ovalIn: face)
            circle.lineWidth = 1.5
            circle.stroke()
            // Crown knob
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 2, y: face.maxY - 0.5, width: 4, height: 2.5), xRadius: 1, yRadius: 1).fill()
            // Eyes
            for dx in [-2.6, 2.6] as [CGFloat] {
                NSBezierPath(ovalIn: NSRect(x: face.midX + dx - 1, y: face.midY + 0.6, width: 2, height: 2.6)).fill()
            }
            // Smile
            let smile = NSBezierPath()
            smile.move(to: CGPoint(x: face.midX - 3, y: face.midY - 2))
            smile.curve(to: CGPoint(x: face.midX + 3, y: face.midY - 2),
                        controlPoint1: CGPoint(x: face.midX - 1.5, y: face.midY - 4.2),
                        controlPoint2: CGPoint(x: face.midX + 1.5, y: face.midY - 4.2))
            smile.lineWidth = 1.2
            smile.lineCapStyle = .round
            smile.stroke()
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
