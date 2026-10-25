import Foundation

/// Parses natural-language reminder phrases into structured reminders.
public struct ReminderParser: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Returns a parsed reminder when the text looks like a reminder request.
    public func parse(_ text: String, now: Date = Date()) -> ParsedReminder? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let relative = parseRelative(trimmed, now: now) {
            return relative
        }
        if let clock = parseClockTime(trimmed, now: now) {
            return clock
        }
        return nil
    }

    /// True when the utterance should be treated as a reminder command
    /// (even if duration parsing later fails).
    public func looksLikeReminder(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("remind me")
            || lower.hasPrefix("reminder:")
            || lower.hasPrefix("nudge me")
    }

    // MARK: - Relative durations

    private func parseRelative(_ text: String, now: Date) -> ParsedReminder? {
        // remind me in 20 minutes to take a break
        // remind me in 1 hour to call mom
        // remind me in 2 hours and 15 minutes to check the oven
        let pattern = #"""
        (?ix)
        ^\s*(?:please\s+)?(?:remind\s+me|nudge\s+me)\s+in\s+
        (?<amount1>\d+)\s*(?<unit1>minutes?|mins?|hours?|hrs?|seconds?|secs?|days?)
        (?:\s+and\s+(?<amount2>\d+)\s*(?<unit2>minutes?|mins?|hours?|hrs?|seconds?|secs?))?
        \s+(?:to\s+|about\s+|that\s+)?(?<task>.+?)\s*$
        """#

        guard let match = firstMatch(pattern: pattern, in: text) else {
            // Alternate: "remind me to X in 20 minutes"
            return parseRelativeTrailing(text, now: now)
        }

        let amount1 = Int(substring(text, match, "amount1") ?? "") ?? 0
        let unit1 = substring(text, match, "unit1") ?? "minutes"
        let amount2 = Int(substring(text, match, "amount2") ?? "") ?? 0
        let unit2 = substring(text, match, "unit2")
        let task = (substring(text, match, "task") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return nil }

        var interval: TimeInterval = duration(amount: amount1, unit: unit1)
        if let unit2, amount2 > 0 {
            interval += duration(amount: amount2, unit: unit2)
        }
        guard interval > 0 else { return nil }

        let fireAt = now.addingTimeInterval(interval)
        let matched = String(text[Range(match.range, in: text)!])
        return ParsedReminder(text: task, fireAt: fireAt, matchedPhrase: matched)
    }

    private func parseRelativeTrailing(_ text: String, now: Date) -> ParsedReminder? {
        let pattern = #"""
        (?ix)
        ^\s*(?:please\s+)?(?:remind\s+me|nudge\s+me)\s+to\s+
        (?<task>.+?)\s+in\s+
        (?<amount>\d+)\s*(?<unit>minutes?|mins?|hours?|hrs?|seconds?|secs?|days?)
        \s*$
        """#
        guard let match = firstMatch(pattern: pattern, in: text) else { return nil }
        let amount = Int(substring(text, match, "amount") ?? "") ?? 0
        let unit = substring(text, match, "unit") ?? "minutes"
        let task = (substring(text, match, "task") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, amount > 0 else { return nil }
        let fireAt = now.addingTimeInterval(duration(amount: amount, unit: unit))
        let matched = String(text[Range(match.range, in: text)!])
        return ParsedReminder(text: task, fireAt: fireAt, matchedPhrase: matched)
    }

    // MARK: - Clock times

    private func parseClockTime(_ text: String, now: Date) -> ParsedReminder? {
        // remind me at 3:30pm to stretch
        // remind me at 15:00 to leave
        let pattern = #"""
        (?ix)
        ^\s*(?:please\s+)?(?:remind\s+me|nudge\s+me)\s+at\s+
        (?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<ampm>am|pm)?
        \s+(?:to\s+|about\s+)?(?<task>.+?)\s*$
        """#
        guard let match = firstMatch(pattern: pattern, in: text) else { return nil }
        guard var hour = Int(substring(text, match, "hour") ?? "") else { return nil }
        let minute = Int(substring(text, match, "minute") ?? "") ?? 0
        let ampm = substring(text, match, "ampm")?.lowercased()
        let task = (substring(text, match, "task") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, (0...59).contains(minute) else { return nil }

        if let ampm {
            if !(1...12).contains(hour) { return nil }
            if ampm == "pm", hour < 12 { hour += 12 }
            if ampm == "am", hour == 12 { hour = 0 }
        } else if hour > 23 {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var fireAt = calendar.date(from: components) else { return nil }
        if fireAt <= now {
            fireAt = calendar.date(byAdding: .day, value: 1, to: fireAt) ?? fireAt
        }
        let matched = String(text[Range(match.range, in: text)!])
        return ParsedReminder(text: task, fireAt: fireAt, matchedPhrase: matched)
    }

    // MARK: - Helpers

    private func duration(amount: Int, unit: String) -> TimeInterval {
        let u = unit.lowercased()
        if u.hasPrefix("sec") { return TimeInterval(amount) }
        if u.hasPrefix("min") { return TimeInterval(amount * 60) }
        if u.hasPrefix("hour") || u.hasPrefix("hr") { return TimeInterval(amount * 3600) }
        if u.hasPrefix("day") { return TimeInterval(amount * 86_400) }
        return 0
    }

    private func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range)
    }

    private func substring(_ text: String, _ match: NSTextCheckingResult, _ name: String) -> String? {
        let key = name as NSString
        let range = match.range(withName: key as String)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}
