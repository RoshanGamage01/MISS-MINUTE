import AppKit
import MinutesCore
import ObjectiveC

@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    /// Items at the top of the menu describing background coding jobs.
    private var workItems: [NSMenuItem] = []
    private var busy = false
    /// Ticks the outfit she's wearing each time the Outfit menu opens (she may have changed on her own).
    private let outfitRefresher = MenuRefresher()

    init(
        onOpenChat: @escaping () -> Void,
        onTalk: @escaping () -> Void,
        onBrief: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        currentLook: @escaping () -> AvatarLook,
        onChooseLook: @escaping (AvatarLook) -> Void,
        onQuit: @escaping () -> Void
    ) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.makeClockImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Miss Minute"
        }

        menu.addItem(withTitle: "Talk to Miss Minute", action: nil, keyEquivalent: "").setHandler(onTalk)
        menu.addItem(withTitle: "Open Chat", action: nil, keyEquivalent: "").setHandler(onOpenChat)
        menu.addItem(withTitle: "Brief Me", action: nil, keyEquivalent: "").setHandler(onBrief)
        let outfits = NSMenu()
        for look in AvatarLook.allCases {
            outfits.addItem(withTitle: look.displayName, action: nil, keyEquivalent: "").setHandler { onChooseLook(look) }
        }
        outfitRefresher.willOpen = { [weak outfits] in
            let current = currentLook()
            for (look, item) in zip(AvatarLook.allCases, outfits?.items ?? []) { item.state = look == current ? .on : .off }
        }
        outfits.delegate = outfitRefresher
        menu.addItem(withTitle: "Outfit", action: nil, keyEquivalent: "").submenu = outfits
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",").setHandler(onOpenSettings)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Miss Minute", action: nil, keyEquivalent: "q").setHandler(onQuit)
        item.menu = menu
        statusItem = item
    }

    /// Shows what background coding jobs are doing: a dot on the icon, a tooltip, and live lines atop the menu.
    /// `goals` are listed too, but a goal waiting for its next step doesn't make her look busy.
    func showBackgroundWork(_ lines: [String], logURL: URL?, goals: [String] = []) {
        workItems.forEach(menu.removeItem)
        workItems = []
        for line in lines + goals {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            workItems.append(item)
        }
        if let logURL {
            let item = NSMenuItem(title: lines.isEmpty ? "Open Last Coding Log" : "Open Coding Log", action: nil, keyEquivalent: "")
            item.setHandler { NSWorkspace.shared.open(logURL) }
            workItems.append(item)
        }
        if !workItems.isEmpty { workItems.append(.separator()) }
        for (index, item) in workItems.enumerated() { menu.insertItem(item, at: index) }

        let nowBusy = !lines.isEmpty
        statusItem?.button?.toolTip = nowBusy ? "Miss Minute — " + lines.joined(separator: "\n") : "Miss Minute"
        if nowBusy != busy {
            busy = nowBusy
            statusItem?.button?.image = Self.makeClockImage(busy: nowBusy)
        }
    }

    private static func makeClockImage(busy: Bool = false) -> NSImage {
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
            // Busy badge: a small dot by the crown while a background job runs.
            if busy {
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)).fill()
            }
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

private final class MenuRefresher: NSObject, NSMenuDelegate {
    var willOpen: () -> Void = {}
    func menuWillOpen(_ menu: NSMenu) { willOpen() }
}

private extension NSMenuItem {
    func setHandler(_ handler: @escaping () -> Void) {
        let target = MenuHandler(handler)
        objc_setAssociatedObject(self, &menuHandlerKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        self.target = target
        self.action = #selector(MenuHandler.invoke)
    }
}
