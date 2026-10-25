import Foundation

/// How Miss Minute should come across right now.
public enum MoodTone: String, Sendable, Equatable, CaseIterable {
    /// Neutral: her usual sunny self.
    case steady
    /// The user seems stressed or frustrated: calm, patient, very little sass.
    case gentle
    /// The user is on a roll: bubbly, celebratory, extra charm.
    case upbeat
    /// Tired or late: soft and low-key, no extra work piled on.
    case cozy

    /// 0 = no sass at all, 1 = full sass. Read by the body (expressions, remarks) and the voice.
    public var sass: Double {
        switch self {
        case .gentle: return 0.1
        case .cozy: return 0.3
        case .steady: return 0.55
        case .upbeat: return 0.85
        }
    }

    /// Delivery nudges on top of each line's prosody: calmer and slower when they're stressed, brighter on wins.
    public var prosodyBias: Prosody {
        switch self {
        case .gentle: return Prosody(rate: 0.95, pitch: 0.97)
        case .cozy: return Prosody(rate: 0.94, pitch: 0.96)
        case .steady: return .neutral
        case .upbeat: return Prosody(rate: 1.04, pitch: 1.05)
        }
    }

    /// Line for the context block, telling the model how to pitch its reply.
    public var guidance: String? {
        switch self {
        case .steady:
            return nil
        case .gentle:
            return "They seem stressed or frustrated right now. Dial the sass way down: calm, warm, patient, and brief. Acknowledge it in a few words if it fits, then just help. No jokes at their expense, no pep-talk speeches."
        case .upbeat:
            return "They're on a roll / just had a win. Be extra bubbly: celebrate it, turn up the Southern charm and playful sass."
        case .cozy:
            return "They've been at it a long time or it's late. Keep it soft and low-key; suggest wrapping up or a break only if it fits."
        }
    }
}

/// A read on how the user is doing, built from what they type or say and what's happening on the Mac.
/// Signals fade back to neutral over time (half-life ~20 minutes), so one grumpy message doesn't stick all day.
public struct MoodTracker: Sendable, Equatable {
    public enum Signal: Sendable, Equatable {
        /// They seem stuck on something (an error, the same screen for ages).
        case stuck
        case taskCompleted
        case taskOverdue
        /// A long job (build, test run) finished.
        case jobFinished
        /// They stepped away for a while.
        case breakTaken
    }

    public private(set) var stress: Double = 0
    public private(set) var cheer: Double = 0
    private var updatedAt: Date
    public var halfLife: TimeInterval

    public init(now: Date = Date(), halfLife: TimeInterval = 20 * 60) {
        updatedAt = now
        self.halfLife = halfLife
    }

    public mutating func observeUserText(_ text: String, at now: Date = Date()) {
        decay(to: now)
        let read = Self.sentiment(of: text)
        stress = min(1, stress + read.stress)
        cheer = min(1, cheer + read.cheer)
        // Good news takes the edge off, and vice versa.
        if read.cheer > 0 { stress = max(0, stress - read.cheer * 0.6) }
        if read.stress > 0 { cheer = max(0, cheer - read.stress * 0.6) }
    }

    public mutating func observe(_ signal: Signal, at now: Date = Date()) {
        decay(to: now)
        switch signal {
        case .stuck:
            stress = min(1, stress + 0.25)
        case .taskOverdue:
            stress = min(1, stress + 0.1)
        case .taskCompleted:
            cheer = min(1, cheer + 0.3)
            stress = max(0, stress - 0.15)
        case .jobFinished:
            cheer = min(1, cheer + 0.1)
        case .breakTaken:
            stress *= 0.5
        }
    }

    /// The tone to use now. `activeMinutes` (time without a break) and the hour feed a fatigue estimate.
    public func tone(at now: Date = Date(), activeMinutes: Int = 0, calendar: Calendar = .current) -> MoodTone {
        let (s, c) = decayed(to: now)
        if s >= 0.4 { return .gentle }
        if Self.fatigue(activeMinutes: activeMinutes, hour: calendar.component(.hour, from: now)) >= 0.6 { return .cozy }
        if c >= 0.35 { return .upbeat }
        return .steady
    }

    public func isStressed(at now: Date = Date()) -> Bool {
        decayed(to: now).stress >= 0.4
    }

    /// 0…1: long stretches without a break and late hours both wear people down.
    public static func fatigue(activeMinutes: Int, hour: Int) -> Double {
        let stretch = min(1, Double(max(0, activeMinutes - 60)) / 120)
        let late: Double
        switch hour {
        case 23, 0...4: late = 0.6
        case 22: late = 0.3
        default: late = 0
        }
        return min(1, stretch + late)
    }

    // MARK: - Reading text

    private static let stressPhrases = [
        "not working", "doesn't work", "does not work", "isn't working", "won't work", "still broken", "keeps failing",
        "keeps crashing", "why won't", "why does it", "what the", "i give up", "so tired", "exhausted", "overwhelmed",
        "stressed", "frustrated", "annoying", "annoyed", "deadline", "running late", "behind on", "ugh", "argh",
        "stuck", "broken", "hate", "help me", "wtf", "ffs", "damn", "dammit", "shit", "fuck", "screwed", "nightmare",
        "again?!", "panic", "freaking out", "sigh"
    ]
    private static let cheerPhrases = [
        "it works", "it worked", "works now", "finally", "yay", "woo", "woohoo", "awesome", "amazing", "nailed it",
        "shipped", "we did it", "did it", "got it working", "love it", "love you", "thank you", "thanks", "perfect",
        "great job", "nice", "excellent", "brilliant", "fantastic", "so happy", "excited", "celebrate", "promoted",
        "passed", "lol", "haha", ":)", ":d", "🎉", "😄", "😊", "🥳", "❤️"
    ]

    /// How much stress and cheer one message carries (each 0…~0.8).
    public static func sentiment(of text: String) -> (stress: Double, cheer: Double) {
        let lower = " " + text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
        func hits(_ phrases: [String]) -> Int {
            phrases.filter { phrase in
                // Whole-word match for plain words; emoji and punctuation phrases match anywhere.
                guard phrase.first?.isLetter == true else { return lower.contains(phrase) }
                return lower.range(of: "(?<![a-z])\(NSRegularExpression.escapedPattern(for: phrase))(?![a-z])", options: .regularExpression) != nil
            }.count
        }
        var stress = Double(hits(stressPhrases)) * 0.22
        var cheer = Double(hits(cheerPhrases)) * 0.18

        let words = text.split(whereSeparator: { !$0.isLetter })
        let shouted = words.filter { $0.count >= 3 && $0.allSatisfy(\.isUppercase) }.count
        let exclaims = text.filter { $0 == "!" }.count
        let doubleQuestion = text.contains("??") || text.contains("?!")
        // Intensity amplifies whichever way the message already leans.
        if shouted >= 2 || exclaims >= 3 || doubleQuestion {
            if stress >= cheer, stress > 0 || doubleQuestion { stress += 0.2 } else { cheer += 0.15 }
        }
        return (min(0.8, stress), min(0.8, cheer))
    }

    // MARK: - Decay

    private mutating func decay(to now: Date) {
        (stress, cheer) = decayed(to: now)
        updatedAt = max(updatedAt, now)
    }

    private func decayed(to now: Date) -> (stress: Double, cheer: Double) {
        let elapsed = max(0, now.timeIntervalSince(updatedAt))
        let factor = pow(0.5, elapsed / max(1, halfLife))
        return (stress * factor, cheer * factor)
    }
}
