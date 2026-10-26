import AppKit
import Foundation
import MinutesCore

/// Her own initiative: every minute she looks around (folders, disk, calendar, tasks, open goals), weighs what's
/// worth doing, and then does it, offers it, or lets it be. Every step of that reasoning goes to the thought log.
/// The user always comes first: she only starts when nothing else has her attention, and any message from them
/// pauses her work.
@MainActor
final class AutonomyLoop {
    /// What she can do with a decision. Wired up by the app model.
    /// Hands work to the agent. Goals the user gave her keep their authority (`.user`); her own ideas are `.selfDirected`.
    var startWork: ((_ note: String, _ initiative: Initiative) -> Void)?
    var offer: ((_ prompt: String, _ fallback: String) -> Void)?
    /// True while she's talking, listening, or already working on something.
    var isBusy: () -> Bool = { true }
    var inMeeting: () -> Bool = { false }
    var frontApp: () -> String? = { nil }
    var upcomingEvents: () -> [UpcomingEvent] = { [] }
    var appsUsedToday: () -> Set<String> = { [] }

    private let settings: () -> AppSettings
    private let goals: GoalStore
    private let tasks: TaskStore
    private let thoughts: ThoughtLog
    private var decider = InitiativeDecider()
    private var timer: Timer?
    private var lastSummary = ""
    /// Last reason logged for passing on each opportunity, so the log only shows changes of mind.
    private var lastSkipReason: [String: String] = [:]
    private var lastScanAt: Date = .distantPast
    private var cachedScan: (downloads: FolderScan?, desktop: FolderScan?, freeGB: Double?) = (nil, nil, nil)
    /// The goal her current self-started turn is working on.
    private(set) var workingGoalID: UUID?

    init(settings: @escaping () -> AppSettings, goals: GoalStore, tasks: TaskStore, thoughts: ThoughtLog) {
        self.settings = settings
        self.goals = goals
        self.tasks = tasks
        self.thoughts = thoughts
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        // First look a little after launch, once the greeting/briefing is out of the way.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            await self?.tick()
        }
    }

    /// Her self-started turn finished (or was paused for the user).
    func workEnded(reply: String?, toolsUsed: [String], error: String?) {
        let goal = workingGoalID.flatMap { id in goals.goals.first { $0.id == id } }
        workingGoalID = nil
        let name = goal.map { "\"\($0.objective)\"" } ?? "my own task"
        if let error {
            thoughts.add(.heldBack, "Stopped working on \(name): \(error)")
        } else if let reply {
            thoughts.add(.acted, "Finished a stretch on \(name) (\(toolsUsed.count) step\(toolsUsed.count == 1 ? "" : "s")). Told them: \(reply)")
        } else {
            thoughts.add(.considered, "Took a closer look at \(name) and decided it wasn't worth doing right now.")
        }
    }

    // MARK: - The loop

    func tick(now: Date = Date()) async {
        let s = settings()
        guard s.autonomyLevel != .off else { return }
        // Never compete with the user (or with herself).
        guard !isBusy() else { return }

        let world = await observe(now: now)
        if world.summary != lastSummary {
            lastSummary = world.summary
            thoughts.add(.noticed, world.summary, at: now)
        }

        let opportunities = OpportunityFinder.find(in: world)
        guard !opportunities.isEmpty else { return }
        let verdicts = decider.decide(opportunities, level: s.autonomyLevel, world: world, dailyActionBudget: s.autonomyDailyActions)
        for verdict in verdicts where verdict.outcome == .skip && !verdict.reason.hasPrefix("already handled") {
            guard lastSkipReason[verdict.opportunity.key] != verdict.reason else { continue }
            lastSkipReason[verdict.opportunity.key] = verdict.reason
            thoughts.add(.considered, "\(verdict.opportunity.title)? Not now: \(verdict.reason).", at: now)
        }
        guard let chosen = verdicts.first, chosen.outcome != .skip else { return }
        lastSkipReason[chosen.opportunity.key] = nil
        await carryOut(chosen, at: now)
    }

    private func carryOut(_ verdict: InitiativeDecider.Verdict, at now: Date) async {
        let opportunity = verdict.opportunity
        switch verdict.outcome {
        case .skip:
            return
        case .offer:
            thoughts.add(.decided, "\(opportunity.rationale) I'll offer to \(opportunity.title.lowercased()), since \(verdict.reason.replacingOccurrences(of: ", so I'll offer", with: "")).", at: now)
            offer?(InitiativeNotes.offerPrompt(opportunity), InitiativeNotes.offerFallback(opportunity))
        case .act:
            let goal: Goal
            if let id = opportunity.goalID, let existing = goals.goals.first(where: { $0.id == id }) {
                goal = existing
                let whose = goal.origin == .user ? "They asked for this, so I'll see it through" : "Picking my own task back up"
                thoughts.add(.decided, "\(whose): \(opportunity.rationale)", at: now)
                workingGoalID = goal.origin == .selfDirected ? goal.id : nil
                startWork?(InitiativeNotes.resume(goal), goal.origin)
            } else {
                goal = await goals.add(objective: opportunity.title, steps: opportunity.steps, origin: .selfDirected)
                thoughts.add(.decided, "\(opportunity.rationale) I'll \(opportunity.title.lowercased()) myself (\(verdict.reason)).", at: now)
                workingGoalID = goal.id
                startWork?(InitiativeNotes.kickoff(opportunity, goal: goal), .selfDirected)
            }
            await goals.markWorked(id: goal.id, at: now)
        }
    }

    // MARK: - Looking around

    private func observe(now: Date) async -> WorldSnapshot {
        // Folder and disk scans touch the file system: every 10 minutes is plenty.
        if now.timeIntervalSince(lastScanAt) > 10 * 60 {
            lastScanAt = now
            cachedScan = await Task.detached(priority: .utility) {
                let home = FileManager.default.homeDirectoryForCurrentUser
                return (
                    SystemScan.folder(home.appendingPathComponent("Downloads"), name: "Downloads", now: now),
                    SystemScan.folder(home.appendingPathComponent("Desktop"), name: "Desktop", now: now),
                    SystemScan.freeDiskGB()
                )
            }.value
        }
        let used = appsUsedToday()
        let unused = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName)
            .filter { !used.contains($0) && !SystemScan.alwaysOn.contains($0) }
        return WorldSnapshot(
            now: now,
            idleSeconds: SystemIdle.idleSeconds(),
            inMeeting: inMeeting(),
            frontApp: frontApp(),
            downloads: cachedScan.downloads,
            desktop: cachedScan.desktop,
            freeDiskGB: cachedScan.freeGB,
            openTasks: tasks.openTasks,
            events: upcomingEvents(),
            goals: goals.goals,
            unusedRunningApps: unused
        )
    }
}

/// File-system reads for the autonomy loop. Read-only.
enum SystemScan {
    /// Apps that are meant to stay open; never suggested for closing.
    static let alwaysOn: Set<String> = ["Finder", "Minutes", "Miss Minute"]

    static func folder(_ url: URL, name: String, now: Date) -> FolderScan? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .contentAccessDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        var loose = 0
        var stale = 0
        var kinds: [String: Int] = [:]
        for item in items {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            loose += 1
            kinds[FolderScan.kind(ofExtension: item.pathExtension), default: 0] += 1
            let touched = max(values.contentModificationDate ?? .distantPast, values.contentAccessDate ?? .distantPast)
            if now.timeIntervalSince(touched) > 30 * 86_400 { stale += 1 }
        }
        return FolderScan(name: name, path: "~/\(url.lastPathComponent)", looseFiles: loose, staleFiles: stale, kinds: kinds)
    }

    static func freeDiskGB() -> Double? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(bytes) / 1_000_000_000
    }
}
