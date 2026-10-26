import Foundation

/// A persona she can switch into for a stretch of work. Each role narrows the tools she sees (fewer tools means
/// faster, more focused turns, especially on local models) and adds a line to her system prompt.
public enum Role: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Everything at once (the default).
    case general
    case developer
    case secretary
    case systemAdmin
    case researcher

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general: return "General"
        case .developer: return "Developer"
        case .secretary: return "Secretary"
        case .systemAdmin: return "System-Admin"
        case .researcher: return "Researcher"
        }
    }

    public var emoji: String {
        switch self {
        case .general: return "⏱"
        case .developer: return "💻"
        case .secretary: return "📋"
        case .systemAdmin: return "🛠"
        case .researcher: return "🔍"
        }
    }

    /// One line for the tool description and the context block.
    public var summary: String {
        switch self {
        case .general: return "every tool; for mixed or casual requests"
        case .developer: return "shell, coding agent, files, screen, web docs; for building, debugging, and QA"
        case .secretary: return "tasks, reminders, calendar, memory, messages on screen; for planning and organizing their day"
        case .systemAdmin: return "shell, AppleScript, system status, apps; for installs, cleanup, settings, and Mac health"
        case .researcher: return "web search, reading pages and the screen, notes; for digging into a question"
        }
    }

    /// Added to the system prompt while the role is active (empty for the general role).
    public var promptModifier: String {
        switch self {
        case .general:
            return ""
        case .developer:
            return "You're in Developer mode: think like a careful senior engineer. Prefer run_shell for builds, tests, and git; hand bigger builds to start_coding_agent; verify with real builds and tests before saying it works."
        case .secretary:
            return "You're in Secretary mode: organized and anticipatory. Keep tasks, reminders, and the calendar tidy; tie things to dates; confirm before anything is sent on their behalf."
        case .systemAdmin:
            return "You're in System-Admin mode: methodical and cautious. Check state before changing it (get_system_status, run_shell reads), batch commands, and never delete or overwrite without asking."
        case .researcher:
            return "You're in Researcher mode: dig until you have a solid answer. Cross-check at least two sources, read pages rather than skimming snippets, and give a short, sourced answer."
        }
    }

    /// The tools this role sees, besides `Role.alwaysAvailable`. nil means every registered tool.
    public var toolNames: Set<String>? {
        switch self {
        case .general:
            return nil
        case .developer:
            return Self.screen.union([
                "run_shell", "run_applescript", "start_coding_agent", "coding_job_status", "open_app", "open_url",
                "focus_app", "browser", "search_web", "read_webpage", "copy_to_clipboard", "read_clipboard",
                "start_goal", "update_goal", "list_goals", "finish_goal", "add_task", "list_tasks", "complete_task",
                "wait"
            ])
        case .secretary:
            return Self.screen.union([
                "add_task", "update_task", "complete_task", "delete_task", "list_tasks", "set_reminder", "start_timer",
                "list_reminders", "cancel_reminder", "get_calendar_events", "create_calendar_event", "forget",
                "open_app", "open_url", "browser", "copy_to_clipboard", "read_clipboard", "search_web", "read_webpage",
                "list_shortcuts", "run_shortcut", "start_goal", "update_goal", "list_goals", "finish_goal", "wait"
            ])
        case .systemAdmin:
            return Self.screen.union([
                "run_shell", "run_applescript", "get_system_status", "get_activity_summary", "open_app", "focus_app",
                "open_url", "list_shortcuts", "run_shortcut", "search_web", "read_webpage", "start_goal",
                "update_goal", "list_goals", "finish_goal", "wait"
            ])
        case .researcher:
            return [
                "search_web", "read_webpage", "browser", "look_at_screen", "read_screen", "open_url",
                "copy_to_clipboard", "read_clipboard", "add_task", "list_tasks", "set_reminder"
            ]
        }
    }

    /// Seeing and operating the screen.
    private static let screen: Set<String> = [
        "look_at_screen", "read_screen", "click", "press_element", "set_text", "type_text", "press_keys", "scroll", "drag"
    ]

    /// Tools every role keeps: changing roles, managing clones, and her memory.
    public static let alwaysAvailable: Set<String> = [
        "switch_role", "spawn_clone", "list_clones", "stop_clone", "remember", "recall", "change_look"
    ]

    public func allows(_ tool: String) -> Bool {
        guard let names = toolNames else { return true }
        return names.contains(tool) || Self.alwaysAvailable.contains(tool)
    }

    /// Reads a role name the way a model or a person might write it ("dev", "System Admin", "sysadmin").
    public static func named(_ text: String) -> Role? {
        let key = text.lowercased().filter(\.isLetter)
        if let exact = allCases.first(where: { $0.rawValue.lowercased() == key || $0.displayName.lowercased().filter(\.isLetter) == key }) {
            return exact
        }
        let aliases: [String: Role] = [
            "default": .general, "normal": .general, "assistant": .general, "all": .general,
            "dev": .developer, "engineer": .developer, "coder": .developer, "programmer": .developer,
            "assistantsecretary": .secretary, "planner": .secretary, "organizer": .secretary, "pa": .secretary,
            "sysadmin": .systemAdmin, "admin": .systemAdmin, "it": .systemAdmin, "ops": .systemAdmin,
            "research": .researcher, "analyst": .researcher
        ]
        return aliases[key]
    }
}

/// `switch_role`: lets her change persona mid-conversation.
@MainActor
public enum RoleTools {
    public static func all(registry: ToolRegistry) -> [AgentTool] {
        let roles = Role.allCases.map { "\($0.rawValue) (\($0.displayName): \($0.summary))" }.joined(separator: "; ")
        return [
            AgentTool(spec: .object(
                "switch_role",
                "Change your active role so you only carry the tools a job needs. Switch when a request is clearly one kind of work (a build, a cleanup, planning their week, research); switch back to general for mixed requests. The new tools apply from your next step. Roles: \(roles).",
                properties: ["role": ["type": "string", "enum": .array(Role.allCases.map { .string($0.rawValue) })]],
                required: ["role"]
            )) { args in
                let text = try args.requiredString("role")
                guard let role = Role.named(text) else {
                    throw ToolError("Unknown role '\(text)'. Pick one of: \(Role.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                let previous = registry.activeRole
                registry.activeRole = role
                guard role != previous else { return .ok("Already in the \(role.displayName) role.") }
                let tools = registry.specs.map(\.name).joined(separator: ", ")
                return .ok("Now in the \(role.displayName) role. Tools available: \(tools).",
                           summary: "\(role.emoji) Switched to \(role.displayName) mode")
            }
        ]
    }
}
