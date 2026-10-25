import Foundation

/// One change to the memory list proposed after a conversation.
public enum MemoryEdit: Sendable, Equatable {
    case add(fact: String, category: String)
    /// `ref` is a memory's short id.
    case update(ref: String, fact: String)
    case remove(ref: String)
    /// Connects two related memories (short ids) so recalling one brings up the other.
    case link(ref: String, to: String)
}

/// Keeps memories current without the user asking: after an exchange that sounds personal, a quick
/// background model call decides what's worth adding, correcting, or dropping.
@MainActor
public final class MemoryCurator {
    private let store: MemoryStore
    private var reviewTask: Task<Void, Never>?

    /// Called with a short line per applied change ("Remembered: …").
    public var onChange: (([String]) -> Void)?

    public init(store: MemoryStore) {
        self.store = store
    }

    /// Reviews one exchange in the background. Cheap no-op when nothing in it sounds memorable.
    public func review(userText: String, reply: String, provider: any ChatProvider, model: String) {
        guard Self.mightBeMemorable(userText) else { return }
        let existing = store.items
        let prompt = Self.prompt(existing: existing, userText: userText, reply: reply)
        let previous = reviewTask
        reviewTask = Task { [weak self] in
            // Reviews run one at a time so edits never race each other.
            await previous?.value
            var output = ""
            do {
                for try await chunk in provider.streamChat(
                    messages: [ChatMessage(role: .user, content: prompt)],
                    model: model,
                    systemPrompt: Self.systemPrompt,
                    depth: .snappy
                ) {
                    output += chunk
                    if output.count > 4_000 { break }
                }
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let changes = await self.apply(Self.parse(output))
            if !changes.isEmpty { self.onChange?(changes) }
        }
    }

    /// Applies edits and returns a human-readable line for each one that changed something.
    @discardableResult
    public func apply(_ edits: [MemoryEdit]) async -> [String] {
        var changes: [String] = []
        // Adds and links in one review can refer to each other by fact text, so links run last.
        let ordered = edits.filter { if case .link = $0 { return false }; return true }.prefix(6)
            + edits.filter { if case .link = $0 { return true }; return false }.prefix(4)
        for edit in ordered {
            switch edit {
            case .add(let fact, let category):
                let before = store.items.count
                let item = await store.remember(fact, category: category)
                if store.items.count != before { changes.append("Remembered: \(item.fact)") }
            case .update(let ref, let fact):
                guard let item = store.item(shortID: ref), item.fact != fact else { continue }
                await store.update(id: item.id, fact: fact)
                changes.append("Updated: \(fact)")
            case .remove(let ref):
                guard let item = store.item(shortID: ref) else { continue }
                await store.forget(id: item.id)
                changes.append("Forgot: \(item.fact)")
            case .link(let a, let b):
                guard let first = store.find(a), let second = store.find(b), first.id != second.id,
                      !(first.links ?? []).contains(second.id) else { continue }
                if await store.link(first.id, second.id) {
                    changes.append("Linked: \(first.fact) ↔ \(second.fact)")
                }
            }
        }
        return changes
    }

    // MARK: - Detection

    /// Whole words or phrases that suggest the user is sharing something about themselves.
    private static let personalMarkers = [
        "i'm", "im", "i've", "i'd", "i'll", "my", "mine", "call me", "remember",
        "prefer", "favorite", "favourite", "love", "hate", "allergic", "birthday", "anniversary",
        "wife", "husband", "partner", "girlfriend", "boyfriend", "son", "daughter", "kids", "mom", "dad",
        "brother", "sister", "friend", "boss", "work", "job", "live", "moved", "usually", "always", "never",
        "anymore", "no longer", "actually", "forget", "goal", "trying to"
    ]

    /// Fast local gate so trivial turns ("thanks!", "what time is it?") never cost a model call.
    public static func mightBeMemorable(_ text: String) -> Bool {
        let normalized = " " + String(text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").map {
            $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " "
        }) + " "
        guard normalized.split(separator: " ").count >= 3 else { return false }
        return personalMarkers.contains { normalized.contains(" \($0) ") }
    }

    // MARK: - Prompting

    static let systemPrompt = """
    You maintain a personal assistant's long-term memory about its user. Reply with JSON only, no prose.
    """

    static func prompt(existing: [MemoryItem], userText: String, reply: String) -> String {
        let list = existing.suffix(60).map { item -> String in
            let links = (item.links ?? []).compactMap { id in existing.first { $0.id == id }?.shortID }
            return "[\(item.shortID)] \(item.fact)" + (links.isEmpty ? "" : " (linked: \(links.joined(separator: ", ")))")
        }.joined(separator: "\n")
        return """
        Current memories:
        \(list.isEmpty ? "(none)" : list)

        Latest exchange:
        User: \(userText.prefix(1_500))
        Assistant: \(reply.prefix(600))

        Decide whether this exchange reveals anything about the user worth remembering long-term: preferences, \
        people in their life, routines, work, goals, important dates, how they like to be addressed. Ignore \
        one-off requests, small talk, things only relevant today, and secrets (passwords, codes, card numbers).
        If a new fact contradicts or refines an existing memory, update that memory instead of adding a duplicate. \
        If the user says something is no longer true or asks to forget it, remove it.
        Write facts as short third-person sentences ("User's sister Maya lives in Austin.").
        Link memories that belong together but don't share obvious words (a person and their birthday, a goal and \
        the routine serving it). In "link", refer to a memory by its id, or to a fact you're adding by its exact text.

        Respond with exactly this JSON shape (use empty arrays when nothing changes, which is most of the time):
        {"add":[{"fact":"...","category":"preference|person|routine|goal|work|other"}],"update":[{"id":"abc123","fact":"..."}],"remove":["abc123"],"link":[["abc123","def456"]]}
        """
    }

    /// Parses the model's JSON, tolerating code fences or stray text around it.
    public static func parse(_ text: String) -> [MemoryEdit] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = JSONValue.parse(String(text[start...end])) else { return [] }
        var edits: [MemoryEdit] = []
        for entry in json["add"]?.arrayValue ?? [] {
            guard let fact = cleaned(entry["fact"]?.stringValue) else { continue }
            edits.append(.add(fact: fact, category: entry["category"]?.stringValue ?? "other"))
        }
        for entry in json["update"]?.arrayValue ?? [] {
            guard let id = entry["id"]?.stringValue, let fact = cleaned(entry["fact"]?.stringValue) else { continue }
            edits.append(.update(ref: id.lowercased(), fact: fact))
        }
        for entry in json["remove"]?.arrayValue ?? [] {
            guard let id = entry.stringValue ?? entry["id"]?.stringValue else { continue }
            edits.append(.remove(ref: id.lowercased()))
        }
        for entry in json["link"]?.arrayValue ?? [] {
            let pair = (entry.arrayValue ?? [entry["a"] ?? .null, entry["b"] ?? .null]).compactMap(\.stringValue)
            guard pair.count == 2 else { continue }
            edits.append(.link(ref: normalizedRef(pair[0]), to: normalizedRef(pair[1])))
        }
        return edits
    }

    /// Short ids are lowercased; fact text (for links to memories added in the same review) is kept as is.
    private static func normalizedRef(_ ref: String) -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 6 && !trimmed.contains(" ") ? trimmed.lowercased() : trimmed
    }

    private static func cleaned(_ fact: String?) -> String? {
        guard let fact = fact?.trimmingCharacters(in: .whitespacesAndNewlines), fact.count >= 4, fact.count <= 240 else {
            return nil
        }
        return fact
    }
}
