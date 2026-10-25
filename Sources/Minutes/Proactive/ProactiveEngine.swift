import AppKit
import Foundation
import MinutesCore

/// Decides when Miss Minute speaks up on her own, and keeps her from nagging.
@MainActor
final class ProactiveEngine {
    enum Trigger {
        case briefing
        case breakSuggestion(activeMinutes: Int, nudgesThisStretch: Int)
        /// They look stuck: an error that won't go away, or the same screen for ages.
        case stuck(StuckDetector.Finding)
        case taskDueSoon(TrackedTask)
        case taskOverdue(TrackedTask)
        case activity(ActivityEvent)
        /// Unprompted small talk: an observation, a question, a tip, a joke.
        case musing
    }

    /// Delivers a remark. `prompt` is an instruction for an AI-written line; `fallback` is spoken if that fails.
    /// A generated reply of exactly `skipToken` means "on reflection, say nothing".
    var deliver: ((_ prompt: String?, _ fallback: String, _ urgent: Bool) -> Void)?
    static let skipToken = "SKIP"
    /// The front app and window title right now.
    var frontWindow: () -> (app: String?, title: String?) = { (nil, nil) }
    /// Whether the user seems stressed (from `MoodTracker`): fewer musings, earlier breaks.
    var isStressed: () -> Bool = { false }
    /// Things she noticed that change how the user is probably feeling.
    var onMoodSignal: ((MoodTracker.Signal) -> Void)?
    /// An error showed up in the window title: a closer look would make her offer specific.
    var onSuspectedError: (() -> Void)?

    private let settings: () -> AppSettings
    private let tasks: TaskStore
    private let reminders: ReminderStore
    private let usage: UsageTracker
    private let calendar: CalendarService
    private var timer: Timer?
    private var lastRemarkAt: Date = .distantPast
    private var lastBreakNudgeAt: Date?
    private var breakNudges = 0
    private var lastActiveMinutes = 0
    private var stuck = StuckDetector()
    private var lastErrorTitle: String?
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

    /// What the screen watcher just noticed; an error in it counts toward "stuck".
    func noteScreen(_ note: String) {
        let front = frontWindow()
        stuck.observe(app: front.app, title: front.title, note: note, idleSeconds: SystemIdle.idleSeconds())
    }

    private func tick() {
        let s = settings()
        let now = Date()
        guard s.activityMonitoringEnabled else { return }
        let idle = SystemIdle.idleSeconds()
        let stressed = isStressed()

        if s.breakRemindersEnabled, maybeSuggestBreak(s, now: now, stressed: stressed) { return }

        let front = frontWindow()
        stuck.observe(app: front.app, title: front.title, idleSeconds: idle, at: now)
        if let title = front.title, title != lastErrorTitle, StuckDetector.errorDetail(in: title) != nil {
            // Look sooner than the usual glance so the offer can name the actual problem.
            lastErrorTitle = title
            onSuspectedError?()
        }
        if !inMeeting, now.timeIntervalSince(lastRemarkAt) >= s.proactivity.minimumGap / 2, let finding = stuck.assess(at: now) {
            if finding.isError { onMoodSignal?(.stuck) }
            fire(.stuck(finding), urgent: false)
            return
        }

        // A stressed user doesn't need small talk.
        if !stressed, let interval = musingInterval(s.proactivity),
           now.timeIntervalSince(lastMusingAt) > interval,
           now.timeIntervalSince(lastRemarkAt) > interval / 2,
           idle < 90 {
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
                onMoodSignal?(.taskOverdue)
                fire(.taskOverdue(task), urgent: false)
                return
            }
        }
    }

    /// Break nudges escalate gently: the first at the user's threshold (sooner when stressed or late at night),
    /// follow-ups closer together if they keep going. Taking a break resets the count.
    private func maybeSuggestBreak(_ s: AppSettings, now: Date, stressed: Bool) -> Bool {
        let active = usage.continuousActiveMinutes(at: now)
        if active < lastActiveMinutes {
            // The stretch reset: they took a break.
            if breakNudges > 0 { onMoodSignal?(.breakTaken) }
            breakNudges = 0
            lastBreakNudgeAt = nil
        }
        lastActiveMinutes = active
        let hour = Calendar.current.component(.hour, from: now)
        let threshold = BreakCoach.threshold(base: s.breakAfterMinutes, stressed: stressed, lateNight: hour >= 22 || hour < 5)
        guard !inMeeting,
              BreakCoach.shouldNudge(activeMinutes: active, threshold: threshold, nudgesThisStretch: breakNudges, lastNudgeAt: lastBreakNudgeAt, now: now),
              fire(.breakSuggestion(activeMinutes: active, nudgesThisStretch: breakNudges), urgent: false)
        else { return false }
        breakNudges += 1
        lastBreakNudgeAt = now
        return true
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

    /// Returns whether the remark went out (it's dropped during meetings or too soon after the last one).
    @discardableResult
    private func fire(_ trigger: Trigger, urgent: Bool) -> Bool {
        let s = settings()
        let now = Date()
        if inMeeting, !urgent { return false }
        var gap = urgent ? s.proactivity.minimumGap / 4 : s.proactivity.minimumGap
        // Help with a problem on screen matters more than small talk.
        if case .stuck = trigger { gap /= 2 }
        guard now.timeIntervalSince(lastRemarkAt) >= gap else { return false }
        lastRemarkAt = now

        let (prompt, fallback) = phrasing(for: trigger)
        // A judgement-call trigger with no canned line needs the model; without it she stays quiet.
        guard s.smartActivityReactions || !fallback.isEmpty else { return false }
        deliver?(s.smartActivityReactions ? prompt : nil, fallback, urgent)
        return true
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
        case .breakSuggestion(let minutes, let nudges):
            let stretch = BreakCoach.stretches[(minutes / 7 + nudges) % BreakCoach.stretches.count]
            let followUp = nudges == 0 ? "" : " You've already nudged me \(nudges) time\(nudges == 1 ? "" : "s") this stretch, so be a touch firmer (still kind) and suggest actually stepping away."
            return (
                "I've been working \(minutes) minutes without a break. In one or two short spoken sentences, nudge me to take a quick break with one concrete stretch or reset (for example: \(stretch)), tailored to what I'm doing and how I seem to be feeling.\(followUp)",
                BreakCoach.line(activeMinutes: minutes, nudgesThisStretch: nudges, index: minutes / 7 + nudges)
            )
        case .stuck(.error(let app, let detail, let minutes)):
            let place = app ?? "your screen"
            return (
                "Automatic check: \(place) has shown what looks like a problem for about \(max(1, minutes)) minutes: \"\(detail)\". If I seem stuck on it, offer ONE specific kind of help in one short spoken line (explain it, find the fix, or fix it for me), ending with a question. If it clearly isn't a problem (say I'm just reading about errors), reply with exactly \(Self.skipToken).",
                "Looks like \(place) has been showin' an error for a bit, sugar. Want me to take a look?"
            )
        case .stuck(.dwelling(let app, let title, let minutes)):
            let window = title.map { " (\"\($0)\")" } ?? ""
            return (
                "Automatic check: I've been on the same screen in \(app)\(window) for \(minutes) minutes while active. Using what you've noticed on my screen, decide whether I look stuck. If so, offer ONE specific kind of help in one short spoken line, ending with a question. If I'm just focused, reply with exactly \(Self.skipToken).",
                ""
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
