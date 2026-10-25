import Foundation

/// Self-healing for tools: try a list of ways to do something until one works, repair slightly-wrong calls
/// from the model, and recognise failures that are worth one retry. Only when every approach fails does the
/// model hear about it, with what was tried so it can pick a different route.
public enum ToolRecovery {
    /// One way of doing the job. Throwing (or returning an error outcome) moves on to the next.
    public struct Attempt {
        public var label: String
        public var run: @MainActor () async throws -> ToolOutcome

        public init(_ label: String, _ run: @escaping @MainActor () async throws -> ToolOutcome) {
            self.label = label
            self.run = run
        }
    }

    /// Runs `attempts` in order and returns the first success. If an earlier approach failed, the success says
    /// so (the model learns what works). If all fail, throws one error listing every approach and why.
    @MainActor
    public static func firstSuccess(_ task: String, _ attempts: [Attempt]) async throws -> ToolOutcome {
        var failures: [String] = []
        for attempt in attempts {
            do {
                try Task.checkCancellation()
                var outcome = try await attempt.run()
                if outcome.isError {
                    failures.append("\(attempt.label): \(outcome.output.prefix(200))")
                    continue
                }
                if !failures.isEmpty {
                    outcome.output += " (Recovered: \(failures.joined(separator: "; ")) — used \(attempt.label) instead.)"
                }
                return outcome
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(attempt.label): \(error.localizedDescription.prefix(200))")
            }
        }
        throw ToolError("Couldn't \(task). Tried: \(failures.joined(separator: "; ")). Try a different approach.")
    }

    // MARK: - Repairing calls

    /// Maps a tool name the model got slightly wrong ("open_application", "OpenApp", "open-app") to a real one.
    public static func resolveName(_ name: String, among known: [String]) -> String? {
        let key = canonical(name)
        if let exact = known.first(where: { canonical($0) == key }) { return exact }
        // Common synonyms in model-invented names.
        let synonyms = ["application": "app", "launch": "open", "start": "open", "website": "url", "link": "url",
                        "todo": "task", "note": "memory", "remove": "delete", "fetch": "get", "show": "list"]
        var tokens = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.count <= 1 {
            // camelCase → tokens
            tokens = name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .lowercased().split(separator: " ").map(String.init)
        }
        let mapped = tokens.map { synonyms[$0] ?? $0 }
        if let hit = known.first(where: { canonical($0) == mapped.joined() }) { return hit }
        // Same words in any order, or one dropped word ("get_calendar" → "get_calendar_events").
        let wanted = Set(mapped)
        let candidates = known.filter { candidate in
            let words = Set(candidate.split(separator: "_").map(String.init))
            return wanted == words || (wanted.isSubset(of: words) && words.count - wanted.count == 1 && wanted.count >= 2)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Fills in missing required arguments when the model used a near-synonym key ("app" for "name",
    /// "link" for "url") or a single unrecognised key. Returns nil when nothing could be repaired.
    public static func repairArguments(_ arguments: JSONValue, spec: ToolSpec) -> JSONValue? {
        guard case .object(var args) = arguments,
              let properties = spec.inputSchema["properties"]?.objectValue else { return nil }
        let required = (spec.inputSchema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        let missing = required.filter { args[$0] == nil || args[$0]?.stringValue?.isEmpty == true }
        guard !missing.isEmpty else { return nil }
        let aliases: [String: [String]] = [
            "name": ["app", "app_name", "application", "title", "shortcut"],
            "url": ["link", "href", "website", "address", "uri"],
            "text": ["content", "message", "body", "value", "string"],
            "title": ["name", "task", "summary", "text"],
            "query": ["q", "search", "term", "keywords", "text"],
            "fact": ["memory", "text", "content"],
            "task": ["id", "task_id", "title", "name"],
            "reminder": ["id", "reminder_id", "text"],
            "memory": ["id", "memory_id", "fact"],
            "minutes": ["duration", "mins", "length", "in_minutes"],
            "command": ["cmd", "shell", "script"]
        ]
        var repaired = false
        for key in missing {
            if let alias = aliases[key]?.first(where: { args[$0] != nil && properties[$0] == nil }) {
                args[key] = args.removeValue(forKey: alias)
                repaired = true
                continue
            }
            let unknown = args.keys.filter { properties[$0] == nil }
            if missing.count == 1, unknown.count == 1, let only = unknown.first {
                args[key] = args.removeValue(forKey: only)
                repaired = true
            }
        }
        return repaired ? .object(args) : nil
    }

    /// Failures that often go away on a second try (network blips, a busy app, a slow launch).
    public static func isTransient(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["timed out", "timeout", "network connection was lost", "temporarily", "try again", "busy",
                "connection reset", "could not connect", "not responding", "-1001", "-1005", "(-600)", "(-1712)"]
            .contains(where: lower.contains)
    }

    // MARK: - Finding what the model meant

    /// The candidate whose text best matches `reference` by shared words (typos in ids, paraphrased titles).
    /// Returns nil unless one candidate clearly wins with at least half the reference's words.
    public static func bestMatch<T>(_ reference: String, in candidates: [T], text: (T) -> String) -> T? {
        let wanted = words(reference)
        guard !wanted.isEmpty else { return nil }
        let scored = candidates.map { candidate -> (T, Double) in
            let have = words(text(candidate))
            let shared = wanted.filter { word in have.contains { $0 == word || ($0.count >= 4 && word.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0))) } }
            return (candidate, Double(shared.count) / Double(wanted.count))
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= 0.5 else { return nil }
        if scored.count > 1, scored[1].1 == best.1 { return nil }
        return best.0
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
    }

    private static func canonical(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

extension JSONValue {
    /// A number the model may have sent as a string ("15", "15 minutes", "1.5h" → 90 when `minutes` is true).
    public func lenientNumber(_ key: String, minutes: Bool = false) -> Double? {
        if let value = self[key]?.doubleValue { return value }
        guard let text = self[key]?.stringValue?.lowercased() else { return nil }
        let digits = text.prefix { $0.isNumber || $0 == "." || $0 == " " }.trimmingCharacters(in: .whitespaces)
        guard let value = Double(digits) else { return nil }
        if minutes, text.contains("h"), !text.contains("min") { return value * 60 }
        if minutes, text.contains("sec") { return value / 60 }
        return value
    }
}
