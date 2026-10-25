import AVFoundation
import Combine
import MinutesCore

/// Speaks Minutes' lines with the most natural system voice available.
@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechManager()

    @Published private(set) var isSpeaking = false
    @Published private(set) var availableVoices: [AVSpeechSynthesisVoice] = []

    private let synthesizer = AVSpeechSynthesizer()
    private var settingsProvider: () -> AppSettings = { .default }

    private override init() {
        super.init()
        synthesizer.delegate = self
        refreshVoices()
    }

    func configure(settingsProvider: @escaping () -> AppSettings) {
        self.settingsProvider = settingsProvider
        refreshVoices()
    }

    func refreshVoices() {
        let english = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en")
        }
        availableVoices = english.sorted { lhs, rhs in
            let lq = Self.qualityRank(lhs)
            let rq = Self.qualityRank(rhs)
            if lq != rq { return lq > rq }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func preferredVoice() -> AVSpeechSynthesisVoice? {
        let settings = settingsProvider()
        if !settings.voiceIdentifier.isEmpty,
           let exact = AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier) {
            return exact
        }
        return pickNaturalVoice()
    }

    func speak(_ text: String) {
        let settings = settingsProvider()
        guard settings.voiceEnabled else { return }
        let cleaned = Self.spokenForm(text)
        guard !cleaned.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = preferredVoice()
        // Map 0.35...0.7 UI rate toward a natural conversational pace.
        let rate = Float(min(max(settings.speechRate, 0.35), 0.7))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (0.85 + (rate - 0.5))
        utterance.pitchMultiplier = 1.05
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.05
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func previewCurrentVoice() {
        speak("Howdy — I'm Minutes, keepin' time on your Mac.")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    private func pickNaturalVoice() -> AVSpeechSynthesisVoice? {
        let voices = availableVoices.isEmpty
            ? AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            : availableVoices

        // Prefer premium/enhanced US voices; fall back gracefully.
        let preferredNames = ["Nora", "Samantha", "Ava", "Allison", "Susan", "Zoe", "Nicky"]
        for name in preferredNames {
            if let match = voices.first(where: {
                $0.name.localizedCaseInsensitiveContains(name) && Self.qualityRank($0) >= 2
            }) {
                return match
            }
        }
        if let premium = voices.first(where: { Self.qualityRank($0) >= 3 && $0.language.hasPrefix("en-US") }) {
            return premium
        }
        if let enhanced = voices.first(where: { Self.qualityRank($0) >= 2 && $0.language.hasPrefix("en-US") }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: "en-US") ?? voices.first
    }

    private static func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    /// Strip markdown-ish noise so TTS sounds natural.
    private static func spokenForm(_ text: String) -> String {
        var s = text
        let patterns = [
            #"\*\*(.+?)\*\*"#,
            #"\*(.+?)\*"#,
            #"`(.+?)`"#,
            #"\[(.+?)\]\(.+?\)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                s = regex.stringByReplacingMatches(
                    in: s,
                    range: NSRange(s.startIndex..., in: s),
                    withTemplate: "$1"
                )
            }
        }
        s = s
            .replacingOccurrences(of: "…", with: ",")
            .replacingOccurrences(of: "—", with: ", ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep spoken alerts short.
        if s.count > 280 {
            s = String(s.prefix(277)) + "…"
        }
        return s
    }
}
