import Foundation

/// A snapshot of the user's situation, attached to each user message as a `<context>` block.
public struct AgentContext: Sendable, Equatable {
    public var now: Date
    public var userName: String?
    public var frontmostApp: String?
    /// Title of the front window (page title in browsers, document name in editors).
    public var frontWindowTitle: String?
    /// What she noticed on screen recently (newest last).
    public var screenNotes: [String]
    /// Which tools need permissions she doesn't have yet.
    public var capabilityNotes: [String]
    public var minutesInApp: Int
    public var continuousActiveMinutes: Int
    public var usageToday: String?
    public var openTasks: [TrackedTask]
    public var upcomingReminders: [Reminder]
    public var calendarLines: [String]
    public var memories: [String]
    public var inputMode: String
    /// How to pitch the reply given the user's mood (`MoodTone.guidance`); nil when nothing stands out.
    public var moodNote: String?

    public init(
        now: Date = Date(),
        userName: String? = nil,
        frontmostApp: String? = nil,
        frontWindowTitle: String? = nil,
        screenNotes: [String] = [],
        capabilityNotes: [String] = [],
        minutesInApp: Int = 0,
        continuousActiveMinutes: Int = 0,
        usageToday: String? = nil,
        openTasks: [TrackedTask] = [],
        upcomingReminders: [Reminder] = [],
        calendarLines: [String] = [],
        memories: [String] = [],
        inputMode: String = "typed",
        moodNote: String? = nil
    ) {
        self.now = now
        self.userName = userName
        self.frontmostApp = frontmostApp
        self.frontWindowTitle = frontWindowTitle
        self.screenNotes = screenNotes
        self.capabilityNotes = capabilityNotes
        self.minutesInApp = minutesInApp
        self.continuousActiveMinutes = continuousActiveMinutes
        self.usageToday = usageToday
        self.openTasks = openTasks
        self.upcomingReminders = upcomingReminders
        self.calendarLines = calendarLines
        self.memories = memories
        self.inputMode = inputMode
        self.moodNote = moodNote
    }

    public func render(calendar: Calendar = .current) -> String {
        var lines: [String] = [Persona.timeAwarePrefix(now: now, calendar: calendar)]
        if let userName, !userName.isEmpty {
            lines.append("User's name: \(userName).")
        }
        lines.append("Message was \(inputMode).")
        if let moodNote, !moodNote.isEmpty {
            lines.append("Their mood: \(moodNote)")
        }
        if let app = frontmostApp {
            lines.append("Frontmost app: \(app) (\(UsageTracker.duration(minutesInApp)) so far). Active without a break: \(UsageTracker.duration(continuousActiveMinutes)).")
        }
        if let title = frontWindowTitle, !title.isEmpty {
            lines.append("Front window: \"\(title)\".")
        }
        if !screenNotes.isEmpty {
            lines.append("What you've noticed on their screen recently (oldest first):")
            lines.append(contentsOf: screenNotes.suffix(5).map { "- \($0)" })
        }
        if let usageToday, !usageToday.isEmpty {
            lines.append("Screen time today: \(usageToday).")
        }

        if openTasks.isEmpty {
            lines.append("Open tasks: none.")
        } else {
            lines.append("Open tasks (\(openTasks.count)):")
            for task in openTasks.prefix(12) {
                var line = "- [\(task.shortID)] \(task.title)"
                if let due = task.dueAt {
                    line += task.isOverdue(at: now) ? " — OVERDUE since \(ToolDates.stamp(due))" : " — due \(ToolDates.stamp(due))"
                }
                if task.priority == .high { line += " — high priority" }
                lines.append(line)
            }
            if openTasks.count > 12 { lines.append("- …and \(openTasks.count - 12) more (list_tasks)") }
        }

        if !upcomingReminders.isEmpty {
            lines.append("Pending reminders:")
            for reminder in upcomingReminders.prefix(5) {
                lines.append("- \(ToolDates.stamp(reminder.fireAt)) \(reminder.text)")
            }
        }
        if !calendarLines.isEmpty {
            lines.append("Calendar (next 24h):")
            lines.append(contentsOf: calendarLines.prefix(8).map { "- \($0)" })
        }
        if !capabilityNotes.isEmpty {
            lines.append(contentsOf: capabilityNotes)
        }
        if !memories.isEmpty {
            lines.append("What you remember about the user:")
            lines.append(contentsOf: memories)
        }
        return lines.joined(separator: "\n")
    }
}
