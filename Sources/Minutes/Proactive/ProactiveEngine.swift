import AppKit
import Foundation
import MinutesCore

/// Decides when Miss Minute speaks up on her own, and keeps her from nagging.
@MainActor
final class ProactiveEngine {
    enum Trigger {
        case briefing
        case breakSuggestion(activeMinutes: Int)
        case taskDueSoon(TrackedTask)
        case taskOverdue(TrackedTask)
        case activity(ActivityEvent)
        /// Unprompted small talk: an observation, a question, a tip, a joke.
        case musing
    }

    /// Delivers a remark. `prompt` is an instruction for an AI-written line; `fallback` is spoken if that fails.
    var deliver: ((_ prompt: String?, _ fallback: String, _ urgent: Bool) -> Void)?

    private let settings: () -> AppSettings
    private let tasks: TaskStore
    private let reminders: ReminderStore
    private let usage: UsageTracker
    private let calendar: CalendarService
    private var timer: Timer?
    private var lastRemarkAt: Date = .distantPast
    private var lastBreakNudgeAt: Date = .distantPast
    private var lastAppRemarkAt: Date = .distantPast
    private var lastMusingAt = Date()
    private let defaults = UserDefaults.standard

    private static let meetingBundles: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp", "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
    ]

    init(settings: @escaping () -> AppSettings, tasks: TaskStore, reminders: ReminderStore, usage: UsageTracker, calendar: CalendarService) {
        self.settings = settings
        self.tasks = tasks
        self.reminders = reminders
        self.usage = usage
        self.calendar = calendar
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Greet with the day's briefing shortly after launch.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            self?.maybeBriefing(force: false)
        }
    }

    var inMeeting: Bool {
        guard settings().quietDuringMeetings,
              let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.meetingBundles.contains(id)
    }

    // MARK: - Inputs

    func handle(_ event: ActivityEvent) {
        let s = settings()
        switch event {
        case .screenDidSleep:
            return
        case .screenDidWake, .returnedFromIdle:
            if maybeBriefing(force: false) { return }
            guard s.announceIdleReturn else { return }
            fire(.activity(event), urgent: false)
        case .processFinished:
            guard s.announceProcessCompletions else { return }
            fire(.activity(event), urgent: true)
        case .appActivated:
            guard s.announceAppSwitches, Date().timeIntervalSince(lastAppRemarkAt) > 10 * 60 else { return }
            lastAppRemarkAt = Date()
            fire(.activity(event), urgent: false)
        }
    }

    private func tick() {
        let s = settings()
        let now = Date()
        guard s.activityMonitoringEnabled else { return }

        if s.breakRemindersEnabled {
            let active = usage.continuousActiveMinutes(at: now)
            if active >= s.breakAfterMinutes, now.timeIntervalSince(lastBreakNudgeAt) > 45 * 60 {
                lastBreakNudgeAt = now
                fire(.breakSuggestion(activeMinutes: active), urgent: false)
                return
            }
        }

        if let interval = musingInterval(s.proactivity),
           now.timeIntervalSince(lastMusingAt) > interval,
           now.timeIntervalSince(lastRemarkAt) > interval / 2,
           SystemIdle.idleSeconds() < 90 {
            lastMusingAt = now
            fire(.musing, urgent: false)
            return
        }

        // Heads-up 15 minutes before a task is due, then once when it goes overdue (at most every 3h).
        for task in tasks.openTasks {
            guard let due = task.dueAt else { continue }
            let untilDue = due.timeIntervalSince(now)
            let lastNudge = task.lastNudgedAt ?? .distantPast
            if untilDue > 0, untilDue <= 15 * 60, lastNudge < due.addingTimeInterval(-20 * 60) {
                markNudged(task)
                fire(.taskDueSoon(task), urgent: true)
                return
            }
            if untilDue < 0, now.timeIntervalSince(lastNudge) > 3 * 3_600, now.timeIntervalSince(due) < 3 * 86_400 {
                markNudged(task)
                fire(.taskOverdue(task), urgent: false)
                return
            }
        }
    }

    /// True when today's briefing hasn't been given yet (and briefings are on).
    var briefingDue: Bool {
        let now = Date()
        return settings().dailyBriefingEnabled
            && Calendar.current.component(.hour, from: now) >= 5
            && defaults.string(forKey: "lastBriefingDay") != Self.dayKey(now)
    }

    /// Delivers the daily briefing once per day (after 5am). Returns true if it fired.
    @discardableResult
    func maybeBriefing(force: Bool) -> Bool {
        guard force || briefingDue else { return false }
        defaults.set(Self.dayKey(Date()), forKey: "lastBriefingDay")
        if force { lastRemarkAt = .distantPast }
        fire(.briefing, urgent: true)
        return true
    }

    /// Help she spotted on screen (from the screen watcher). Rate-limited like any unprompted remark.
    func offer(_ line: String) {
        let s = settings()
        let now = Date()
        guard !inMeeting, now.timeIntervalSince(lastRemarkAt) >= s.proactivity.minimumGap / 2 else { return }
        lastRemarkAt = now
        lastMusingAt = now
        deliver?(nil, line, false)
    }

    // MARK: - Output

    private func fire(_ trigger: Trigger, urgent: Bool) {
        let s = settings()
        let now = Date()
        if inMeeting, !urgent { return }
        let gap = urgent ? s.proactivity.minimumGap / 4 : s.proactivity.minimumGap
        guard now.timeIntervalSince(lastRemarkAt) >= gap else { return }
        lastRemarkAt = now

        let (prompt, fallback) = phrasing(for: trigger)
        deliver?(s.smartActivityReactions ? prompt : nil, fallback, urgent)
    }

    private func phrasing(for trigger: Trigger) -> (prompt: String?, fallback: String) {
        let name = settings().userName
        switch trigger {
        case .briefing:
            let fallback = Briefing.compose(
                tasks: tasks.openTasks,
                reminders: reminders.upcoming,
                calendarLines: calendar.upcomingLines(),
                name: name.isEmpty ? nil : name
            )
            return (Briefing.modelInstruction, fallback)
        case .breakSuggestion(let minutes):
            return (
                "I've been working \(minutes) minutes without a break. In one or two short spoken sentences, nudge me to take a quick break, tailored to what I'm doing.",
                ActivityCopy.breakSuggestion(activeMinutes: minutes)
            )
        case .taskDueSoon(let task):
            let when = task.dueAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "soon"
            return (
                "My task \"\(task.title)\" is due at \(when). Give me a short spoken heads-up and one tip to get it done.",
                "Heads up, sugar: \"\(task.title)\" is due at \(when)."
            )
        case .taskOverdue(let task):
            return (
                "My task \"\(task.title)\" is overdue. In one short spoken line, check in kindly and offer to reschedule it or mark it done.",
                "Hon, \"\(task.title)\" slipped past its due time. Want me to push it back, or is it done?"
            )
        case .musing:
            // No canned small talk: if the model can't write something real, she stays quiet.
            return (Self.musingPrompt, "")
        case .activity(let event):
            return (
                "Desktop event: \(event.summary) React in ONE short spoken line (max 22 words), helpful and in character. No quotes.",
                ActivityCopy.line(for: event)
            )
        }
    }

    private func musingInterval(_ proactivity: Proactivity) -> TimeInterval? {
        switch proactivity {
        case .quiet: return nil
        case .balanced: return 18 * 60
        case .chatty: return 7 * 60
        }
    }

    private static let musingPrompt = """
    Start a little conversation with me, the way a friend who lives on my desktop would. Pick ONE, whatever \
    fits the moment best: a playful observation about what I'm doing right now, a quick question about my day or \
    plans, a genuinely useful tip tied to my tasks or schedule, or a light TVA-flavored joke. One or two short \
    spoken sentences. Ending with a question is good. Don't repeat anything you've said recently.
    """

    private func markNudged(_ task: TrackedTask) {
        Task { await tasks.update(id: task.id) { $0.lastNudgedAt = Date() } }
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
