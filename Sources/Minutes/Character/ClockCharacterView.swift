import SwiftUI
import MinutesCore

/// Original cartoon clock character drawn with SwiftUI shapes (not based on any trademarked design).
struct ClockCharacterView: View {
    var mood: CharacterMood
    var size: CGFloat
    var isChatOpen: Bool

    @State private var bounce = false
    @State private var blink = false
    @State private var mouthOpen = false
    @State private var thinkPulse = false
    @State private var minuteAngle: Double = -60
    @State private var hourAngle: Double = 40

    var body: some View {
        ZStack {
            // Soft ground shadow
            Ellipse()
                .fill(Color.black.opacity(0.18))
                .frame(width: size * 0.55, height: size * 0.1)
                .offset(y: size * 0.42)
                .scaleEffect(x: bounce ? 1.05 : 0.95, y: 1)

            characterBody
                .offset(y: bounce ? -4 : 0)
        }
        .frame(width: size, height: size)
        .onAppear { startIdleMotion() }
        .onChange(of: mood) { newMood in
            updateMotion(for: newMood)
        }
        .accessibilityLabel("Minutes, your desktop helper")
        .accessibilityHint("Click to open chat")
    }

    private var characterBody: some View {
        ZStack {
            // Legs
            Capsule()
                .fill(legColor)
                .frame(width: size * 0.08, height: size * 0.18)
                .offset(x: -size * 0.12, y: size * 0.38)
            Capsule()
                .fill(legColor)
                .frame(width: size * 0.08, height: size * 0.18)
                .offset(x: size * 0.12, y: size * 0.38)

            // Shoes
            Capsule()
                .fill(Color(red: 0.45, green: 0.22, blue: 0.12))
                .frame(width: size * 0.14, height: size * 0.06)
                .offset(x: -size * 0.12, y: size * 0.46)
            Capsule()
                .fill(Color(red: 0.45, green: 0.22, blue: 0.12))
                .frame(width: size * 0.14, height: size * 0.06)
                .offset(x: size * 0.12, y: size * 0.46)

            // Arms
            Capsule()
                .fill(armColor)
                .frame(width: size * 0.08, height: size * 0.22)
                .rotationEffect(.degrees(mood == .talking ? -25 : -12))
                .offset(x: -size * 0.38, y: size * 0.05)
            Capsule()
                .fill(armColor)
                .frame(width: size * 0.08, height: size * 0.22)
                .rotationEffect(.degrees(mood == .announcing ? 30 : 14))
                .offset(x: size * 0.38, y: size * 0.05)

            // Clock body
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.92, blue: 0.55),
                            Color(red: 0.95, green: 0.72, blue: 0.22)
                        ],
                        center: .topLeading,
                        startRadius: 4,
                        endRadius: size * 0.55
                    )
                )
                .overlay(
                    Circle()
                        .stroke(Color(red: 0.72, green: 0.45, blue: 0.12), lineWidth: size * 0.045)
                )
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .frame(width: size * 0.72, height: size * 0.72)

            // Tick marks
            ForEach(0..<12, id: \.self) { i in
                Capsule()
                    .fill(Color(red: 0.55, green: 0.32, blue: 0.1).opacity(0.7))
                    .frame(width: size * 0.02, height: size * 0.05)
                    .offset(y: -size * 0.28)
                    .rotationEffect(.degrees(Double(i) * 30))
            }

            // Clock hands
            Capsule()
                .fill(Color(red: 0.25, green: 0.15, blue: 0.08))
                .frame(width: size * 0.03, height: size * 0.16)
                .offset(y: -size * 0.06)
                .rotationEffect(.degrees(hourAngle))
            Capsule()
                .fill(Color(red: 0.35, green: 0.18, blue: 0.08))
                .frame(width: size * 0.025, height: size * 0.22)
                .offset(y: -size * 0.08)
                .rotationEffect(.degrees(minuteAngle))
            Circle()
                .fill(Color(red: 0.7, green: 0.2, blue: 0.15))
                .frame(width: size * 0.05, height: size * 0.05)

            // Eyes
            eye(x: -size * 0.12)
            eye(x: size * 0.12)

            // Mouth
            mouth
                .offset(y: size * 0.18)

            // Thinking dots
            if mood == .thinking {
                HStack(spacing: size * 0.04) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Color(red: 0.95, green: 0.85, blue: 0.4))
                            .frame(width: size * 0.06, height: size * 0.06)
                            .scaleEffect(thinkPulse ? 1.15 : 0.85)
                            .animation(
                                .easeInOut(duration: 0.45)
                                    .repeatForever()
                                    .delay(Double(i) * 0.12),
                                value: thinkPulse
                            )
                    }
                }
                .offset(y: -size * 0.48)
            }

            // Tiny crown sprocket (original flourish, not a logo)
            RoundedRectangle(cornerRadius: size * 0.03)
                .fill(Color(red: 0.85, green: 0.55, blue: 0.18))
                .frame(width: size * 0.18, height: size * 0.08)
                .overlay(
                    Capsule()
                        .fill(Color(red: 0.95, green: 0.75, blue: 0.3))
                        .frame(width: size * 0.08, height: size * 0.1)
                        .offset(y: -size * 0.04)
                )
                .offset(y: -size * 0.38)
        }
    }

    private func eye(x: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(Color.white)
                .frame(width: size * 0.14, height: blink ? size * 0.02 : size * 0.16)
            if !blink {
                Circle()
                    .fill(Color(red: 0.2, green: 0.12, blue: 0.08))
                    .frame(width: size * 0.06, height: size * 0.06)
                    .offset(y: mood == .talking ? 1 : 0)
            }
        }
        .offset(x: x, y: -size * 0.02)
    }

    @ViewBuilder
    private var mouth: some View {
        switch mood {
        case .talking, .announcing:
            Capsule()
                .fill(Color(red: 0.55, green: 0.18, blue: 0.15))
                .frame(width: size * 0.18, height: mouthOpen ? size * 0.1 : size * 0.04)
        case .thinking:
            Capsule()
                .fill(Color(red: 0.45, green: 0.2, blue: 0.12))
                .frame(width: size * 0.1, height: size * 0.03)
        case .idle:
            // Smile
            MinutesSmile()
                .stroke(Color(red: 0.45, green: 0.2, blue: 0.12), style: StrokeStyle(lineWidth: size * 0.025, lineCap: .round))
                .frame(width: size * 0.2, height: size * 0.1)
        }
    }

    private var armColor: Color { Color(red: 0.95, green: 0.78, blue: 0.35) }
    private var legColor: Color { Color(red: 0.9, green: 0.7, blue: 0.28) }

    private func startIdleMotion() {
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            bounce = true
        }
        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
            minuteAngle += 360
        }
        scheduleBlink()
        updateMotion(for: mood)
    }

    private func scheduleBlink() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 2_500_000_000...5_000_000_000))
                blink = true
                try? await Task.sleep(nanoseconds: 120_000_000)
                blink = false
            }
        }
    }

    private func updateMotion(for mood: CharacterMood) {
        switch mood {
        case .talking, .announcing:
            withAnimation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true)) {
                mouthOpen = true
            }
            thinkPulse = false
        case .thinking:
            mouthOpen = false
            thinkPulse = true
        case .idle:
            mouthOpen = false
            thinkPulse = false
        }
        _ = isChatOpen
    }
}

private struct MinutesSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return path
    }
}
