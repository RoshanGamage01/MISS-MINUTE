import AppKit
import Foundation
import IOKit
import MinutesCore

/// Watches the user's Mac for app switches, finished shell/build jobs, idle return, and display sleep/wake.
@MainActor
final class ActivityMonitor {
    var onEvent: ((ActivityEvent) -> Void)?
    /// Receives focus/idle bookkeeping (screen time, time without a break).
    var usage: UsageTracker?

    private var settingsProvider: () -> AppSettings = { .default }
    private var timer: Timer?
    private var lastFrontAppID: String?
    private var isIdle = false
    private var trackedJobs: [Int32: TrackedJob] = [:]
    private var idlePeakSeconds: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var isPolling = false

    private struct TrackedJob {
        var name: String
        var startedAt: Date
    }

    private let watchedExecutables: Set<String> = [
        "swift", "swiftc", "xcodebuild", "npm", "node", "pnpm", "yarn",
        "cargo", "rustc", "go", "python", "python3", "ruby", "docker",
        "git", "make", "cmake", "gradle", "mvn", "javac", "clang", "gcc",
        "webpack", "vite", "next", "esbuild", "tsc", "bun", "deno"
    ]

    func configure(settingsProvider: @escaping () -> AppSettings) {
        self.settingsProvider = settingsProvider
    }

    func start() {
        guard !started else { return }
        started = true

        let front = NSWorkspace.shared.frontmostApplication
        lastFrontAppID = front?.bundleIdentifier
        if let name = front?.localizedName { usage?.appDidActivate(name) }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleAppActivation(note)
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emit(.screenDidSleep) }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emit(.screenDidWake) }
        })

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        started = false
    }

    private func tick() {
        let settings = settingsProvider()
        guard settings.activityMonitoringEnabled else { return }
        refreshIdleState(settings: settings)
        if settings.announceProcessCompletions {
            pollBackgroundJobsAsync()
        }
    }

    private func handleAppActivation(_ note: Notification) {
        let settings = settingsProvider()
        guard settings.activityMonitoringEnabled else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let bundleID = app.bundleIdentifier ?? ""
        if bundleID == Bundle.main.bundleIdentifier { return }
        if bundleID == lastFrontAppID { return }
        lastFrontAppID = bundleID

        let name = app.localizedName ?? "another app"
        usage?.appDidActivate(name)
        // The proactive engine decides whether this is worth a remark.
        emit(.appActivated(name: name, bundleID: bundleID))
    }

    private func refreshIdleState(settings: AppSettings) {
        let idle = SystemIdle.idleSeconds()
        // Five quiet minutes counts as a break for screen-time purposes.
        if idle >= 5 * 60, !isIdle {
            isIdle = true
            usage?.userWentIdle(idleSince: Date().addingTimeInterval(-idle))
        } else if idle < 5, isIdle {
            isIdle = false
            usage?.userReturned()
        }
        Task { await usage?.tick() }

        if idle >= 15 * 60 {
            idlePeakSeconds = max(idlePeakSeconds, idle)
            return
        }
        if idlePeakSeconds >= 15 * 60, idle < 5 {
            let minutes = max(15, Int(idlePeakSeconds / 60))
            idlePeakSeconds = 0
            emit(.returnedFromIdle(idleMinutes: minutes))
        }
    }

    private func pollBackgroundJobsAsync() {
        guard !isPolling else { return }
        isPolling = true
        let names = watchedExecutables
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = ProcessSnapshot.current(matching: names)
            await MainActor.run {
                self?.applyProcessSnapshot(snapshot)
                self?.isPolling = false
            }
        }
    }

    private func applyProcessSnapshot(_ snapshot: [Int32: String]) {
        let now = Date()
        let currentPIDs = Set(snapshot.keys)

        for (pid, name) in snapshot {
            if trackedJobs[pid] == nil {
                trackedJobs[pid] = TrackedJob(name: name, startedAt: now)
            }
        }

        for pid in trackedJobs.keys.filter({ !currentPIDs.contains($0) }) {
            guard let job = trackedJobs.removeValue(forKey: pid) else { continue }
            let duration = Int(now.timeIntervalSince(job.startedAt))
            guard duration >= 25 else { continue }
            emit(.processFinished(name: job.name, ranForSeconds: duration))
        }

        if trackedJobs.count > 80 {
            trackedJobs = trackedJobs.filter { currentPIDs.contains($0.key) }
        }
    }

    private func emit(_ event: ActivityEvent) {
        guard settingsProvider().activityMonitoringEnabled else { return }
        onEvent?(event)
    }
}

enum SystemIdle {
    /// Seconds since last HID activity. Returns 0 on failure.
    static func idleSeconds() -> TimeInterval {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOHIDSystem")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }

        var unmanagedProps: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanagedProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanagedProps?.takeRetainedValue() as? [String: Any],
              let idleNs = props["HIDIdleTime"] as? UInt64
        else { return 0 }
        return TimeInterval(idleNs) / 1_000_000_000
    }
}

enum ProcessSnapshot {
    static func current(matching names: Set<String>) -> [Int32: String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var result: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(String(trimmed[..<space])) else { continue }
            var comm = String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            if let slash = comm.lastIndex(of: "/") {
                comm = String(comm[comm.index(after: slash)...])
            }
            let base = comm.lowercased()
            if names.contains(base) {
                result[pid] = base
            }
        }
        return result
    }
}
