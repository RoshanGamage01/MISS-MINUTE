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
                // `open -a` needs the exact name; if that misses, find the closest installed app ("VS Code" →
                // "Visual Studio Code"), then ask Spotlight.
                return try await ToolRecovery.firstSuccess("open \(name)", [
                    .init("open -a") {
                        let result = await Shell.run("/usr/bin/open", ["-a", name])
                        guard result.status == 0 else { throw ToolError(result.error.isEmpty ? "not found" : String(result.error.prefix(160))) }
                        return .ok("Opened \(name).", summary: "Opened \(name)")
                    },
                    .init("closest installed app") {
                        guard let url = AppLocator.installedApp(named: name) else { throw ToolError("no installed app matches") }
                        return try await AppLocator.launch(url)
                    },
                    .init("Spotlight") {
                        guard let url = await AppLocator.spotlightApp(named: name) else { throw ToolError("Spotlight found nothing") }
                        return try await AppLocator.launch(url)
                    }
                ])
            },

            AgentTool(spec: .object(
                "open_url",
                "Open a web link (or mailto:, maps:, etc.) in the default app.",
                properties: ["url": ["type": "string"]],
                required: ["url"]
            )) { args in
                let raw = try args.requiredString("url")
                guard let url = LinkRepair.url(from: raw) else {
                    throw ToolError("That doesn't look like a link I can open.")
                }
                let label = url.host ?? url.absoluteString
                return try await ToolRecovery.firstSuccess("open \(raw)", [
                    .init("NSWorkspace") {
                        guard NSWorkspace.shared.open(url) else { throw ToolError("the system refused the link") }
                        return .ok("Opened \(url.absoluteString).", summary: "Opened \(label)")
                    },
                    .init("open command") {
                        let result = await Shell.run("/usr/bin/open", [url.absoluteString])
                        guard result.status == 0 else { throw ToolError(String(result.error.prefix(160))) }
                        return .ok("Opened \(url.absoluteString).", summary: "Opened \(label)")
                    }
                ])
            },

            AgentTool(spec: .object(
                "copy_to_clipboard",
                "Put text on the user's clipboard (drafts, snippets, addresses).",
                properties: ["text": ["type": "string"]],
                required: ["text"]
            )) { args in
                let text = try args.requiredString("text")
                // Check it actually landed; another app can hold the pasteboard for a moment.
                return try await ToolRecovery.firstSuccess("copy to the clipboard", [
                    .init("pasteboard") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        guard NSPasteboard.general.string(forType: .string) == text else { throw ToolError("didn't stick") }
                        return .ok("Copied \(text.count) characters.", summary: "Copied to clipboard")
                    },
                    .init("pbcopy") {
                        // The text is passed as an argument, never interpolated into the script.
                        let result = await Shell.run("/bin/sh", ["-c", "printf '%s' \"$1\" | /usr/bin/pbcopy", "sh", text])
                        guard result.status == 0, NSPasteboard.general.string(forType: .string) == text else {
                            throw ToolError("pbcopy failed")
                        }
                        return .ok("Copied \(text.count) characters.", summary: "Copied to clipboard")
                    }
                ])
            },

            AgentTool(spec: .object(
                "read_clipboard",
                "Read the text currently on the clipboard. Only when the user refers to what they copied."
            )) { _ in
                if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                    return .ok(String(text.prefix(8_000)), summary: "Read the clipboard")
                }
                // Copied files or links rather than text.
                if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
                    let list = urls.prefix(50).map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n")
                    return .ok("The clipboard holds \(urls.count) item(s):\n\(list)", summary: "Read the clipboard")
                }
                let fallback = await Shell.run("/usr/bin/pbpaste", [])
                let text = fallback.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard fallback.status == 0, !text.isEmpty else { return .ok("The clipboard has no text.") }
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
                var ran = name
                var result = await Shell.run("/usr/bin/shortcuts", arguments, timeout: 60)
                if result.status != 0, result.status != -1 {
                    // Usually a slightly-off name: retry once with the closest shortcut that exists.
                    let list = await Shell.run("/usr/bin/shortcuts", ["list"])
                    let names = list.output.split(separator: "\n").map(String.init)
                    if !names.contains(name),
                       let match = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
                           ?? ToolRecovery.bestMatch(name, in: names, text: { $0 }) {
                        arguments[1] = match
                        ran = match
                        result = await Shell.run("/usr/bin/shortcuts", arguments, timeout: 60)
                    }
                }
                guard result.status == 0 else {
                    let reason = result.status == -1 ? "it timed out after a minute" : String(result.error.prefix(300))
                    throw ToolError("Shortcut '\(ran)' failed: \(reason)")
                }
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let renamed = ran == name ? "" : " (closest match for '\(name)')"
                return .ok(output.isEmpty ? "Ran '\(ran)'\(renamed)." : "Ran '\(ran)'\(renamed). Output: \(output.prefix(2_000))",
                           summary: "Ran shortcut: \(ran)")
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

    /// Timed events in the next few hours, for the autonomy loop. Empty without access.
    func upcomingEvents(within interval: TimeInterval = 3 * 3_600) -> [UpcomingEvent] {
        guard isEnabled(), hasAccess else { return [] }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(interval), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map { UpcomingEvent(title: $0.title ?? "Untitled", start: $0.startDate, location: $0.location) }
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
        // No default calendar (fresh account, or it was deleted): fall back to any calendar that takes events.
        guard let target = store.defaultCalendarForNewEvents
            ?? store.calendars(for: .event).first(where: \.allowsContentModifications) else {
            throw ToolError("There's no calendar I can add events to. The user may need to add one in the Calendar app.")
        }
        event.calendar = target
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            // The chosen calendar may be read-only (subscribed, shared); try the others before giving up.
            for other in store.calendars(for: .event) where other.allowsContentModifications && other != target {
                event.calendar = other
                if (try? store.save(event, span: .thisEvent)) != nil { return }
            }
            throw error
        }
    }
}

// MARK: - Helpers

/// Finds installed apps when `open -a` doesn't recognise the name the model used.
@MainActor
enum AppLocator {
    private static let folders = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications"
    ]

    /// The installed app whose name best matches: exact, then prefix, then shared words, then contains.
    static func installedApp(named name: String) -> URL? {
        let apps = folders.flatMap { folder -> [URL] in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        }
        let key = normalized(name)
        guard !key.isEmpty else { return nil }
        func appName(_ url: URL) -> String { normalized(url.deletingPathExtension().lastPathComponent) }
        if let exact = apps.first(where: { appName($0) == key }) { return exact }
        if let prefix = apps.first(where: { appName($0).hasPrefix(key) }) { return prefix }
        if let words = ToolRecovery.bestMatch(name, in: apps, text: { $0.deletingPathExtension().lastPathComponent }) { return words }
        // Initialisms like "VS Code" → "Visual Studio Code".
        if let initials = apps.first(where: { abbreviations($0.deletingPathExtension().lastPathComponent).contains(key) }) {
            return initials
        }
        return apps.first(where: { appName($0).contains(key) })
    }

    static func spotlightApp(named name: String) async -> URL? {
        let safe = name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        let query = "kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == '*\(safe)*'cd"
        let result = await Shell.run("/usr/bin/mdfind", [query], timeout: 8)
        return result.output.split(separator: "\n").first.map { URL(fileURLWithPath: String($0)) }
    }

    static func launch(_ url: URL) async throws -> ToolOutcome {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
        return .ok("Opened \(name).", summary: "Opened \(name)")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// "Visual Studio Code" → ["vsc", "vscode"]: all initials, and initials plus the last word.
    private static func abbreviations(_ name: String) -> Set<String> {
        let words = name.split(separator: " ").map { normalized(String($0)) }.filter { !$0.isEmpty }
        guard words.count >= 2 else { return [] }
        let initials = words.compactMap(\.first).map(String.init)
        return [initials.joined(), initials.dropLast().joined() + words.last!]
    }
}

/// Turns what the model passes as a link into something openable: trims quotes and brackets, adds a scheme,
/// percent-encodes stray spaces, and treats plain words as a web search.
enum LinkRepair {
    static func url(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>`")))
        guard !text.isEmpty else { return nil }
        let hasScheme = text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil
        if !hasScheme {
            let looksLikeHost = text.range(of: #"^[^\s/]+\.[a-zA-Z]{2,}(:\d+)?(/|$|\?)"#, options: .regularExpression) != nil
                || text.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/|$)"#, options: .regularExpression) != nil
                || text.hasPrefix("localhost")
            guard looksLikeHost else {
                // Not a link at all: search for it instead of failing.
                var search = URLComponents(string: "https://www.google.com/search")!
                search.queryItems = [URLQueryItem(name: "q", value: text)]
                return search.url
            }
            text = (text.hasPrefix("localhost") ? "http://" : "https://") + text
        }
        if let url = URL(string: text), url.scheme != nil { return url }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "#%")))
        return encoded.flatMap(URL.init(string:))
    }
}

enum Shell {
    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
    }

    /// Runs a process off the main thread. Output is drained while it runs, so chatty commands can't stall on a
    /// full pipe. Cancelling the calling task stops the process. `onOutputLine` gets each finished stdout line as it
    /// arrives (on a background thread).
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20, cwd: URL? = nil,
                    onOutputLine: (@Sendable (String) -> Void)? = nil) async -> Result {
        let process = Process()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let output = OutputBuffer(), error = OutputBuffer()
                let lines = onOutputLine.map { LineStream($0) }
                out.fileHandleForReading.readabilityHandler = {
                    let chunk = $0.availableData
                    output.append(chunk)
                    lines?.feed(chunk)
                }
                err.fileHandleForReading.readabilityHandler = { error.append($0.availableData) }
                do {
                    try process.run()
                } catch {
                    return Result(status: -1, output: "", error: error.localizedDescription)
                }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                let timedOut = process.isRunning
                if timedOut {
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                output.append(rest)
                lines?.feed(rest)
                lines?.finish()
                error.append(err.fileHandleForReading.readDataToEndOfFile())
                return Result(status: timedOut ? -1 : process.terminationStatus, output: output.text, error: error.text)
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Hands whole stdout lines to a callback as the reader thread receives them.
    private final class LineStream: @unchecked Sendable {
        private let lock = NSLock()
        private var splitter = LineSplitter()
        private let deliver: @Sendable (String) -> Void

        init(_ deliver: @escaping @Sendable (String) -> Void) { self.deliver = deliver }

        func feed(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            splitter.feed(chunk).forEach(deliver)
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }
            splitter.finish().map(deliver)
        }
    }

    /// Collects pipe output from the reader thread, keeping only the last 2 MB.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            if data.count > 2_000_000 { data = data.suffix(1_000_000) }
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
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
