import Combine
import Foundation

/// A bigger objective she works through step by step, across turns and app restarts, until it's done.
public struct Goal: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case active
        /// Waiting on the user (a sign-in, a go-ahead for something sensitive).
        case waiting
        case done
        case abandoned
    }

    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public enum Status: String, Codable, Sendable, CaseIterable {
            case pending
            case doing
            case done
            case skipped
            case failed
            /// Needs the user before it can go on.
            case needsUser = "needs_user"

            public var isSettled: Bool { self == .done || self == .skipped }
        }

        public var id: Int
        public var title: String
        public var status: Status
        public var note: String?
        public var updatedAt: Date?

        public init(id: Int, title: String, status: Status = .pending, note: String? = nil, updatedAt: Date? = nil) {
            self.id = id
            self.title = title
            self.status = status
            self.note = note
            self.updatedAt = updatedAt
        }
    }

    public var id: UUID
    public var objective: String
    /// Who set it: the user, or she did after noticing something.
    public var origin: Initiative
    public var status: Status
    public var steps: [Step]
    public var createdAt: Date
    public var updatedAt: Date
    /// Last time she picked it up (so the loop paces itself).
    public var lastWorkedAt: Date?
    /// Turns spent on it without finishing; a goal that keeps stalling gets handed back to the user.
    public var attempts: Int
    /// What came of it, once finished.
    public var outcome: String?

    public init(
        id: UUID = UUID(),
        objective: String,
        origin: Initiative,
        steps: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.objective = objective
        self.origin = origin
        self.status = .active
        self.steps = steps.enumerated().map { Step(id: $0.offset + 1, title: $0.element) }
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.lastWorkedAt = nil
        self.attempts = 0
        self.outcome = nil
    }

    public var shortID: String { String(id.uuidString.prefix(6)).lowercased() }
    public var isOpen: Bool { status == .active || status == .waiting }
    public var settledCount: Int { steps.filter { $0.status.isSettled }.count }

    /// The step to work on next: one in progress, else the first not yet settled.
    public var nextStep: Step? {
        steps.first { $0.status == .doing } ?? steps.first { !$0.status.isSettled && $0.status != .needsUser && $0.status != .failed }
            ?? steps.first { $0.status == .failed }
    }

    /// Records progress on a step. A step that needs the user puts the goal on hold; settling the last one
    /// finishes it.
    public mutating func setStep(_ stepID: Int, to status: Step.Status, note: String? = nil, at now: Date = Date()) -> Bool {
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else { return false }
        steps[index].status = status
        if let note, !note.isEmpty { steps[index].note = note }
        steps[index].updatedAt = now
        updatedAt = now
        if status == .doing { lastWorkedAt = now }
        if steps.contains(where: { $0.status == .needsUser }) {
            self.status = .waiting
        } else if steps.allSatisfy({ $0.status.isSettled }) {
            self.status = .done
            if outcome == nil { outcome = "All \(steps.count) steps done." }
        } else {
            self.status = .active
        }
        return true
    }

    /// Adds steps discovered along the way.
    public mutating func addSteps(_ titles: [String], at now: Date = Date()) {
        var next = (steps.map(\.id).max() ?? 0) + 1
        for title in titles where !title.trimmingCharacters(in: .whitespaces).isEmpty {
            steps.append(Step(id: next, title: title))
            next += 1
        }
        if status == .done { status = .active }
        updatedAt = now
    }

    public mutating func finish(_ status: Status, outcome: String?, at now: Date = Date()) {
        self.status = status
        if let outcome, !outcome.isEmpty { self.outcome = outcome }
        updatedAt = now
    }

    /// One line for the context block and the log: "[a1b2c3] Tidy Downloads — 2/4, next: Move PDFs into Documents".
    public var summaryLine: String {
        var line = "[\(shortID)] \(objective) — \(settledCount)/\(steps.count)"
        switch status {
        case .waiting:
            let blocker = steps.first { $0.status == .needsUser }
            line += ", waiting on the user" + (blocker.map { ": \($0.title)" } ?? "")
        case .done, .abandoned:
            line += ", \(status.rawValue)"
        case .active:
            if let next = nextStep { line += ", next: \(next.title)" }
        }
        if origin == .selfDirected { line += " (your own idea)" }
        return line
    }
}

@MainActor
public final class GoalStore: ObservableObject {
    @Published public private(set) var goals: [Goal] = []
    /// A goal changed (for the thought log).
    public var onChange: ((Goal, String) -> Void)?

    private let store: JSONFileStore<[Goal]>

    public init(store: JSONFileStore<[Goal]> = JSONFileStore(url: MinutesPaths.goalsURL)) {
        self.store = store
    }

    public func load() async {
        goals = (try? await store.load(default: [])) ?? []
    }

    public var open: [Goal] { goals.filter(\.isOpen).sorted { $0.createdAt < $1.createdAt } }
    public var active: [Goal] { goals.filter { $0.status == .active } }

    @discardableResult
    public func add(objective: String, steps: [String], origin: Initiative) async -> Goal {
        let goal = Goal(objective: objective, origin: origin, steps: steps)
        goals.append(goal)
        onChange?(goal, "New goal: \(objective) (\(steps.count) steps)")
        await persist()
        return goal
    }

    public func update(id: UUID, _ mutate: (inout Goal) -> Void) async {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        mutate(&goals[index])
        await persist()
    }

    /// Updates one step and reports the change.
    @discardableResult
    public func setStep(goal id: UUID, step: Int, status: Goal.Step.Status, note: String?) async -> Goal? {
        guard let index = goals.firstIndex(where: { $0.id == id }),
              goals[index].setStep(step, to: status, note: note) else { return nil }
        let goal = goals[index]
        let title = goal.steps.first { $0.id == step }?.title ?? "step \(step)"
        var line = "\(goal.objective): \(title) → \(status.rawValue.replacingOccurrences(of: "_", with: " "))"
        if let note, !note.isEmpty { line += " (\(note))" }
        onChange?(goal, line)
        if goal.status == .done { onChange?(goal, "Goal done: \(goal.objective)") }
        await persist()
        return goal
    }

    public func finish(id: UUID, status: Goal.Status, outcome: String?) async {
        await update(id: id) { $0.finish(status, outcome: outcome) }
        if let goal = goals.first(where: { $0.id == id }) {
            onChange?(goal, "Goal \(status.rawValue): \(goal.objective)" + (outcome.map { " — \($0)" } ?? ""))
        }
    }

    /// Marks that she's picking a goal up again.
    public func markWorked(id: UUID, at now: Date = Date()) async {
        await update(id: id) {
            $0.lastWorkedAt = now
            $0.attempts += 1
        }
    }

    /// By short ID, full UUID, or part of the objective.
    public func find(_ reference: String) -> Goal? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ref.isEmpty else { return nil }
        if let exact = goals.first(where: { $0.shortID == ref || $0.id.uuidString.lowercased() == ref }) { return exact }
        let candidates = goals.sorted { $0.isOpen && !$1.isOpen }
        return candidates.first { $0.objective.lowercased().contains(ref) || ref.contains($0.objective.lowercased()) }
    }

    /// Drops finished goals older than a week.
    public func pruneFinished(olderThan interval: TimeInterval = 7 * 86_400, now: Date = Date()) async {
        let before = goals.count
        goals.removeAll { !$0.isOpen && now.timeIntervalSince($0.updatedAt) > interval }
        if goals.count != before { await persist() }
    }

    private func persist() async {
        try? await store.save(goals)
    }
}

/// Tools for working toward a bigger objective: plan it as steps, then record each step as it goes.
@MainActor
public enum GoalTools {
    public static func all(store: GoalStore, initiative: @escaping () -> Initiative) -> [AgentTool] {
        let goalRef: JSONValue = ["type": "string", "description": "Goal short id (from list_goals or the context) or part of its objective."]
        return [
            AgentTool(spec: .object(
                "start_goal",
                "Plan a multi-step objective before working on it (\"get my Downloads folder organized\", \"set up a Python project and get its tests passing\", \"prepare for tomorrow's 10am meeting\"). Break it into 2–8 concrete, checkable steps in order. Then work through them, calling update_goal as each starts and finishes. Skip this for one-step requests.",
                properties: [
                    "objective": ["type": "string", "description": "The outcome, in a short phrase."],
                    "steps": ["type": "array", "items": ["type": "string"], "description": "Concrete actions in order, each short and checkable."]
                ],
                required: ["objective", "steps"]
            )) { args in
                let objective = try args.requiredString("objective")
                let steps = (args["steps"]?.arrayValue ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard !steps.isEmpty else { throw ToolError("Give at least one step.") }
                if let existing = store.open.first(where: { $0.objective.caseInsensitiveCompare(objective) == .orderedSame }) {
                    return .ok("That goal already exists: \(existing.summaryLine). Continue it with update_goal.")
                }
                let goal = await store.add(objective: objective, steps: Array(steps.prefix(12)), origin: initiative())
                let plan = goal.steps.map { "\($0.id). \($0.title)" }.joined(separator: "\n")
                return .ok("Goal [\(goal.shortID)] planned:\n\(plan)\nStart on step 1 now (update_goal with status doing, then done).",
                           summary: "Planned: \(objective) (\(goal.steps.count) steps)")
            },

            AgentTool(spec: .object(
                "update_goal",
                "Record progress on a goal step: doing when you start it, done when it's verified, failed if it didn't work (then try another way), skipped if it turned out unnecessary, needs_user if only the user can do it (a sign-in, a go-ahead to send or delete). You can also add steps you discover.",
                properties: [
                    "goal": goalRef,
                    "step": ["type": "integer", "description": "Step number."],
                    "status": ["type": "string", "enum": .array(Goal.Step.Status.allCases.map { .string($0.rawValue) })],
                    "note": ["type": "string", "description": "What happened, in a few words."],
                    "add_steps": ["type": "array", "items": ["type": "string"], "description": "New steps to append."]
                ],
                required: ["goal"]
            )) { args in
                guard let goal = store.find(try args.requiredString("goal")) else {
                    throw ToolError("No goal matches that. Call list_goals.")
                }
                let added = (args["add_steps"]?.arrayValue ?? []).compactMap(\.stringValue)
                if !added.isEmpty { await store.update(id: goal.id) { $0.addSteps(added) } }
                var current = store.goals.first { $0.id == goal.id } ?? goal
                if let step = args["step"]?.intValue {
                    guard let raw = args.optionalString("status"), let status = Goal.Step.Status(rawValue: raw) else {
                        throw ToolError("Give a status for step \(step).")
                    }
                    guard let updated = await store.setStep(goal: goal.id, step: step, status: status, note: args.optionalString("note")) else {
                        throw ToolError("Goal [\(goal.shortID)] has no step \(step).")
                    }
                    current = updated
                }
                var text = current.summaryLine
                switch current.status {
                case .done: text += "\nAll steps are done. Check the overall result, then finish_goal with a one-line outcome."
                case .waiting: text += "\nOn hold until the user helps. Ask them for exactly what's needed, in one short sentence."
                case .active: if let next = current.nextStep { text += "\nNext: step \(next.id), \(next.title)." }
                case .abandoned: break
                }
                let stepTitle = args["step"]?.intValue.flatMap { id in current.steps.first { $0.id == id }?.title }
                return .ok(text, summary: stepTitle.map { "\(current.objective): \($0)" })
            },

            AgentTool(spec: .object(
                "list_goals",
                "List goals in progress with their steps.",
                properties: ["include_finished": ["type": "boolean"]]
            )) { args in
                let list = (args["include_finished"]?.boolValue ?? false) ? store.goals : store.open
                guard !list.isEmpty else { return .ok("No goals in progress.") }
                return .ok(list.map { goal in
                    ([goal.summaryLine] + goal.steps.map { "  \($0.id). [\($0.status.rawValue)] \($0.title)\($0.note.map { " — \($0)" } ?? "")" })
                        .joined(separator: "\n")
                }.joined(separator: "\n"))
            },

            AgentTool(spec: .object(
                "finish_goal",
                "Close a goal: done once the objective is achieved and checked, or abandoned if it can't or shouldn't be done (say why).",
                properties: [
                    "goal": goalRef,
                    "status": ["type": "string", "enum": ["done", "abandoned"]],
                    "outcome": ["type": "string", "description": "One line on what came of it."]
                ],
                required: ["goal", "status"]
            )) { args in
                guard let goal = store.find(try args.requiredString("goal")) else {
                    throw ToolError("No goal matches that. Call list_goals.")
                }
                let status: Goal.Status = args.optionalString("status") == "abandoned" ? .abandoned : .done
                await store.finish(id: goal.id, status: status, outcome: args.optionalString("outcome"))
                return .ok("Goal [\(goal.shortID)] \(status.rawValue).", summary: "\(status == .done ? "Finished" : "Dropped"): \(goal.objective)")
            }
        ]
    }
}
