import Combine
import Foundation

/// A lightweight copy of Miss Minute sent off to do one job in the background ("Web-Scraper", "File-Watcher")
/// with a subset of her tools, while she keeps talking to the user. It reports progress as it goes and its
/// result comes back to her when it's done.
public struct AgentClone: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case running, finished, failed, cancelled
    }

    public let id: Int
    /// What it's for, in a word or two ("Web-Scraper").
    public var purpose: String
    /// Its instructions.
    public var task: String
    public var tools: [String]
    public var status: Status
    /// The latest thing it's doing or reported ("Searching the web…").
    public var progress: String
    public var steps: Int
    public var result: String?
    public var startedAt: Date
    public var finishedAt: Date?
    /// Who asked for it; a clone she sent on her own is held to the autonomy policy like she is.
    public var initiative: Initiative

    public var isRunning: Bool { status == .running }
    public var shortID: String { "c\(id)" }
    public var icon: String { Self.icon(for: purpose) }

    /// What floats next to her while it works ("🔍 Searching the web…").
    public var label: String {
        let text: String
        switch status {
        case .running: text = progress
        case .finished: text = "\(purpose) done"
        case .failed: text = "\(purpose) hit a snag"
        case .cancelled: text = "\(purpose) stopped"
        }
        let trimmed = text.count > 30 ? String(text.prefix(29)) + "…" : text
        return "\(icon) \(trimmed)"
    }

    public var summaryLine: String {
        var line = "[\(shortID)] \(icon) \(purpose) — \(status.rawValue)"
        if isRunning { line += ", \(progress) (\(steps) step\(steps == 1 ? "" : "s"))" }
        if let result, !isRunning { line += ": \(result.prefix(160))" }
        return line
    }

    public static func icon(for purpose: String) -> String {
        let text = purpose.lowercased()
        let table: [([String], String)] = [
            (["watch", "monitor", "wait", "poll", "observe", "guard"], "👀"),
            (["web", "search", "scrap", "research", "browse", "look up", "lookup", "news", "price"], "🔍"),
            (["file", "folder", "download", "disk", "tidy", "clean", "organiz"], "📁"),
            (["build", "test", "code", "compile", "deploy", "debug", "git"], "🛠"),
            (["calendar", "meeting", "schedule", "agenda"], "📅"),
            (["mail", "message", "inbox", "chat"], "✉️"),
            (["summar", "read", "doc", "note"], "📝")
        ]
        return table.first { keys, _ in keys.contains(where: text.contains) }?.1 ?? "⏱"
    }
}

@MainActor
public final class CloneManager: ObservableObject {
    @Published public private(set) var clones: [AgentClone] = []

    public static let maxActive = 3
    public static let maxSteps = 30
    /// A watcher can wait between checks, but nothing lives forever.
    public static let maxLifetime: TimeInterval = 2 * 3600
    /// Clones never touch the mouse and keyboard (that would fight her and the user), and can't clone themselves
    /// or change her role or outfit.
    public static let excludedTools: Set<String> = [
        "click", "press_element", "set_text", "type_text", "press_keys", "scroll", "drag", "focus_app",
        "switch_role", "spawn_clone", "list_clones", "stop_clone", "change_look"
    ]
    /// What a clone gets when no tools are named.
    public static let defaultTools = ["search_web", "read_webpage", "run_shell", "recall"]
    /// Tools only clones have.
    public static let cloneOnlyTools: Set<String> = ["report_progress", "pause"]

    public var providerFactory: () throws -> any ChatProvider
    public var settingsProvider: () -> AppSettings
    /// Same guardrail as her own tool calls; a non-nil reason blocks the call.
    public var toolPolicy: ((ToolCall, Initiative) -> String?)?
    /// A clone made progress. `note` is set when it reported something itself, and `urgent` when it asked to
    /// tell her right away.
    public var onProgress: ((_ clone: AgentClone, _ note: String?, _ urgent: Bool) -> Void)?
    /// A clone finished, failed, or was stopped.
    public var onFinished: ((AgentClone) -> Void)?

    private let registry: ToolRegistry
    private var runs: [Int: Task<Void, Never>] = [:]
    private var nextID = 1

    public init(
        registry: ToolRegistry,
        settingsProvider: @escaping () -> AppSettings = { .default },
        providerFactory: @escaping () throws -> any ChatProvider
    ) {
        self.registry = registry
        self.settingsProvider = settingsProvider
        self.providerFactory = providerFactory
    }

    public var active: [AgentClone] { clones.filter(\.isRunning) }

    public func clone(_ id: Int) -> AgentClone? { clones.first { $0.id == id } }

    /// "c2", "2", or part of its purpose.
    public func find(_ ref: String) -> AgentClone? {
        let key = ref.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = key.hasPrefix("c") ? String(key.dropFirst()) : key
        if let id = Int(digits), let match = clone(id) { return match }
        let byPurpose = clones.filter { $0.purpose.lowercased().contains(key) }
        return byPurpose.first(where: \.isRunning) ?? byPurpose.last
    }

    /// Works out which tools a clone gets: names are repaired, role names expand to that role's tools, and
    /// anything a clone can't have is dropped. Returns the tools and a note about what was left out.
    public func resolveTools(_ requested: [String]) -> (tools: [String], note: String?) {
        let known = registry.names
        var picked: [String] = []
        var dropped: [String] = []
        for raw in requested {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let tool = known.contains(name) ? name : ToolRecovery.resolveName(name, among: known) {
                if Self.excludedTools.contains(tool) { dropped.append(tool) } else { picked.append(tool) }
            } else if let role = Role.named(name) {
                let names = role.toolNames.map { set in known.filter(set.contains) } ?? known
                picked += names.filter { !Self.excludedTools.contains($0) }
            } else if !Self.cloneOnlyTools.contains(name) {
                dropped.append(name)
            }
        }
        if picked.isEmpty { picked = Self.defaultTools.filter(known.contains) }
        var seen = Set<String>()
        let tools = picked.filter { seen.insert($0).inserted }
        let note = dropped.isEmpty ? nil : "Left out (not available to clones): \(dropped.joined(separator: ", "))."
        return (tools, note)
    }

    /// Starts a clone in the background and returns right away.
    @discardableResult
    public func spawn(purpose: String, task: String, tools: [String], initiative: Initiative = .user) throws -> AgentClone {
        let purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !purpose.isEmpty else { throw ToolError("Give the clone a purpose.") }
        guard active.count < Self.maxActive else {
            throw ToolError("Already \(active.count) clones running (the most at once is \(Self.maxActive)). Wait for one to finish or stop one.")
        }
        let clone = AgentClone(
            id: nextID, purpose: purpose, task: task.isEmpty ? purpose : task, tools: resolveTools(tools).tools,
            status: .running, progress: "Starting…", steps: 0, startedAt: Date(), initiative: initiative
        )
        nextID += 1
        clones.append(clone)
        pruneFinished()
        runs[clone.id] = Task { [weak self] in await self?.run(clone.id) }
        return clone
    }

    @discardableResult
    public func cancel(_ id: Int) -> AgentClone? {
        guard let clone = clone(id), clone.isRunning else { return nil }
        runs[id]?.cancel()
        runs[id] = nil
        let stopped = finish(id, status: .cancelled, result: "Stopped before it finished.")
        return stopped
    }

    public func cancelAll() {
        active.forEach { cancel($0.id) }
    }

    /// The hidden note that hands a clone's result back to her.
    public static func followUpNote(for clone: AgentClone) -> String {
        let outcome: String
        switch clone.status {
        case .finished: outcome = "finished"
        case .failed: outcome = "failed"
        case .cancelled: outcome = "was stopped"
        case .running: outcome = "is still running"
        }
        let wrapUp = clone.initiative == .selfDirected
            ? "Use it to finish what you started. If there's nothing worth telling the user, reply with just \(InitiativeNotes.skipToken)."
            : "Use it to finish what it was helping with, then tell the user the result in a sentence or two."
        return """
        Your clone [\(clone.shortID)] \(clone.icon) \(clone.purpose) \(outcome) after \(clone.steps) step(s). Its report:
        \(clone.result ?? "(no report)")

        \(wrapUp)
        """
    }

    public static func systemPrompt(for clone: AgentClone) -> String {
        """
        You are a clone of Miss Minute, the TVA's helpful clock, sent off to do one job in the background while \
        she keeps helping the user. Your purpose: \(clone.purpose).

        - Work on your own; nobody will answer questions. Make sensible choices and keep going.
        - Use only your tools. Call report_progress with a short line when you learn something useful or reach a \
        milestone; set urgent only for something she should hear right now (the file changed, the build broke).
        - To watch for something, check, then pause, then check again, until it happens or it's clearly not going to.
        - Never delete, send, buy, or overwrite anything; leave that to Miss Minute.
        - When you're done, reply with a short, factual report (what you found or did, with any paths, numbers, or \
        links she'll need). No pleasantries: she'll put it in her own words.
        """
    }

    // MARK: - Running

    private func run(_ id: Int) async {
        guard let start = clone(id) else { return }
        let settings = settingsProvider()
        var messages = [ChatMessage(role: .user, content: start.task, contextNote: Persona.timeAwarePrefix())]
        var lastText = ""
        do {
            let provider = try providerFactory()
            let specs = registry.specs(named: Set(start.tools)) + Self.cloneOnlySpecs
            for _ in 0..<Self.maxSteps {
                try Task.checkCancellation()
                guard Date().timeIntervalSince(start.startedAt) < Self.maxLifetime else {
                    throw ToolError("Ran out of time after \(Int(Self.maxLifetime / 60)) minutes.")
                }
                let request = AgentRequest(
                    messages: messages,
                    model: settings.model,
                    systemPrompt: Self.systemPrompt(for: start),
                    tools: specs,
                    depth: .snappy,
                    allowWebSearch: settings.webSearchEnabled && provider.kind == .anthropic
                )
                var text = ""
                var calls: [ToolCall] = []
                var stop: TurnStopReason = .other
                var raw: JSONValue?
                for try await event in provider.streamTurn(request) {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta): text += delta
                    case .toolCall(let call): calls.append(call)
                    case .status(let status): update(id) { $0.progress = status }
                    case .finished(let reason, let content):
                        stop = reason
                        raw = content
                    case .toolCallStarted: break
                    }
                }
                try Task.checkCancellation()
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lastText = text }
                messages.append(ChatMessage(role: .assistant, content: text, toolCalls: calls.isEmpty ? nil : calls, providerContent: raw))
                if stop == .pauseTurn { continue }
                if calls.isEmpty { break }

                for call in calls {
                    try Task.checkCancellation()
                    update(id) {
                        $0.steps += 1
                        if !Self.cloneOnlyTools.contains(call.name) { $0.progress = ChatService.statusLine(for: call) }
                    }
                    let outcome = await perform(call, cloneID: id, allowed: Set(start.tools), initiative: start.initiative)
                    messages.append(ChatMessage(
                        role: .tool, content: outcome.output, toolCallID: call.id, toolName: call.name,
                        isError: outcome.isError ? true : nil, images: outcome.images.isEmpty ? nil : outcome.images
                    ))
                    if !Self.cloneOnlyTools.contains(call.name), let current = clone(id) {
                        onProgress?(current, nil, false)
                    }
                }
                // Screenshots only matter for the next step; keep the clone's history light.
                for index in messages.indices.dropLast() where messages[index].images != nil {
                    messages[index].images = nil
                    messages[index].content += "\n[screenshot dropped]"
                }
            }
            guard !Task.isCancelled, clone(id)?.isRunning == true else { return }
            finish(id, status: .finished, result: lastText.isEmpty ? "Finished without a report." : lastText)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), clone(id)?.isRunning == true else { return }
            if let providerError = error as? ChatProviderError, providerError == .cancelled { return }
            finish(id, status: .failed, result: error.localizedDescription)
        }
    }

    private func perform(_ call: ToolCall, cloneID id: Int, allowed: Set<String>, initiative: Initiative) async -> ToolOutcome {
        switch call.name {
        case "report_progress":
            let note = call.arguments.optionalString("note") ?? ""
            guard !note.isEmpty else { return .failure("Give a short note.") }
            let urgent = call.arguments["urgent"]?.boolValue ?? false
            update(id) { $0.progress = note }
            if let current = clone(id) { onProgress?(current, note, urgent) }
            return .ok(urgent ? "Sent to Miss Minute right away." : "Noted.")
        case "pause":
            let seconds = min(300, max(1, call.arguments.lenientNumber("seconds") ?? 30))
            update(id) { $0.progress = "Waiting \(Int(seconds))s…" }
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return .failure("Stopped while waiting.")
            }
            return .ok("Waited \(Int(seconds)) seconds.")
        default:
            if let reason = toolPolicy?(call, initiative) { return .failure("NOT ALLOWED: \(reason)") }
            return await registry.execute(call, allowed: allowed)
        }
    }

    private static let cloneOnlySpecs: [ToolSpec] = [
        .object(
            "report_progress",
            "Tell Miss Minute how it's going: a finding, a milestone, or (urgent) something she should hear right away.",
            properties: [
                "note": ["type": "string", "description": "One short line."],
                "urgent": ["type": "boolean", "description": "Interrupt her with it now (only for things that can't wait)."]
            ],
            required: ["note"]
        ),
        .object(
            "pause",
            "Wait before checking again (for watching a file, a page, or a job). Up to 300 seconds.",
            properties: ["seconds": ["type": "number"]],
            required: ["seconds"]
        )
    ]

    private func update(_ id: Int, _ change: (inout AgentClone) -> Void) {
        guard let index = clones.firstIndex(where: { $0.id == id }), clones[index].isRunning else { return }
        change(&clones[index])
    }

    @discardableResult
    private func finish(_ id: Int, status: AgentClone.Status, result: String) -> AgentClone? {
        guard let index = clones.firstIndex(where: { $0.id == id }), clones[index].isRunning else { return nil }
        clones[index].status = status
        clones[index].result = result
        clones[index].finishedAt = Date()
        runs[id] = nil
        let done = clones[index]
        onFinished?(done)
        return done
    }

    /// Keeps the last few finished clones for list_clones; running ones always stay.
    private func pruneFinished(keep: Int = 6) {
        let finished = clones.filter { !$0.isRunning }
        guard finished.count > keep else { return }
        let drop = Set(finished.prefix(finished.count - keep).map(\.id))
        clones.removeAll { drop.contains($0.id) }
    }
}

/// The main agent's handle on her clones.
@MainActor
public enum CloneTools {
    public static func all(manager: CloneManager, initiative: @escaping () -> Initiative) -> [AgentTool] {
        let cloneRef: JSONValue = ["type": "string", "description": "Clone id like c2 (from list_clones or the context) or part of its purpose."]
        return [
            AgentTool(spec: .object(
                "spawn_clone",
                "Send a clone of yourself to do a self-contained job in the background, in parallel, while you carry on (research a topic, scrape a page, watch a file or a download, run a long check). It works alone with only the tools you give it, can't use the mouse or keyboard, and reports back to you when done. Up to \(CloneManager.maxActive) at once. Don't use it for quick one-step things: just do those.",
                properties: [
                    "purpose": ["type": "string", "description": "A short label, e.g. \"Web-Scraper\", \"File-Watcher\", \"Price-Checker\"."],
                    "task": ["type": "string", "description": "Complete instructions: what to do, when it's done, and what to report back."],
                    "tools": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Tool names it may use (e.g. [\"search_web\", \"read_webpage\"]) or a role name (developer, secretary, systemAdmin, researcher). Defaults to web search, reading pages, and run_shell."
                    ]
                ],
                required: ["purpose", "task"]
            )) { args in
                let purpose = try args.requiredString("purpose")
                let task = args.optionalString("task") ?? purpose
                let requested = (args["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
                    + (args["tools"]?.stringValue.map { $0.split(separator: ",").map(String.init) } ?? [])
                let note = manager.resolveTools(requested).note
                let clone = try manager.spawn(purpose: purpose, task: task, tools: requested, initiative: initiative())
                var output = "Clone [\(clone.shortID)] \(clone.icon) \(clone.purpose) is working in the background with: \(clone.tools.joined(separator: ", "))."
                if let note { output += " \(note)" }
                output += " It'll report back on its own; carry on with other work (or tell the user it's on it)."
                return .ok(output, summary: "\(clone.icon) Sent a clone: \(clone.purpose)")
            },

            AgentTool(spec: .object("list_clones", "See your clones: what each is doing, and what finished ones found.")) { _ in
                guard !manager.clones.isEmpty else { return .ok("No clones running or recently finished.") }
                return .ok(manager.clones.map(\.summaryLine).joined(separator: "\n"))
            },

            AgentTool(spec: .object(
                "stop_clone",
                "Call a clone back before it finishes (the user changed their mind, or it's no longer needed). Pass \"all\" to stop every clone.",
                properties: ["clone": cloneRef],
                required: ["clone"]
            )) { args in
                let ref = try args.requiredString("clone")
                if ref.lowercased() == "all" {
                    let count = manager.active.count
                    manager.cancelAll()
                    return .ok("Stopped \(count) clone(s).", summary: count == 0 ? nil : "Called back \(count) clone(s)")
                }
                guard let clone = manager.find(ref) else {
                    throw ToolError("No clone matches '\(ref)'. " + (manager.active.isEmpty ? "None are running." : "Running: \(manager.active.map(\.summaryLine).joined(separator: "; "))"))
                }
                guard let stopped = manager.cancel(clone.id) else { return .ok("[\(clone.shortID)] already \(clone.status.rawValue).") }
                return .ok("Stopped [\(stopped.shortID)] \(stopped.purpose).", summary: "Called back the \(stopped.purpose) clone")
            }
        ]
    }
}
