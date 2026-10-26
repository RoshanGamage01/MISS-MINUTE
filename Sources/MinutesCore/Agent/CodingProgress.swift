import Foundation

/// Something a background coding agent just did, read from its `stream-json` output.
public enum CodingProgressEvent: Equatable, Sendable {
    /// A short "what I'm doing" line ("Editing Autonomy.swift").
    case step(String)
    /// A line of the agent's own commentary ("The build fails because…").
    case note(String)
    /// A tool call came back with an error.
    case problem(String)
    /// The agent's final report.
    case finished(result: String, isError: Bool)
}

/// Turns Claude Code / cursor-agent `--output-format stream-json` lines into short progress events.
/// Stateful only so an edit right after "the bug is…" reads as "Fixing X" rather than "Editing X".
public struct CodingProgressParser: Sendable {
    private var fixing = false

    public init() {}

    public mutating func parse(_ line: String) -> [CodingProgressEvent] {
        guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
              data.first == UInt8(ascii: "{"),
              let raw = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let json = JSONValue(any: raw)
        switch json["type"]?.stringValue {
        case "system" where json["subtype"]?.stringValue == "init":
            return [.step("Getting started")]
        case "assistant":
            return (json["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                switch block["type"]?.stringValue {
                case "text":
                    guard let note = Self.firstLine(block["text"]?.stringValue) else { return nil }
                    fixing = note.range(of: #"\b(fix|bug|broken|error|fail)"#, options: [.regularExpression, .caseInsensitive]) != nil
                    return .note(note)
                case "tool_use":
                    return describe(tool: block["name"]?.stringValue ?? "", input: block["input"] ?? .null).map(CodingProgressEvent.step)
                default:
                    return nil
                }
            }
        case "user":
            // Claude Code echoes tool results back as user turns; only failures are worth a line.
            let failed = (json["message"]?["content"]?.arrayValue ?? []).contains {
                $0["type"]?.stringValue == "tool_result" && $0["is_error"]?.boolValue == true
            }
            return failed ? [.problem("Hit a snag, working around it")] : []
        case "tool_call" where json["subtype"]?.stringValue == "started":
            // cursor-agent: {"tool_call": {"readToolCall": {"args": {...}}}} or {"function": {"name", "arguments"}}.
            guard let calls = json["tool_call"]?.objectValue,
                  let key = calls.keys.sorted().first(where: { $0.hasSuffix("ToolCall") || $0 == "function" }),
                  let call = calls[key] else { return [] }
            if key == "function" {
                let args = call["arguments"]?.stringValue
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                    .map { JSONValue(any: $0) }
                return describe(tool: call["name"]?.stringValue ?? "", input: args ?? .null).map { [.step($0)] } ?? []
            }
            let name = key.hasSuffix("ToolCall") ? String(key.dropLast("ToolCall".count)) : key
            return describe(tool: name, input: call["args"] ?? .null).map { [.step($0)] } ?? []
        case "result":
            let isError = json["is_error"]?.boolValue == true || json["subtype"]?.stringValue?.hasPrefix("error") == true
            return [.finished(result: json["result"]?.stringValue ?? "", isError: isError)]
        default:
            return []
        }
    }

    /// A short present-tense line for one tool call, or nil for calls not worth showing.
    public func describe(tool: String, input: JSONValue) -> String? {
        let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? input["notebook_path"]?.stringValue
        let file = path.map { ($0 as NSString).lastPathComponent }
        switch tool.lowercased().replacingOccurrences(of: "_", with: "") {
        case "read":
            return file.map { "Reading \($0)" } ?? "Reading files"
        case "write":
            guard let file else { return "Writing files" }
            if let subject = Self.testSubject(file) { return "Writing tests for \(subject)" }
            return "Writing \(file)"
        case "edit", "multiedit", "strreplace", "searchreplace", "notebookedit":
            guard let file else { return "Editing files" }
            if let subject = Self.testSubject(file) { return "Updating tests for \(subject)" }
            return fixing ? "Fixing \(file)" : "Editing \(file)"
        case "delete":
            return file.map { "Removing \($0)" } ?? "Removing files"
        case "bash", "shell", "runterminalcmd":
            return Self.describe(command: input["command"]?.stringValue ?? "", description: input["description"]?.stringValue)
        case "grep", "search", "codebasesearch":
            guard let pattern = (input["pattern"] ?? input["query"])?.stringValue, !pattern.isEmpty else { return "Searching the code" }
            return "Searching the code for “\(Self.clip(pattern, 30))”"
        case "glob", "ls", "listdir":
            return "Looking around the project"
        case "todowrite", "updatetodos":
            let todos = input["todos"]?.arrayValue ?? []
            let active = todos.first { $0["status"]?.stringValue == "in_progress" }
            return (active?["activeForm"] ?? active?["content"])?.stringValue.map { Self.clip($0, 70) }
        case "websearch":
            return input["query"]?.stringValue.map { "Searching the web for “\(Self.clip($0, 40))”" } ?? "Searching the web"
        case "webfetch":
            return "Reading a web page"
        case "task", "agent":
            return input["description"]?.stringValue.map { "Sending a helper to: \(Self.clip($0, 50))" } ?? "Sending a helper"
        default:
            return nil
        }
    }

    /// Names the common commands by what they do; anything else shows its own description or the command itself.
    static func describe(command: String, description: String?) -> String {
        let rules: [(pattern: String, line: String)] = [
            (#"\b(swift|npm|pnpm|yarn|bun|go|cargo|mix|dotnet)\s+(run\s+)?test\b|\bpytest\b|\bjest\b|\bvitest\b|\bxcodebuild\b.*\btest\b|\brspec\b"#, "Running the tests"),
            (#"\b(swift|cargo|go|dotnet)\s+build\b|\b(npm|pnpm|yarn|bun)\s+run\s+build\b|\bxcodebuild\b|\bmake\b|\btsc\b|\bgradle\b"#, "Building the project"),
            (#"\b(npm|pnpm|yarn|bun)\s+(install|i|add)\b|\bpip3?\s+install\b|\bbrew\s+install\b|\bpod\s+install\b|\buv\s+(add|sync)\b"#, "Installing dependencies"),
            (#"\bgit\s+commit\b"#, "Committing changes"),
            (#"\b(npm|pnpm|yarn|bun)\s+(run\s+)?(dev|start)\b|\bswift\s+run\b"#, "Starting the app")
        ]
        for rule in rules where command.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.line
        }
        if let description, !description.isEmpty { return clip(description, 70) }
        let oneLine = command.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return "Running `\(clip(oneLine, 40))`"
    }

    /// "MoodTests.swift" → "Mood.swift"; nil when the file isn't a test.
    static func testSubject(_ file: String) -> String? {
        let ext = (file as NSString).pathExtension
        let base = (file as NSString).deletingPathExtension
        let dotted = ext.isEmpty ? "" : ".\(ext)"
        for suffix in ["Tests", "Test", "Spec", ".test", ".spec", "_test", "_spec"] where base.hasSuffix(suffix) && base.count > suffix.count {
            return String(base.dropLast(suffix.count)) + dotted
        }
        if base.hasPrefix("test_"), base.count > 5 { return String(base.dropFirst(5)) + dotted }
        return nil
    }

    public static func firstLine(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        return clip(line, 140)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// A coding job's progress so far: every step and note, with repeats collapsed and the oldest dropped past a limit.
public struct CodingProgressLog: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case step, note, problem
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: Int
        public var date: Date
        public var text: String
        public var kind: Kind
    }

    public let limit: Int
    public private(set) var entries: [Entry] = []
    /// The latest "what I'm doing" line.
    public private(set) var currentStep: String?
    private var nextID = 0

    public init(limit: Int = 200) {
        self.limit = limit
    }

    /// Adds an entry; returns false (and adds nothing) when it just repeats the latest one.
    @discardableResult
    public mutating func record(_ text: String, kind: Kind, at date: Date = Date()) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, entries.last?.text != text else { return false }
        entries.append(Entry(id: nextID, date: date, text: text, kind: kind))
        nextID += 1
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        if kind == .step { currentStep = text }
        return true
    }

    public func recent(_ count: Int) -> [Entry] {
        Array(entries.suffix(count))
    }

    /// "[+03:12] Editing Autonomy.swift", timed from the job's start.
    public static func line(for entry: Entry, since start: Date) -> String {
        let seconds = max(0, Int(entry.date.timeIntervalSince(start)))
        let prefix = String(format: "[+%02d:%02d]", seconds / 60, seconds % 60)
        switch entry.kind {
        case .step: return "\(prefix) \(entry.text)"
        case .note: return "\(prefix)   “\(entry.text)”"
        case .problem: return "\(prefix) ⚠︎ \(entry.text)"
        }
    }
}

/// Decides when a progress line is worth interrupting the user for: not in the first moments of a job, not more often
/// than `interval`, and never the same line twice in a row.
public struct ProgressPacer: Sendable {
    public var firstDelay: TimeInterval
    public var interval: TimeInterval
    private var lastAt: Date?
    private var lastText: String?

    public init(firstDelay: TimeInterval = 30, interval: TimeInterval = 75) {
        self.firstDelay = firstDelay
        self.interval = interval
    }

    /// The line to show now, or nil to stay quiet.
    public mutating func next(_ text: String?, startedAt: Date, now: Date = Date()) -> String? {
        guard let text, text != lastText, now.timeIntervalSince(startedAt) >= firstDelay else { return nil }
        if let lastAt, now.timeIntervalSince(lastAt) < interval { return nil }
        lastAt = now
        lastText = text
        return text
    }
}

/// Splits streamed output into whole lines, holding back a partial last line until it's finished.
public struct LineSplitter: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func feed(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        // A runaway line with no newline shouldn't grow forever.
        if pending.count > 4_000_000 { pending.removeAll() }
        return lines
    }

    /// Whatever's left once the stream ends.
    public mutating func finish() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}
