import Foundation

/// Links related memories so recalling one brings its neighbours along ("Maya lives in Austin" ↔ "Maya's
/// birthday is May 3" ↔ "User is flying to Austin in June"). Links come from shared names and keywords, plus
/// any the curator asks for explicitly. Pure functions; `MemoryStore` owns the data.
public enum MemoryGraph {
    /// Most links kept per memory (strongest first), so the graph stays small and meaningful.
    public static let maxLinks = 5
    /// Minimum association score for an automatic link.
    public static let linkThreshold = 0.34

    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "her", "was", "one", "our", "out", "has",
        "had", "his", "how", "its", "who", "did", "get", "got", "him", "she", "they", "them", "their", "there", "then",
        "than", "this", "that", "these", "those", "with", "from", "into", "onto", "over", "about", "after", "before",
        "when", "what", "which", "where", "while", "would", "could", "should", "will", "just", "like", "likes", "also",
        "very", "really", "much", "more", "most", "some", "each", "every", "been", "being", "have", "does", "doing",
        "user", "user's", "users", "prefers", "prefer", "usually", "always", "never", "often", "named", "called",
        "lives", "live", "works", "work", "loves", "love", "wants", "want", "goes", "going", "is", "on", "in", "at",
        "to", "of", "a", "an", "it", "by", "or", "as", "be", "my", "me", "we", "us", "he", "so", "if", "no", "do"
    ]

    private static let calendarWords: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november",
        "december", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "i", "i'm"
    ]

    /// Capitalised words that aren't sentence starters: likely people, places, products ("Maya", "Austin").
    public static func entities(in fact: String) -> Set<String> {
        let words = fact.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
        var result: Set<String> = []
        for (index, raw) in words.enumerated() {
            let word = stripPossessive(String(raw))
            guard let first = word.first, first.isUppercase, word.count >= 2 else { continue }
            let lower = word.lowercased()
            // Sentence starters ("The", "She") and calendar words aren't names.
            if stopwords.contains(lower) || calendarWords.contains(lower) || (index == 0 && word.count < 3) { continue }
            result.insert(lower)
        }
        return result
    }

    /// Content words, lowercased and lightly stemmed.
    public static func keywords(in fact: String) -> Set<String> {
        Set(fact.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map { stem(stripPossessive(String($0))) }
            .filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    /// 0…1 association between two facts: shared entities count most, then shared keywords, then category.
    public static func association(_ a: MemoryItem, _ b: MemoryItem) -> Double {
        guard a.id != b.id else { return 0 }
        let ea = entities(in: a.fact), eb = entities(in: b.fact)
        let ka = keywords(in: a.fact), kb = keywords(in: b.fact)
        var score = 0.0
        if !ea.isEmpty, !eb.isEmpty, !ea.isDisjoint(with: eb) { score += 0.5 }
        let union = ka.union(kb).count
        if union > 0 { score += Double(ka.intersection(kb).count) / Double(union) }
        if score > 0, a.category == b.category, a.category != "other", a.category != "general" { score += 0.08 }
        return min(1, score)
    }

    /// The strongest automatic links for `item` among `others` (ids, best first).
    public static func suggestedLinks(for item: MemoryItem, among others: [MemoryItem], limit: Int = maxLinks) -> [UUID] {
        others.map { ($0.id, association(item, $0)) }
            .filter { $0.1 >= linkThreshold }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Spreading activation: memories matching `query` directly, then their linked neighbours (at a discount).
    /// Returns (item, score, viaLink) ordered by score.
    public static func activate(query: String, items: [MemoryItem], limit: Int) -> [(item: MemoryItem, score: Double, viaLink: Bool)] {
        let words = keywords(in: query).union(entities(in: query))
        guard !words.isEmpty else { return [] }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var scores: [UUID: (Double, Bool)] = [:]
        for item in items {
            let hay = keywords(in: item.fact).union(entities(in: item.fact)).union([item.category.lowercased()])
            let hits = words.intersection(hay).count
            guard hits > 0 else { continue }
            scores[item.id] = (Double(hits) / Double(words.count), false)
        }
        for (id, (score, _)) in scores {
            for neighbour in byID[id]?.links ?? [] where byID[neighbour] != nil {
                let spread = score * 0.5
                if (scores[neighbour]?.0 ?? 0) < spread { scores[neighbour] = (spread, true) }
            }
        }
        return scores.compactMap { id, value in byID[id].map { (item: $0, score: value.0, viaLink: value.1) } }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.createdAt > $1.item.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    private static func stripPossessive(_ word: String) -> String {
        for suffix in ["'s", "’s"] where word.hasSuffix(suffix) { return String(word.dropLast(2)) }
        return word
    }

    private static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}
