import Combine
import Foundation

public enum TaskPriority: String, Codable, CaseIterable, Sendable {
    case low
    case normal
    case high
}

public struct TrackedTask: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var notes: String?
    public var dueAt: Date?
    public var priority: TaskPriority
    public var isDone: Bool
    public var createdAt: Date
    public var completedAt: Date?
    /// Last time Miss Minute nudged about this task (so she doesn't nag).
    public var lastNudgedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String? = nil,
        dueAt: Date? = nil,
        priority: TaskPriority = .normal,
        isDone: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        lastNudgedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.priority = priority
        self.isDone = isDone
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.lastNudgedAt = lastNudgedAt
    }

    public func isOverdue(at now: Date = Date()) -> Bool {
        guard !isDone, let dueAt else { return false }
        return dueAt < now
    }

    /// Short stable handle the model can use to refer to a task.
    public var shortID: String { String(id.uuidString.prefix(6)).lowercased() }
}

@MainActor
public final class TaskStore: ObservableObject {
    @Published public private(set) var tasks: [TrackedTask] = []

    private let store: JSONFileStore<[TrackedTask]>

    public init(store: JSONFileStore<[TrackedTask]> = JSONFileStore(url: MinutesPaths.tasksURL)) {
        self.store = store
    }

    public func load() async {
        tasks = (try? await store.load(default: [])) ?? []
    }

    public var openTasks: [TrackedTask] {
        tasks.filter { !$0.isDone }.sorted(by: Self.ordering)
    }

    public func overdue(at now: Date = Date()) -> [TrackedTask] {
        openTasks.filter { $0.isOverdue(at: now) }
    }

    public func dueToday(at now: Date = Date(), calendar: Calendar = .current) -> [TrackedTask] {
        openTasks.filter { task in
            guard let due = task.dueAt else { return false }
            return calendar.isDate(due, inSameDayAs: now) && due >= now
        }
    }

    @discardableResult
    public func add(title: String, notes: String? = nil, dueAt: Date? = nil, priority: TaskPriority = .normal) async -> TrackedTask {
        let task = TrackedTask(title: title, notes: notes, dueAt: dueAt, priority: priority)
        tasks.append(task)
        await persist()
        return task
    }

    public func update(id: UUID, _ mutate: (inout TrackedTask) -> Void) async {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
        await persist()
    }

    public func setDone(id: UUID, _ done: Bool = true) async {
        await update(id: id) {
            $0.isDone = done
            $0.completedAt = done ? Date() : nil
        }
    }

    public func remove(id: UUID) async {
        tasks.removeAll { $0.id == id }
        await persist()
    }

    /// Finds a task by short ID, full UUID, or fuzzy title match.
    public func find(_ reference: String) -> TrackedTask? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ref.isEmpty else { return nil }
        if let exact = tasks.first(where: { $0.shortID == ref || $0.id.uuidString.lowercased() == ref }) {
            return exact
        }
        let candidates = tasks.sorted { !$0.isDone && $1.isDone }
        if let title = candidates.first(where: { $0.title.lowercased() == ref }) { return title }
        return candidates.first(where: { $0.title.lowercased().contains(ref) || ref.contains($0.title.lowercased()) })
    }

    /// Removes completed tasks older than a week.
    public func pruneCompleted(olderThan interval: TimeInterval = 7 * 86_400) async {
        let cutoff = Date().addingTimeInterval(-interval)
        let before = tasks.count
        tasks.removeAll { $0.isDone && ($0.completedAt ?? $0.createdAt) < cutoff }
        if tasks.count != before { await persist() }
    }

    private func persist() async {
        try? await store.save(tasks)
    }

    static func ordering(_ a: TrackedTask, _ b: TrackedTask) -> Bool {
        switch (a.dueAt, b.dueAt) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            let rank: [TaskPriority: Int] = [.high: 0, .normal: 1, .low: 2]
            if a.priority != b.priority { return rank[a.priority]! < rank[b.priority]! }
            return a.createdAt < b.createdAt
        }
    }
}
