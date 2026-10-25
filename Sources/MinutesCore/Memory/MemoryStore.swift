import Combine
import Foundation

/// A durable fact Miss Minute knows about the user ("prefers tea", "sister's birthday is May 3").
public struct MemoryItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var fact: String
    public var category: String
    public var createdAt: Date
    /// Related memories (see `MemoryGraph`). Optional so memory files from before links still load.
    public var links: [UUID]?

    public init(id: UUID = UUID(), fact: String, category: String = "general", createdAt: Date = Date(), links: [UUID]? = nil) {
        self.id = id
        self.fact = fact
        self.category = category
        self.createdAt = createdAt
        self.links = links
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
        var item = MemoryItem(fact: trimmed, category: category.lowercased())
        items.append(item)
        if items.count > capacity {
            let dropped = Set(items.prefix(items.count - capacity).map(\.id))
            items.removeFirst(items.count - capacity)
            removeLinks(to: dropped)
        }
        relink(item.id)
        item = items.first { $0.id == item.id } ?? item
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
        relink(id)
        await persist()
    }

    /// Links two memories explicitly (both directions).
    @discardableResult
    public func link(_ a: UUID, _ b: UUID) async -> Bool {
        guard a != b, items.contains(where: { $0.id == a }), items.contains(where: { $0.id == b }) else { return false }
        connect(a, b, front: true)
        await persist()
        return true
    }

    /// Memories linked to `id`, strongest first.
    public func related(to id: UUID) -> [MemoryItem] {
        guard let item = items.first(where: { $0.id == id }) else { return [] }
        return (item.links ?? []).compactMap { link in items.first { $0.id == link } }
    }

    /// Adds automatic links from one memory to the others it's most associated with. Existing links (including
    /// ones the curator made explicitly, which may share no words) are kept.
    private func relink(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let others = items.filter { $0.id != id }
        for target in MemoryGraph.suggestedLinks(for: item, among: others) {
            connect(id, target, front: false)
        }
    }

    private func connect(_ a: UUID, _ b: UUID, front: Bool) {
        for (from, to) in [(a, b), (b, a)] {
            guard let index = items.firstIndex(where: { $0.id == from }) else { continue }
            var links = (items[index].links ?? []).filter { $0 != to }
            if front { links.insert(to, at: 0) } else { links.append(to) }
            items[index].links = Array(links.prefix(MemoryGraph.maxLinks))
        }
    }

    private func removeLinks(to ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in items.indices where items[index].links?.contains(where: ids.contains) == true {
            items[index].links = items[index].links?.filter { !ids.contains($0) }
        }
    }

    public func item(shortID: String) -> MemoryItem? {
        let ref = shortID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.first { $0.shortID == ref }
    }

    public func forget(id: UUID) async {
        items.removeAll { $0.id == id }
        removeLinks(to: [id])
        await persist()
    }

    public func find(_ reference: String) -> MemoryItem? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ref.isEmpty else { return nil }
        return items.first(where: { $0.shortID == ref })
            ?? items.first(where: { $0.fact.lowercased().contains(ref) })
    }

    /// Relevance search: keyword matches first, then memories linked to them.
    public func search(_ query: String, limit: Int = 12) -> [MemoryItem] {
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }
        guard !words.isEmpty else { return Array(items.suffix(limit)) }
        let activated = MemoryGraph.activate(query: query, items: items, limit: limit).map(\.item)
        if !activated.isEmpty { return activated }
        // Fall back to plain substring matching (partial words, numbers).
        let scored = items.map { item -> (MemoryItem, Int) in
            let hay = (item.fact + " " + item.category).lowercased()
            return (item, words.filter { hay.contains($0) }.count)
        }
        return scored.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// The facts included with every user message. With `query` (the user's message), memories related to it
    /// come first, each followed by a linked fact or two for context; recent memories fill the rest.
    public func contextLines(query: String? = nil, limit: Int = 30) -> [String] {
        var lines: [String] = []
        var shown: Set<UUID> = []
        if let query, !query.isEmpty {
            for hit in MemoryGraph.activate(query: query, items: items, limit: 8) where !hit.viaLink {
                guard lines.count < limit, shown.insert(hit.item.id).inserted else { continue }
                lines.append("- \(hit.item.fact)")
                for neighbour in related(to: hit.item.id).prefix(2) where lines.count < limit && shown.insert(neighbour.id).inserted {
                    lines.append("  - related: \(neighbour.fact)")
                }
            }
        }
        for item in items.reversed() where lines.count < limit && shown.insert(item.id).inserted {
            lines.append("- \(item.fact)")
        }
        return lines
    }

    private func persist() async {
        try? await store.save(items)
    }
}
