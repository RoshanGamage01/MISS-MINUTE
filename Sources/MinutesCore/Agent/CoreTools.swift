import Foundation

/// Tools backed by Miss Minute's own stores: tasks, reminders/timers, and long-term memory.
@MainActor
public enum CoreTools {
    public static func all(tasks: TaskStore, reminders: ReminderStore, memory: MemoryStore) -> [AgentTool] {
        taskTools(tasks) + reminderTools(reminders) + memoryTools(memory)
    }

    // MARK: Tasks

    static func taskTools(_ store: TaskStore) -> [AgentTool] {
        let taskRef: JSONValue = ["type": "string", "description": "Task short id (from list_tasks) or part of its title."]
        let due: JSONValue = ["type": "string", "description": "Local due date/time, ISO 8601 like 2026-10-25T17:00. Omit if none."]
        let priority: JSONValue = ["type": "string", "enum": ["low", "normal", "high"]]

        return [
            AgentTool(spec: .object(
                "add_task",
                "Track a to-do for the user. Use whenever they mention something they need or plan to do.",
                properties: [
                    "title": ["type": "string", "description": "Short, actionable title."],
                    "notes": ["type": "string"],
                    "due": due,
                    "priority": priority
                ],
                required: ["title"]
            )) { args in
                let title = try args.requiredString("title")
                let dueAt = try args.optionalString("due").map(parseDate)
                let prio = args.optionalString("priority").flatMap(TaskPriority.init(rawValue:)) ?? .normal
                let task = await store.add(title: title, notes: args.optionalString("notes"), dueAt: dueAt, priority: prio)
                let dueText = dueAt.map { " (due \(ToolDates.describe($0)))" } ?? ""
                return .ok("Added task [\(task.shortID)] \(title)\(dueText).", summary: "Added task: \(title)\(dueText)")
            },

            AgentTool(spec: .object(
                "list_tasks",
                "List the user's tracked tasks with ids, due dates, and priority.",
                properties: ["include_done": ["type": "boolean", "description": "Include recently completed tasks."]]
            )) { args in
                let includeDone = args["include_done"]?.boolValue ?? false
                let list = includeDone ? store.tasks.sorted(by: TaskStore.ordering) : store.openTasks
                guard !list.isEmpty else { return .ok("No tasks tracked.") }
                let now = Date()
                let lines = list.map { task -> String in
                    var parts = ["[\(task.shortID)]", task.isDone ? "✓" : "○", task.title]
                    if let due = task.dueAt { parts.append("due \(ToolDates.stamp(due))\(task.isOverdue(at: now) ? " OVERDUE" : "")") }
                    if task.priority != .normal { parts.append("priority \(task.priority.rawValue)") }
                    if let notes = task.notes { parts.append("notes: \(notes)") }
                    return parts.joined(separator: " ")
                }
                return .ok(lines.joined(separator: "\n"))
            },

            AgentTool(spec: .object(
                "complete_task",
                "Mark a task done.",
                properties: ["task": taskRef],
                required: ["task"]
            )) { args in
                let ref = try args.requiredString("task")
                guard let task = store.find(ref) else { throw ToolError("No task matches '\(ref)'. Call list_tasks.") }
                await store.setDone(id: task.id)
                let remaining = store.openTasks.count
                return .ok("Completed [\(task.shortID)] \(task.title). \(remaining) open task(s) left.", summary: "Done: \(task.title)")
            },

            AgentTool(spec: .object(
                "update_task",
                "Change a task's title, notes, due date, or priority. Pass due as \"none\" to clear it.",
                properties: ["task": taskRef, "title": ["type": "string"], "notes": ["type": "string"], "due": due, "priority": priority],
                required: ["task"]
            )) { args in
                let ref = try args.requiredString("task")
                guard let task = store.find(ref) else { throw ToolError("No task matches '\(ref)'.") }
                var newDue: Date?? = nil
                if let dueText = args.optionalString("due") {
                    if dueText.lowercased() == "none" {
                        newDue = .some(nil)
                    } else {
                        newDue = .some(try parseDate(dueText))
                    }
                }
                await store.update(id: task.id) { t in
                    if let title = args.optionalString("title") { t.title = title }
                    if let notes = args.optionalString("notes") { t.notes = notes }
                    if let p = args.optionalString("priority").flatMap(TaskPriority.init(rawValue:)) { t.priority = p }
                    if let newDue { t.dueAt = newDue; t.lastNudgedAt = nil }
                }
                return .ok("Updated [\(task.shortID)].", summary: "Updated task: \(args.optionalString("title") ?? task.title)")
            },

            AgentTool(spec: .object(
                "delete_task",
                "Delete a task entirely (use complete_task for finished work).",
                properties: ["task": taskRef],
                required: ["task"]
            )) { args in
                let ref = try args.requiredString("task")
                guard let task = store.find(ref) else { throw ToolError("No task matches '\(ref)'.") }
                await store.remove(id: task.id)
                return .ok("Deleted [\(task.shortID)] \(task.title).", summary: "Removed task: \(task.title)")
            }
        ]
    }

    // MARK: Reminders & timers

    static func reminderTools(_ store: ReminderStore) -> [AgentTool] {
        [
            AgentTool(spec: .object(
                "set_reminder",
                "Schedule a reminder that Miss Minute will speak and notify at the given time. Give either `at` or `in_minutes`.",
                properties: [
                    "text": ["type": "string", "description": "What to remind the user about, phrased for them."],
                    "at": ["type": "string", "description": "Local time, ISO 8601 like 2026-10-25T15:30."],
                    "in_minutes": ["type": "number", "description": "Minutes from now."]
                ],
                required: ["text"]
            )) { args in
                let text = try args.requiredString("text")
                let fireAt: Date
                if let minutes = args["in_minutes"]?.doubleValue, minutes > 0 {
                    fireAt = Date().addingTimeInterval(minutes * 60)
                } else if let at = args.optionalString("at") {
                    fireAt = try parseDate(at)
                } else {
                    throw ToolError("Provide `at` or `in_minutes`.")
                }
                guard fireAt > Date().addingTimeInterval(-60) else {
                    throw ToolError("That time (\(ToolDates.stamp(fireAt))) is in the past.")
                }
                let reminder = await store.add(text: text, fireAt: fireAt)
                let when = ToolDates.describe(fireAt)
                return .ok("Reminder [\(reminder.shortID)] set for \(when).", summary: "Reminder \(when): \(text)")
            },

            AgentTool(spec: .object(
                "start_timer",
                "Start a countdown timer (focus session, tea, break). Miss Minute announces when it ends.",
                properties: [
                    "minutes": ["type": "number"],
                    "label": ["type": "string", "description": "e.g. \"focus\", \"pasta\"."]
                ],
                required: ["minutes"]
            )) { args in
                guard let minutes = args["minutes"]?.doubleValue, minutes > 0, minutes <= 24 * 60 else {
                    throw ToolError("minutes must be between 0 and 1440.")
                }
                let label = args.optionalString("label") ?? "timer"
                let fireAt = Date().addingTimeInterval(minutes * 60)
                await store.add(text: "Your \(label) timer is up (\(Int(minutes.rounded())) min).", fireAt: fireAt)
                return .ok("Timer '\(label)' running; ends at \(ToolDates.stamp(fireAt)).",
                           summary: "Timer: \(label), \(Int(minutes.rounded())) min")
            },

            AgentTool(spec: .object("list_reminders", "List pending reminders and timers.")) { _ in
                let upcoming = store.upcoming
                guard !upcoming.isEmpty else { return .ok("No pending reminders.") }
                return .ok(upcoming.map { "[\($0.shortID)] \(ToolDates.stamp($0.fireAt)) — \($0.text)" }.joined(separator: "\n"))
            },

            AgentTool(spec: .object(
                "cancel_reminder",
                "Cancel a pending reminder or timer.",
                properties: ["reminder": ["type": "string", "description": "Short id or part of its text."]],
                required: ["reminder"]
            )) { args in
                let ref = try args.requiredString("reminder")
                guard let reminder = store.find(ref) else { throw ToolError("No pending reminder matches '\(ref)'.") }
                await store.remove(id: reminder.id)
                return .ok("Cancelled [\(reminder.shortID)].", summary: "Cancelled reminder: \(reminder.text)")
            }
        ]
    }

    // MARK: Memory

    static func memoryTools(_ store: MemoryStore) -> [AgentTool] {
        [
            AgentTool(spec: .object(
                "remember",
                "Save a durable fact about the user (preferences, people, routines, goals, important dates). Don't save trivia or secrets like passwords.",
                properties: [
                    "fact": ["type": "string", "description": "One self-contained sentence, e.g. \"User's sister Maya's birthday is May 3.\""],
                    "category": ["type": "string", "description": "preference | person | routine | goal | work | other"]
                ],
                required: ["fact"]
            )) { args in
                let fact = try args.requiredString("fact")
                let item = await store.remember(fact, category: args.optionalString("category") ?? "other")
                return .ok("Saved memory [\(item.shortID)].", summary: "Remembered: \(fact)")
            },

            AgentTool(spec: .object(
                "recall",
                "Search everything remembered about the user. The most recent memories are already in your context; use this for older ones.",
                properties: ["query": ["type": "string"]]
            )) { args in
                let results = store.search(args.optionalString("query") ?? "")
                guard !results.isEmpty else { return .ok("Nothing remembered about that.") }
                return .ok(results.map { "[\($0.shortID)] (\($0.category)) \($0.fact)" }.joined(separator: "\n"))
            },

            AgentTool(spec: .object(
                "forget",
                "Delete a remembered fact when the user asks or it's no longer true.",
                properties: ["memory": ["type": "string", "description": "Short id or part of the fact."]],
                required: ["memory"]
            )) { args in
                let ref = try args.requiredString("memory")
                guard let item = store.find(ref) else { throw ToolError("No memory matches '\(ref)'.") }
                await store.forget(id: item.id)
                return .ok("Forgot [\(item.shortID)].", summary: "Forgot: \(item.fact)")
            }
        ]
    }

    private static func parseDate(_ text: String) throws -> Date {
        guard let date = ToolDates.parse(text) else {
            throw ToolError("Couldn't read the date '\(text)'. Use ISO 8601 local time like 2026-10-25T15:30.")
        }
        return date
    }
}
