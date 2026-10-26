import AppKit
import SwiftUI
import MinutesCore

/// Miss Minute, drawn live: rubber-hose limbs, white gloves, lashes, real-time clock hands,
/// lip-sync, cursor-tracking eyes, and an optional TVA hologram skin.
struct MissMinuteView: View {
    var mood: CharacterMood
    var size: CGFloat
    var skin: CharacterSkin
    var isHovering: Bool
    /// 0…1 mouth openness from the voice engine, sampled per frame.
    var mouthLevel: (TimeInterval) -> Double
    /// Normalized look direction (-1…1, y down), sampled per frame.
    var gazeTarget: () -> CGPoint
    /// Walking, sleeping, perching… written by the behavior engine.
    var bodyState: BodyState = BodyState()
    /// The outfit to wear, for previews that have no behavior engine (which otherwise sets it on `bodyState`).
    var look: AvatarLook? = nil

    @State private var motion = MotionState()

    static func canvasSize(for size: CGFloat) -> CGSize {
        CGSize(width: size * 1.45, height: size * 1.5)
    }

    /// Height of her seat (hips) above the bottom of the canvas, for sitting on window edges.
    static func seatHeight(for size: CGFloat) -> CGFloat {
        let canvas = canvasSize(for: size)
        let u = canvas.width / 145
        return canvas.height - (canvas.height * 0.41 + 38 * u)
    }

    var body: some View {
        let canvas = Self.canvasSize(for: size)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                if let look, bodyState.changeLook(to: look, animated: motion.hasStarted), motion.hasStarted {
                    bodyState.perform(.twirl, for: BodyDirector.twirlSeconds)
                }
                motion.step(
                    t: t,
                    mood: mood,
                    mouth: mouthLevel(t),
                    gaze: gazeTarget(),
                    body: bodyState
                )
                var renderer = MissMinuteRenderer(
                    t: t,
                    date: timeline.date,
                    mood: mood,
                    skin: skin,
                    hover: isHovering,
                    motion: motion,
                    body: bodyState,
                    canvas: canvasSize
                )
                renderer.draw(in: &context)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .accessibilityElement()
        .accessibilityLabel("Miss Minute")
        .accessibilityHint("Click to talk. Drag to move.")
    }
}

// MARK: - Motion (eased per frame, no SwiftUI publishing)

final class MotionState {
    private var lastTime: TimeInterval = 0
    var gaze: CGPoint = .zero
    var mouth: Double = 0
    var leftHand = CGPoint(x: -40, y: 30)
    var leftElbow = CGPoint(x: -58, y: 16)
    var rightHand = CGPoint(x: 40, y: 30)
    var rightElbow = CGPoint(x: 58, y: 16)
    var browLift: Double = 0
    var squash: Double = 0
    var facing: CGFloat = 0
    var walkPhase: Double = 0
    var leftGlove: GloveShape = .open
    var rightGlove: GloveShape = .open
    private var lastMood: CharacterMood = .idle
    private var moodChangedAt: TimeInterval = 0

    func step(t: TimeInterval, mood: CharacterMood, mouth target: Double, gaze rawGaze: CGPoint, body: BodyState) {
        // First frame snaps straight to the pose; after that everything eases.
        let dt = lastTime == 0 ? 10 : min(0.1, max(0.0, t - lastTime))
        if lastTime == 0 { lastMood = mood }
        lastTime = t
        if mood != lastMood {
            lastMood = mood
            moodChangedAt = t
            squash = 1 // little hop on every mood change
        }
        squash = max(0, squash - dt * 3.5)

        let expression = body.currentExpression(at: t)
        let gesture = body.currentGesture(at: t)
        facing += (body.facing - facing) * CGFloat(min(1, dt * 6))
        if body.walking { walkPhase += dt * 9 }

        var gazeTarget = rawGaze
        if mood == .thinking { gazeTarget = CGPoint(x: 0.55, y: -0.7) }
        if mood == .working { gazeTarget = CGPoint(x: 0.3 * sin(t * 1.7), y: 0.35) }
        if body.walking { gazeTarget = CGPoint(x: body.facing * 0.9, y: 0.1) }
        if expression == .lookAround { gazeTarget = CGPoint(x: sin(t * 1.9), y: -0.25 + 0.2 * cos(t * 1.3)) }
        switch gesture {
        case .point, .peer: gazeTarget = body.pointVector
        case .think: gazeTarget = CGPoint(x: 0.55, y: -0.75)
        case .celebrate: gazeTarget = CGPoint(x: 0, y: -0.3)
        default: break
        }
        gaze = ease(gaze, gazeTarget, rate: 9, dt: dt)
        mouth += (target - mouth) * min(1, dt * 22)

        let pose: Pose
        if body.asleep {
            pose = Pose.sleeping
        } else if body.airborne {
            pose = Pose.airborne
        } else if let gesture {
            pose = Pose.gesture(gesture, t: t, elapsed: t - body.gestureStart, toward: body.pointVector)
        } else if expression == .yawn {
            pose = Pose.stretch
        } else if expression == .wave {
            pose = Pose.target(for: .announcing, t: t)
        } else if body.walking, mood == .idle {
            pose = Pose.walking(phase: walkPhase)
        } else if expression == .happy, mood == .idle {
            pose = Pose.target(for: .talking, t: t)
        } else {
            pose = Pose.target(for: mood, t: t)
        }
        leftHand = ease(leftHand, pose.leftHand, rate: 7, dt: dt)
        leftElbow = ease(leftElbow, pose.leftElbow, rate: 7, dt: dt)
        rightHand = ease(rightHand, pose.rightHand, rate: 7, dt: dt)
        rightElbow = ease(rightElbow, pose.rightElbow, rate: 7, dt: dt)
        browLift += (pose.brow - browLift) * min(1, dt * 6)
        leftGlove = pose.leftGlove
        rightGlove = pose.rightGlove
    }

    var timeInMood: TimeInterval { lastTime - moodChangedAt }
    /// False until the first frame is drawn (so a preview starts in its outfit instead of twirling into it).
    var hasStarted: Bool { lastTime != 0 }

    private func ease(_ a: CGPoint, _ b: CGPoint, rate: Double, dt: Double) -> CGPoint {
        let k = CGFloat(min(1, dt * rate))
        return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }
}

/// Arm targets in face units (face radius = 40, origin = face center, y down).
private struct Pose {
    var leftHand: CGPoint
    var leftElbow: CGPoint
    var rightHand: CGPoint
    var rightElbow: CGPoint
    var brow: Double
    var leftGlove: GloveShape = .open
    var rightGlove: GloveShape = .open

    static let leftHip = (hand: CGPoint(x: -39, y: 29), elbow: CGPoint(x: -60, y: 14))
    static let rightHip = (hand: CGPoint(x: 39, y: 29), elbow: CGPoint(x: 60, y: 14))

    static let sleeping = Pose(
        leftHand: CGPoint(x: -9, y: 44), leftElbow: CGPoint(x: -44, y: 46),
        rightHand: CGPoint(x: 9, y: 44), rightElbow: CGPoint(x: 44, y: 46), brow: -0.2
    )
    static let airborne = Pose(
        leftHand: CGPoint(x: -54, y: -32), leftElbow: CGPoint(x: -62, y: -6),
        rightHand: CGPoint(x: 54, y: -32), rightElbow: CGPoint(x: 62, y: -6), brow: 1
    )
    static let stretch = Pose(
        leftHand: CGPoint(x: -36, y: -46), leftElbow: CGPoint(x: -58, y: -20),
        rightHand: CGPoint(x: 36, y: -46), rightElbow: CGPoint(x: 58, y: -20), brow: 0.6
    )

    /// Deliberate gestures. `toward` is the normalized direction (y down) of what she's pointing at.
    static func gesture(_ gesture: BodyGesture, t: TimeInterval, elapsed: TimeInterval, toward: CGPoint) -> Pose {
        switch gesture {
        case .point:
            // Point with the arm on the target's side; keep the aim out of her own body.
            let side: CGFloat = toward.x >= 0 ? 1 : -1
            var dir = CGPoint(x: abs(toward.x) < 0.25 ? side * 0.25 : toward.x, y: min(0.55, max(-0.9, toward.y)))
            let length = max(0.001, hypot(dir.x, dir.y))
            dir = CGPoint(x: dir.x / length, y: dir.y / length)
            let shoulder = CGPoint(x: 36 * side, y: 8)
            // A little jab forward as the gesture lands.
            let reach = 14 + 2 * CGFloat(max(0, sin(min(1, elapsed * 4) * .pi)))
            let hand = shoulder + CGPoint(x: dir.x * reach, y: dir.y * reach)
            let elbow = shoulder + CGPoint(x: dir.x * 7 - dir.y * 3 * side, y: dir.y * 7 + dir.x * 3 * side)
            let rest = side > 0 ? leftHip : rightHip
            return side > 0
                ? Pose(leftHand: rest.hand, leftElbow: rest.elbow, rightHand: hand, rightElbow: elbow, brow: 0.5, rightGlove: .point)
                : Pose(leftHand: hand, leftElbow: elbow, rightHand: rest.hand, rightElbow: rest.elbow, brow: 0.5, leftGlove: .point)
        case .thumbsUp:
            let pump = CGFloat(sin(min(1, elapsed * 3) * .pi)) * 4
            return Pose(
                leftHand: leftHip.hand, leftElbow: leftHip.elbow,
                rightHand: CGPoint(x: 44, y: -8 - pump), rightElbow: CGPoint(x: 60, y: 22),
                brow: 0.7, rightGlove: .thumbsUp
            )
        case .think:
            let tap = CGFloat(max(0, sin(t * 5))) * 2.5
            return Pose(
                leftHand: CGPoint(x: -6, y: 46), leftElbow: CGPoint(x: -46, y: 44),
                rightHand: CGPoint(x: 10, y: 36 - tap), rightElbow: CGPoint(x: 52, y: 46),
                brow: 0.65, rightGlove: .point
            )
        case .celebrate:
            let a = CGFloat(sin(t * 14)) * 5
            return Pose(
                leftHand: CGPoint(x: -44 + a, y: -34), leftElbow: CGPoint(x: -62, y: -8),
                rightHand: CGPoint(x: 44 - a, y: -34), rightElbow: CGPoint(x: 62, y: -8),
                brow: 1
            )
        case .shrug:
            let lift = CGFloat(min(1, elapsed * 5)) * 4
            return Pose(
                leftHand: CGPoint(x: -58, y: 6 - lift), leftElbow: CGPoint(x: -46, y: 30),
                rightHand: CGPoint(x: 58, y: 6 - lift), rightElbow: CGPoint(x: 46, y: 30),
                brow: 0.9
            )
        case .peer:
            let side: CGFloat = toward.x >= 0 ? 1 : -1
            let hand = CGPoint(x: 14 * side, y: -30)
            let elbow = CGPoint(x: 54 * side, y: -16)
            let rest = side > 0 ? leftHip : rightHip
            return side > 0
                ? Pose(leftHand: rest.hand, leftElbow: rest.elbow, rightHand: hand, rightElbow: elbow, brow: 0.8)
                : Pose(leftHand: hand, leftElbow: elbow, rightHand: rest.hand, rightElbow: rest.elbow, brow: 0.8)
        case .twirl:
            // Arms out for balance through the spin, then a "ta-da" with one hand high.
            if elapsed < BodyDirector.twirlSeconds * 0.75 {
                return Pose(
                    leftHand: CGPoint(x: -60, y: -12), leftElbow: CGPoint(x: -56, y: 8),
                    rightHand: CGPoint(x: 60, y: -12), rightElbow: CGPoint(x: 56, y: 8),
                    brow: 0.9
                )
            }
            return Pose(
                leftHand: leftHip.hand, leftElbow: leftHip.elbow,
                rightHand: CGPoint(x: 50, y: -42), rightElbow: CGPoint(x: 64, y: -10),
                brow: 1
            )
        }
    }

    static func walking(phase: Double) -> Pose {
        let swing = CGFloat(sin(phase))
        return Pose(
            leftHand: CGPoint(x: -45, y: 24 + 7 * swing), leftElbow: CGPoint(x: -57, y: 10),
            rightHand: CGPoint(x: 45, y: 24 - 7 * swing), rightElbow: CGPoint(x: 57, y: 10),
            brow: 0.2
        )
    }

    static func target(for mood: CharacterMood, t: TimeInterval) -> Pose {
        let s = CGFloat(sin(t * 1.3))
        switch mood {
        case .idle:
            return Pose(
                leftHand: leftHip.hand + CGPoint(x: 0, y: s),
                leftElbow: leftHip.elbow + CGPoint(x: -s, y: 0),
                rightHand: rightHip.hand + CGPoint(x: 0, y: -s),
                rightElbow: rightHip.elbow + CGPoint(x: s, y: 0),
                brow: 0
            )
        case .talking:
            let a = CGFloat(sin(t * 4.6)), b = CGFloat(sin(t * 3.4 + 1.2))
            return Pose(
                leftHand: CGPoint(x: -57, y: 2 + 6 * a),
                leftElbow: CGPoint(x: -54, y: 26),
                rightHand: CGPoint(x: 55, y: 16 + 4 * b),
                rightElbow: CGPoint(x: 62, y: 30),
                brow: 0.35 + 0.25 * Double(max(0, a))
            )
        case .thinking:
            return Pose(
                leftHand: leftHip.hand,
                leftElbow: leftHip.elbow,
                rightHand: CGPoint(x: 17, y: 43 + s),
                rightElbow: CGPoint(x: 56, y: 44),
                brow: 0.5
            )
        case .working:
            let a = CGFloat(sin(t * 7)), b = CGFloat(sin(t * 7 + .pi))
            return Pose(
                leftHand: CGPoint(x: -48, y: -4 + 6 * a),
                leftElbow: CGPoint(x: -64, y: 20),
                rightHand: CGPoint(x: 48, y: -4 + 6 * b),
                rightElbow: CGPoint(x: 64, y: 20),
                brow: 0.25
            )
        case .announcing:
            let wave = CGFloat(sin(t * 10))
            return Pose(
                leftHand: leftHip.hand,
                leftElbow: leftHip.elbow,
                rightHand: CGPoint(x: 54 + 6 * wave, y: -40),
                rightElbow: CGPoint(x: 66, y: -6),
                brow: 0.8
            )
        case .listening:
            return Pose(
                leftHand: CGPoint(x: -49, y: -15 + 0.6 * s),
                leftElbow: CGPoint(x: -64, y: 12),
                rightHand: rightHip.hand,
                rightElbow: rightHip.elbow,
                brow: 0.6
            )
        case .concerned:
            return Pose(
                leftHand: CGPoint(x: -9, y: 47),
                leftElbow: CGPoint(x: -52, y: 40),
                rightHand: CGPoint(x: 9, y: 47),
                rightElbow: CGPoint(x: 52, y: 40),
                brow: -0.6
            )
        }
    }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }

/// What her white glove is doing.
enum GloveShape {
    case open, point, thumbsUp
}

// MARK: - Palette

struct MinutePalette {
    var rimTop: Color
    var rimBottom: Color
    var rimStroke: Color
    var dialCenter: Color
    var dialEdge: Color
    var tick: Color
    var line: Color
    var eyeWhite: Color
    var pupil: Color
    var limb: Color
    var glove: Color
    var gloveLine: Color
    var mouth: Color
    var tongue: Color
    var cheek: Color
    var hands: Color
    var pivot: Color
    var shoe: Color
    /// The hologram light (outer glow, projector, time door) and small decorative accents.
    var glow: Color = Color(hex: 0xFF8A1E)
    var accent: Color = Color(hex: 0xFFB566)

    static let classic = MinutePalette(
        rimTop: Color(hex: 0xFF8A26), rimBottom: Color(hex: 0xE8590C), rimStroke: Color(hex: 0x8A2E08),
        dialCenter: Color(hex: 0xFFF4E3), dialEdge: Color(hex: 0xFFC27A), tick: Color(hex: 0xC2410C),
        line: Color(hex: 0x3B1405), eyeWhite: .white, pupil: Color(hex: 0x1C0A03),
        limb: Color(hex: 0x1C0A03), glove: .white, gloveLine: Color(hex: 0x3B1405),
        mouth: Color(hex: 0x6B1D0B), tongue: Color(hex: 0xF06A6A), cheek: Color(hex: 0xFF6B6B).opacity(0.38),
        hands: Color(hex: 0x3B1405), pivot: Color(hex: 0xD9480F), shoe: Color(hex: 0x2B1206)
    )

    static let hologram = MinutePalette(
        rimTop: Color(hex: 0xFF9A33).opacity(0.62), rimBottom: Color(hex: 0xFF6A00).opacity(0.55),
        rimStroke: Color(hex: 0xFFD9A8),
        dialCenter: Color(hex: 0xFFC285).opacity(0.36), dialEdge: Color(hex: 0xFF8A26).opacity(0.42),
        tick: Color(hex: 0xFFE3BD).opacity(0.85),
        line: Color(hex: 0xFFEBD1), eyeWhite: Color(hex: 0xFFE2BA).opacity(0.9), pupil: Color(hex: 0x5C2100),
        limb: Color(hex: 0xFFB566), glove: Color(hex: 0xFFEEDB).opacity(0.92), gloveLine: Color(hex: 0xFFF7EC),
        mouth: Color(hex: 0x5C1E00).opacity(0.85), tongue: Color(hex: 0xFF9466).opacity(0.85),
        cheek: Color(hex: 0xFF5530).opacity(0.28),
        hands: Color(hex: 0xFFF2E0), pivot: Color(hex: 0xFFF2E0), shoe: Color(hex: 0xFFA149).opacity(0.85)
    )

    /// Every outfit in both skins, worked out once: each look recolors the signature orange.
    private static let table: [CharacterSkin: [AvatarLook: MinutePalette]] = {
        var table: [CharacterSkin: [AvatarLook: MinutePalette]] = [:]
        for skin in CharacterSkin.allCases {
            let base: MinutePalette = skin == .hologram ? .hologram : .classic
            var looks: [AvatarLook: MinutePalette] = [:]
            for look in AvatarLook.allCases { looks[look] = base.recolored(for: look) }
            table[skin] = looks
        }
        return table
    }()

    static func forLook(_ look: AvatarLook, skin: CharacterSkin) -> MinutePalette {
        table[skin]?[look] ?? (skin == .hologram ? .hologram : .classic)
    }

    /// The palette partway through a change of outfit.
    static func current(_ transition: LookTransition, skin: CharacterSkin, at t: TimeInterval) -> MinutePalette {
        let to = forLook(transition.to, skin: skin)
        guard transition.isAnimating(at: t) else { return to }
        let from = forLook(transition.from, skin: skin)
        let k = transition.progress(at: t)
        return from.zip(to) { $0.mixed(with: $1, by: k) }
    }

    private func map(_ f: (Color) -> Color) -> MinutePalette {
        zip(self) { a, _ in f(a) }
    }

    private func zip(_ other: MinutePalette, _ f: (Color, Color) -> Color) -> MinutePalette {
        var out = self
        let keys: [WritableKeyPath<MinutePalette, Color>] = [
            \.rimTop, \.rimBottom, \.rimStroke, \.dialCenter, \.dialEdge, \.tick, \.line, \.eyeWhite, \.pupil,
            \.limb, \.glove, \.gloveLine, \.mouth, \.tongue, \.cheek, \.hands, \.pivot, \.shoe, \.glow, \.accent,
        ]
        for key in keys { out[keyPath: key] = f(self[keyPath: key], other[keyPath: key]) }
        return out
    }

    private func recolored(for look: AvatarLook) -> MinutePalette {
        // Hue shift from her signature orange (~27°), plus saturation/brightness. Whites and near-greys
        // (gloves, eye highlights) stay as they are.
        let (hueShift, sat, bright): (Double, Double, Double)
        switch look {
        case .signature: return self
        case .night: (hueShift, sat, bright) = (0.66, 0.85, 0.95)
        case .sunny: (hueShift, sat, bright) = (0.055, 1.05, 1.08)
        case .tvaFormal: (hueShift, sat, bright) = (0.01, 0.6, 0.9)
        case .variant: (hueShift, sat, bright) = (0.33, 0.85, 0.92)
        }
        var out = map { $0.shifted(hue: hueShift, saturation: sat, brightness: bright) }
        if look == .variant {
            // Loki's gold trim on the dial.
            out.tick = Color(hex: 0xFFD34D)
            out.pivot = Color(hex: 0xFFD34D)
            out.accent = Color(hex: 0xFFD34D)
        }
        return out
    }
}

extension Color {
    private var srgb: NSColor { NSColor(self).usingColorSpace(.sRGB) ?? .white }

    func shifted(hue: Double, saturation: Double, brightness: Double) -> Color {
        let c = srgb
        guard c.saturationComponent > 0.08 else { return self }
        let h = (c.hueComponent + hue).truncatingRemainder(dividingBy: 1)
        return Color(nsColor: NSColor(
            hue: h,
            saturation: min(1, c.saturationComponent * saturation),
            brightness: min(1, c.brightnessComponent * brightness),
            alpha: c.alphaComponent
        ))
    }

    func mixed(with other: Color, by k: Double) -> Color {
        let a = srgb, b = other.srgb
        func lerp(_ x: CGFloat, _ y: CGFloat) -> Double { Double(x + (y - x) * k) }
        return Color(.sRGB,
                     red: lerp(a.redComponent, b.redComponent),
                     green: lerp(a.greenComponent, b.greenComponent),
                     blue: lerp(a.blueComponent, b.blueComponent),
                     opacity: lerp(a.alphaComponent, b.alphaComponent))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Renderer

struct MissMinuteRenderer {
    let t: TimeInterval
    let date: Date
    let mood: CharacterMood
    let skin: CharacterSkin
    let hover: Bool
    let motion: MotionState
    let body: BodyState
    let canvas: CGSize
    /// The outfit's colors (cross-fading while she changes).
    let palette: MinutePalette

    init(t: TimeInterval, date: Date, mood: CharacterMood, skin: CharacterSkin, hover: Bool,
         motion: MotionState, body: BodyState, canvas: CGSize) {
        self.t = t
        self.date = date
        self.mood = mood
        self.skin = skin
        self.hover = hover
        self.motion = motion
        self.body = body
        self.canvas = canvas
        palette = MinutePalette.current(body.look, skin: skin, at: t)
    }

    var expression: BodyState.Expression { body.currentExpression(at: t) }
    var gesture: BodyGesture? { body.currentGesture(at: t) }
    var aura: BodyAura { body.currentAura(at: t) }
    var gestureElapsed: TimeInterval { t - body.gestureStart }
    var onFloor: Bool { !body.perched && !body.airborne && !body.hovering }

    /// One face unit (face radius = 40 units).
    var u: CGFloat { canvas.width / 145 }
    var hologramGlow: Color { palette.glow }
    /// How much of an outfit is showing (its accessories fade in and out with the colors).
    func weight(of look: AvatarLook) -> Double { body.look.weight(of: look, at: t) }
    /// 0…1 through the outfit-change spin, or nil.
    var twirlProgress: Double? {
        guard gesture == .twirl else { return nil }
        return min(1, max(0, gestureElapsed / BodyDirector.twirlSeconds))
    }

    // Body motion
    var bob: CGFloat {
        if body.asleep { return CGFloat(sin(t * 1.3)) * 1.4 + 2 }
        if body.walking { return -abs(CGFloat(sin(motion.walkPhase))) * 3.5 }
        if gesture == .celebrate {
            // Bouncing for joy.
            return -abs(CGFloat(sin(gestureElapsed * 7))) * 9
        }
        if let spin = twirlProgress {
            // A little hop up into the spin and back down.
            return -CGFloat(sin(spin * .pi)) * 8
        }
        if body.hovering { return CGFloat(sin(t * 2.4)) * 3 }
        let speed = (mood == .talking || mood == .working) ? 3.4 : 2.1
        let amp: CGFloat = (mood == .announcing) ? 3.2 : 2.0
        return CGFloat(sin(t * speed)) * amp - CGFloat(motion.squash) * 4
    }
    var center: CGPoint { CGPoint(x: canvas.width / 2, y: canvas.height * 0.41 + bob * u) }
    var tilt: Angle {
        let base = sin(t * 0.9) * 2.2
        let talk = mood == .talking ? sin(t * 2.3) * 3 : 0
        let curious = mood == .thinking ? -6.0 : (mood == .listening ? 7.0 : 0)
        // Leaning into the direction of travel, more when floating across the screen.
        let lean = Double(motion.facing) * (body.walking ? 5 : (body.hovering ? 7 : 2))
        let droop = body.asleep ? 9.0 : 0
        return .degrees(base + talk + curious + lean + droop)
    }

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * u, y: y * u)
    }

    mutating func draw(in context: inout GraphicsContext) {
        var context = context
        if let teleport = body.teleportProgress(at: t) {
            drawTeleport(in: &context, progress: teleport)
        }
        if body.hovering, !body.perched { drawHoverGlow(in: &context) }
        if skin == .hologram {
            if onFloor { drawProjector(in: &context) }
            var flicker = 0.9 + 0.05 * sin(t * 13.7) + 0.03 * sin(t * 31.0) - (glitchActive ? 0.18 : 0)
            if body.asleep { flicker *= 0.7 }
            let renderer = self
            context.drawLayer { glowLayer in
                glowLayer.addFilter(.shadow(color: hologramGlow.opacity(hover ? 0.95 : 0.75), radius: 9 * renderer.u))
                glowLayer.opacity = flicker
                glowLayer.drawLayer { layer in
                    renderer.drawCharacterWithGlitch(in: &layer)
                    renderer.drawScanlines(in: &layer)
                }
            }
        } else {
            if onFloor { drawGroundShadow(in: &context) }
            if hover {
                context.addFilter(.shadow(color: palette.glow.opacity(0.45), radius: 10 * u))
            }
            drawCharacter(in: &context)
        }
    }

    // MARK: Hologram effects

    var glitchActive: Bool {
        // The formal projection is steady.
        if weight(of: .tvaFormal) > 0.5 { return false }
        // A brief tear every few seconds, at pseudo-random intervals.
        let window = 5.3
        let slot = floor(t / window)
        let offset = (sin(slot * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let start = abs(offset) * (window - 0.3)
        let phase = t - slot * window
        return phase > start && phase < start + 0.14
    }

    func drawCharacterWithGlitch(in context: inout GraphicsContext) {
        guard glitchActive else {
            drawCharacter(in: &context)
            return
        }
        let bandY = canvas.height * CGFloat(0.25 + 0.4 * abs(sin(floor(t * 7) * 1.7)))
        let bandH = canvas.height * 0.07
        let band = CGRect(x: 0, y: bandY, width: canvas.width, height: bandH)
        var outside = context
        outside.clip(to: Path(CGRect(origin: .zero, size: canvas)).subtracting(Path(band)))
        drawCharacter(in: &outside)
        var inside = context
        inside.clip(to: Path(band))
        inside.translateBy(x: 4 * u * CGFloat(sin(t * 50)), y: 0)
        drawCharacter(in: &inside)
    }

    func drawScanlines(in context: inout GraphicsContext) {
        // Thin lines punched out of the hologram…
        var lines = Path()
        let spacing = max(2.5, 2.4 * u)
        var y = CGFloat((t * 6).truncatingRemainder(dividingBy: Double(spacing)))
        while y < canvas.height {
            lines.addRect(CGRect(x: 0, y: y, width: canvas.width, height: max(0.8, spacing * 0.36)))
            y += spacing
        }
        var punch = context
        punch.blendMode = .destinationOut
        punch.fill(lines, with: .color(.black.opacity(0.32)))

        // …and a bright sweep travelling down, only where she's drawn.
        let sweepY = CGFloat((t * 0.45).truncatingRemainder(dividingBy: 1)) * canvas.height * 1.4 - canvas.height * 0.2
        var sweep = context
        sweep.blendMode = .sourceAtop
        sweep.fill(
            Path(CGRect(x: 0, y: sweepY, width: canvas.width, height: canvas.height * 0.12)),
            with: .linearGradient(
                Gradient(colors: [.clear, palette.gloveLine.opacity(0.45), .clear]),
                startPoint: CGPoint(x: 0, y: sweepY),
                endPoint: CGPoint(x: 0, y: sweepY + canvas.height * 0.12)
            )
        )
    }

    func drawProjector(in context: inout GraphicsContext) {
        let base = CGPoint(x: canvas.width / 2, y: canvas.height * 0.97)
        let footY = canvas.height * 0.41 + 68 * u
        // Light cone from the emitter up to her feet.
        var cone = Path()
        cone.move(to: CGPoint(x: base.x - 10 * u, y: base.y))
        cone.addLine(to: CGPoint(x: base.x + 10 * u, y: base.y))
        cone.addLine(to: CGPoint(x: base.x + 34 * u, y: footY))
        cone.addLine(to: CGPoint(x: base.x - 34 * u, y: footY))
        cone.closeSubpath()
        context.fill(cone, with: .linearGradient(
            Gradient(colors: [hologramGlow.opacity(0.32), hologramGlow.opacity(0.0)]),
            startPoint: base,
            endPoint: CGPoint(x: base.x, y: footY)
        ))
        // Emitter puck.
        let pulse = 0.75 + 0.25 * sin(t * 3)
        var glow = context
        glow.addFilter(.blur(radius: 5 * u))
        glow.fill(Path(ellipseIn: CGRect(x: base.x - 22 * u, y: base.y - 4 * u, width: 44 * u, height: 8 * u)),
                  with: .color(hologramGlow.opacity(0.55 * pulse)))
        context.fill(Path(ellipseIn: CGRect(x: base.x - 14 * u, y: base.y - 2.2 * u, width: 28 * u, height: 4.4 * u)),
                     with: .color(Color(hex: 0xFFE0B8).opacity(0.8)))
    }

    func drawGroundShadow(in context: inout GraphicsContext) {
        let y = canvas.height * 0.41 + 71 * u
        let w = (46 - bob * 1.5) * u
        var shadow = context
        shadow.addFilter(.blur(radius: 3 * u))
        shadow.fill(Path(ellipseIn: CGRect(x: canvas.width / 2 - w / 2, y: y - 3 * u, width: w, height: 6 * u)),
                    with: .color(.black.opacity(0.28)))
    }

    // MARK: Character

    func drawCharacter(in context: inout GraphicsContext) {
        var ctx = context
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: tilt)
        let stretch = 1 + CGFloat(motion.squash) * 0.06
        ctx.scaleBy(x: 1 / stretch, y: stretch)
        if let spin = twirlProgress {
            drawTwirlSwirl(in: &ctx, progress: spin)
            // Turning around her own axis: squeeze to an edge, show her back (mirrored), round again.
            let eased = spin * spin * (3 - 2 * spin)
            let sx = CGFloat(cos(2 * .pi * eased))
            ctx.scaleBy(x: sx >= 0 ? max(0.08, sx) : min(-0.08, sx), y: 1)
        }

        drawAuraBehind(in: &ctx)
        drawOutfitBehind(in: &ctx)
        drawLegs(in: &ctx)
        drawCrown(in: &ctx)
        drawFace(in: &ctx)
        drawOutfitFront(in: &ctx)
        drawArm(in: &ctx, shoulder: p(-36, 8), elbow: motion.leftElbow, hand: motion.leftHand, side: -1, shape: motion.leftGlove)
        drawArm(in: &ctx, shoulder: p(36, 8), elbow: motion.rightElbow, hand: motion.rightHand, side: 1, shape: motion.rightGlove)
        if gesture == .think {
            drawThoughtBubble(in: &ctx)
        } else {
            drawMoodAccents(in: &ctx)
        }
        drawAuraFront(in: &ctx)
        if gesture == .celebrate { drawConfetti(in: &ctx) }
        if body.asleep { drawSnores(in: &ctx) }
    }

    func drawSnores(in ctx: inout GraphicsContext) {
        for i in 0..<3 {
            let phase = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let pos = p(30 + CGFloat(phase) * 18, -40 - CGFloat(phase) * 26)
            let size = (6 + CGFloat(phase) * 7) * u
            ctx.draw(
                Text("z").font(.system(size: size, weight: .heavy, design: .rounded))
                    .foregroundColor(Color(hex: 0xFFD9A8).opacity(1 - phase)),
                at: pos
            )
        }
    }

    func drawLegs(in ctx: inout GraphicsContext) {
        let kick = mood == .announcing ? CGFloat(sin(t * 8)) * 3 : 0
        let step = CGFloat(-bob) * 0.6
        for side in [CGFloat(-1), 1] {
            let hip = p(13 * side, 36)
            var foot = p((17 + (side > 0 ? kick : 0)) * side, 64 + step)
            var knee = p(22 * side, 50)
            if body.walking {
                // Alternating stride in the direction she's facing.
                let phase = motion.walkPhase + (side > 0 ? .pi : 0)
                let stride = CGFloat(sin(phase)) * 7 * (motion.facing == 0 ? 1 : motion.facing)
                let lift = max(0, CGFloat(cos(phase))) * 5
                foot = p(15 * side + stride, 64 + step - lift)
                knee = p(19 * side + stride * 0.6, 49 - lift * 0.5)
            } else if body.perched || body.hovering {
                // Legs dangling over the window edge (or in mid-air), swinging.
                let swing = CGFloat(sin(t * 2.2 + (side > 0 ? 1.4 : 0))) * 3
                foot = p(11 * side + swing, 57)
                knee = p(15 * side, 47)
            } else if body.airborne {
                foot = p(21 * side, 56)
                knee = p(26 * side, 42)
            }
            var leg = Path()
            leg.move(to: hip)
            leg.addQuadCurve(to: foot, control: knee)
            strokeLimb(leg, in: &ctx, width: 3.4)

            // Cartoon shoe, toe out.
            let shoeRect = CGRect(x: foot.x - 6.5 * u + 3 * u * side, y: foot.y - 2 * u, width: 13 * u, height: 6.5 * u)
            ctx.fill(Path(ellipseIn: shoeRect), with: .color(palette.shoe))
            ctx.fill(Path(ellipseIn: shoeRect.insetBy(dx: 3.5 * u, dy: 1.6 * u).offsetBy(dx: 1.5 * u * side, dy: -1 * u)),
                     with: .color(.white.opacity(skin == .hologram ? 0.35 : 0.22)))
        }
    }

    func drawCrown(in ctx: inout GraphicsContext) {
        // Winding stem and knob on top of the clock.
        let stem = Path(roundedRect: CGRect(x: -3.6 * u, y: -48 * u, width: 7.2 * u, height: 9 * u), cornerRadius: 1.5 * u)
        ctx.fill(stem, with: .linearGradient(Gradient(colors: [palette.rimTop, palette.rimBottom]),
                                             startPoint: p(0, -48), endPoint: p(0, -39)))
        ctx.stroke(stem, with: .color(palette.rimStroke), lineWidth: 1.2 * u)
        let knob = Path(roundedRect: CGRect(x: -7.5 * u, y: -55 * u, width: 15 * u, height: 8 * u), cornerRadius: 3.5 * u)
        ctx.fill(knob, with: .linearGradient(Gradient(colors: [palette.rimTop, palette.rimBottom]),
                                             startPoint: p(0, -55), endPoint: p(0, -47)))
        ctx.stroke(knob, with: .color(palette.rimStroke), lineWidth: 1.2 * u)
        for x in [-3.5, 0, 3.5] as [CGFloat] {
            var ridge = Path()
            ridge.move(to: p(x, -53.5))
            ridge.addLine(to: p(x, -48.5))
            ctx.stroke(ridge, with: .color(palette.rimStroke.opacity(0.6)), lineWidth: 0.8 * u)
        }
    }

    func drawFace(in ctx: inout GraphicsContext) {
        let r: CGFloat = 40 * u
        let face = Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
        ctx.fill(face, with: .linearGradient(Gradient(colors: [palette.rimTop, palette.rimBottom]),
                                             startPoint: CGPoint(x: -r * 0.5, y: -r), endPoint: CGPoint(x: r * 0.5, y: r)))
        ctx.stroke(face, with: .color(palette.rimStroke), lineWidth: 2.3 * u)

        // Dial
        let dr = r * 0.82
        let dial = Path(ellipseIn: CGRect(x: -dr, y: -dr, width: 2 * dr, height: 2 * dr))
        ctx.fill(dial, with: .radialGradient(Gradient(colors: [palette.dialCenter, palette.dialEdge]),
                                             center: CGPoint(x: -dr * 0.25, y: -dr * 0.3), startRadius: 0, endRadius: dr * 1.25))
        ctx.stroke(dial, with: .color(palette.rimStroke.opacity(0.55)), lineWidth: 1 * u)

        // Rim gloss
        var gloss = Path()
        gloss.addArc(center: .zero, radius: r * 0.91, startAngle: .degrees(200), endAngle: .degrees(255), clockwise: false)
        ctx.stroke(gloss, with: .color(.white.opacity(skin == .hologram ? 0.55 : 0.45)),
                   style: StrokeStyle(lineWidth: 2.2 * u, lineCap: .round))

        // Hour ticks
        for i in 0..<12 {
            let angle = Double(i) * .pi / 6
            let major = i % 3 == 0
            let pos = CGPoint(x: CGFloat(sin(angle)) * dr * 0.88, y: -CGFloat(cos(angle)) * dr * 0.88)
            let size = (major ? 2.6 : 1.6) * u
            ctx.fill(Path(ellipseIn: CGRect(x: pos.x - size / 2, y: pos.y - size / 2, width: size, height: size)),
                     with: .color(palette.tick))
        }

        drawCheeks(in: &ctx)
        drawEyes(in: &ctx)
        drawClockHands(in: &ctx)
        drawMouth(in: &ctx)
    }

    func drawCheeks(in ctx: inout GraphicsContext) {
        let strength = mood == .announcing || mood == .talking ? 1.0 : 0.75
        for side in [CGFloat(-1), 1] {
            let rect = CGRect(x: (22 * side - 5.5) * u, y: 6 * u, width: 11 * u, height: 6 * u)
            var blush = ctx
            blush.addFilter(.blur(radius: 1.6 * u))
            blush.fill(Path(ellipseIn: rect), with: .color(palette.cheek.opacity(strength)))
        }
    }

    var blinkAmount: CGFloat {
        if mood == .concerned, sin(t * 0.7) > 0.6 { return 0.25 }
        let cycle = 3.9
        let slot = floor(t / cycle)
        let phase = t - slot * cycle
        let doubleBlink = Int(slot) % 4 == 2
        func closed(_ start: Double) -> CGFloat {
            let x = (phase - start) / 0.14
            guard x > 0, x < 1 else { return 0 }
            return CGFloat(sin(x * .pi))
        }
        return max(closed(0.1), doubleBlink ? closed(0.34) : 0)
    }

    func drawEyes(in ctx: inout GraphicsContext) {
        let delighted = expression == .happy || gesture == .celebrate
        if body.asleep || delighted || expression == .yawn {
            drawClosedEyes(in: &ctx, happy: delighted && !body.asleep)
            return
        }
        let blink = blinkAmount
        let surprised = expression == .surprised || body.airborne
        let wide: CGFloat = surprised ? 1.2 : ((mood == .announcing || mood == .listening) ? 1.08 : 1)
        let gaze = motion.gaze
        for side in [CGFloat(-1), 1] {
            let c = p(12.5 * side, -9)
            let w = 15 * u * wide
            let h = max(1.2 * u, 19.5 * u * wide * (1 - blink))
            let eye = Path(ellipseIn: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
            ctx.fill(eye, with: .color(palette.eyeWhite))
            ctx.stroke(eye, with: .color(palette.line), lineWidth: 1.15 * u)

            if blink < 0.7 {
                var inner = ctx
                inner.clip(to: eye)
                let pupilCenter = CGPoint(x: c.x + gaze.x * 3.2 * u, y: c.y + gaze.y * 4.2 * u + 1.5 * u)
                let pw = 7.6 * u, ph = 10.5 * u
                inner.fill(Path(ellipseIn: CGRect(x: pupilCenter.x - pw / 2, y: pupilCenter.y - ph / 2, width: pw, height: ph)),
                           with: .color(palette.pupil))
                let hl = 2.6 * u
                inner.fill(Path(ellipseIn: CGRect(x: pupilCenter.x - 2.6 * u, y: pupilCenter.y - 4 * u, width: hl, height: hl)),
                           with: .color(.white.opacity(0.95)))
                inner.fill(Path(ellipseIn: CGRect(x: pupilCenter.x + 1 * u, y: pupilCenter.y + 1.5 * u, width: 1.2 * u, height: 1.2 * u)),
                           with: .color(.white.opacity(0.7)))
            }
            if aura == .focused, !surprised {
                // Focused: heavy upper lids, like she's locked onto the code.
                var lid = ctx
                lid.clip(to: eye)
                let lidBottom = c.y - h / 2 + h * 0.38
                lid.fill(Path(CGRect(x: c.x - w, y: c.y - h, width: 2 * w, height: lidBottom - (c.y - h))),
                         with: .color(palette.rimTop))
                var edge = Path()
                edge.move(to: CGPoint(x: c.x - w / 2, y: lidBottom))
                edge.addLine(to: CGPoint(x: c.x + w / 2, y: lidBottom))
                lid.stroke(edge, with: .color(palette.line), lineWidth: 1.4 * u)
            }

            // Lashes on the outer top edge.
            let top = CGPoint(x: c.x, y: c.y - h / 2)
            for i in 0..<3 {
                let fi = CGFloat(i)
                let start = CGPoint(x: top.x + side * (2.5 + fi * 2.6) * u, y: top.y + (fi * fi * 0.55) * u)
                var lash = Path()
                lash.move(to: start)
                lash.addQuadCurve(
                    to: CGPoint(x: start.x + side * (3.2 + fi) * u, y: start.y - (4.3 - fi * 0.6) * u),
                    control: CGPoint(x: start.x + side * 0.6 * u, y: start.y - 3.2 * u)
                )
                ctx.stroke(lash, with: .color(palette.line), style: StrokeStyle(lineWidth: 1.25 * u, lineCap: .round))
            }

            // Brows
            let lift = CGFloat(motion.browLift)
            let worried = mood == .concerned || gesture == .shrug
            let skeptical = (mood == .thinking || gesture == .think) && side > 0
            let determined = aura == .focused && !worried
            var brow = Path()
            let browY = c.y - h / 2 - (4.5 + lift * 2.5 + (skeptical ? 2 : 0)) * u
            let innerY = worried ? browY - 2.2 * u : (determined ? browY + 2.6 * u : browY + 0.8 * u)
            brow.move(to: CGPoint(x: c.x - side * 5.5 * u, y: innerY))
            brow.addQuadCurve(to: CGPoint(x: c.x + side * 6 * u, y: browY + 1.2 * u),
                              control: CGPoint(x: c.x, y: browY - 2.4 * u))
            ctx.stroke(brow, with: .color(palette.line), style: StrokeStyle(lineWidth: 1.5 * u, lineCap: .round))
        }
    }

    /// Sleepy (curved down) or delighted (^ ^) closed eyes, with lashes.
    func drawClosedEyes(in ctx: inout GraphicsContext, happy: Bool) {
        for side in [CGFloat(-1), 1] {
            let c = p(12.5 * side, -7)
            var lid = Path()
            lid.move(to: CGPoint(x: c.x - 6.5 * u, y: c.y))
            lid.addQuadCurve(to: CGPoint(x: c.x + 6.5 * u, y: c.y),
                             control: CGPoint(x: c.x, y: c.y + (happy ? -7 : 5) * u))
            ctx.stroke(lid, with: .color(palette.line), style: StrokeStyle(lineWidth: 1.8 * u, lineCap: .round))
            var lash = Path()
            lash.move(to: CGPoint(x: c.x + side * 6.5 * u, y: c.y))
            lash.addLine(to: CGPoint(x: c.x + side * 9.5 * u, y: c.y - 2.5 * u))
            ctx.stroke(lash, with: .color(palette.line), style: StrokeStyle(lineWidth: 1.3 * u, lineCap: .round))
        }
    }

    func drawClockHands(in ctx: inout GraphicsContext) {
        let comps = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double(comps.second ?? 0) + Double(comps.nanosecond ?? 0) / 1e9
        let minutes = Double(comps.minute ?? 0) + seconds / 60
        let hours = Double((comps.hour ?? 0) % 12) + minutes / 60
        var minuteAngle = minutes / 60 * 2 * .pi
        var hourAngle = hours / 12 * 2 * .pi
        if mood == .thinking || mood == .working {
            // Spinning hands while she works things out.
            minuteAngle = t * 5.5
            hourAngle = t * 0.9
        }
        let pivot = p(0, 4)
        func hand(_ angle: Double, length: CGFloat, width: CGFloat) {
            var path = Path()
            path.move(to: pivot)
            path.addLine(to: CGPoint(x: pivot.x + CGFloat(sin(angle)) * length * u, y: pivot.y - CGFloat(cos(angle)) * length * u))
            ctx.stroke(path, with: .color(palette.hands), style: StrokeStyle(lineWidth: width * u, lineCap: .round))
        }
        hand(hourAngle, length: 7.5, width: 2.1)
        hand(minuteAngle, length: 11, width: 1.5)
        let d = 3.2 * u
        ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - d / 2, y: pivot.y - d / 2, width: d, height: d)), with: .color(palette.pivot))
    }

    func drawMouth(in ctx: inout GraphicsContext) {
        let c = p(0, 20)
        let open = CGFloat(min(1, max(0, motion.mouth)))
        let speaking = open > 0.04

        if !speaking, body.asleep || expression == .yawn || expression == .surprised || body.airborne {
            let yawn = expression == .yawn
            let gasp = !yawn && !body.asleep
            let breathe = CGFloat(sin(t * 1.3))
            let w = (yawn ? 9 : gasp ? 6 : 3.5 + breathe * 0.6) * u
            let h = (yawn ? 12 : gasp ? 7.5 : 3.5 + breathe * 0.8) * u
            let oval = Path(ellipseIn: CGRect(x: c.x - w / 2, y: c.y - h / 2 + 2 * u, width: w, height: h))
            ctx.fill(oval, with: .color(palette.mouth))
            ctx.stroke(oval, with: .color(palette.line), lineWidth: 1.1 * u)
            return
        }
        let delighted = expression == .happy || expression == .wave || gesture == .celebrate || gesture == .thumbsUp

        if speaking || mood == .announcing || delighted {
            let o = max(open, (mood == .announcing || delighted) ? 0.55 : 0)
            let width = (17 + 3 * o) * u
            let depth = (3 + 10 * o) * u
            var mouth = Path()
            mouth.move(to: CGPoint(x: c.x - width / 2, y: c.y - 1 * u))
            mouth.addQuadCurve(to: CGPoint(x: c.x + width / 2, y: c.y - 1 * u), control: CGPoint(x: c.x, y: c.y + 1.4 * u))
            mouth.addQuadCurve(to: CGPoint(x: c.x - width / 2, y: c.y - 1 * u), control: CGPoint(x: c.x, y: c.y + depth * 1.6))
            mouth.closeSubpath()
            ctx.fill(mouth, with: .color(palette.mouth))
            if o > 0.25 {
                var inner = ctx
                inner.clip(to: mouth)
                inner.fill(Path(ellipseIn: CGRect(x: c.x - 5.5 * u, y: c.y + depth * 0.6, width: 11 * u, height: 8 * u)),
                           with: .color(palette.tongue))
                inner.fill(Path(CGRect(x: c.x - width / 2, y: c.y - 2 * u, width: width, height: 2.6 * u)),
                           with: .color(.white.opacity(skin == .hologram ? 0.6 : 0.9)))
            }
            ctx.stroke(mouth, with: .color(palette.line), style: StrokeStyle(lineWidth: 1.3 * u, lineJoin: .round))
            return
        }

        var path = Path()
        let mouthMood: CharacterMood = gesture == .shrug ? .concerned : (gesture == .think ? .thinking : mood)
        switch mouthMood {
        case .thinking:
            // Pursed, off to one side.
            path.move(to: CGPoint(x: c.x - 1 * u, y: c.y + 1 * u))
            path.addQuadCurve(to: CGPoint(x: c.x + 7 * u, y: c.y - 0.5 * u), control: CGPoint(x: c.x + 3 * u, y: c.y + 2.5 * u))
        case .concerned:
            path.move(to: CGPoint(x: c.x - 7 * u, y: c.y + 3 * u))
            path.addQuadCurve(to: CGPoint(x: c.x + 7 * u, y: c.y + 3 * u), control: CGPoint(x: c.x, y: c.y - 2.5 * u))
        case .listening:
            let d = 4.5 * u
            path.addEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2 + 1 * u, width: d, height: d * 1.15))
            ctx.fill(path, with: .color(palette.mouth))
        default:
            // Big friendly smile with dimples.
            path.move(to: CGPoint(x: c.x - 10 * u, y: c.y - 2 * u))
            path.addQuadCurve(to: CGPoint(x: c.x + 10 * u, y: c.y - 2 * u), control: CGPoint(x: c.x, y: c.y + 9 * u))
            for side in [CGFloat(-1), 1] {
                path.move(to: CGPoint(x: c.x + side * 11.2 * u, y: c.y - 3.6 * u))
                path.addQuadCurve(to: CGPoint(x: c.x + side * 9.4 * u, y: c.y - 0.8 * u),
                                  control: CGPoint(x: c.x + side * 11.4 * u, y: c.y - 1.6 * u))
            }
        }
        ctx.stroke(path, with: .color(palette.line), style: StrokeStyle(lineWidth: 1.7 * u, lineCap: .round))
    }

    func drawArm(in ctx: inout GraphicsContext, shoulder: CGPoint, elbow: CGPoint, hand: CGPoint, side: CGFloat, shape: GloveShape = .open) {
        let e = p(elbow.x, elbow.y), h = p(hand.x, hand.y)
        var arm = Path()
        arm.move(to: shoulder)
        arm.addQuadCurve(to: h, control: e)
        strokeLimb(arm, in: &ctx, width: 3.2)
        let angle = atan2(h.y - e.y, h.x - e.x)
        switch shape {
        case .open: drawGlove(in: &ctx, at: h, pointing: angle, side: side)
        case .point, .thumbsUp: drawFist(in: &ctx, at: h, pointing: angle, side: side, thumbUp: shape == .thumbsUp)
        }
    }

    /// Rubber-hose limb; the classic skin gets a warm rim so dark limbs read on dark desktops.
    func strokeLimb(_ path: Path, in ctx: inout GraphicsContext, width: CGFloat) {
        if skin == .classic {
            ctx.stroke(path, with: .color(Color(hex: 0xFFB066).opacity(0.75)),
                       style: StrokeStyle(lineWidth: (width + 1.8) * u, lineCap: .round))
        }
        ctx.stroke(path, with: .color(palette.limb), style: StrokeStyle(lineWidth: width * u, lineCap: .round))
    }

    func drawGlove(in ctx: inout GraphicsContext, at point: CGPoint, pointing angle: CGFloat, side: CGFloat) {
        var g = ctx
        g.translateBy(x: point.x, y: point.y)
        g.rotate(by: .radians(Double(angle)))
        g.scaleBy(x: 1.4, y: 1.4)
        // Cuff
        let cuff = Path(roundedRect: CGRect(x: -3.2 * u, y: -4.4 * u, width: 3.4 * u, height: 8.8 * u), cornerRadius: 1.4 * u)
        // Palm + three fingers + thumb
        var glove = Path(ellipseIn: CGRect(x: -0.5 * u, y: -4.6 * u, width: 9 * u, height: 9.2 * u))
        for i in 0..<3 {
            let y = (-3.6 + CGFloat(i) * 2.9) * u
            glove.addEllipse(in: CGRect(x: 6.2 * u, y: y - 1.5 * u, width: 4.6 * u, height: 3.1 * u))
        }
        glove.addEllipse(in: CGRect(x: 2.5 * u, y: (side > 0 ? -7.4 : 3.6) * u, width: 3.6 * u, height: 4 * u))
        g.fill(glove, with: .color(palette.glove))
        g.stroke(glove, with: .color(palette.gloveLine), lineWidth: 0.9 * u)
        g.fill(cuff, with: .color(palette.glove))
        g.stroke(cuff, with: .color(palette.gloveLine), lineWidth: 0.9 * u)
        // Classic three stitch lines on the back of the glove.
        for i in 0..<2 {
            var stitch = Path()
            let y = (-1.4 + CGFloat(i) * 2.8) * u
            stitch.move(to: CGPoint(x: 1.8 * u, y: y))
            stitch.addLine(to: CGPoint(x: 4.6 * u, y: y))
            g.stroke(stitch, with: .color(palette.gloveLine.opacity(0.7)), lineWidth: 0.7 * u)
        }
    }

    /// A gloved fist with the index finger out (pointing) or the thumb up (approval).
    func drawFist(in ctx: inout GraphicsContext, at point: CGPoint, pointing angle: CGFloat, side: CGFloat, thumbUp: Bool) {
        var g = ctx
        g.translateBy(x: point.x, y: point.y)
        g.rotate(by: .radians(Double(angle)))
        g.scaleBy(x: 1.4, y: 1.4)
        let cuff = Path(roundedRect: CGRect(x: -3.2 * u, y: -4.4 * u, width: 3.4 * u, height: 8.8 * u), cornerRadius: 1.4 * u)
        var fist = Path(ellipseIn: CGRect(x: -0.5 * u, y: -4.4 * u, width: 9 * u, height: 8.8 * u))
        // Curled knuckles.
        for i in 0..<3 {
            let y = (-2.9 + CGFloat(i) * 2.9) * u
            fist.addEllipse(in: CGRect(x: 6 * u, y: y - 1.4 * u, width: 3.4 * u, height: 2.8 * u))
        }
        func finger(from start: CGPoint, toward dir: CGPoint, length: CGFloat) {
            var f = Path()
            f.move(to: start)
            f.addLine(to: CGPoint(x: start.x + dir.x * length * u, y: start.y + dir.y * length * u))
            g.stroke(f, with: .color(palette.gloveLine), style: StrokeStyle(lineWidth: 4.2 * u, lineCap: .round))
            g.stroke(f, with: .color(palette.glove), style: StrokeStyle(lineWidth: 2.6 * u, lineCap: .round))
        }
        g.fill(fist, with: .color(palette.glove))
        g.stroke(fist, with: .color(palette.gloveLine), lineWidth: 0.9 * u)
        if thumbUp {
            // Thumb straight up on screen, whichever way the arm is turned (undo the glove's rotation).
            let up = CGPoint(x: -sin(angle), y: -cos(angle))
            finger(from: CGPoint(x: 3.5 * u, y: 0), toward: up, length: 7.5)
        } else {
            finger(from: CGPoint(x: 7 * u, y: -2.6 * u), toward: CGPoint(x: 1, y: 0), length: 7)
            g.fill(Path(ellipseIn: CGRect(x: 2.5 * u, y: (side > 0 ? -6.6 : 3) * u, width: 3.4 * u, height: 3.6 * u)), with: .color(palette.glove))
        }
        g.fill(cuff, with: .color(palette.glove))
        g.stroke(cuff, with: .color(palette.gloveLine), lineWidth: 0.9 * u)
    }

    // MARK: Auras, teleport, hover

    var auraColor: Color {
        BodyDirector.auraColor(aura, look: body.look.target).map { Color(hex: $0) } ?? .clear
    }

    /// Glow behind her clock face (drawn in face units, before the body).
    func drawAuraBehind(in ctx: inout GraphicsContext) {
        guard aura != .none else { return }
        let pulse = 0.5 + 0.5 * sin(t * (aura == .alert ? 12 : 4))
        let radius: CGFloat = (aura == .celebrating ? 58 : 50) * u
        var glow = ctx
        glow.addFilter(.blur(radius: 9 * u))
        glow.fill(Path(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)),
                  with: .radialGradient(Gradient(colors: [auraColor.opacity(0.55 * pulse + 0.2), auraColor.opacity(0)]),
                                        center: .zero, startRadius: 30 * u, endRadius: radius))
    }

    /// The parts of the look drawn over her: the processing halo, `</>` while focused, celebration sparkles.
    func drawAuraFront(in ctx: inout GraphicsContext) {
        switch aura {
        case .processing:
            // A dashed halo ring turning around the rim, like a loading dial.
            var ring = Path()
            ring.addArc(center: .zero, radius: 45 * u, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            let phase = CGFloat(t * 40).truncatingRemainder(dividingBy: 100)
            ctx.stroke(ring, with: .color(auraColor.opacity(0.75 + 0.2 * sin(t * 4))),
                       style: StrokeStyle(lineWidth: 1.6 * u, lineCap: .round, dash: [6 * u, 5 * u], dashPhase: phase * u))
        case .focused:
            let bob = CGFloat(sin(t * 2)) * 2
            ctx.draw(Text("</>").font(.system(size: 9 * u, weight: .heavy, design: .monospaced))
                        .foregroundColor(auraColor.opacity(0.9)),
                     at: p(-42, -44 + bob))
        case .celebrating:
            for i in 0..<5 {
                let a = t * 1.6 + Double(i) * 1.2566
                let r = 52 + 4 * sin(t * 5 + Double(i))
                drawSparkle(in: &ctx, at: p(CGFloat(cos(a) * r), CGFloat(sin(a) * r)), size: 3 + 1.5 * CGFloat(sin(t * 8 + Double(i))))
            }
        case .alert:
            var ring = Path()
            let grow = CGFloat((t * 2).truncatingRemainder(dividingBy: 1))
            ring.addArc(center: .zero, radius: (42 + grow * 14) * u, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            ctx.stroke(ring, with: .color(auraColor.opacity(0.8 * (1 - Double(grow)))), lineWidth: 1.8 * u)
        case .none:
            break
        }
    }

    func drawSparkle(in ctx: inout GraphicsContext, at c: CGPoint, size: CGFloat, color: Color = Color(hex: 0xFFF1C2)) {
        var star = Path()
        let s = size * u
        star.move(to: CGPoint(x: c.x, y: c.y - s))
        star.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: c)
        star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: c)
        star.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: c)
        star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: c)
        ctx.fill(star, with: .color(color))
    }

    // MARK: Outfits

    /// Parts of the outfit behind her: sun rays, Loki horns.
    func drawOutfitBehind(in ctx: inout GraphicsContext) {
        let sunny = weight(of: .sunny)
        if sunny > 0.01 {
            var rays = Path()
            let spin = t * 0.35
            for i in 0..<12 {
                let a = spin + Double(i) * .pi / 6
                let outer = 58 + 4 * sin(t * 2.2 + Double(i))
                func at(_ r: Double, _ angle: Double) -> CGPoint { p(CGFloat(cos(angle) * r), CGFloat(sin(angle) * r)) }
                rays.move(to: at(43, a - 0.13))
                rays.addLine(to: at(outer, a))
                rays.addLine(to: at(43, a + 0.13))
                rays.closeSubpath()
            }
            var layer = ctx
            layer.opacity = sunny
            layer.addFilter(.shadow(color: Color(hex: 0xFFC93C).opacity(0.8), radius: 4 * u))
            layer.fill(rays, with: .radialGradient(
                Gradient(colors: [Color(hex: 0xFFE27A).opacity(0.95), Color(hex: 0xFFB020).opacity(0.25)]),
                center: .zero, startRadius: 42 * u, endRadius: 62 * u))
        }

        let variant = weight(of: .variant)
        if variant > 0.01 {
            var layer = ctx
            layer.opacity = variant
            for side in [CGFloat(-1), 1] {
                // Swept back and up, the way Loki wears them. The base hides behind her rim.
                var horn = Path()
                horn.move(to: p(28 * side, -26))
                horn.addQuadCurve(to: p(41 * side, -57), control: p(50 * side, -36))
                horn.addQuadCurve(to: p(12 * side, -33), control: p(30 * side, -44))
                horn.closeSubpath()
                layer.fill(horn, with: .linearGradient(
                    Gradient(colors: [Color(hex: 0xFFE98A), Color(hex: 0xD4A017)]),
                    startPoint: p(41 * side, -57), endPoint: p(20 * side, -30)))
                layer.stroke(horn, with: .color(skin == .hologram ? Color(hex: 0xFFF3C4) : Color(hex: 0x6B4E0A)),
                             lineWidth: 1.1 * u)
            }
        }
    }

    /// Parts of the outfit over her: the night sky, the bow tie.
    func drawOutfitFront(in ctx: inout GraphicsContext) {
        let night = weight(of: .night)
        if night > 0.01 {
            var layer = ctx
            layer.opacity = night
            let c = p(-42, -42), r = 8 * u
            let moon = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                .subtracting(Path(ellipseIn: CGRect(x: c.x - r + 4.5 * u, y: c.y - r - 2.5 * u, width: 2 * r, height: 2 * r)))
            layer.addFilter(.shadow(color: Color(hex: 0xC9B6FF).opacity(0.9), radius: 3 * u))
            layer.fill(moon, with: .color(Color(hex: 0xF4EEFF)))
            let stars: [(CGFloat, CGFloat, Double)] = [(-26, -56, 0), (44, -36, 1.7), (50, 8, 3.1), (-52, -10, 4.4)]
            for (x, y, phase) in stars {
                let twinkle = 0.5 + 0.5 * sin(t * 2.6 + phase)
                drawSparkle(in: &layer, at: p(x, y), size: 1.6 + 1.6 * CGFloat(twinkle),
                            color: Color(hex: 0xE9E2FF).opacity(0.35 + 0.65 * twinkle))
            }
        }

        let formal = weight(of: .tvaFormal)
        if formal > 0.01 {
            var layer = ctx
            layer.opacity = formal
            let c = p(0, 42)
            var bow = Path()
            for side in [CGFloat(-1), 1] {
                bow.move(to: c)
                bow.addLine(to: CGPoint(x: c.x + 11 * u * side, y: c.y - 5.5 * u))
                bow.addQuadCurve(to: CGPoint(x: c.x + 11 * u * side, y: c.y + 5.5 * u),
                                 control: CGPoint(x: c.x + 13 * u * side, y: c.y))
                bow.closeSubpath()
            }
            let tie = skin == .hologram ? Color(hex: 0xFFE0B8).opacity(0.9) : Color(hex: 0x5A1F08)
            layer.fill(bow, with: .color(tie))
            layer.stroke(bow, with: .color(palette.rimStroke), style: StrokeStyle(lineWidth: 1 * u, lineJoin: .round))
            let knot = Path(roundedRect: CGRect(x: c.x - 3 * u, y: c.y - 3.5 * u, width: 6 * u, height: 7 * u), cornerRadius: 1.8 * u)
            layer.fill(knot, with: .color(tie))
            layer.stroke(knot, with: .color(palette.rimStroke), lineWidth: 1 * u)
        }
    }

    /// Sparkles swirling around her while she spins into a new outfit (in the new outfit's colors).
    func drawTwirlSwirl(in ctx: inout GraphicsContext, progress e: Double) {
        let fade = sin(e * .pi)
        for i in 0..<8 {
            let a = e * 2 * .pi * 1.5 + Double(i) * .pi / 4
            let r = 46 + 10 * e
            let pos = p(CGFloat(cos(a) * r), CGFloat(sin(a) * r * 0.55 + 10 - 30 * e))
            drawSparkle(in: &ctx, at: pos, size: 2.2 + 1.6 * CGFloat(fade),
                        color: (i.isMultiple(of: 2) ? palette.glow : Color(hex: 0xFFF1C2)).opacity(fade))
        }
    }

    /// Thinking it over: three dots rising to a little bubble with an ellipsis.
    func drawThoughtBubble(in ctx: inout GraphicsContext) {
        let color = Color(hex: 0xFFE7C2).opacity(0.92)
        for (i, d) in [(0, 2.6), (1, 3.8)] as [(Int, CGFloat)] {
            let pos = p(34 + CGFloat(i) * 6, -40 - CGFloat(i) * 7)
            ctx.fill(Path(ellipseIn: CGRect(x: pos.x - d * u / 2, y: pos.y - d * u / 2, width: d * u, height: d * u)), with: .color(color))
        }
        let bubble = CGRect(x: 38 * u, y: -60 * u, width: 26 * u, height: 14 * u)
        ctx.fill(Path(roundedRect: bubble, cornerRadius: 7.5 * u), with: .color(color))
        for i in 0..<3 {
            let lit = Int(t * 3) % 3 == i
            let d: CGFloat = (lit ? 3.4 : 2.6) * u
            let x = bubble.minX + (6.5 + CGFloat(i) * 6.5) * u
            ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: bubble.midY - d / 2, width: d, height: d)),
                     with: .color(palette.rimBottom.opacity(lit ? 1 : 0.6)))
        }
    }

    /// Confetti showering down while she celebrates.
    func drawConfetti(in ctx: inout GraphicsContext) {
        let colors: [Color] = [Color(hex: 0xFFE27A), Color(hex: 0xFF8A26), .white, Color(hex: 0x7FE7FF), Color(hex: 0xFF6B6B)]
        let elapsed = gestureElapsed
        for i in 0..<16 {
            let seed = Double(i) * 12.9898
            let x = CGFloat((sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)) * 70
            let speed = 40 + abs(sin(seed * 1.7)) * 30
            let y = -70 + CGFloat((elapsed * speed + abs(sin(seed * 3.1)) * 40).truncatingRemainder(dividingBy: 130))
            let spin = Angle.radians(elapsed * 6 + seed)
            var piece = ctx
            piece.translateBy(x: x * u, y: y * u)
            piece.rotate(by: spin)
            piece.fill(Path(CGRect(x: -1.6 * u, y: -0.9 * u, width: 3.2 * u, height: 1.8 * u)), with: .color(colors[i % colors.count]))
        }
    }

    /// A TVA time door: it opens, she's squeezed into it, her window jumps, and she steps out the other side.
    /// Leaves `context` set up so the character is drawn squeezed and faded to match.
    func drawTeleport(in context: inout GraphicsContext, progress p: Double) {
        let jump = BodyState.teleportJumpAt
        let leaving = p < jump
        let q = leaving ? p / jump : (p - jump) / (1 - jump)
        let open = leaving ? min(1, q * 2.4) : max(0, 1 - max(0, q - 0.45) * 1.8)
        let squeeze = leaving ? CGFloat(1 - q * q) : CGFloat(sqrt(q))

        let doorCenter = CGPoint(x: canvas.width / 2, y: canvas.height * 0.5)
        let w = 64 * u * CGFloat(open), h = 120 * u
        // A zero-width door would fill the whole canvas with its gradient.
        if open > 0.01 {
            let door = Path(ellipseIn: CGRect(x: doorCenter.x - w / 2, y: doorCenter.y - h / 2, width: w, height: h))
            var glow = context
            glow.addFilter(.blur(radius: 8 * u))
            glow.fill(door, with: .color(palette.glow.opacity(0.8 * open)))
            let rim = MinutePalette.forLook(body.look.target, skin: .classic)
            context.fill(door, with: .radialGradient(
                Gradient(colors: [Color(hex: 0xFFF1DC).opacity(0.95), rim.rimTop.opacity(0.85), rim.rimBottom.opacity(0.7)]),
                center: doorCenter, startRadius: 0, endRadius: max(1, h / 2)))
            context.stroke(door, with: .color(Color(hex: 0xFFE0B8).opacity(open)), lineWidth: 1.6 * u)
        }
        // Sparks thrown off as she passes through.
        for i in 0..<10 {
            let a = Double(i) * 0.628 + p * 4
            let r = (20 + 45 * q) * Double(u)
            let pos = CGPoint(x: doorCenter.x + CGFloat(cos(a) * r), y: doorCenter.y + CGFloat(sin(a) * r * 1.4))
            let d = 2.4 * u * CGFloat(1 - q)
            context.fill(Path(ellipseIn: CGRect(x: pos.x - d / 2, y: pos.y - d / 2, width: d, height: d)),
                         with: .color(Color(hex: 0xFFE0B8).opacity(1 - q)))
        }
        context.translateBy(x: canvas.width / 2, y: center.y)
        context.scaleBy(x: max(0.02, squeeze), y: 1 + (1 - squeeze) * 0.18)
        context.translateBy(x: -canvas.width / 2, y: -center.y)
        context.opacity = 0.35 + 0.65 * Double(squeeze)
    }

    /// A soft glow under her feet while she floats.
    func drawHoverGlow(in context: inout GraphicsContext) {
        let y = canvas.height * 0.41 + 70 * u
        let w = (34 + bob * 1.2) * u
        var glow = context
        glow.addFilter(.blur(radius: 5 * u))
        glow.fill(Path(ellipseIn: CGRect(x: canvas.width / 2 - w / 2, y: y - 3 * u, width: w, height: 6 * u)),
                  with: .color(hologramGlow.opacity(0.45)))
    }

    func drawMoodAccents(in ctx: inout GraphicsContext) {
        switch mood {
        case .thinking, .working:
            // Orbiting tick marks above her head.
            for i in 0..<3 {
                let a = t * 2.6 + Double(i) * 2.1
                let pos = p(40 + CGFloat(cos(a)) * 9, -46 + CGFloat(sin(a)) * 5)
                let s = (2.2 + 0.8 * sin(a)) * u
                ctx.fill(Path(ellipseIn: CGRect(x: pos.x - s / 2, y: pos.y - s / 2, width: s, height: s)),
                         with: .color(palette.accent.opacity(0.9)))
            }
        case .listening:
            // Sound waves coming into her "ear".
            for i in 0..<3 {
                let phase = (t * 1.6 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                var wave = Path()
                wave.addArc(center: p(-44, -14), radius: (8 + CGFloat(phase) * 14) * u,
                            startAngle: .degrees(150), endAngle: .degrees(210), clockwise: false)
                ctx.stroke(wave, with: .color(palette.accent.opacity(0.85 * (1 - phase))),
                           style: StrokeStyle(lineWidth: 1.4 * u, lineCap: .round))
            }
        case .announcing:
            // Sparkle by the waving hand.
            let s = CGFloat(0.6 + 0.4 * sin(t * 9))
            let c = p(motion.rightHand.x + 9, motion.rightHand.y - 10)
            var star = Path()
            star.move(to: CGPoint(x: c.x, y: c.y - 4 * u * s))
            star.addLine(to: CGPoint(x: c.x, y: c.y + 4 * u * s))
            star.move(to: CGPoint(x: c.x - 4 * u * s, y: c.y))
            star.addLine(to: CGPoint(x: c.x + 4 * u * s, y: c.y))
            ctx.stroke(star, with: .color(Color(hex: 0xFFE7C2)), style: StrokeStyle(lineWidth: 1.2 * u, lineCap: .round))
        default:
            break
        }
    }
}
