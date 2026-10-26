import Foundation

/// An outfit she wears: colors, glow, and a signature accessory. Chosen by the user (or by her when asked),
/// and kept until changed. Independent of what she's doing: task glows (`BodyAura`) are drawn on top of it.
public enum AvatarLook: String, Codable, CaseIterable, Sendable, Identifiable {
    /// TVA orange, the way she looks in the show.
    case signature
    /// Deep purple glow, a crescent moon and twinkling stars.
    case night
    /// Warm gold with sun rays turning behind her.
    case sunny
    /// Muted TVA amber, a bow tie, and a steady (no-glitch) projection.
    case tvaFormal
    /// Loki green and gold, with little golden horns.
    case variant

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .signature: return "Signature"
        case .night: return "Night"
        case .sunny: return "Sunny"
        case .tvaFormal: return "TVA Formal"
        case .variant: return "Variant"
        }
    }

    public var summary: String {
        switch self {
        case .signature: return "classic TVA orange"
        case .night: return "a deep purple glow with a crescent moon and stars"
        case .sunny: return "warm gold with sun rays behind her"
        case .tvaFormal: return "muted TVA amber with a bow tie and a steady, glitch-free projection"
        case .variant: return "Loki green and gold with little golden horns"
        }
    }

    /// Words people use for each look ("your night look", "go formal", "back to normal").
    var aliases: [String] {
        switch self {
        case .signature: return ["signature", "default", "normal", "usual", "regular", "original", "orange", "standard", "classic look", "reset"]
        case .night: return ["night", "nighttime", "midnight", "purple", "moon", "moonlight", "evening", "dark look"]
        case .sunny: return ["sunny", "sun", "sunshine", "golden", "gold look", "yellow", "bright", "morning", "summer"]
        case .tvaFormal: return ["tva formal", "formal", "professional", "business", "office", "suit", "bow tie", "bowtie", "fancy", "work look"]
        case .variant: return ["variant", "loki", "green", "horns", "horned", "mischief"]
        }
    }

    /// The look a phrase asks for, or nil if it doesn't name one. Accepts raw values ("tvaFormal"),
    /// display names, and casual names ("your night look", "go professional").
    public static func matching(_ phrase: String) -> AvatarLook? {
        let text = phrase.lowercased()
        if let exact = allCases.first(where: { $0.rawValue.lowercased() == text || $0.displayName.lowercased() == text }) {
            return exact
        }
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let joined = " " + words.joined(separator: " ") + " "
        // More specific looks first, so "Loki green and gold" isn't read as sunny.
        for look in [AvatarLook.variant, .tvaFormal, .night, .sunny, .signature] {
            if look.aliases.contains(where: { joined.contains(" \($0) ") }) { return look }
        }
        return nil
    }
}

/// A timed, eased change from one look to another, so palettes and accessories cross-fade instead of popping.
public struct LookTransition: Sendable, Equatable {
    public private(set) var from: AvatarLook
    public private(set) var to: AvatarLook
    public private(set) var start: TimeInterval
    public var duration: TimeInterval

    public static let defaultDuration: TimeInterval = 1.4

    /// Already wearing `look` (no animation).
    public init(settledOn look: AvatarLook, duration: TimeInterval = Self.defaultDuration) {
        from = look
        to = look
        start = 0
        self.duration = duration
    }

    /// The look she's heading to (or wearing).
    public var target: AvatarLook { to }

    /// 0…1, eased (smoothstep), through the change.
    public func progress(at t: TimeInterval) -> Double {
        guard from != to, duration > 0 else { return 1 }
        let x = min(1, max(0, (t - start) / duration))
        return x * x * (3 - 2 * x)
    }

    public func isAnimating(at t: TimeInterval) -> Bool {
        from != to && t - start < duration
    }

    /// How much of `look` is showing right now (0…1). The weights of `from` and `to` always add up to 1.
    public func weight(of look: AvatarLook, at t: TimeInterval) -> Double {
        let p = progress(at: t)
        if from == to { return look == to ? 1 : 0 }
        if look == to { return p }
        if look == from { return 1 - p }
        return 0
    }

    /// Starts heading to `look`. Returns false when she's already wearing (or heading to) it. Changing her
    /// mind mid-change reverses smoothly from wherever the blend is; a third look starts from whichever
    /// look was showing more.
    @discardableResult
    public mutating func retarget(to look: AvatarLook, at t: TimeInterval, animated: Bool = true) -> Bool {
        guard look != to else { return false }
        guard animated else {
            from = look
            to = look
            return true
        }
        if isAnimating(at: t) {
            let linear = min(1, max(0, (t - start) / duration))
            if look == from {
                // Reverse: smoothstep(1 - x) = 1 - smoothstep(x), so the blend carries on from the same spot.
                from = to
                to = look
                start = t - (1 - linear) * duration
                return true
            }
            from = linear >= 0.5 ? to : from
        } else {
            from = to
        }
        to = look
        start = t
        return true
    }
}
