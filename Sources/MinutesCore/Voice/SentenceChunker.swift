import Foundation

/// Splits streaming text into speakable sentences so the voice can start before the reply is finished.
public struct SentenceChunker: Sendable {
    private var buffer = ""
    /// Fragments shorter than this wait for more text ("Mr. ", "e.g. ").
    public var minimumLength: Int
    /// When set, the first chunk may also end at a clause break (", " "; " " — ") once it's this long,
    /// so the voice can start before the first full sentence arrives.
    public var firstClauseLength: Int?
    /// When set, the first chunk goes out as soon as it's speakable: at the first punctuation mark, or after
    /// this many words if none arrives. Later chunks are whole sentences again (better intonation, and they
    /// render while the first one plays).
    public var firstChunkWords: Int?
    /// When set, the second chunk may end at a clause break once it's this long. The first chunk is only a few
    /// words (well under a second of audio), so waiting for a whole long second sentence left a silent gap
    /// while it streamed in and rendered.
    public var followUpClauseLength: Int?
    /// When set, a run-on sentence longer than this is cut at its last clause break (or space), so one long
    /// sentence can't hold up the voice.
    public var maximumLength: Int?
    private var emittedCount = 0
    private var emittedAny: Bool { emittedCount > 0 }

    private static let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "st.", "vs.", "e.g.", "i.e.", "etc."]

    public init(
        minimumLength: Int = 14,
        firstClauseLength: Int? = nil,
        firstChunkWords: Int? = nil,
        followUpClauseLength: Int? = nil,
        maximumLength: Int? = nil
    ) {
        self.minimumLength = minimumLength
        self.firstClauseLength = firstClauseLength
        self.firstChunkWords = firstChunkWords
        self.followUpClauseLength = followUpClauseLength
        self.maximumLength = maximumLength
    }

    /// The settings for a streamed reply: first few words at once, the next clause soon after, then sentences.
    public static func streaming(firstChunkWords: Int?) -> SentenceChunker {
        SentenceChunker(firstChunkWords: firstChunkWords, followUpClauseLength: firstChunkWords == nil ? nil : 40, maximumLength: 220)
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
                emittedCount += 1
            }
        }
        return sentences
    }

    /// Returns whatever is left once the stream ends.
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !rest.isEmpty { emittedCount += 1 }
        return rest.isEmpty ? nil : rest
    }

    /// End index (exclusive) of the first complete sentence that's long enough, if any.
    private func nextBoundary() -> String.Index? {
        if !emittedAny, let words = firstChunkWords, let early = earlyBoundary(words: words) {
            return early
        }
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
                if let clause = clauseLength, length >= clause,
                   ",;:—".contains(char), next < buffer.endIndex, buffer[next].isWhitespace {
                    return next
                }
            }
            index = next
        }
        return overflowBoundary()
    }

    /// Clause breaks are allowed for the first chunk (`firstClauseLength`) and the second (`followUpClauseLength`).
    private var clauseLength: Int? {
        switch emittedCount {
        case 0: return firstClauseLength
        case 1: return followUpClauseLength
        default: return nil
        }
    }

    /// For a sentence past `maximumLength`: the last clause break inside the limit, else the last space.
    private func overflowBoundary() -> String.Index? {
        guard let maximumLength, buffer.count > maximumLength else { return nil }
        let limit = buffer.index(buffer.startIndex, offsetBy: maximumLength)
        var lastClause: String.Index?
        var lastSpace: String.Index?
        var inCode = false
        var index = buffer.startIndex
        while index < limit {
            let char = buffer[index]
            let next = buffer.index(after: index)
            if char == "`" { inCode.toggle() }
            if !inCode, buffer.distance(from: buffer.startIndex, to: next) >= minimumLength, next < buffer.endIndex {
                if ",;:—".contains(char), buffer[next].isWhitespace { lastClause = next }
                if char.isWhitespace { lastSpace = index }
            }
            index = next
        }
        return lastClause ?? lastSpace
    }

    /// First-chunk boundary: any sentence or clause punctuation followed by whitespace, or the space after
    /// the `words`-th word. Never inside a code span or after a lone abbreviation like "Dr.".
    private func earlyBoundary(words: Int) -> String.Index? {
        var index = buffer.startIndex
        var inCode = false
        var wordCount = 0
        var inWord = false
        var wordStart = buffer.startIndex
        while index < buffer.endIndex {
            let char = buffer[index]
            let next = buffer.index(after: index)
            if char == "`" { inCode.toggle() }
            if char.isWhitespace {
                if inWord {
                    inWord = false
                    wordCount += 1
                    if !inCode, wordCount >= words { return index }
                }
            } else if !inWord {
                inWord = true
                wordStart = index
            }
            if !inCode, wordCount + (inWord ? 1 : 0) >= 1, ".!?…,;:—".contains(char), next < buffer.endIndex {
                var after = next
                while after < buffer.endIndex, "\"')”’]".contains(buffer[after]) {
                    after = buffer.index(after: after)
                }
                let word = buffer[wordStart..<next].lowercased()
                if after < buffer.endIndex, buffer[after].isWhitespace, !Self.abbreviations.contains(word),
                   buffer.distance(from: buffer.startIndex, to: next) >= 3 {
                    return after
                }
            }
            index = next
        }
        return nil
    }
}
