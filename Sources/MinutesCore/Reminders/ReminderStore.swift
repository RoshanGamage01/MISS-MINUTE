import Combine
import Foundation

@MainActor
public final class ReminderStore: ObservableObject {
    @Published public private(set) var reminders: [Reminder] = []

    private let store: JSONFileStore<[Reminder]>
    private var timer: Timer?

    public var onFire: ((Reminder) -> Void)?

    public init(store: JSONFileStore<[Reminder]> = JSONFileStore(url: MinutesPaths.remindersURL)) {
        self.store = store
    }

    public func load() async {
        do {
            reminders = try await store.load(default: [])
                .sorted { $0.fireAt < $1.fireAt }
        } catch {
            reminders = []
        }
        startTimer()
    }

    public func add(parsed: ParsedReminder) async {
        let reminder = Reminder(
            text: parsed.text,
            fireAt: parsed.fireAt,
            sourcePhrase: parsed.matchedPhrase
        )
        reminders.append(reminder)
        reminders.sort { $0.fireAt < $1.fireAt }
        await persist()
    }

    @discardableResult
    public func add(text: String, fireAt: Date) async -> Reminder {
        let reminder = Reminder(text: text, fireAt: fireAt)
        reminders.append(reminder)
        reminders.sort { $0.fireAt < $1.fireAt }
        await persist()
        return reminder
    }

    public var upcoming: [Reminder] {
        reminders.filter { !$0.isFired }
    }

    /// Finds a pending reminder by short ID or text match.
    public func find(_ reference: String) -> Reminder? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ref.isEmpty else { return nil }
        return upcoming.first(where: { $0.shortID == ref })
            ?? upcoming.first(where: { $0.text.lowercased().contains(ref) })
    }

    public func remove(id: UUID) async {
        reminders.removeAll { $0.id == id }
        await persist()
    }

    public func dueReminders(at date: Date = Date()) -> [Reminder] {
        reminders.filter { !$0.isFired && $0.fireAt <= date }
    }

    public func markFired(id: UUID) async {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].isFired = true
        await persist()
    }

    public func pruneFired(olderThan interval: TimeInterval = 86_400) async {
        let cutoff = Date().addingTimeInterval(-interval)
        reminders.removeAll { $0.isFired && $0.fireAt < cutoff }
        await persist()
    }

    private func persist() async {
        try? await store.save(reminders)
    }

    private func startTimer() {
        timer?.invalidate()
        // Timer needs RunLoop; on Linux tests we skip auto-polling.
        #if os(macOS)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkDue()
            }
        }
        #endif
    }

    public func checkDue(now: Date = Date()) async {
        let due = dueReminders(at: now)
        for reminder in due {
            await markFired(id: reminder.id)
            onFire?(reminder)
        }
        await pruneFired()
    }
}
