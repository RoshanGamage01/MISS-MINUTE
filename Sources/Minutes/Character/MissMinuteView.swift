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
        facing += (body.facing - facing) * CGFloat(min(1, dt * 6))
        if body.walking { walkPhase += dt * 9 }

        var gazeTarget = rawGaze
        if mood == .thinking { gazeTarget = CGPoint(x: 0.55, y: -0.7) }
        if mood == .working { gazeTarget = CGPoint(x: 0.3 * sin(t * 1.7), y: 0.35) }
        if body.walking { gazeTarget = CGPoint(x: body.facing * 0.9, y: 0.1) }
        if expression == .lookAround { gazeTarget = CGPoint(x: sin(t * 1.9), y: -0.25 + 0.2 * cos(t * 1.3)) }
        gaze = ease(gaze, gazeTarget, rate: 9, dt: dt)
        mouth += (target - mouth) * min(1, dt * 22)

        let pose: Pose
        if body.asleep {
            pose = Pose.sleeping
        } else if body.airborne {
            pose = Pose.airborne
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
    }

    var timeInMood: TimeInterval { lastTime - moodChangedAt }

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

// MARK: - Palette

private struct MinutePalette {
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

private struct MissMinuteRenderer {
    let t: TimeInterval
    let date: Date
    let mood: CharacterMood
    let skin: CharacterSkin
    let hover: Bool
    let motion: MotionState
    let body: BodyState
    let canvas: CGSize

    var expression: BodyState.Expression { body.currentExpression(at: t) }
    var onFloor: Bool { !body.perched && !body.airborne }

    /// One face unit (face radius = 40 units).
    var u: CGFloat { canvas.width / 145 }
    var palette: MinutePalette { skin == .hologram ? .hologram : .classic }
    let hologramGlow = Color(hex: 0xFF8A1E)

    // Body motion
    var bob: CGFloat {
        if body.asleep { return CGFloat(sin(t * 1.3)) * 1.4 + 2 }
        if body.walking { return -abs(CGFloat(sin(motion.walkPhase))) * 3.5 }
        let speed = (mood == .talking || mood == .working) ? 3.4 : 2.1
        let amp: CGFloat = (mood == .announcing) ? 3.2 : 2.0
        return CGFloat(sin(t * speed)) * amp - CGFloat(motion.squash) * 4
    }
    var center: CGPoint { CGPoint(x: canvas.width / 2, y: canvas.height * 0.41 + bob * u) }
    var tilt: Angle {
        let base = sin(t * 0.9) * 2.2
        let talk = mood == .talking ? sin(t * 2.3) * 3 : 0
        let curious = mood == .thinking ? -6.0 : (mood == .listening ? 7.0 : 0)
        let lean = Double(motion.facing) * (body.walking ? 5 : 2)
        let droop = body.asleep ? 9.0 : 0
        return .degrees(base + talk + curious + lean + droop)
    }

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * u, y: y * u)
    }

    mutating func draw(in context: inout GraphicsContext) {
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
                context.addFilter(.shadow(color: Color(hex: 0xFF8A1E).opacity(0.45), radius: 10 * u))
            }
            drawCharacter(in: &context)
        }
    }

    // MARK: Hologram effects

    var glitchActive: Bool {
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
                Gradient(colors: [.clear, Color(hex: 0xFFF1DC).opacity(0.45), .clear]),
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

        drawLegs(in: &ctx)
        drawCrown(in: &ctx)
        drawFace(in: &ctx)
        drawArm(in: &ctx, shoulder: p(-36, 8), elbow: motion.leftElbow, hand: motion.leftHand, side: -1)
        drawArm(in: &ctx, shoulder: p(36, 8), elbow: motion.rightElbow, hand: motion.rightHand, side: 1)
        drawMoodAccents(in: &ctx)
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
            } else if body.perched {
                // Legs dangling over the window edge, swinging.
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
        if body.asleep || expression == .happy || expression == .yawn {
            drawClosedEyes(in: &ctx, happy: expression == .happy && !body.asleep)
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
            let worried = mood == .concerned
            let skeptical = mood == .thinking && side > 0
            var brow = Path()
            let browY = c.y - h / 2 - (4.5 + lift * 2.5 + (skeptical ? 2 : 0)) * u
            let innerY = worried ? browY - 2.2 * u : browY + 0.8 * u
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
        let delighted = expression == .happy || expression == .wave

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
        switch mood {
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

    func drawArm(in ctx: inout GraphicsContext, shoulder: CGPoint, elbow: CGPoint, hand: CGPoint, side: CGFloat) {
        let e = p(elbow.x, elbow.y), h = p(hand.x, hand.y)
        var arm = Path()
        arm.move(to: shoulder)
        arm.addQuadCurve(to: h, control: e)
        strokeLimb(arm, in: &ctx, width: 3.2)
        drawGlove(in: &ctx, at: h, pointing: atan2(h.y - e.y, h.x - e.x), side: side)
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

    func drawMoodAccents(in ctx: inout GraphicsContext) {
        switch mood {
        case .thinking, .working:
            // Orbiting tick marks above her head.
            for i in 0..<3 {
                let a = t * 2.6 + Double(i) * 2.1
                let pos = p(40 + CGFloat(cos(a)) * 9, -46 + CGFloat(sin(a)) * 5)
                let s = (2.2 + 0.8 * sin(a)) * u
                ctx.fill(Path(ellipseIn: CGRect(x: pos.x - s / 2, y: pos.y - s / 2, width: s, height: s)),
                         with: .color(Color(hex: 0xFFB566).opacity(0.9)))
            }
        case .listening:
            // Sound waves coming into her "ear".
            for i in 0..<3 {
                let phase = (t * 1.6 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                var wave = Path()
                wave.addArc(center: p(-44, -14), radius: (8 + CGFloat(phase) * 14) * u,
                            startAngle: .degrees(150), endAngle: .degrees(210), clockwise: false)
                ctx.stroke(wave, with: .color(Color(hex: 0xFFB566).opacity(0.85 * (1 - phase))),
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
