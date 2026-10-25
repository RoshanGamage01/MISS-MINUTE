import AppKit
import CoreGraphics
import MinutesCore

/// What her body is doing right now. Written by `BehaviorEngine`, read by the renderer every frame.
final class BodyState {
    enum Expression {
        case none, happy, surprised, wave, yawn, lookAround
    }

    var walking = false
    /// -1 facing left, 1 facing right, 0 facing you.
    var facing: CGFloat = 0
    var asleep = false
    var perched = false
    var airborne = false
    var expression: Expression = .none
    var expressionUntil: TimeInterval = 0

    func express(_ expression: Expression, for seconds: TimeInterval) {
        self.expression = expression
        expressionUntil = Date.timeIntervalSinceReferenceDate + seconds
    }

    func currentExpression(at t: TimeInterval) -> Expression {
        t < expressionUntil ? expression : .none
    }
}

/// Gives Miss Minute a life of her own: she wanders, follows your cursor, hops onto the top of your
/// windows, dozes off when you're away, wakes when you're back, and reacts when you pet or grab her.
@MainActor
final class BehaviorEngine {
    let body = BodyState()

    /// Window position access (Cocoa screen coordinates).
    var frame: () -> NSRect? = { nil }
    var setOrigin: (NSPoint) -> Void = { _ in }
    var characterSize: () -> CGFloat = { 150 }
    var settings: () -> AppSettings = { .default }
    /// True while she's in a conversation (chat open, thinking, talking, listening).
    var isEngaged: () -> Bool = { false }
    /// A little line to show/speak (physical reactions). `speak` false = bubble only.
    var onRemark: ((String, _ speak: Bool) -> Void)?

    private enum Plan {
        case resting(until: Date)
        case walking(toX: CGFloat)
        case jumping(from: NSPoint, to: NSPoint, start: Date, duration: TimeInterval, perchOn: CGWindowID?, offset: CGFloat)
        case perched(window: CGWindowID, offset: CGFloat)
        case falling(velocity: CGFloat)
    }

    private var plan: Plan = .resting(until: Date().addingTimeInterval(6))
    private var timer: Timer?
    private var lastTick = Date()
    private var floorY: CGFloat?
    private var homeX: CGFloat?
    private var isDragging = false
    private var idleSeconds: TimeInterval = 0
    private var lastIdleCheck = Date.distantPast
    private var lastPerchCheck = Date.distantPast
    private var asleepSince: Date?
    private var hoverStart: Date?
    private var lastRemarkAt = Date.distantPast
    private var lastPetAt = Date.distantPast

    private let walkSpeed: CGFloat = 95   // points per second
    private let gravity: CGFloat = 2_600

    func start() {
        timer?.invalidate()
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Called when the user moves her to a corner from Settings.
    func resetHome() {
        guard let frame = frame() else { return }
        floorY = frame.minY
        homeX = frame.minX
        plan = .resting(until: Date().addingTimeInterval(4))
        body.perched = false
        body.airborne = false
    }

    // MARK: - User interaction

    func dragBegan() {
        isDragging = true
        body.walking = false
        body.perched = false
        body.airborne = true
        wake(silently: true)
        body.express(.surprised, for: 1.2)
        remark(["Whoa! Where're we goin', sugar?", "Easy now!", "Wheee!"].randomElement()!, speak: false)
    }

    func dragEnded() {
        isDragging = false
        body.airborne = false
        guard let frame = frame() else { return }
        // Wherever you put her becomes her new floor.
        floorY = frame.minY
        homeX = frame.minX
        plan = .resting(until: Date().addingTimeInterval(randomPause() + 5))
        body.express(.happy, for: 1.2)
    }

    func hoverChanged(_ hovering: Bool) {
        if hovering {
            hoverStart = Date()
        } else {
            hoverStart = nil
        }
    }

    func clicked() {
        wake(silently: true)
        body.walking = false
        if case .walking = plan { plan = .resting(until: Date().addingTimeInterval(8)) }
        body.express(.happy, for: 1.0)
    }

    // MARK: - Loop

    private func tick() {
        let now = Date()
        let dt = CGFloat(min(0.1, now.timeIntervalSince(lastTick)))
        lastTick = now
        guard !isDragging, let frame = frame() else { return }
        if floorY == nil { floorY = frame.minY; homeX = frame.minX }

        refreshIdle(now)
        handlePetting(now)
        handleSleep(now, frame: frame)

        let engaged = isEngaged()
        if engaged {
            // Pay attention: stop wandering and face the user.
            if case .walking = plan { plan = .resting(until: now.addingTimeInterval(randomPause())) }
            body.walking = false
            body.facing = 0
        }

        switch plan {
        case .resting(let until):
            body.walking = false
            if !engaged, !body.asleep, now >= until, settings().liveliness != .still {
                decide(frame: frame)
            }

        case .walking(let targetX):
            let dx = targetX - frame.minX
            if abs(dx) < 2 {
                body.walking = false
                body.facing = 0
                plan = .resting(until: now.addingTimeInterval(randomPause()))
            } else {
                body.walking = true
                body.facing = dx > 0 ? 1 : -1
                let step = min(abs(dx), walkSpeed * dt) * (dx > 0 ? 1 : -1)
                setOrigin(NSPoint(x: frame.minX + step, y: floorY ?? frame.minY))
            }

        case .jumping(let from, let to, let start, let duration, let window, let offset):
            body.airborne = true
            let p = min(1, now.timeIntervalSince(start) / duration)
            let eased = CGFloat(p)
            let arc = CGFloat(4 * p * (1 - p)) * max(80, abs(to.y - from.y) * 0.35)
            setOrigin(NSPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased + arc))
            body.facing = to.x >= from.x ? 1 : -1
            if p >= 1 {
                body.airborne = false
                body.facing = 0
                if let window {
                    body.perched = true
                    plan = .perched(window: window, offset: offset)
                    body.express(.happy, for: 1.5)
                } else {
                    plan = .resting(until: now.addingTimeInterval(randomPause()))
                }
            }

        case .perched(let window, let offset):
            guard now.timeIntervalSince(lastPerchCheck) > 0.05 else { break }
            lastPerchCheck = now
            if let windowFrame = WindowFinder.frame(of: window), let origin = perchOrigin(on: windowFrame, offset: offset) {
                if abs(origin.x - frame.minX) > 0.5 || abs(origin.y - frame.minY) > 0.5 {
                    setOrigin(origin)
                }
            } else {
                // The window closed, moved off-screen, or got too tall: down she goes.
                body.perched = false
                body.airborne = true
                plan = .falling(velocity: 0)
                body.express(.surprised, for: 1.0)
            }

        case .falling(let velocity):
            let floor = floorY ?? frame.minY
            let v = velocity + gravity * dt
            let y = frame.minY - v * dt
            if y <= floor {
                setOrigin(NSPoint(x: frame.minX, y: floor))
                body.airborne = false
                plan = .resting(until: now.addingTimeInterval(randomPause()))
                remark(["Oof! Little help next time?", "Whoa — stuck the landin'!", "Well, that window had other plans."].randomElement()!, speak: false)
            } else {
                setOrigin(NSPoint(x: frame.minX, y: y))
                plan = .falling(velocity: v)
            }
        }
    }

    private func decide(frame: NSRect) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = frame.width
        let minX = visible.minX, maxX = visible.maxX - width
        let roll = Double.random(in: 0..<1)

        switch roll {
        case ..<0.38:
            // Stroll somewhere along her floor.
            let target = CGFloat.random(in: minX...max(minX, maxX))
            plan = .walking(toX: target)
        case ..<0.55:
            // Wander over toward where you're working.
            let mouse = NSEvent.mouseLocation
            let target = min(max(mouse.x - width / 2 + CGFloat.random(in: -140...140), minX), maxX)
            plan = .walking(toX: target)
        case ..<0.72:
            if let jump = perchJump(from: frame) {
                plan = jump
            } else {
                plan = .walking(toX: CGFloat.random(in: minX...max(minX, maxX)))
            }
        case ..<0.85:
            body.express([.lookAround, .wave, .happy].randomElement()!, for: 2.2)
            plan = .resting(until: Date().addingTimeInterval(randomPause()))
        default:
            if body.perched {
                // Hop back down.
                body.perched = false
                plan = .jumping(from: frame.origin, to: NSPoint(x: frame.minX, y: floorY ?? visible.minY),
                                start: Date(), duration: 0.6, perchOn: nil, offset: 0)
            } else {
                plan = .walking(toX: homeX ?? frame.minX)
            }
        }
    }

    // MARK: - Perching on windows

    private func perchJump(from frame: NSRect) -> Plan? {
        guard let target = WindowFinder.frontWindow() else { return nil }
        let offset = CGFloat.random(in: 0.2...0.8) * target.frame.width
        guard let origin = perchOrigin(on: target.frame, offset: offset) else { return nil }
        body.perched = false
        return .jumping(from: frame.origin, to: origin, start: Date(), duration: 0.75, perchOn: target.id, offset: offset)
    }

    /// Where her window goes so she sits on the window's top edge, or nil if she wouldn't fit.
    private func perchOrigin(on window: NSRect, offset: CGFloat) -> NSPoint? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(window) }) ?? NSScreen.main else { return nil }
        let size = characterSize()
        let canvas = MissMinuteView.canvasSize(for: size)
        let seat = MissMinuteView.seatHeight(for: size)
        let origin = NSPoint(x: window.minX + offset - canvas.width / 2, y: window.maxY - seat)
        let visible = screen.visibleFrame
        guard window.width > canvas.width * 0.8,
              origin.y + canvas.height <= visible.maxY,
              origin.x >= visible.minX - canvas.width * 0.3,
              origin.x + canvas.width <= visible.maxX + canvas.width * 0.3
        else { return nil }
        return origin
    }

    // MARK: - Sleep, idle, petting

    private func refreshIdle(_ now: Date) {
        guard now.timeIntervalSince(lastIdleCheck) > 1 else { return }
        lastIdleCheck = now
        idleSeconds = SystemIdle.idleSeconds()
    }

    private func handleSleep(_ now: Date, frame: NSRect) {
        let settings = settings()
        if !body.asleep, idleSeconds > 240, !isEngaged(), settings.liveliness != .still {
            body.asleep = true
            body.walking = false
            asleepSince = now
            if case .walking = plan { plan = .resting(until: .distantFuture) }
        } else if body.asleep, idleSeconds < 2 {
            wake(silently: false)
        }
    }

    private func wake(silently: Bool) {
        guard body.asleep else { return }
        body.asleep = false
        let slept = Date().timeIntervalSince(asleepSince ?? Date())
        asleepSince = nil
        body.express(.yawn, for: 1.8)
        plan = .resting(until: Date().addingTimeInterval(4))
        // Long absences get a proper welcome from the proactive engine; short naps just a yawn.
        if !silently, slept < 15 * 60 {
            remark(["*yawn* Oh! There you are, sugar.", "Mmm — I must've dozed off. I'm up!", "*stretches* Back to it, then!"].randomElement()!, speak: false)
        }
    }

    private func handlePetting(_ now: Date) {
        guard let hoverStart, now.timeIntervalSince(hoverStart) > 1.4, now.timeIntervalSince(lastPetAt) > 25 else { return }
        lastPetAt = now
        wake(silently: true)
        body.express(.happy, for: 2.0)
        remark(["Hehe, that tickles!", "Aw, you're sweet.", "Well hey there, hon!"].randomElement()!, speak: Bool.random())
    }

    private func remark(_ line: String, speak: Bool) {
        guard Date().timeIntervalSince(lastRemarkAt) > 20 else { return }
        lastRemarkAt = Date()
        onRemark?(line, speak)
    }

    private func randomPause() -> TimeInterval {
        Double.random(in: settings().liveliness.pauseRange)
    }
}

/// On-screen window lookup via Core Graphics (bounds only; no Screen Recording permission needed).
enum WindowFinder {
    struct Window {
        var id: CGWindowID
        var frame: NSRect
    }

    /// The frontmost app's main window, if it's a normal, reasonably large window.
    static func frontWindow() -> Window? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let frame = cocoaFrame(info),
                  frame.width > 320, frame.height > 200
            else { continue }
            return Window(id: id, frame: frame)
        }
        return nil
    }

    static func frame(of id: CGWindowID) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true
        else { return nil }
        return cocoaFrame(info)
    }

    private static func cocoaFrame(_ info: [String: Any]) -> NSRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let mainHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        return NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
