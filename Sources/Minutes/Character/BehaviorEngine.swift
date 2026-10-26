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
    /// Floating on her own (gliding somewhere, or hovering beside what she's working on).
    var hovering = false

    /// A deliberate gesture (pointing, thumbs up…) and when it started/ends.
    private(set) var gesture: BodyGesture?
    private(set) var gestureStart: TimeInterval = 0
    private var gestureUntil: TimeInterval = 0
    /// Direction from her face to what she's pointing or looking at (normalized, y down).
    var pointVector = CGPoint(x: 1, y: 0)

    /// The look she holds while working (processing glow, focused face), set from the agent's state…
    var steadyAura: BodyAura = .none
    /// …and short bursts on top of it (celebration, alert).
    private var flashAura: BodyAura = .none
    private var flashAuraUntil: TimeInterval = 0

    /// The outfit she's wearing, and the cross-fade while she changes into another. Set by the user or the
    /// agent, never by task state: auras are drawn on top of whatever look she has on.
    private(set) var look = LookTransition(settledOn: .signature)

    /// Starts changing into `look` (or puts it on instantly). Returns false if she's already wearing it.
    @discardableResult
    func changeLook(to look: AvatarLook, animated: Bool = true) -> Bool {
        self.look.retarget(to: look, at: Date.timeIntervalSinceReferenceDate, animated: animated)
    }

    /// When the current teleport began (0 = not teleporting).
    var teleportStart: TimeInterval = 0
    static let teleportDuration: TimeInterval = 0.55
    /// Fraction of the teleport at which her window jumps to the new spot.
    static let teleportJumpAt: Double = 0.44

    func express(_ expression: Expression, for seconds: TimeInterval) {
        self.expression = expression
        expressionUntil = Date.timeIntervalSinceReferenceDate + seconds
    }

    func currentExpression(at t: TimeInterval) -> Expression {
        t < expressionUntil ? expression : .none
    }

    func perform(_ gesture: BodyGesture, for seconds: TimeInterval) {
        let now = Date.timeIntervalSinceReferenceDate
        self.gesture = gesture
        gestureStart = now
        gestureUntil = now + seconds
    }

    func currentGesture(at t: TimeInterval) -> BodyGesture? {
        t < gestureUntil ? gesture : nil
    }

    func flash(_ aura: BodyAura, for seconds: TimeInterval) {
        flashAura = aura
        flashAuraUntil = Date.timeIntervalSinceReferenceDate + seconds
    }

    func currentAura(at t: TimeInterval) -> BodyAura {
        t < flashAuraUntil ? flashAura : steadyAura
    }

    /// 0…1 through a teleport, or nil when she isn't teleporting.
    func teleportProgress(at t: TimeInterval) -> Double? {
        guard teleportStart > 0 else { return nil }
        let p = (t - teleportStart) / Self.teleportDuration
        return p >= 0 && p < 1 ? p : nil
    }
}

/// Gives Miss Minute a life of her own: she wanders, follows your cursor, hops onto the top of your
/// windows, dozes off when you're away, wakes when you're back, and reacts when you pet or grab her.
/// Her mood follows the user's (`MoodTone`): calm and close by when they're stressed, bouncy when they're
/// winning, quiet and still when it's late.
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
    /// How the user seems to be doing right now.
    var tone: () -> MoodTone = { .steady }

    private enum Plan {
        case resting(until: Date)
        case walking(toX: CGFloat)
        case jumping(from: NSPoint, to: NSPoint, start: Date, duration: TimeInterval, perchOn: CGWindowID?, offset: CGFloat)
        case perched(window: CGWindowID, offset: CGFloat)
        case falling(velocity: CGFloat)
        /// Floating straight to a spot she chose on purpose.
        case gliding(from: NSPoint, to: NSPoint, start: Date, duration: TimeInterval, arrival: Arrival)
        /// Out through a time door, in at the destination.
        case teleporting(to: NSPoint, start: Date, moved: Bool, arrival: Arrival)
        /// Floating beside what she's working on; heads home once the work is done.
        case hovering(until: Date)
    }

    /// What she does on arriving somewhere she chose to go.
    private enum Arrival {
        case rest
        case hover
        case perch(window: CGWindowID, offset: CGFloat)
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
    private var currentTone: MoodTone = .steady
    private var lastToneCheck = Date.distantPast

    private var lastDragAt = Date.distantPast
    /// What she's pointing/looking at (Cocoa screen coordinates), while a gesture lasts.
    private var pointTarget: NSPoint?
    private var pendingMove: Task<Void, Never>?
    private let director = BodyDirector()

    private let walkSpeed: CGFloat = 95   // points per second
    private let gravity: CGFloat = 2_600

    func start() {
        timer?.invalidate()
        lastTick = Date()
        // Wake up already wearing the saved look; only later changes animate.
        body.changeLook(to: settings().avatarLook, animated: false)
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
        body.hovering = false
    }

    // MARK: - User interaction

    func dragBegan() {
        isDragging = true
        pendingMove?.cancel()
        body.walking = false
        body.perched = false
        body.hovering = false
        body.teleportStart = 0
        body.airborne = true
        wake(silently: true)
        body.express(.surprised, for: 1.2)
        remark(lines(sassy: ["Whoa! Where're we goin', sugar?", "Easy now!", "Wheee!"],
                     gentle: ["Oh! Alright, hon, wherever you need me.", "Movin' along with you."]), speak: false)
    }

    func dragEnded() {
        isDragging = false
        lastDragAt = Date()
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
        refreshTone(now)
        refreshLook()
        refreshPointing(frame: frame)
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

        case .gliding(let from, let to, let start, let duration, let arrival):
            let p = min(1, now.timeIntervalSince(start) / duration)
            // Ease in and out, with a slight lift mid-flight so it reads as floating, not sliding.
            let e = CGFloat(p * p * (3 - 2 * p))
            let lift = CGFloat(sin(p * .pi)) * min(40, hypot(to.x - from.x, to.y - from.y) * 0.08)
            setOrigin(NSPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e + lift))
            body.hovering = true
            body.facing = abs(to.x - from.x) < 4 ? 0 : (to.x > from.x ? 1 : -1)
            if p >= 1 { arrive(arrival, at: now) }

        case .teleporting(let to, let start, let moved, let arrival):
            let p = now.timeIntervalSince(start) / BodyState.teleportDuration
            if !moved, p >= BodyState.teleportJumpAt {
                setOrigin(to)
                plan = .teleporting(to: to, start: start, moved: true, arrival: arrival)
            }
            if p >= 1 {
                body.teleportStart = 0
                arrive(arrival, at: now)
            }

        case .hovering(let until):
            body.hovering = true
            body.walking = false
            if now >= until {
                if engaged {
                    plan = .hovering(until: now.addingTimeInterval(3))
                } else {
                    go(to: .home, travel: .glide)
                }
            }

        case .falling(let velocity):
            let floor = floorY ?? frame.minY
            let v = velocity + gravity * dt
            let y = frame.minY - v * dt
            if y <= floor {
                setOrigin(NSPoint(x: frame.minX, y: floor))
                body.airborne = false
                plan = .resting(until: now.addingTimeInterval(randomPause()))
                remark(lines(sassy: ["Oof! Little help next time?", "Whoa — stuck the landin'!", "Well, that window had other plans."],
                             gentle: ["Whoops, I'm alright!", "Down I come."]), speak: false)
            } else {
                setOrigin(NSPoint(x: frame.minX, y: y))
                plan = .falling(velocity: v)
            }
        }
    }

    // MARK: - Looks

    /// Picks up a new look however it was chosen (her `change_look` tool, Settings, the menu bar) and
    /// changes into it with a twirl while the colors cross-fade. Runs alongside whatever she's working on.
    private func refreshLook() {
        let wanted = settings().avatarLook
        guard body.changeLook(to: wanted) else { return }
        react(to: .lookChanged(to: wanted))
    }

    // MARK: - Purposeful behavior

    /// Acts on a cue from the agent: a gesture, a look, and maybe a trip somewhere on screen.
    func perform(_ cue: BodyCue) {
        if let gesture = cue.gesture {
            wake(silently: true)
            body.perform(gesture, for: cue.gestureSeconds)
            if gesture == .point || gesture == .peer {
                pointTarget = cue.destination.flatMap(point(of:))
            } else {
                pointTarget = nil
            }
        }
        if let aura = cue.aura, aura != .none {
            body.flash(aura, for: cue.auraSeconds)
        }
        guard let destination = cue.destination else { return }
        pendingMove?.cancel()
        let travel = cue.travel
        guard cue.delay > 0 else {
            go(to: destination, travel: travel)
            return
        }
        pendingMove = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cue.delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // The app that just opened is in front now: aim at it, then go.
            if self.body.currentGesture(at: Date.timeIntervalSinceReferenceDate) == .point {
                self.pointTarget = self.point(of: destination)
            }
            self.go(to: destination, travel: travel)
        }
    }

    /// Carries out an agent event (see `BodyDirector` for the mapping).
    func react(to event: AgentBodyEvent) {
        if let cue = director.cue(for: event) { perform(cue) }
    }

    /// Whether she may move on her own right now: not while held, not right after the user placed her,
    /// and not when she's been told to stay put.
    private var mayTravel: Bool {
        !isDragging && settings().liveliness != .still && Date().timeIntervalSince(lastDragAt) > 90
    }

    private func go(to destination: BodyDestination, travel: BodyTravel) {
        guard mayTravel, let frame = frame() else { return }
        // Calm mode never pops in and out; she floats over instead.
        let travel: BodyTravel = settings().liveliness == .lively ? travel : .glide
        switch destination {
        case .activeWindow:
            guard let window = WindowFinder.frontWindow() else { return }
            if case .perched(let id, _) = plan, id == window.id { return }
            // Sit on the end of the window nearest to where she is now.
            let offset = min(max(frame.midX - window.frame.minX, window.frame.width * 0.12), window.frame.width * 0.88)
            if let origin = perchOrigin(on: window.frame, offset: offset) {
                move(to: origin, from: frame, by: travel, arrival: .perch(window: window.id, offset: offset))
            } else if let origin = beside(NSPoint(x: window.frame.midX, y: window.frame.midY), size: frame.size) {
                // Too tall to sit on: float alongside it instead.
                move(to: origin, from: frame, by: travel, arrival: .hover)
            }
        case .cursor:
            if let origin = beside(NSEvent.mouseLocation, size: frame.size) {
                move(to: origin, from: frame, by: travel, arrival: .hover)
            }
        case .screenPoint(let x, let y):
            if let origin = beside(NSPoint(x: x, y: y), size: frame.size) {
                move(to: origin, from: frame, by: travel, arrival: .hover)
            }
        case .home:
            let origin = NSPoint(x: homeX ?? frame.minX, y: floorY ?? frame.minY)
            move(to: origin, from: frame, by: travel, arrival: .rest)
        }
    }

    private func move(to origin: NSPoint, from frame: NSRect, by travel: BodyTravel, arrival: Arrival) {
        body.walking = false
        body.perched = false
        body.airborne = false
        let distance = hypot(origin.x - frame.minX, origin.y - frame.minY)
        if distance < 12 {
            setOrigin(origin)
            arrive(arrival, at: Date())
            return
        }
        if travel == .teleport {
            body.teleportStart = Date.timeIntervalSinceReferenceDate
            plan = .teleporting(to: origin, start: Date(), moved: false, arrival: arrival)
        } else {
            let duration = min(1.3, max(0.4, Double(distance) / 900))
            plan = .gliding(from: frame.origin, to: origin, start: Date(), duration: duration, arrival: arrival)
        }
    }

    private func arrive(_ arrival: Arrival, at now: Date) {
        body.facing = 0
        switch arrival {
        case .rest:
            body.hovering = false
            plan = .resting(until: now.addingTimeInterval(randomPause()))
        case .hover:
            body.hovering = true
            plan = .hovering(until: now.addingTimeInterval(6))
        case .perch(let window, let offset):
            body.hovering = false
            body.perched = true
            plan = .perched(window: window, offset: offset)
        }
    }

    /// Where her window goes to float just beside a point (on whichever side has room), so her hand can
    /// point at it without covering it.
    private func beside(_ point: NSPoint, size: NSSize) -> NSPoint? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        var x = point.x < visible.midX ? point.x + gap : point.x - size.width - gap
        var y = point.y - size.height * 0.6
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        return NSPoint(x: x, y: y)
    }

    private func point(of destination: BodyDestination) -> NSPoint? {
        switch destination {
        case .activeWindow:
            return WindowFinder.frontWindow().map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) }
        case .cursor:
            return NSEvent.mouseLocation
        case .screenPoint(let x, let y):
            return NSPoint(x: x, y: y)
        case .home:
            return nil
        }
    }

    /// Keeps her pointing arm and eyes aimed at the target as she (or it) moves.
    private func refreshPointing(frame: NSRect) {
        let face = NSPoint(x: frame.midX, y: frame.minY + frame.height * 0.59)
        if body.currentGesture(at: Date.timeIntervalSinceReferenceDate) == nil { pointTarget = nil }
        guard let target = pointTarget else {
            body.pointVector = CGPoint(x: body.facing == 0 ? 1 : body.facing, y: 0)
            return
        }
        let dx = target.x - face.x, dy = face.y - target.y
        let length = max(1, hypot(dx, dy))
        body.pointVector = CGPoint(x: dx / length, y: dy / length)
    }

    private func decide(frame: NSRect) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = frame.width
        let minX = visible.minX, maxX = visible.maxX - width
        var roll = Double.random(in: 0..<1)
        switch currentTone {
        case .gentle:
            // Stay calm and close: mostly drift over near where they're working, no acrobatics.
            if roll < 0.5 {
                let mouse = NSEvent.mouseLocation
                plan = .walking(toX: min(max(mouse.x - width / 2 + CGFloat.random(in: -200...200), minX), maxX))
            } else {
                plan = .resting(until: Date().addingTimeInterval(randomPause()))
            }
            return
        case .cozy:
            // Low-key: fewer outings, mostly resting.
            if roll < 0.6 {
                plan = .resting(until: Date().addingTimeInterval(randomPause()))
                return
            }
            roll = Double.random(in: 0..<0.55)
        case .upbeat:
            // Bouncy: more hops and happy waves.
            if roll < 0.25 {
                body.express([.happy, .wave].randomElement()!, for: 2.0)
            }
            roll = roll < 0.5 ? Double.random(in: 0.55..<0.85) : roll
        case .steady:
            break
        }

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
        remark(lines(sassy: ["Hehe, that tickles!", "Aw, you're sweet.", "Well hey there, hon!"],
                     gentle: ["Deep breath, sugar. You've got this.", "I'm right here with you, hon.", "One thing at a time — we'll sort it out."]),
               speak: Bool.random())
    }

    /// Notices mood shifts every few seconds and shows them: a happy wave when things start going well, a
    /// quiet walk over to keep them company when they get stressed.
    private func refreshTone(_ now: Date) {
        guard now.timeIntervalSince(lastToneCheck) > 5 else { return }
        lastToneCheck = now
        let tone = tone()
        guard tone != currentTone else { return }
        let previous = currentTone
        currentTone = tone
        guard !body.asleep, !isEngaged(), settings().liveliness != .still else { return }
        switch tone {
        case .upbeat where previous != .upbeat:
            body.express(.happy, for: 2.2)
        case .gentle:
            if case .walking = plan { plan = .resting(until: now.addingTimeInterval(2)) }
            body.facing = 0
        default:
            break
        }
    }

    /// Picks a line that fits the mood: playful sass normally, softer words when the user is having a hard time.
    private func lines(sassy: [String], gentle: [String]) -> String {
        (currentTone.sass < 0.35 ? gentle : sassy).randomElement()!
    }

    private func remark(_ line: String, speak: Bool) {
        guard Date().timeIntervalSince(lastRemarkAt) > 20 else { return }
        lastRemarkAt = Date()
        onRemark?(line, speak)
    }

    private func randomPause() -> TimeInterval {
        let pause = Double.random(in: settings().liveliness.pauseRange)
        // Calmer moods mean longer, stiller pauses; good moods a bit more bustle.
        switch currentTone {
        case .gentle, .cozy: return pause * 1.6
        case .upbeat: return pause * 0.8
        case .steady: return pause
        }
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
