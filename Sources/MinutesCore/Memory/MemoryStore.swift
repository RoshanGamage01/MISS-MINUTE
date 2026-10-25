import Combine
import Foundation

/// A durable fact Miss Minute knows about the user ("prefers tea", "sister's birthday is May 3").
public struct MemoryItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var fact: String
    public var category: String
    public var createdAt: Date

    public init(id: UUID = UUID(), fact: String, category: String = "general", createdAt: Date = Date()) {
        self.id = id
        self.fact = fact
        self.category = category
        self.createdAt = createdAt
    }

    public var shortID: String { String(id.uuidString.prefix(6)).lowercased() }
}

@MainActor
public final class MemoryStore: ObservableObject {
    @Published public private(set) var items: [MemoryItem] = []

    private let store: JSONFileStore<[MemoryItem]>
    public let capacity: Int

    public init(
        store: JSONFileStore<[MemoryItem]> = JSONFileStore(url: MinutesPaths.memoryURL),
        capacity: Int = 200
    ) {
        self.store = store
        self.capacity = capacity
    }

    public func load() async {
        items = (try? await store.load(default: [])) ?? []
    }

    @discardableResult
    public func remember(_ fact: String, category: String = "general") async -> MemoryItem {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = items.first(where: { $0.fact.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let item = MemoryItem(fact: trimmed, category: category.lowercased())
        items.append(item)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
        await persist()
        return item
    }

    /// Replaces a memory's text (when a fact changes, e.g. they moved cities).
    public func update(id: UUID, fact: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].fact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        // Freshly confirmed facts count as recent.
        let item = items.remove(at: index)
        items.append(item)
        await persist()
    }

    public func item(shortID: String) -> MemoryItem? {
        let ref = shortID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.first { $0.shortID == ref }
    }

    public func forget(id: UUID) async {
        items.removeAll { $0.id == id }
        await persist()
    }

    public func find(_ reference: String) -> MemoryItem? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ref.isEmpty else { return nil }
        return items.first(where: { $0.shortID == ref })
            ?? items.first(where: { $0.fact.lowercased().contains(ref) })
    }

    /// Simple keyword relevance search.
    public func search(_ query: String, limit: Int = 12) -> [MemoryItem] {
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }
        guard !words.isEmpty else { return Array(items.suffix(limit)) }
        let scored = items.map { item -> (MemoryItem, Int) in
            let hay = (item.fact + " " + item.category).lowercased()
            return (item, words.filter { hay.contains($0) }.count)
        }
        return scored.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// The facts included with every user message (most recent first, capped).
    public func contextLines(limit: Int = 30) -> [String] {
        items.suffix(limit).reversed().map { "- \($0.fact)" }
    }

    private func persist() async {
        try? await store.save(items)
    }
}
