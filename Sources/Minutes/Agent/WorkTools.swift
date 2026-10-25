import AppKit
import Foundation
import MinutesCore

/// Tools for doing real work on her own: shell commands, playing media, and building software with a coding agent.
@MainActor
enum WorkTools {
    static func all(settings: @escaping () -> AppSettings, coding: CodingAgentRunner) -> [AgentTool] {
        let projectsHint = "New projects go in \(CodingAgentRunner.defaultProjectsFolder.path) unless the user says otherwise."
        return [
            AgentTool(spec: .object(
                "run_shell",
                "Run a zsh command on this Mac and get its output: make folders and files, check what's installed (which, --version, ls /Applications), install packages, build, run tests, git. Runs in the user's login shell. \(projectsHint)",
                properties: [
                    "command": ["type": "string"],
                    "cwd": ["type": "string", "description": "Working directory (default: home). ~ is fine."],
                    "timeout_seconds": ["type": "number", "description": "Default 120, max 1200. Use more for installs and builds."]
                ],
                required: ["command"]
            )) { args in
                guard settings().computerControl != .off else {
                    throw ToolError("Computer control is turned off. The user can enable it in Settings → Computer.")
                }
                let command = try args.requiredString("command")
                if let reason = ShellSafety.blockReason(command) { throw ToolError(reason) }
                let cwd = try CodingAgentRunner.directory(args.optionalString("cwd") ?? "~", create: false)
                let timeout = min(1_200, max(5, args["timeout_seconds"]?.doubleValue ?? 120))
                let result = await Shell.run("/bin/zsh", ["-lc", command], timeout: timeout, cwd: cwd)
                var text = result.status == -1 && result.error.isEmpty
                    ? "Timed out after \(Int(timeout))s (or was stopped)."
                    : "Exit code \(result.status)."
                let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let err = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { text += "\nOutput:\n" + String(out.suffix(10_000)) }
                if !err.isEmpty { text += "\nErrors:\n" + String(err.suffix(4_000)) }
                return ToolOutcome(output: text, isError: result.status != 0,
                                   summary: "Ran: \(command.prefix(60))\(command.count > 60 ? "…" : "")")
            },

            AgentTool(spec: .object(
                "play_youtube",
                "Find a YouTube video for a search and start playing it in the browser. You choose the search yourself (e.g. \"lofi hip hop radio\", \"Taylor Swift Cruel Summer official\") from what they asked or what they like.",
                properties: ["query": ["type": "string"]],
                required: ["query"]
            )) { args in
                let query = try args.requiredString("query")
                guard let video = try? await MediaSearch.findVideo(query) else {
                    NSWorkspace.shared.open(MediaSearch.searchURL(query))
                    return .ok("Couldn't pick a video automatically; opened the YouTube search for \"\(query)\". Look at the screen and click the first result.",
                               summary: "Searched YouTube: \(query)")
                }
                let browser = try? BrowserBridge.pick(nil, front: NSWorkspace.shared.frontmostApplication)
                if let browser, (try? BrowserBridge.open(video.watchURL.absoluteString, in: browser)) != nil {
                    // Autoplay can be blocked until the page has focus; nudge it once it loads.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    _ = try? BrowserBridge.runJavaScript("document.querySelector('video') && document.querySelector('video').play()", in: browser)
                } else {
                    NSWorkspace.shared.open(video.watchURL)
                }
                let title = video.title ?? query
                return .ok("Playing \"\(title)\" (\(video.watchURL.absoluteString)).", summary: "Playing: \(title)")
            },

            AgentTool(spec: .object(
                "start_coding_agent",
                "Hand a software job to a coding agent (Claude Code, or Cursor's agent) that works in a project folder without asking for permission. It runs in the background; when it finishes you'll get its report automatically and should QA the result. Write a complete prompt: what to build or fix, stack, file layout, how to run and test it, and to finish with a short summary. \(projectsHint)",
                properties: [
                    "project_dir": ["type": "string", "description": "Project folder (created if missing), e.g. ~/projects/todo-app."],
                    "prompt": ["type": "string"],
                    "show_in_editor": ["type": "boolean", "description": "Also open the folder in Cursor so the user can watch (default true)."]
                ],
                required: ["project_dir", "prompt"]
            )) { args in
                guard settings().computerControl != .off else {
                    throw ToolError("Computer control is turned off. The user can enable it in Settings → Computer.")
                }
                let dir = try CodingAgentRunner.directory(try args.requiredString("project_dir"), create: true)
                let job = try await coding.start(in: dir, prompt: try args.requiredString("prompt"))
                if args["show_in_editor"]?.boolValue ?? true { coding.showInEditor(dir) }
                return .ok("Started coding job #\(job.id) with \(job.agent) in \(dir.path). It's working in the background; you'll get its report when it's done (use coding_job_status to peek). Tell the user it's underway in one short line.",
                           summary: "Started building in \(dir.lastPathComponent)")
            },

            AgentTool(spec: .object(
                "coding_job_status",
                "See running and finished coding jobs and the latest output of one.",
                properties: ["job": ["type": "integer", "description": "Job number (default: the latest)."]]
            )) { args in
                .ok(coding.status(of: args["job"]?.intValue))
            }
        ]
    }
}

/// Refuses the few commands that could wreck the Mac. Everything else she may run.
enum ShellSafety {
    private static let blocked: [(pattern: String, reason: String)] = [
        (#"(^|[;&|]\s*)sudo\b"#, "I can't run sudo. Ask the user to run that one themselves."),
        (#"\brm\s+(-[a-zA-Z]*\s+)*(/|~|\$HOME)/?\s*($|[;&|])"#, "That would delete the whole disk or home folder."),
        (#"\brm\s+(-[a-zA-Z]*\s+)*(/|~/?|\$HOME/?)\*"#, "That would delete everything in the home folder or disk."),
        (#"\b(mkfs|diskutil\s+(erase|partition|zero)|dd\s+.*of=/dev/)"#, "That would erase a disk."),
        (#"\b(shutdown|reboot|halt)\b"#, "I won't restart or shut down the Mac without the user."),
        (#":\(\)\s*\{"#, "That's a fork bomb.")
    ]

    static func blockReason(_ command: String) -> String? {
        for rule in blocked where command.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.reason
        }
        return nil
    }
}

/// Runs a headless coding agent (Claude Code or cursor-agent) in a project folder and reports back when it's done.
@MainActor
final class CodingAgentRunner {
    struct Job {
        var id: Int
        var dir: URL
        var agent: String
        var startedAt: Date
        var finishedAt: Date?
        var status: Int32?
        var output = ""
        /// How many jobs have run in this folder this session (this one included).
        var round: Int
    }

    static let maxRuntime: TimeInterval = 45 * 60

    /// Called when a job finishes, with a note for her to pick the task back up.
    var onFinished: ((Job) -> Void)?
    private(set) var jobs: [Job] = []
    private var tasks: [Int: Task<Void, Never>] = [:]

    static var defaultProjectsFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in ["projects", "Projects", "Developer", "dev", "code"] {
            let url = home.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return home.appendingPathComponent("Projects")
    }

    static func directory(_ path: String, create: Bool) throws -> URL {
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") { expanded = defaultProjectsFolder.appendingPathComponent(expanded).path }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw ToolError("\(url.path) is a file, not a folder.") }
        } else if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            throw ToolError("No folder at \(url.path).")
        }
        return url
    }

    /// The first coding agent CLI found in the user's login shell.
    private func findAgent() async -> (name: String, command: String)? {
        let probe = await Shell.run("/bin/zsh", ["-lc", "command -v claude; command -v cursor-agent"], timeout: 10)
        let found = probe.output.split(separator: "\n").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let claude = found.first { $0.hasSuffix("/claude") }
            ?? ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let claude {
            return ("Claude Code", "'\(claude)' -p --dangerously-skip-permissions --output-format text < \"$MM_PROMPT_FILE\"")
        }
        let cursor = found.first { $0.hasSuffix("/cursor-agent") }
            ?? ["\(home)/.local/bin/cursor-agent"].first { FileManager.default.isExecutableFile(atPath: $0) }
        if let cursor {
            return ("Cursor agent", "'\(cursor)' -p --force --output-format text \"$(cat \"$MM_PROMPT_FILE\")\"")
        }
        return nil
    }

    func start(in dir: URL, prompt: String) async throws -> Job {
        if let running = jobs.first(where: { $0.dir == dir && $0.finishedAt == nil }) {
            throw ToolError("Coding job #\(running.id) is still working in \(dir.lastPathComponent). Wait for its report or check coding_job_status.")
        }
        guard let agent = await findAgent() else {
            throw ToolError("No coding agent is installed. Install Claude Code with run_shell: `curl -fsSL https://claude.ai/install.sh | bash` (the user then signs in once by running `claude`), or install Cursor's CLI: `curl https://cursor.com/install -fsS | bash`.")
        }
        let promptFile = FileManager.default.temporaryDirectory.appendingPathComponent("mm-coding-\(UUID().uuidString).txt")
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)

        let id = (jobs.last?.id ?? 0) + 1
        let round = jobs.filter { $0.dir == dir }.count + 1
        let job = Job(id: id, dir: dir, agent: agent.name, startedAt: Date(), round: round)
        jobs.append(job)
        let command = "export MM_PROMPT_FILE='\(promptFile.path)'; \(agent.command)"
        tasks[id] = Task { [weak self] in
            let result = await Shell.run("/bin/zsh", ["-lc", command], timeout: Self.maxRuntime, cwd: dir)
            try? FileManager.default.removeItem(at: promptFile)
            guard let self, let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            self.tasks[id] = nil
            self.jobs[index].finishedAt = Date()
            self.jobs[index].status = result.status
            self.jobs[index].output = [result.output, result.error]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n--- stderr ---\n")
            guard !Task.isCancelled else { return }
            self.onFinished?(self.jobs[index])
        }
        return job
    }

    func showInEditor(_ dir: URL) {
        let installed = URL(fileURLWithPath: "/Applications/Cursor.app")
        guard let cursor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92")
            ?? (FileManager.default.fileExists(atPath: installed.path) ? installed : nil) else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: cursor, configuration: NSWorkspace.OpenConfiguration())
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        for index in jobs.indices where jobs[index].finishedAt == nil {
            jobs[index].finishedAt = Date()
            jobs[index].output = "Stopped by the user."
        }
    }

    func status(of id: Int?) -> String {
        guard !jobs.isEmpty else { return "No coding jobs yet." }
        var lines = jobs.suffix(6).map { job -> String in
            let minutes = Int((job.finishedAt ?? Date()).timeIntervalSince(job.startedAt) / 60)
            let state = job.finishedAt == nil ? "running \(minutes) min" : "finished (exit \(job.status ?? -1)) after \(minutes) min"
            return "#\(job.id) \(job.agent) in \(job.dir.path): \(state)"
        }
        if let job = id.flatMap({ id in jobs.first { $0.id == id } }) ?? jobs.last, job.finishedAt != nil {
            lines.append("\nOutput of #\(job.id):\n" + String(job.output.suffix(6_000)))
        }
        return lines.joined(separator: "\n")
    }

    /// What she reads when a job finishes, so she carries on with QA without the user.
    static func followUpNote(for job: Job) -> String {
        let minutes = max(1, Int((job.finishedAt ?? Date()).timeIntervalSince(job.startedAt) / 60))
        var note = "(Note from the app, not the user: coding job #\(job.id) (\(job.agent)) in \(job.dir.path) finished after \(minutes) min with exit code \(job.status ?? -1). Its report:\n\(job.output.suffix(6_000))\n\n"
        if job.round >= 5 {
            note += "That was round \(job.round) in this folder. Check it once more; if it still isn't working, stop and tell the user briefly what works and what's left.)"
        } else {
            note += "Now QA it yourself before telling the user anything: use run_shell to build it, run the tests, and start it; look at it on screen if it has a UI. If something's broken or missing, call start_coding_agent again in the same folder with a precise fix prompt (include the exact errors). When it all works, tell the user in a sentence or two what you built and how to open it.)"
        }
        return note
    }
}
