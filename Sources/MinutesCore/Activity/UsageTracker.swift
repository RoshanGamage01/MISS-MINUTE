import Foundation

public struct AppUsageDay: Codable, Sendable, Equatable {
    public var day: String
    public var seconds: [String: Double]

    public init(day: String, seconds: [String: Double] = [:]) {
        self.day = day
        self.seconds = seconds
    }
}

/// Tracks how long each app is frontmost and how long the user has been continuously active.
/// Pure bookkeeping: the app layer feeds it events.
@MainActor
public final class UsageTracker {
    public private(set) var days: [AppUsageDay] = []
    private var currentApp: String?
    private var currentSince: Date?
    private var activeSince: Date?
    private var lastPersist: Date = .distantPast
    private let store: JSONFileStore<[AppUsageDay]>?
    private let calendar: Calendar

    public init(store: JSONFileStore<[AppUsageDay]>? = JSONFileStore(url: MinutesPaths.usageURL), calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    public func load() async {
        guard let store else { return }
        days = (try? await store.load(default: [])) ?? []
    }

    public func appDidActivate(_ name: String, at now: Date = Date()) {
        flush(at: now)
        currentApp = name
        currentSince = now
        if activeSince == nil { activeSince = now }
    }

    /// Call when the user has been idle long enough to count as a break.
    public func userWentIdle(at now: Date = Date(), idleSince: Date) {
        flush(at: idleSince)
        currentSince = nil
        activeSince = nil
    }

    public func userReturned(at now: Date = Date()) {
        currentSince = now
        activeSince = now
    }

    /// Minutes of continuous activity since the last real break.
    public func continuousActiveMinutes(at now: Date = Date()) -> Int {
        guard let activeSince else { return 0 }
        return Int(now.timeIntervalSince(activeSince) / 60)
    }

    public var frontmostApp: String? { currentApp }

    public func minutesInCurrentApp(at now: Date = Date()) -> Int {
        guard let currentSince else { return 0 }
        return Int(now.timeIntervalSince(currentSince) / 60)
    }

    /// Today's top apps by focused time.
    public func today(at now: Date = Date(), top: Int = 6) -> [(app: String, minutes: Int)] {
        var totals = days.first(where: { $0.day == Self.key(now, calendar) })?.seconds ?? [:]
        if let app = currentApp, let since = currentSince {
            let start = max(since, calendar.startOfDay(for: now))
            totals[app, default: 0] += max(0, now.timeIntervalSince(start))
        }
        return totals.sorted { $0.value > $1.value }
            .prefix(top)
            .map { (app: $0.key, minutes: Int($0.value / 60)) }
            .filter { $0.minutes > 0 }
    }

    public func todaySummary(at now: Date = Date()) -> String {
        let list = today(at: now)
        guard !list.isEmpty else { return "No app usage recorded yet today." }
        return list.map { "\($0.app) \(Self.duration($0.minutes))" }.joined(separator: ", ")
    }

    /// Persists periodically; safe to call often.
    public func tick(at now: Date = Date()) async {
        guard now.timeIntervalSince(lastPersist) > 120 else { return }
        flush(at: now)
        if currentApp != nil, currentSince != nil { currentSince = now }
        lastPersist = now
        if let store { try? await store.save(days) }
    }

    private func flush(at now: Date) {
        guard let app = currentApp, let since = currentSince, now > since else { return }
        // Split across midnight.
        var start = since
        while start < now {
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? now
            let end = min(dayEnd, now)
            add(app: app, seconds: end.timeIntervalSince(start), day: Self.key(start, calendar))
            start = end
        }
        currentSince = now
    }

    private func add(app: String, seconds: Double, day: String) {
        if let index = days.firstIndex(where: { $0.day == day }) {
            days[index].seconds[app, default: 0] += seconds
        } else {
            days.append(AppUsageDay(day: day, seconds: [app: seconds]))
            if days.count > 14 { days.removeFirst(days.count - 14) }
        }
    }

    nonisolated static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    nonisolated public static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
