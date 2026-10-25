import Foundation

/// Splits streaming text into speakable sentences so the voice can start before the reply is finished.
public struct SentenceChunker: Sendable {
    private var buffer = ""
    /// Fragments shorter than this wait for more text ("Mr. ", "e.g. ").
    public var minimumLength: Int
    /// When set, the first chunk may also end at a clause break (", " "; " " — ") once it's this long,
    /// so the voice can start before the first full sentence arrives.
    public var firstClauseLength: Int?
    private var emittedAny = false

    public init(minimumLength: Int = 14, firstClauseLength: Int? = nil) {
        self.minimumLength = minimumLength
        self.firstClauseLength = firstClauseLength
    }

    /// Adds streamed text and returns any sentences that are now complete.
    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let end = nextBoundary() {
            let sentence = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty {
                sentences.append(sentence)
                emittedAny = true
            }
        }
        return sentences
    }

    /// Returns whatever is left once the stream ends.
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    /// End index (exclusive) of the first complete sentence that's long enough, if any.
    private func nextBoundary() -> String.Index? {
        var index = buffer.startIndex
        var inCode = false
        while index < buffer.endIndex {
            let char = buffer[index]
            let next = buffer.index(after: index)
            if char == "`" { inCode.toggle() }
            let length = buffer.distance(from: buffer.startIndex, to: next)
            if !inCode, length >= minimumLength {
                if char == "\n" { return next }
                if ".!?…".contains(char), next < buffer.endIndex {
                    // Sentence end must be followed by whitespace (not "3.5" or "example.com").
                    var after = next
                    // Allow closing quotes/brackets right after the punctuation.
                    while after < buffer.endIndex, "\"')”’]".contains(buffer[after]) {
                        after = buffer.index(after: after)
                    }
                    if after < buffer.endIndex, buffer[after].isWhitespace {
                        return after
                    }
                }
                if !emittedAny, let clause = firstClauseLength, length >= clause,
                   ",;:—".contains(char), next < buffer.endIndex, buffer[next].isWhitespace {
                    return next
                }
            }
            index = next
        }
        return nil
    }
}
