import Foundation

// MARK: - What she can see

/// A quick count of a folder's loose files (gathered by the app; pure data here).
public struct FolderScan: Sendable, Equatable {
    public var name: String
    public var path: String
    /// Files sitting at the top level (not in subfolders).
    public var looseFiles: Int
    /// Loose files untouched for 30+ days.
    public var staleFiles: Int
    /// Loose files by kind ("Images": 12, "Installers": 5…).
    public var kinds: [String: Int]

    public init(name: String, path: String, looseFiles: Int, staleFiles: Int, kinds: [String: Int] = [:]) {
        self.name = name
        self.path = path
        self.looseFiles = looseFiles
        self.staleFiles = staleFiles
        self.kinds = kinds
    }

    public var kindSummary: String {
        kinds.sorted { $0.value > $1.value }.prefix(4).map { "\($0.value) \($0.key.lowercased())" }.joined(separator: ", ")
    }

    /// Groups a file extension into a folder name for tidying.
    public static func kind(ofExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp": return "Images"
        case "pdf", "doc", "docx", "txt", "rtf", "md", "pages", "key", "numbers", "xls", "xlsx", "csv", "ppt", "pptx": return "Documents"
        case "dmg", "pkg", "app", "mpkg": return "Installers"
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz": return "Archives"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return "Audio"
        case "mp4", "mov", "m4v", "avi", "mkv", "webm": return "Videos"
        case "swift", "py", "js", "ts", "json", "html", "css", "sh", "rb", "go", "rs", "java", "c", "cpp", "h": return "Code"
        default: return "Other"
        }
    }
}

public struct UpcomingEvent: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var location: String?

    public init(title: String, start: Date, location: String? = nil) {
        self.title = title
        self.start = start
        self.location = location
    }
}

/// Everything the autonomy loop looks at on one tick.
public struct WorldSnapshot: Sendable, Equatable {
    public var now: Date
    public var idleSeconds: TimeInterval
    public var inMeeting: Bool
    public var frontApp: String?
    public var downloads: FolderScan?
    public var desktop: FolderScan?
    public var freeDiskGB: Double?
    public var openTasks: [TrackedTask]
    public var events: [UpcomingEvent]
    public var goals: [Goal]
    /// Regular apps running in the background that weren't used today.
    public var unusedRunningApps: [String]

    public init(
        now: Date = Date(),
        idleSeconds: TimeInterval = 0,
        inMeeting: Bool = false,
        frontApp: String? = nil,
        downloads: FolderScan? = nil,
        desktop: FolderScan? = nil,
        freeDiskGB: Double? = nil,
        openTasks: [TrackedTask] = [],
        events: [UpcomingEvent] = [],
        goals: [Goal] = [],
        unusedRunningApps: [String] = []
    ) {
        self.now = now
        self.idleSeconds = idleSeconds
        self.inMeeting = inMeeting
        self.frontApp = frontApp
        self.downloads = downloads
        self.desktop = desktop
        self.freeDiskGB = freeDiskGB
        self.openTasks = openTasks
        self.events = events
        self.goals = goals
        self.unusedRunningApps = unusedRunningApps
    }

    /// One line for the thought log.
    public var summary: String {
        var parts: [String] = []
        if let downloads { parts.append("Downloads has \(downloads.looseFiles) loose files (\(downloads.staleFiles) a month old)") }
        if let desktop, desktop.looseFiles > 0 { parts.append("Desktop has \(desktop.looseFiles)") }
        if let freeDiskGB { parts.append(String(format: "%.0f GB free", freeDiskGB)) }
        let overdue = openTasks.filter { $0.isOverdue(at: now) }.count
        if overdue > 0 { parts.append("\(overdue) overdue task\(overdue == 1 ? "" : "s")") }
        let open = goals.filter(\.isOpen).count
        if open > 0 { parts.append("\(open) goal\(open == 1 ? "" : "s") in progress") }
        if let next = events.first(where: { $0.start > now }) {
            parts.append("next event \"\(next.title)\" in \(max(1, Int(next.start.timeIntervalSince(now) / 60))) min")
        }
        return parts.isEmpty ? "All quiet." : parts.joined(separator: "; ") + "."
    }
}

// MARK: - What she could do about it

/// Something worth doing that nobody asked for, with her case for it.
public struct Opportunity: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case resumeGoal, stalledGoal, meetingPrep, organizeFolder, lowDisk, overdueTasks, idleApps
    }

    public var kind: Kind
    /// Stable key for cooldowns ("organize|Downloads", "goal|a1b2c3").
    public var key: String
    public var title: String
    /// Why it's worth doing, in her words.
    public var rationale: String
    /// The plan, as goal steps.
    public var steps: [String]
    /// The riskiest thing the plan should need.
    public var risk: ActionRisk
    /// How much it helps (0…1).
    public var value: Double
    /// How time-sensitive it is (0…1).
    public var urgency: Double
    /// Only ever offered, never done unasked (it touches the user's choices: their deadlines, their apps).
    public var offerOnly: Bool
    /// How long before she considers this again after acting on or offering it.
    public var cooldown: TimeInterval
    /// For `.resumeGoal` / `.stalledGoal`.
    public var goalID: UUID?

    public var id: String { key }

    public init(kind: Kind, key: String, title: String, rationale: String, steps: [String] = [], risk: ActionRisk,
                value: Double, urgency: Double, offerOnly: Bool = false, cooldown: TimeInterval, goalID: UUID? = nil) {
        self.kind = kind
        self.key = key
        self.title = title
        self.rationale = rationale
        self.steps = steps
        self.risk = risk
        self.value = value
        self.urgency = urgency
        self.offerOnly = offerOnly
        self.cooldown = cooldown
        self.goalID = goalID
    }
}

public enum OpportunityFinder {
    public static func find(in world: WorldSnapshot) -> [Opportunity] {
        var found: [Opportunity] = []
        let now = world.now

        for goal in world.goals where goal.status == .active {
            guard let next = goal.nextStep else { continue }
            if goal.attempts >= 6 {
                found.append(Opportunity(
                    kind: .stalledGoal, key: "stalled|\(goal.shortID)", title: "Ask for help with \"\(goal.objective)\"",
                    rationale: "I've picked \"\(goal.objective)\" up \(goal.attempts) times and it's stuck on \"\(next.title)\".",
                    risk: .observe, value: 0.6, urgency: 0.4, offerOnly: true, cooldown: 12 * 3_600, goalID: goal.id))
                continue
            }
            let fromUser = goal.origin == .user
            found.append(Opportunity(
                kind: .resumeGoal, key: "goal|\(goal.shortID)", title: "Continue \"\(goal.objective)\"",
                rationale: "\(goal.objective) is \(goal.settledCount)/\(goal.steps.count) done; next is \"\(next.title)\".",
                risk: .reversible, value: fromUser ? 0.9 : 0.6, urgency: fromUser ? 0.6 : 0.3,
                cooldown: fromUser ? 4 * 60 : 15 * 60, goalID: goal.id))
        }

        if let event = world.events.first(where: { (5 * 60)...(25 * 60) ~= $0.start.timeIntervalSince(now) }) {
            let minutes = Int(event.start.timeIntervalSince(now) / 60)
            found.append(Opportunity(
                kind: .meetingPrep, key: "meeting|\(event.title)|\(Int(event.start.timeIntervalSince1970))",
                title: "Get ready for \"\(event.title)\"",
                rationale: "\"\(event.title)\" starts in \(minutes) minutes.",
                steps: [
                    "Check the event details (get_calendar_events) for a link, location, or agenda",
                    "Set a reminder two minutes before it starts",
                    "Open the meeting link or related notes if there are any"
                ],
                risk: .reversible, value: 0.7, urgency: 0.9, cooldown: 3 * 3_600))
        }

        for folder in [world.downloads, world.desktop].compactMap({ $0 }) {
            let cluttered = folder.looseFiles >= 30 || folder.staleFiles >= 15
            guard cluttered else { continue }
            found.append(Opportunity(
                kind: .organizeFolder, key: "organize|\(folder.name)", title: "Tidy \(folder.name)",
                rationale: "\(folder.name) has \(folder.looseFiles) loose files (\(folder.kindSummary)), \(folder.staleFiles) untouched for a month.",
                steps: [
                    "List what's loose in \(folder.path) (ls -la) and count the files",
                    "Make folders by kind inside it (Images, Documents, Installers, Archives, Audio, Videos, Code, Other) with mkdir -p",
                    "Move loose files older than a week into the matching folder with mv -n (never overwrite, never delete)",
                    "Count again to confirm every file is still there, just sorted"
                ],
                risk: .reversible, value: min(0.75, 0.4 + Double(folder.looseFiles) / 200), urgency: 0.2,
                cooldown: 3 * 86_400))
        }

        if let free = world.freeDiskGB, free < 15 {
            found.append(Opportunity(
                kind: .lowDisk, key: "disk", title: "Find what's eating disk space",
                rationale: String(format: "Only %.0f GB of disk is free.", free),
                steps: [
                    "Find the biggest folders in the home folder (du -sh ~/* ~/Library/Caches 2>/dev/null | sort -h | tail)",
                    "Tell the user the top space hogs and what's safe to clear (don't delete anything)"
                ],
                risk: .observe, value: free < 5 ? 0.85 : 0.6, urgency: free < 5 ? 0.9 : 0.4, cooldown: 86_400))
        }

        let overdue = world.openTasks.filter { $0.isOverdue(at: now) }
        if overdue.count >= 3 {
            found.append(Opportunity(
                kind: .overdueTasks, key: "overdue", title: "Triage overdue tasks",
                rationale: "\(overdue.count) tasks are overdue, oldest \"\(overdue.first?.title ?? "")\".",
                risk: .reversible, value: 0.6, urgency: 0.5, offerOnly: true, cooldown: 8 * 3_600))
        }

        if world.unusedRunningApps.count >= 6 {
            found.append(Opportunity(
                kind: .idleApps, key: "apps", title: "Close apps you haven't used today",
                rationale: "\(world.unusedRunningApps.count) apps are open but unused today (\(world.unusedRunningApps.prefix(4).joined(separator: ", "))).",
                risk: .impactful, value: 0.4, urgency: 0.2, offerOnly: true, cooldown: 86_400))
        }
        return found
    }
}

// MARK: - Choosing

/// Weighs the opportunities and picks at most one per tick: do it, offer it, or let it be. Remembers what
/// it tried so she doesn't repeat herself, and keeps a daily budget so she never runs away with the Mac.
public struct InitiativeDecider: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable { case act, offer, skip }

    public struct Verdict: Sendable, Equatable {
        public var opportunity: Opportunity
        public var outcome: Outcome
        public var score: Double
        public var reason: String
    }

    public static let threshold = 0.45
    /// Minimum time between things she starts on her own.
    public static let minimumGap: TimeInterval = 8 * 60
    public static let maxOffersPerDay = 6

    public var lastTried: [String: Date] = [:]
    public var lastInitiativeAt: Date?
    public var day = ""
    public var actsToday = 0
    public var offersToday = 0

    public init() {}

    public static func score(_ opportunity: Opportunity, idleSeconds: TimeInterval) -> Double {
        var score = 0.6 * opportunity.value + 0.4 * opportunity.urgency
        // While they're busy at the keyboard, only time-sensitive things are worth an interruption.
        if idleSeconds < 60, opportunity.urgency < 0.7 { score -= 0.2 }
        return score
    }

    /// Picks what to do. Returns every verdict (for the log), with the chosen one first if there is one.
    public mutating func decide(
        _ opportunities: [Opportunity],
        level: AutonomyLevel,
        world: WorldSnapshot,
        dailyActionBudget: Int
    ) -> [Verdict] {
        let now = world.now
        let today = Self.dayKey(now)
        if today != day {
            day = today
            actsToday = 0
            offersToday = 0
        }
        lastTried = lastTried.filter { now.timeIntervalSince($0.value) < 7 * 86_400 }

        var verdicts: [Verdict] = opportunities.map { opportunity in
            let score = Self.score(opportunity, idleSeconds: world.idleSeconds)
            func skip(_ reason: String) -> Verdict { Verdict(opportunity: opportunity, outcome: .skip, score: score, reason: reason) }

            guard let ceiling = level.ceiling else { return skip("working on my own is off") }
            if world.inMeeting { return skip("they're in a call") }
            if let last = lastTried[opportunity.key], now.timeIntervalSince(last) < opportunity.cooldown {
                return skip("already handled it \(Self.ago(now.timeIntervalSince(last)))")
            }
            if score < Self.threshold { return skip(String(format: "not worth it right now (score %.2f)", score)) }
            // Goals can involve the screen; she picks them up when the user pauses, not mid-typing.
            if opportunity.kind == .resumeGoal, world.idleSeconds < 120 { return skip("they're at the keyboard; I'll continue when they pause") }
            let gap = opportunity.kind == .resumeGoal ? opportunity.cooldown : Self.minimumGap
            if let lastInitiativeAt, now.timeIntervalSince(lastInitiativeAt) < gap {
                return skip("I just did something on my own")
            }
            let mayAct = !opportunity.offerOnly && opportunity.risk <= ceiling
            if mayAct, actsToday < dailyActionBudget {
                return Verdict(opportunity: opportunity, outcome: .act, score: score,
                               reason: String(format: "worth doing (score %.2f) and within what I may do myself", score))
            }
            if offersToday >= Self.maxOffersPerDay { return skip("I've offered enough for one day") }
            let why = opportunity.offerOnly ? "it's their call" : mayAct ? "I've hit today's limit for doing things myself" : "it's beyond what I may do on my own"
            return Verdict(opportunity: opportunity, outcome: .offer, score: score, reason: "\(why), so I'll offer")
        }

        verdicts.sort { a, b in
            if (a.outcome == .skip) != (b.outcome == .skip) { return b.outcome == .skip }
            return a.score > b.score
        }
        // Only the best one goes ahead; the rest wait for a later tick.
        for index in verdicts.indices.dropFirst() where verdicts[index].outcome != .skip {
            verdicts[index].outcome = .skip
            verdicts[index].reason = "something else matters more right now"
        }
        if let chosen = verdicts.first, chosen.outcome != .skip {
            lastTried[chosen.opportunity.key] = now
            lastInitiativeAt = now
            if chosen.outcome == .act { actsToday += 1 } else { offersToday += 1 }
        }
        return verdicts
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 90 { return "\(minutes) min ago" }
        return "\(minutes / 60)h ago"
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}

// MARK: - Briefing the model

/// The hidden notes that hand a self-started job to the agent loop.
public enum InitiativeNotes {
    public static let skipToken = "SKIP"

    private static let ground = "You're doing this on your own initiative, not because they asked, so stay within safe, undoable actions: never delete, send, buy, or overwrite anything. If a step needs that, mark it needs_user with update_goal. Don't take over the mouse or keyboard while they're using the computer; prefer commands. Call update_goal as each step starts and finishes, and verify before marking a step done."

    public static func kickoff(_ opportunity: Opportunity, goal: Goal) -> String {
        let plan = goal.steps.map { "\($0.id). \($0.title)" }.joined(separator: "\n")
        return """
        (Note from the app, not the user: you noticed something and decided to handle it yourself. \(opportunity.rationale)
        Goal [\(goal.shortID)] "\(goal.objective)" is planned:
        \(plan)
        Work through it now with tools; adjust the steps with update_goal if a closer look calls for it. \(ground) When it's done, finish_goal and tell them in one short, friendly sentence what you did. If on a closer look it isn't worth doing, finish_goal as abandoned and reply with exactly \(skipToken).)
        """
    }

    public static func resume(_ goal: Goal) -> String {
        let steps = goal.steps.map { "\($0.id). [\($0.status.rawValue)] \($0.title)\($0.note.map { " — \($0)" } ?? "")" }.joined(separator: "\n")
        let whose = goal.origin == .user ? "They asked you for this earlier; pick it back up and see it through." : "This was your own idea."
        return """
        (Note from the app, not the user: picking up goal [\(goal.shortID)] "\(goal.objective)" again. \(whose)
        \(steps)
        Carry on from the next unfinished step. \(goal.origin == .user ? "Call update_goal as each step starts and finishes, and verify before marking a step done." : ground) When it's all done, finish_goal and tell them in one short sentence. If you're blocked, mark the step needs_user and ask them for exactly what's needed.\(goal.origin == .user ? "" : " If there's nothing useful to do right now, reply with exactly \(skipToken).")))
        """
    }

    /// For an offer (spoken through the proactive voice, not the agent loop).
    public static func offerPrompt(_ opportunity: Opportunity) -> String {
        "Automatic check: \(opportunity.rationale) Offer to \(opportunity.title.prefix(1).lowercased() + opportunity.title.dropFirst()) in one short, friendly spoken line ending with a question. If it doesn't seem helpful right now, reply with exactly \(skipToken)."
    }

    public static func offerFallback(_ opportunity: Opportunity) -> String {
        "\(opportunity.rationale) Want me to \(opportunity.title.prefix(1).lowercased() + opportunity.title.dropFirst()), sugar?"
    }
}
