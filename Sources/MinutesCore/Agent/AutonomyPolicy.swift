import Foundation

/// Who started an agent turn. The user's own requests run with full trust (the persona already makes her ask
/// before sending, paying, or deleting); work she starts herself is held to `AutonomyPolicy`.
public enum Initiative: String, Codable, Sendable, Equatable {
    /// Typed or spoken by the user, or a background follow-up to something they asked for.
    case user
    /// Something she noticed and decided to do on her own.
    case selfDirected
}

/// How much she may do on her own, without being asked.
public enum AutonomyLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Never starts anything herself.
    case off
    /// Notices things and offers, but only looks and keeps notes on her own.
    case suggest
    /// Also does safe, undoable things: tracks tasks and reminders, opens apps, tidies files without overwriting.
    case safe
    /// Also runs commands and operates apps while the user is away. Never sends, pays, or deletes.
    case trusted

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .suggest: return "Suggest"
        case .safe: return "Safe"
        case .trusted: return "Trusted"
        }
    }

    public var explanation: String {
        switch self {
        case .off: return "She only acts when you ask."
        case .suggest: return "She notices things and offers to help, but doesn't act on her own."
        case .safe: return "She handles undoable chores herself: tasks, reminders, opening apps, tidying files (never overwriting). Bigger things she offers first."
        case .trusted: return "She also runs commands and operates apps on her own while you're away. Sending, paying, and deleting always wait for you."
        }
    }

    /// The riskiest kind of action she may take on her own at this level.
    public var ceiling: ActionRisk? {
        switch self {
        case .off: return nil
        case .suggest: return .observe
        case .safe: return .reversible
        case .trusted: return .impactful
        }
    }
}

/// How much a tool call can change. Ordered: each level includes the ones before it.
public enum ActionRisk: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Only looks: reads the screen, lists tasks, searches.
    case observe
    /// Changes her own notes or something trivially undone (a task, a reminder, an app opening, a file moved without overwriting).
    case reversible
    /// Changes the user's things in ways that aren't trivially undone: typing, clicking, running commands.
    case impactful
    /// Deletes, sends, pays, or otherwise can't be taken back. Always needs the user.
    case sensitive

    public static func < (lhs: ActionRisk, rhs: ActionRisk) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .observe: return "look"
        case .reversible: return "safe"
        case .impactful: return "impactful"
        case .sensitive: return "sensitive"
        }
    }
}

/// The guardrail for work she starts herself. Enforced in code before each tool runs, so a confused model
/// can't talk its way past it.
public enum AutonomyPolicy {
    public enum Decision: Equatable, Sendable {
        case allow
        /// Not on her own. The reason goes back to the model so it can offer instead.
        case deny(String)

        public var isAllowed: Bool { self == .allow }
    }

    static let observeTools: Set<String> = [
        "look_at_screen", "read_screen", "list_tasks", "list_reminders", "recall", "get_calendar_events",
        "get_system_status", "get_activity_summary", "search_web", "read_webpage", "read_clipboard",
        "list_shortcuts", "coding_job_status", "wait", "list_goals"
    ]
    static let reversibleTools: Set<String> = [
        "add_task", "update_task", "complete_task", "set_reminder", "start_timer", "cancel_reminder", "remember",
        "start_goal", "update_goal", "finish_goal", "open_app", "focus_app", "open_url", "change_look"
    ]
    static let sensitiveTools: Set<String> = ["delete_task", "forget"]
    /// Tools that drive the mouse and keyboard; on her own she never fights the user for them.
    static let handsOnTools: Set<String> = [
        "click", "press_element", "set_text", "type_text", "press_keys", "scroll", "drag", "browser"
    ]

    /// Words in any argument that mean "this leaves the Mac or can't be undone".
    private static let sensitiveWords = try! NSRegularExpression(pattern:
        #"\b(send|submit|post|tweet|reply|email|e-mail|imessage|buy|order|pay|purchase|checkout|transfer|delete|erase|wipe|unsubscribe|password|passcode)\b"#,
        options: [.caseInsensitive])

    public static func risk(of call: ToolCall) -> ActionRisk {
        let name = call.name
        if sensitiveTools.contains(name) { return .sensitive }
        if name == "run_shell" {
            return ShellIntent.risk(of: call.arguments["command"]?.stringValue ?? "")
        }
        if observeTools.contains(name) { return .observe }
        if handsOnTools.contains(name) || name == "run_applescript" || name == "run_shortcut" {
            return mentionsSensitive(call.arguments) ? .sensitive : .impactful
        }
        if reversibleTools.contains(name) { return .reversible }
        // Anything new or unknown is treated with care until it's classified.
        return mentionsSensitive(call.arguments) ? .sensitive : .impactful
    }

    /// Whether a tool call may run. `userIdleSeconds` keeps her hands off the keyboard while the user is using it.
    public static func decide(
        _ call: ToolCall,
        initiative: Initiative,
        level: AutonomyLevel,
        userIdleSeconds: TimeInterval
    ) -> Decision {
        guard initiative == .selfDirected else { return .allow }
        guard let ceiling = level.ceiling else {
            return .deny("Working on your own is turned off. Stop and don't act.")
        }
        let risk = risk(of: call)
        if risk == .sensitive {
            return .deny("This would send, pay for, or delete something, which always needs the user. Don't do it; ask them in one short sentence instead.")
        }
        if risk > ceiling {
            return .deny("That's more than you may do on your own at the \"\(level.displayName)\" autonomy level. Don't try another way around it; offer it to the user in one short sentence instead.")
        }
        if handsOnTools.contains(call.name), userIdleSeconds < 120 {
            return .deny("The user is using the keyboard and mouse right now, so don't take them over. Do it with a command, or offer it to them.")
        }
        return .allow
    }
}

/// What a shell command does, for deciding whether she may run it unasked.
public enum ShellIntent {
    private static let readOnlyCommands: Set<String> = [
        "ls", "find", "du", "df", "stat", "file", "wc", "head", "tail", "cat", "pwd", "which", "whoami", "date",
        "uptime", "sw_vers", "mdfind", "mdls", "echo", "grep", "sort", "uniq", "basename", "dirname", "test", "["
    ]
    private static let organizeCommands: Set<String> = ["mkdir", "mv", "cd", "true"]
    private static let destructive = try! NSRegularExpression(pattern:
        #"(^|[;&|`(\s])(rm|rmdir|srm|shred|trash|unlink|kill|killall|pkill|sudo|chmod|chown|dd|mkfs|diskutil|launchctl|defaults|crontab|curl|wget|scp|rsync|ssh|git\s+(push|reset|clean|checkout)|osascript)\b|>>?\s*(?!/dev/null\b|&)\S|-delete\b|-exec(dir)?\b"#,
        options: [])

    public static func risk(of command: String) -> ActionRisk {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .observe }
        if destructive.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return .sensitive
        }
        let segments = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ";|&\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var risk = ActionRisk.observe
        for segment in segments {
            let words = segment.split(separator: " ").map(String.init)
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            if readOnlyCommands.contains(program) { continue }
            if organizeCommands.contains(program) {
                // Moving is only undoable when it can't overwrite: `mv -n` (or `-i`, which declines without a tty).
                let flags = words.dropFirst().filter { $0.hasPrefix("-") && !$0.hasPrefix("--") }.joined()
                if program == "mv", flags.contains("f") || !(flags.contains("n") || flags.contains("i")) {
                    risk = max(risk, .impactful)
                } else {
                    risk = max(risk, .reversible)
                }
                continue
            }
            risk = max(risk, .impactful)
        }
        return risk
    }
}

extension AutonomyPolicy {
    static func mentionsSensitive(_ value: JSONValue) -> Bool {
        let text = flatten(value)
        return sensitiveWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func flatten(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .array(let items): return items.map(flatten).joined(separator: " ")
        case .object(let fields): return fields.values.map(flatten).joined(separator: " ")
        default: return ""
        }
    }
}
