import AppKit
import EventKit
import Foundation
import IOKit.ps
import MinutesCore

/// Tools that act on the Mac itself: apps, links, clipboard, Shortcuts, calendar, and status.
@MainActor
enum SystemTools {
    static func all(usage: UsageTracker, calendar: CalendarService) -> [AgentTool] {
        [
            AgentTool(spec: .object(
                "open_app",
                "Open (or bring forward) a Mac app by name, e.g. \"Notes\", \"Spotify\", \"Xcode\".",
                properties: ["name": ["type": "string"]],
                required: ["name"]
            )) { args in
                let name = try args.requiredString("name")
                let result = await Shell.run("/usr/bin/open", ["-a", name])
                guard result.status == 0 else { throw ToolError("Couldn't find an app called \(name).") }
                return .ok("Opened \(name).", summary: "Opened \(name)")
            },

            AgentTool(spec: .object(
                "open_url",
                "Open a web link (or mailto:, maps:, etc.) in the default app.",
                properties: ["url": ["type": "string"]],
                required: ["url"]
            )) { args in
                var raw = try args.requiredString("url")
                if !raw.contains("://"), !raw.hasPrefix("mailto:") { raw = "https://" + raw }
                guard let url = URL(string: raw), NSWorkspace.shared.open(url) else {
                    throw ToolError("That doesn't look like a link I can open.")
                }
                return .ok("Opened \(raw).", summary: "Opened \(url.host ?? raw)")
            },

            AgentTool(spec: .object(
                "copy_to_clipboard",
                "Put text on the user's clipboard (drafts, snippets, addresses).",
                properties: ["text": ["type": "string"]],
                required: ["text"]
            )) { args in
                let text = try args.requiredString("text")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return .ok("Copied \(text.count) characters.", summary: "Copied to clipboard")
            },

            AgentTool(spec: .object(
                "read_clipboard",
                "Read the text currently on the clipboard. Only when the user refers to what they copied."
            )) { _ in
                guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                    return .ok("The clipboard has no text.")
                }
                return .ok(String(text.prefix(8_000)), summary: "Read the clipboard")
            },

            AgentTool(spec: .object("list_shortcuts", "List the user's Apple Shortcuts by name.")) { _ in
                let result = await Shell.run("/usr/bin/shortcuts", ["list"])
                guard result.status == 0 else { throw ToolError("Couldn't list Shortcuts.") }
                let names = result.output.split(separator: "\n").prefix(150).joined(separator: "\n")
                return .ok(names.isEmpty ? "No shortcuts found." : names)
            },

            AgentTool(spec: .object(
                "run_shortcut",
                "Run one of the user's Apple Shortcuts by exact name (home automation, messages, music, anything they've built). Use list_shortcuts if unsure of the name.",
                properties: [
                    "name": ["type": "string"],
                    "input": ["type": "string", "description": "Optional text input for the shortcut."]
                ],
                required: ["name"]
            )) { args in
                let name = try args.requiredString("name")
                var arguments = ["run", name]
                var inputFile: URL?
                if let input = args.optionalString("input") {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("mm-shortcut-\(UUID().uuidString).txt")
                    try input.write(to: file, atomically: true, encoding: .utf8)
                    arguments += ["--input-path", file.path]
                    inputFile = file
                }
                defer { if let inputFile { try? FileManager.default.removeItem(at: inputFile) } }
                let result = await Shell.run("/usr/bin/shortcuts", arguments, timeout: 60)
                guard result.status == 0 else {
                    throw ToolError("Shortcut '\(name)' failed: \(result.error.prefix(300))")
                }
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return .ok(output.isEmpty ? "Ran '\(name)'." : "Ran '\(name)'. Output: \(output.prefix(2_000))",
                           summary: "Ran shortcut: \(name)")
            },

            AgentTool(spec: .object(
                "get_activity_summary",
                "How the user's day is going on this Mac: frontmost app, time without a break, and today's screen time by app."
            )) { _ in
                let now = Date()
                var lines: [String] = []
                if let app = usage.frontmostApp {
                    lines.append("Frontmost: \(app) for \(UsageTracker.duration(usage.minutesInCurrentApp(at: now))).")
                }
                lines.append("Active without a break: \(UsageTracker.duration(usage.continuousActiveMinutes(at: now))).")
                lines.append("Today: \(usage.todaySummary(at: now))")
                return .ok(lines.joined(separator: "\n"))
            },

            AgentTool(spec: .object("get_system_status", "Battery, storage, and uptime of this Mac.")) { _ in
                .ok(SystemStatus.summary())
            },

            AgentTool(spec: .object(
                "get_calendar_events",
                "List calendar events in a window of days from today.",
                properties: [
                    "days_ahead": ["type": "number", "description": "Days to look ahead (default 1, max 31)."],
                    "days_back": ["type": "number", "description": "Days to look back (default 0)."]
                ]
            )) { args in
                guard await calendar.ensureAccess() else {
                    throw ToolError("No calendar access. The user can turn it on in Settings → Awareness.")
                }
                let ahead = min(31, max(0, args["days_ahead"]?.doubleValue ?? 1))
                let back = min(31, max(0, args["days_back"]?.doubleValue ?? 0))
                let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-back * 86_400)
                let end = Date().addingTimeInterval(max(ahead, 0.04) * 86_400)
                let lines = calendar.eventLines(from: start, to: end)
                return .ok(lines.isEmpty ? "No events in that window." : lines.joined(separator: "\n"))
            },

            AgentTool(spec: .object(
                "create_calendar_event",
                "Add an event to the user's default calendar. Confirm details with the user first if anything is ambiguous.",
                properties: [
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "Local start, ISO 8601 like 2026-10-27T14:00."],
                    "end": ["type": "string", "description": "Local end; defaults to one hour after start."],
                    "location": ["type": "string"],
                    "notes": ["type": "string"]
                ],
                required: ["title", "start"]
            )) { args in
                guard await calendar.ensureAccess() else {
                    throw ToolError("No calendar access. The user can turn it on in Settings → Awareness.")
                }
                let title = try args.requiredString("title")
                guard let start = ToolDates.parse(try args.requiredString("start")) else { throw ToolError("Unreadable start time.") }
                let end = args.optionalString("end").flatMap { ToolDates.parse($0) } ?? start.addingTimeInterval(3_600)
                try calendar.createEvent(title: title, start: start, end: end,
                                         location: args.optionalString("location"), notes: args.optionalString("notes"))
                return .ok("Added '\(title)' at \(ToolDates.stamp(start)).",
                           summary: "Calendar: \(title), \(ToolDates.describe(start))")
            }
        ]
    }
}

// MARK: - Calendar

@MainActor
final class CalendarService {
    private let store = EKEventStore()
    var isEnabled: () -> Bool = { false }

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Requests access if the user enabled calendar awareness.
    func ensureAccess() async -> Bool {
        guard isEnabled() else { return false }
        if hasAccess { return true }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    func eventLines(from start: Date, to end: Date) -> [String] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(40)
            .map { event in
                var line = event.isAllDay
                    ? "\(event.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) all day"
                    : "\(ToolDates.stamp(event.startDate))–\(event.endDate.formatted(date: .omitted, time: .shortened))"
                line += " \(event.title ?? "Untitled")"
                if let location = event.location, !location.isEmpty { line += " @ \(location)" }
                return line
            }
    }

    /// Events in the next day, for the context block. Empty without access.
    func upcomingLines() -> [String] {
        guard isEnabled(), hasAccess else { return [] }
        return eventLines(from: Date(), to: Date().addingTimeInterval(86_400))
    }

    func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?) throws {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = max(end, start.addingTimeInterval(300))
        event.location = location
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }
}

// MARK: - Helpers

enum Shell {
    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
    }

    /// Runs a process off the main thread.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                return Result(status: -1, output: "", error: error.localizedDescription)
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning { process.terminate() }
            let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return Result(status: process.isRunning ? -1 : process.terminationStatus, output: output, error: error)
        }.value
    }
}

enum SystemStatus {
    static func summary() -> String {
        var lines: [String] = []
        if let battery = batteryLine() { lines.append(battery) }
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity {
            let gb = { (bytes: Int64) in String(format: "%.0f GB", Double(bytes) / 1_000_000_000) }
            lines.append("Storage: \(gb(free)) free of \(gb(Int64(total))).")
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        lines.append("Uptime: \(UsageTracker.duration(Int(uptime / 60))).")
        let memory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        lines.append(String(format: "Memory: %.0f GB installed.", memory))
        return lines.joined(separator: "\n")
    }

    static func batteryLine() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let percent = capacity * 100 / max
            let charging = (desc[kIOPSIsChargingKey] as? Bool) == true
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return "Battery: \(percent)%\(charging ? ", charging" : (onAC ? ", on power" : ", on battery"))."
        }
        return nil
    }
}
