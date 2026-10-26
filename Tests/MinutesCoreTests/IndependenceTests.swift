import XCTest
@testable import MinutesCore

final class AutonomyPolicyTests: XCTestCase {
    private func call(_ name: String, _ args: [String: JSONValue] = [:]) -> ToolCall {
        ToolCall(id: "1", name: name, arguments: .object(args))
    }

    func testUserRequestsAreNeverGated() {
        let delete = call("delete_task", ["task": "abc"])
        XCTAssertEqual(AutonomyPolicy.decide(delete, initiative: .user, level: .off, userIdleSeconds: 0), .allow)
    }

    func testSafeLevelAllowsUndoableChoresOnly() {
        let decide = { (c: ToolCall) in AutonomyPolicy.decide(c, initiative: .selfDirected, level: .safe, userIdleSeconds: 600) }
        XCTAssertTrue(decide(call("add_task", ["title": "Pay rent"])).isAllowed, "tracking a task is fine")
        XCTAssertTrue(decide(call("look_at_screen")).isAllowed)
        XCTAssertTrue(decide(call("run_shell", ["command": "mkdir -p ~/Downloads/Images && mv -n ~/Downloads/a.png ~/Downloads/Images/"])).isAllowed)
        XCTAssertFalse(decide(call("run_shell", ["command": "mv ~/Downloads/a.png ~/Downloads/Images/"])).isAllowed, "plain mv can overwrite")
        XCTAssertFalse(decide(call("click", ["x": 10, "y": 10])).isAllowed)
        XCTAssertFalse(decide(call("run_shell", ["command": "npm test"])).isAllowed)
    }

    func testSensitiveNeverRunsUnasked() {
        for level in AutonomyLevel.allCases {
            let decide = { (c: ToolCall) in AutonomyPolicy.decide(c, initiative: .selfDirected, level: level, userIdleSeconds: 9_999) }
            XCTAssertFalse(decide(call("delete_task", ["task": "x"])).isAllowed)
            XCTAssertFalse(decide(call("run_shell", ["command": "rm -rf ~/Downloads/old"])).isAllowed)
            XCTAssertFalse(decide(call("type_text", ["text": "Send it to Sam"])).isAllowed)
            XCTAssertFalse(decide(call("press_element", ["label": "Buy now"])).isAllowed)
        }
    }

    func testTrustedKeepsHandsOffWhileUserIsActive() {
        let click = call("click", ["x": 1, "y": 1])
        XCTAssertFalse(AutonomyPolicy.decide(click, initiative: .selfDirected, level: .trusted, userIdleSeconds: 5).isAllowed)
        XCTAssertTrue(AutonomyPolicy.decide(click, initiative: .selfDirected, level: .trusted, userIdleSeconds: 300).isAllowed)
        XCTAssertTrue(AutonomyPolicy.decide(call("run_shell", ["command": "swift test"]), initiative: .selfDirected, level: .trusted, userIdleSeconds: 0).isAllowed)
    }

    func testOffAndSuggestOnlyLook() {
        XCTAssertFalse(AutonomyPolicy.decide(call("read_screen"), initiative: .selfDirected, level: .off, userIdleSeconds: 600).isAllowed)
        XCTAssertTrue(AutonomyPolicy.decide(call("read_screen"), initiative: .selfDirected, level: .suggest, userIdleSeconds: 600).isAllowed)
        XCTAssertFalse(AutonomyPolicy.decide(call("add_task", ["title": "x"]), initiative: .selfDirected, level: .suggest, userIdleSeconds: 600).isAllowed)
    }

    func testUnknownToolsAreTreatedWithCare() {
        XCTAssertEqual(AutonomyPolicy.risk(of: call("brand_new_tool")), .impactful)
    }

    func testShellIntent() {
        XCTAssertEqual(ShellIntent.risk(of: "ls -la ~/Downloads"), .observe)
        XCTAssertEqual(ShellIntent.risk(of: "ls ~/Downloads 2>/dev/null | wc -l"), .observe)
        XCTAssertEqual(ShellIntent.risk(of: "du -sh ~/* ~/Library/Caches 2>/dev/null | sort -h | tail"), .observe)
        XCTAssertEqual(ShellIntent.risk(of: "cd ~/Downloads && mkdir -p Images && mv -n *.png Images/"), .reversible)
        XCTAssertEqual(ShellIntent.risk(of: "mv -fn a b"), .impactful, "-f wins over -n")
        XCTAssertEqual(ShellIntent.risk(of: "brew install jq"), .impactful)
        XCTAssertEqual(ShellIntent.risk(of: "rm old.zip"), .sensitive)
        XCTAssertEqual(ShellIntent.risk(of: "echo hi > notes.txt"), .sensitive, "redirecting can overwrite")
        XCTAssertEqual(ShellIntent.risk(of: "find . -name '*.tmp' -delete"), .sensitive)
        XCTAssertEqual(ShellIntent.risk(of: "git push origin main"), .sensitive)
        XCTAssertEqual(ShellIntent.risk(of: "make 2>&1"), .impactful)
    }
}

final class GoalTests: XCTestCase {
    func testStepsDriveTheGoal() {
        var goal = Goal(objective: "Tidy Downloads", origin: .selfDirected, steps: ["List", "Sort", "Check"])
        XCTAssertEqual(goal.nextStep?.id, 1)
        XCTAssertTrue(goal.setStep(1, to: .done))
        XCTAssertTrue(goal.setStep(2, to: .doing))
        XCTAssertEqual(goal.nextStep?.id, 2)
        XCTAssertNotNil(goal.lastWorkedAt)
        XCTAssertFalse(goal.setStep(9, to: .done), "no such step")

        XCTAssertTrue(goal.setStep(2, to: .needsUser, note: "needs a sign-in"))
        XCTAssertEqual(goal.status, .waiting)
        XCTAssertTrue(goal.summaryLine.contains("waiting on the user"))
        XCTAssertEqual(goal.nextStep?.id, 3, "the blocked step is passed over")

        _ = goal.setStep(2, to: .done)
        XCTAssertEqual(goal.status, .active)
        _ = goal.setStep(3, to: .skipped)
        XCTAssertEqual(goal.status, .done)
        XCTAssertNotNil(goal.outcome)
        XCTAssertFalse(goal.isOpen)

        goal.addSteps(["Tell them"])
        XCTAssertEqual(goal.status, .active, "new steps reopen it")
        XCTAssertEqual(goal.nextStep?.id, 4)
    }

    func testSummaryLine() {
        let goal = Goal(objective: "Ship v2", origin: .user, steps: ["Build", "Test"])
        XCTAssertEqual(goal.summaryLine, "[\(goal.shortID)] Ship v2 — 0/2, next: Build")
    }

    func testContextShowsOpenGoals() {
        let open = Goal(objective: "Ship v2", origin: .user, steps: ["Build"])
        var done = Goal(objective: "Old thing", origin: .user, steps: ["x"])
        _ = done.setStep(1, to: .done)
        let text = AgentContext(goals: [open, done]).render()
        XCTAssertTrue(text.contains("Goals in progress:"))
        XCTAssertTrue(text.contains("Ship v2"))
        XCTAssertFalse(text.contains("Old thing"))
    }
}

final class InitiativeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func world(idle: TimeInterval = 600, downloads: Int = 0, freeGB: Double? = 200, goals: [Goal] = [],
                       events: [UpcomingEvent] = [], tasks: [TrackedTask] = [], inMeeting: Bool = false) -> WorldSnapshot {
        WorldSnapshot(
            now: now, idleSeconds: idle, inMeeting: inMeeting,
            downloads: FolderScan(name: "Downloads", path: "~/Downloads", looseFiles: downloads, staleFiles: downloads / 2, kinds: ["Images": downloads]),
            freeDiskGB: freeGB, openTasks: tasks, events: events, goals: goals
        )
    }

    func testFindsClutterDiskAndMeetings() {
        let found = OpportunityFinder.find(in: world(
            downloads: 80, freeGB: 4,
            events: [UpcomingEvent(title: "Standup", start: now.addingTimeInterval(15 * 60))]
        ))
        let kinds = Set(found.map(\.kind))
        XCTAssertEqual(kinds, [.organizeFolder, .lowDisk, .meetingPrep])
        XCTAssertFalse(found.first { $0.kind == .organizeFolder }!.steps.isEmpty, "comes with a plan")
        XCTAssertTrue(OpportunityFinder.find(in: world(downloads: 5)).isEmpty, "a tidy Mac needs nothing")
    }

    func testGoalsResumeUntilTheyStall() {
        var goal = Goal(objective: "Ship v2", origin: .user, steps: ["Build", "Test"])
        XCTAssertEqual(OpportunityFinder.find(in: world(goals: [goal])).first?.kind, .resumeGoal)
        var decider = InitiativeDecider()
        let typing = world(idle: 10, goals: [goal])
        XCTAssertEqual(decider.decide(OpportunityFinder.find(in: typing), level: .safe, world: typing, dailyActionBudget: 10).first?.outcome, .skip,
                       "never picks a goal up mid-typing")
        XCTAssertFalse(InitiativeNotes.resume(goal).contains(InitiativeNotes.skipToken), "a user's goal is spoken normally, so no SKIP")
        goal.attempts = 6
        let stalled = OpportunityFinder.find(in: world(goals: [goal])).first
        XCTAssertEqual(stalled?.kind, .stalledGoal)
        XCTAssertEqual(stalled?.offerOnly, true)
    }

    func testOverdueTasksAreOnlyOffered() {
        let overdue = (0..<3).map { TrackedTask(title: "T\($0)", dueAt: now.addingTimeInterval(-3_600)) }
        let found = OpportunityFinder.find(in: world(tasks: overdue))
        XCTAssertEqual(found.first?.kind, .overdueTasks)
        XCTAssertEqual(found.first?.offerOnly, true)
    }

    func testPicksOneThingAndRemembersIt() {
        var decider = InitiativeDecider()
        let snapshot = world(downloads: 120, freeGB: 3)
        let verdicts = decider.decide(OpportunityFinder.find(in: snapshot), level: .safe, world: snapshot, dailyActionBudget: 10)
        XCTAssertEqual(verdicts.filter { $0.outcome != .skip }.count, 1, "one thing at a time")
        XCTAssertEqual(verdicts.first?.opportunity.kind, .lowDisk, "most valuable and urgent first")
        XCTAssertEqual(verdicts.first?.outcome, .act, "looking into disk use is within Safe")

        // Right after, she waits; once the gap passes, the next thing comes up, but never the same one again soon.
        var later = snapshot
        later.now = now.addingTimeInterval(60)
        XCTAssertTrue(decider.decide(OpportunityFinder.find(in: later), level: .safe, world: later, dailyActionBudget: 10).allSatisfy { $0.outcome == .skip })
        later.now = now.addingTimeInterval(InitiativeDecider.minimumGap + 1)
        let next = decider.decide(OpportunityFinder.find(in: later), level: .safe, world: later, dailyActionBudget: 10)
        XCTAssertEqual(next.first?.opportunity.kind, .organizeFolder)
        XCTAssertEqual(next.first?.outcome, .act)
        XCTAssertEqual(next.first { $0.opportunity.kind == .lowDisk }?.outcome, .skip)
    }

    func testOffersWhatSheMayNotDo() {
        var decider = InitiativeDecider()
        let snapshot = world(downloads: 120)
        let verdict = decider.decide(OpportunityFinder.find(in: snapshot), level: .suggest, world: snapshot, dailyActionBudget: 10).first
        XCTAssertEqual(verdict?.outcome, .offer)
    }

    func testDailyBudgetTurnsActsIntoOffers() {
        var decider = InitiativeDecider()
        let snapshot = world(downloads: 120)
        XCTAssertEqual(decider.decide(OpportunityFinder.find(in: snapshot), level: .safe, world: snapshot, dailyActionBudget: 0).first?.outcome, .offer)
    }

    func testStaysOutOfTheWay() {
        var decider = InitiativeDecider()
        let off = world(downloads: 120)
        XCTAssertTrue(decider.decide(OpportunityFinder.find(in: off), level: .off, world: off, dailyActionBudget: 10).allSatisfy { $0.outcome == .skip })
        let meeting = world(downloads: 120, inMeeting: true)
        XCTAssertTrue(decider.decide(OpportunityFinder.find(in: meeting), level: .trusted, world: meeting, dailyActionBudget: 10).allSatisfy { $0.outcome == .skip })
        // Busy at the keyboard: low-urgency chores wait.
        let busy = world(idle: 5, downloads: 60)
        XCTAssertTrue(decider.decide(OpportunityFinder.find(in: busy), level: .safe, world: busy, dailyActionBudget: 10).allSatisfy { $0.outcome == .skip })
    }

    func testNotesCarryThePlanAndTheRules() {
        let opportunity = OpportunityFinder.find(in: world(downloads: 120)).first!
        let goal = Goal(objective: opportunity.title, origin: .selfDirected, steps: opportunity.steps)
        let note = InitiativeNotes.kickoff(opportunity, goal: goal)
        XCTAssertTrue(note.contains(goal.shortID))
        XCTAssertTrue(note.contains("never delete"))
        XCTAssertTrue(note.contains(InitiativeNotes.skipToken))
        XCTAssertTrue(InitiativeNotes.resume(goal).contains("1. [pending]"))
    }

    func testSkipReplies() {
        XCTAssertTrue(ChatService.isSkip("SKIP"))
        XCTAssertTrue(ChatService.isSkip(" skip. "))
        XCTAssertFalse(ChatService.isSkip("I skipped the old installers."))
    }

    func testSettingsAndPersonaUpgrade() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"settingsVersion":5}"#.utf8))
        XCTAssertEqual(settings.autonomyLevel, .safe)
        XCTAssertFalse(Persona.isLegacyDefault(Persona.defaultPrompt))
        XCTAssertTrue(Persona.isLegacyDefault("…use the context block (time, what they're doing, tasks, reminders, memories) to be personal…"))
    }
}
