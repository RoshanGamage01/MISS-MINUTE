import Foundation

public struct ToolOutcome: Sendable, Equatable {
    /// What the model reads back.
    public var output: String
    public var isError: Bool
    /// What the user sees in the chat ("Added task: Ship the build").
    public var summary: String?
    /// Images returned to the model (e.g. a screenshot).
    public var images: [ImageAttachment]

    public init(output: String, isError: Bool = false, summary: String? = nil, images: [ImageAttachment] = []) {
        self.output = output
        self.isError = isError
        self.summary = summary
        self.images = images
    }

    public static func ok(_ output: String, summary: String? = nil, images: [ImageAttachment] = []) -> ToolOutcome {
        ToolOutcome(output: output, summary: summary, images: images)
    }

    public static func failure(_ output: String) -> ToolOutcome {
        ToolOutcome(output: output, isError: true)
    }
}

public struct ToolError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct AgentTool {
    public var spec: ToolSpec
    public var run: @MainActor (JSONValue) async throws -> ToolOutcome

    public init(spec: ToolSpec, run: @escaping @MainActor (JSONValue) async throws -> ToolOutcome) {
        self.spec = spec
        self.run = run
    }
}

@MainActor
public final class ToolRegistry {
    private var tools: [String: AgentTool] = [:]
    private var order: [String] = []
    /// Her current persona; it decides which tools the model sees and may call.
    public var activeRole: Role = .general {
        didSet { if activeRole != oldValue { onRoleChanged?(activeRole) } }
    }
    public var onRoleChanged: ((Role) -> Void)?

    public init() {}

    public func register(_ tool: AgentTool) {
        if tools[tool.spec.name] == nil { order.append(tool.spec.name) }
        tools[tool.spec.name] = tool
    }

    public func register(_ list: [AgentTool]) {
        list.forEach(register)
    }

    /// Stable, ordered list of the tools the active role allows (stable order keeps the prompt cache warm).
    public var specs: [ToolSpec] { specs(for: activeRole) }

    /// Every registered tool, whatever the role.
    public var allSpecs: [ToolSpec] { order.compactMap { tools[$0]?.spec } }

    public var names: [String] { order }

    public func specs(for role: Role) -> [ToolSpec] {
        order.filter(role.allows).compactMap { tools[$0]?.spec }
    }

    /// The named tools, in registry order (clones carry a subset).
    public func specs(named allowed: Set<String>) -> [ToolSpec] {
        order.filter(allowed.contains).compactMap { tools[$0]?.spec }
    }

    /// Runs a call, limited to what the active role allows.
    public func execute(_ call: ToolCall) async -> ToolOutcome {
        await execute(call, allowed: Set(order.filter(activeRole.allows)), roleName: activeRole.displayName)
    }

    /// Runs a call, limited to `allowed` tool names (a role or a clone's subset).
    public func execute(_ call: ToolCall, allowed: Set<String>, roleName: String? = nil) async -> ToolOutcome {
        if let raw = call.arguments["__invalid_json"]?.stringValue {
            return .failure("INVALID_JSON: the arguments for \(call.name) were not valid JSON (\(raw.prefix(200))). Call the tool again with valid JSON.")
        }
        let available = order.filter(allowed.contains)
        // Self-healing: a slightly-wrong tool name or argument key is repaired instead of bounced back.
        guard let name = available.contains(call.name) ? call.name : ToolRecovery.resolveName(call.name, among: available),
              let tool = tools[name] else {
            if tools[call.name] != nil, let roleName {
                return .failure("\(call.name) isn't available in the \(roleName) role. Call switch_role first (general has every tool).")
            }
            if tools[call.name] != nil {
                return .failure("\(call.name) isn't one of your tools. Available: \(available.joined(separator: ", ")).")
            }
            return .failure("Unknown tool \(call.name). Available: \(available.joined(separator: ", ")).")
        }
        let arguments = ToolRecovery.repairArguments(call.arguments, spec: tool.spec) ?? call.arguments
        var outcome = await run(tool, name: name, arguments: arguments)
        // Reads and opens are safe to repeat, so a network blip or busy app gets one more go.
        if outcome.isError, Self.retrySafe.contains(name), ToolRecovery.isTransient(outcome.output), !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 600_000_000)
            outcome = await run(tool, name: name, arguments: arguments)
        }
        return outcome
    }

    /// Tools with no side effects beyond what a repeat would do anyway.
    public static let retrySafe: Set<String> = [
        "open_app", "open_url", "focus_app", "look_at_screen", "read_screen", "search_web", "read_webpage",
        "get_calendar_events", "list_shortcuts", "get_system_status", "get_activity_summary", "read_clipboard",
        "copy_to_clipboard", "list_tasks", "list_reminders", "recall", "coding_job_status"
    ]

    private func run(_ tool: AgentTool, name: String, arguments: JSONValue) async -> ToolOutcome {
        do {
            return try await tool.run(arguments)
        } catch is CancellationError {
            return .failure("\(name) was cancelled.")
        } catch {
            return .failure("\(name) failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Argument helpers

extension JSONValue {
    public func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ToolError("Missing required argument '\(key)'.")
        }
        return value
    }

    public func optionalString(_ key: String) -> String? {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

public enum ToolDates {
    /// Parses ISO-8601-ish local date/times the model produces ("2026-10-25T15:30", "2026-10-25 15:30:00", "2026-10-25").
    public static func parse(_ text: String, calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        if let day = formatter.date(from: trimmed) {
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
        }
        return ReminderParser(calendar: calendar).parse("remind me at \(trimmed) to x")?.fireAt
    }

    public static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    /// Machine-readable local timestamp for tool output.
    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }
}
