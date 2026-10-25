import Foundation

/// Finds "Hey Minute" (and how speech recognition tends to hear it) in a live transcript, and returns what
/// was said after it. "Wait a minute" and "in a minute" don't count: it needs a greeting or "Miss" first.
public enum WakePhrase {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(?:(?:hey|hi|hay|okay|ok|yo)[,!.]?\s+(?:miss\s+|ms\.?\s+)?|miss\s+|ms\.?\s+)(?:minute|minutes|minnie|minny|minuit|minuet|minutes')(?![a-z])"#,
        options: [.caseInsensitive]
    )

    /// The request after the most recent wake phrase ("" if they only said the phrase), or nil if not heard.
    public static func command(in transcript: String) -> String? {
        let range = NSRange(transcript.startIndex..., in: transcript)
        guard let match = pattern.matches(in: transcript, range: range).last,
              let end = Range(match.range, in: transcript)?.upperBound else { return nil }
        // Drop the comma/space after the phrase, but keep the request's own ending ("…?") for end-of-speech detection.
        let leading = CharacterSet(charactersIn: ",.!?;:—-").union(.whitespacesAndNewlines)
        let rest = transcript[end...].drop { $0.unicodeScalars.allSatisfy(leading.contains) }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
