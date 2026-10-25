import Foundation

/// The daily rundown Miss Minute gives on the first activity of the day.
public enum Briefing {
    /// Instruction sent to the model (with a context block) to produce a spoken briefing.
    public static let modelInstruction = """
    Give me my daily briefing out loud: greet me for the time of day, then in 2–4 short sentences cover what \
    matters today — overdue or due-today tasks, calendar events, pending reminders — and recommend the one thing \
    to start with. If the day is clear, say so and suggest something useful. No lists, no markdown.
    """

    /// Offline fallback built straight from the data.
    public static func compose(
        tasks: [TrackedTask],
        reminders: [Reminder],
        calendarLines: [String],
        name: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var parts = [ActivityCopy.greeting(at: now, name: name)]
        let overdue = tasks.filter { $0.isOverdue(at: now) }
        let today = tasks.filter { task in
            guard let due = task.dueAt else { return false }
            return calendar.isDate(due, inSameDayAs: now) && due >= now
        }
        let remindersToday = reminders.filter { calendar.isDate($0.fireAt, inSameDayAs: now) }

        if !overdue.isEmpty {
            parts.append("\(count(overdue.count, "task")) slipped past due — \(overdue.first!.title) is first in line.")
        }
        if !today.isEmpty {
            parts.append("Due today: \(today.prefix(3).map(\.title).joined(separator: ", ")).")
        }
        if !calendarLines.isEmpty {
            parts.append("On the calendar: \(calendarLines.prefix(2).joined(separator: "; ")).")
        }
        if !remindersToday.isEmpty {
            parts.append("\(count(remindersToday.count, "reminder")) set for today.")
        }
        if overdue.isEmpty && today.isEmpty && calendarLines.isEmpty {
            if let next = tasks.first {
                parts.append("Nothing urgent. If you've got a minute, \(next.title) is waiting.")
            } else {
                parts.append("Your timeline's wide open. Tell me what we're tackling and I'll keep track.")
            }
        }
        return parts.joined(separator: " ")
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "One \(noun)" : "\(n) \(noun)s"
    }
}
