import Foundation

/// Per-line delivery so she doesn't sound monotone: excited lines a touch faster and brighter, questions lift,
/// thoughtful lines slow down, plus a small natural wobble between lines. Engines apply what they support
/// (`say` honours rate only; Apple voices rate and pitch; Kokoro and ElevenLabs speed).
public struct Prosody: Sendable, Equatable {
    /// Speaking-rate multiplier (1 = the user's chosen pace).
    public var rate: Double
    /// Pitch multiplier (1 = the voice's natural pitch).
    public var pitch: Double

    public static let neutral = Prosody(rate: 1, pitch: 1)

    public init(rate: Double, pitch: Double) {
        self.rate = rate
        self.pitch = pitch
    }

    /// - Parameters:
    ///   - index: the line's position in the reply (varies the wobble from line to line).
    ///   - expressiveness: 0 = flat and even, 1 = very animated.
    public static func forLine(_ text: String, index: Int, expressiveness: Double) -> Prosody {
        let e = min(max(expressiveness, 0), 1)
        guard e > 0 else { return .neutral }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        var rate = 1.0
        var pitch = 1.0

        if trimmed.hasSuffix("!") {
            rate += 0.07 * e
            pitch += 0.09 * e
        } else if trimmed.hasSuffix("?") {
            rate -= 0.02 * e
            pitch += 0.07 * e
        }
        let thoughtful = ["hmm", "well,", "so,", "oh,", "honestly", "i think", "maybe"]
        if trimmed.contains("…") || trimmed.contains("...") || thoughtful.contains(where: lower.hasPrefix) {
            rate -= 0.08 * e
            pitch -= 0.03 * e
        }
        let excited = ["yay", "woo", "great", "awesome", "congrat", "love", "amazing", "nice"]
        if excited.contains(where: lower.contains) {
            pitch += 0.04 * e
        }
        // Short asides land quicker; long explanations settle into a steadier pace.
        if trimmed.count < 24 { rate += 0.03 * e }
        if trimmed.count > 140 { rate -= 0.03 * e }

        // Deterministic wobble so the same reply sounds the same, but neighbouring lines differ.
        let seed = trimmed.unicodeScalars.reduce(UInt32(truncatingIfNeeded: index &* 2_654_435_761)) { ($0 &* 31) &+ $1.value }
        let wobbleRate = (Double(seed % 1_000) / 1_000 - 0.5) * 0.08 * e
        let wobblePitch = (Double((seed / 1_000) % 1_000) / 1_000 - 0.5) * 0.10 * e
        rate += wobbleRate
        pitch += wobblePitch

        return Prosody(rate: min(max(rate, 0.85), 1.18), pitch: min(max(pitch, 0.88), 1.2))
    }
}
