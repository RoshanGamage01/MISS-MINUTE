import AppKit
import MinutesCore

/// Lets Miss Minute see and operate the Mac: screenshots, reading UI, mouse, keyboard, browser, and AppleScript.
///
/// Observing needs Screen Recording (screenshots) or Accessibility (UI text). Acting needs Accessibility and is
/// gated by the Computer Control setting: Off, Ask first (once per task), or On her own.
@MainActor
final class ComputerController {
    let reader = AccessibilityReader()
    var settings: () -> AppSettings = { .default }
    /// Hide/disable Miss Minute's own windows while she drives the screen (and restore afterwards).
    var onBeginActing: (() -> Void)?
    var onEndActing: (() -> Void)?
    /// The request she's working on, for the approval prompt.
    var currentRequest: () -> String? = { nil }

    /// Last app the user was in that isn't Miss Minute — the one she should look at and act on.
    private(set) var targetApp: NSRunningApplication?
    private var lastShot: ScreenCapture.Shot?
    private var approvedForTask = false
    private var isActing = false
    private var observer: NSObjectProtocol?

    init() {
        targetApp = NSWorkspace.shared.frontmostApplication.flatMap { Self.isSelf($0) ? nil : $0 }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !Self.isSelf(app) else { return }
            Task { @MainActor in self?.targetApp = app }
        }
    }

    nonisolated private static func isSelf(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Ends the current task: revokes approval and gives the screen back.
    func endTask() {
        approvedForTask = false
        lastShot = nil
        if isActing {
            isActing = false
            onEndActing?()
        }
    }

    /// One-line description of what's in front of the user (for context).
    func frontSummary() -> (app: String?, title: String?) {
        guard let app = targetApp else { return (nil, nil) }
        return (app.localizedName, AccessibilityReader.frontWindowTitle(of: app))
    }

    // MARK: - Gate

    /// Checks permission to act, asking the user once per task in "Ask first" mode.
    private func authorize(_ action: String) async throws {
        switch settings().computerControl {
        case .off:
            throw ToolError("Computer control is turned off. The user can enable it in Settings → Computer.")
        case .auto:
            break
        case .ask:
            if !approvedForTask {
                approvedForTask = askApproval(firstAction: action)
                if !approvedForTask {
                    throw ToolError("The user declined to let you control the computer for this task. Explain what they could do themselves instead.")
                }
            }
        }
        try InputController.requireAccessibility()
        if !isActing {
            isActing = true
            onBeginActing?()
        }
        // If Miss Minute's own window took focus (chat panel, approval alert), hand it back to the user's app.
        if let target = targetApp, NSWorkspace.shared.frontmostApplication.map(Self.isSelf) ?? false {
            target.activate()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func askApproval(firstAction: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Let Miss Minute use your Mac for this task?"
        var info = "She'd like to \(firstAction)"
        if let request = currentRequest(), !request.isEmpty {
            info += " to help with: “\(request.prefix(160))”"
        }
        info += ".\n\nShe'll click and type in your apps until the task is done. Press ⌥Esc anytime to stop her."
        alert.informativeText = info
        alert.addButton(withTitle: "Allow for this task")
        alert.addButton(withTitle: "Not now")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func requireObserving() throws {
        guard settings().screenAwareness != .off else {
            throw ToolError("Screen awareness is turned off. The user can enable it in Settings → Computer.")
        }
    }

    // MARK: - Tools

    func tools() -> [AgentTool] {
        [
            AgentTool(spec: .object(
                "look_at_screen",
                "Take a screenshot of the user's screen (Miss Minute's own windows are hidden from it). Use it to see what they're doing, read anything visual, and to find where to click. Coordinates for `click` are pixels in this image.",
                properties: ["detail": ["type": "string", "enum": ["normal", "high"], "description": "high = sharper image for small text."]]
            )) { [unowned self] args in
                try self.requireObserving()
                let local = self.settings().provider.isLocal
                let high = args.optionalString("detail") == "high"
                let shot = try await ScreenCapture.capture(maxDimension: high ? 1600 : (local ? 1024 : 1280), quality: high ? 0.75 : 0.6)
                self.lastShot = shot
                let (app, title) = self.frontSummary()
                var text = "Screenshot \(shot.image.width)×\(shot.image.height) px."
                if let app { text += " Front app: \(app)" + (title.map { ", window \"\($0)\"" } ?? "") + "." }
                return .ok(text, summary: "Looked at your screen", images: [shot.image])
            },

            AgentTool(spec: .object(
                "read_screen",
                "Read the front app's window as text: headings, text, buttons, fields, links (works in browsers too). Actionable elements get [ids] for press_element / set_text. Cheaper and more precise than a screenshot for text.",
                properties: ["app": ["type": "string", "description": "Optional app name to read instead of the front app."]]
            )) { [unowned self] args in
                try self.requireObserving()
                guard AXIsProcessTrusted() else {
                    InputController.requestAccessibility()
                    throw ToolError("I need Accessibility permission to read apps. Turn on Miss Minute in System Settings → Privacy & Security → Accessibility.")
                }
                let app = try self.resolveApp(args.optionalString("app"))
                let snapshot = self.reader.snapshot(of: app)
                let header = "App: \(snapshot.app)" + (snapshot.windowTitle.map { " — window \"\($0)\"" } ?? "")
                return .ok(header + "\n" + snapshot.text, summary: "Read \(snapshot.app)")
            },

            AgentTool(spec: .object(
                "click",
                "Click at a point in the most recent look_at_screen image (pixel coordinates).",
                properties: [
                    "x": ["type": "number"], "y": ["type": "number"],
                    "button": ["type": "string", "enum": ["left", "right"]],
                    "double": ["type": "boolean"]
                ],
                required: ["x", "y"]
            )) { [unowned self] args in
                guard let shot = self.lastShot else { throw ToolError("Call look_at_screen first so I know where things are.") }
                guard let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue,
                      x >= 0, y >= 0, x <= Double(shot.image.width), y <= Double(shot.image.height) else {
                    throw ToolError("x/y must be inside the \(shot.image.width)×\(shot.image.height) screenshot.")
                }
                try await self.authorize("click on your screen")
                let point = shot.screenPoint(x: x, y: y)
                InputController.click(at: point, right: args.optionalString("button") == "right", count: args["double"]?.boolValue == true ? 2 : 1)
                try? await Task.sleep(nanoseconds: 350_000_000)
                return .ok("Clicked at (\(Int(x)), \(Int(y))). Look again to confirm the result.", summary: "Clicked")
            },

            AgentTool(spec: .object(
                "press_element",
                "Press a button, link, tab, checkbox, or menu item by its [id] from the latest read_screen.",
                properties: ["id": ["type": "integer"]],
                required: ["id"]
            )) { [unowned self] args in
                guard let id = args["id"]?.intValue else { throw ToolError("Missing id.") }
                _ = try self.reader.element(id)
                try await self.authorize("press a button in \(self.targetApp?.localizedName ?? "an app")")
                try self.reader.press(id)
                try? await Task.sleep(nanoseconds: 400_000_000)
                return .ok("Pressed [\(id)]. Read or look again to confirm.", summary: "Pressed a button")
            },

            AgentTool(spec: .object(
                "set_text",
                "Fill a text field by its [id] from the latest read_screen (replaces its contents).",
                properties: ["id": ["type": "integer"], "text": ["type": "string"]],
                required: ["id", "text"]
            )) { [unowned self] args in
                guard let id = args["id"]?.intValue else { throw ToolError("Missing id.") }
                let text = args["text"]?.stringValue ?? ""
                _ = try self.reader.element(id)
                try await self.authorize("type into \(self.targetApp?.localizedName ?? "an app")")
                try self.reader.setText(id, text)
                return .ok("Filled [\(id)].", summary: "Filled in a field")
            },

            AgentTool(spec: .object(
                "type_text",
                "Type text at the current keyboard focus (click a field first). Set press_enter to submit.",
                properties: ["text": ["type": "string"], "press_enter": ["type": "boolean"]],
                required: ["text"]
            )) { [unowned self] args in
                let text = args["text"]?.stringValue ?? ""
                try await self.authorize("type into \(self.targetApp?.localizedName ?? "an app")")
                InputController.type(text)
                if args["press_enter"]?.boolValue == true { try InputController.press("return") }
                try? await Task.sleep(nanoseconds: 250_000_000)
                return .ok("Typed \(text.count) characters.", summary: "Typed text")
            },

            AgentTool(spec: .object(
                "press_keys",
                "Press a key or shortcut, e.g. \"cmd+t\", \"cmd+l\", \"return\", \"esc\", \"tab\", \"down\", \"cmd+shift+4\".",
                properties: ["keys": ["type": "string"]],
                required: ["keys"]
            )) { [unowned self] args in
                let keys = try args.requiredString("keys")
                try await self.authorize("press \(keys)")
                try InputController.press(keys)
                try? await Task.sleep(nanoseconds: 300_000_000)
                return .ok("Pressed \(keys).", summary: "Pressed \(keys)")
            },

            AgentTool(spec: .object(
                "scroll",
                "Scroll the front window. Optional x/y (screenshot pixels) to scroll a specific area.",
                properties: [
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "amount": ["type": "integer", "description": "1–15 notches, default 5."],
                    "x": ["type": "number"], "y": ["type": "number"]
                ],
                required: ["direction"]
            )) { [unowned self] args in
                let direction = try args.requiredString("direction")
                let amount = max(1, min(15, args["amount"]?.intValue ?? 5))
                try await self.authorize("scroll")
                var point: CGPoint?
                if let shot = self.lastShot, let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue {
                    point = shot.screenPoint(x: x, y: y)
                }
                let dy = direction == "down" ? amount : (direction == "up" ? -amount : 0)
                let dx = direction == "right" ? amount : (direction == "left" ? -amount : 0)
                InputController.scroll(dy: dy, dx: dx, at: point)
                try? await Task.sleep(nanoseconds: 300_000_000)
                return .ok("Scrolled \(direction).", summary: nil)
            },

            AgentTool(spec: .object(
                "drag",
                "Drag from one point to another in the latest screenshot (pixels).",
                properties: ["from_x": ["type": "number"], "from_y": ["type": "number"], "to_x": ["type": "number"], "to_y": ["type": "number"]],
                required: ["from_x", "from_y", "to_x", "to_y"]
            )) { [unowned self] args in
                guard let shot = self.lastShot else { throw ToolError("Call look_at_screen first.") }
                guard let fx = args["from_x"]?.doubleValue, let fy = args["from_y"]?.doubleValue,
                      let tx = args["to_x"]?.doubleValue, let ty = args["to_y"]?.doubleValue else { throw ToolError("Missing coordinates.") }
                try await self.authorize("drag on your screen")
                InputController.drag(from: shot.screenPoint(x: fx, y: fy), to: shot.screenPoint(x: tx, y: ty))
                return .ok("Dragged.", summary: "Dragged")
            },

            AgentTool(spec: .object(
                "focus_app",
                "Bring an app to the front (launching it if needed) so you can look at or act in it.",
                properties: ["name": ["type": "string"]],
                required: ["name"]
            )) { [unowned self] args in
                let name = try args.requiredString("name")
                if let running = NSWorkspace.shared.runningApplications.first(where: {
                    $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
                }) {
                    running.activate()
                    self.targetApp = running
                } else {
                    let result = await Shell.run("/usr/bin/open", ["-a", name])
                    guard result.status == 0 else { throw ToolError("Couldn't find an app called \(name).") }
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                return .ok("\(name) is in front.", summary: "Switched to \(name)")
            },

            AgentTool(spec: .object(
                "browser",
                "Work with the user's web browser (Chrome, Safari, Arc, Brave, Edge) in their signed-in session. Actions: \"current\" (URL and title of the active tab), \"read\" (the active tab's page text), \"open\" (open url in a new tab and bring the browser forward).",
                properties: [
                    "action": ["type": "string", "enum": ["current", "read", "open"]],
                    "url": ["type": "string"],
                    "browser": ["type": "string", "description": "Optional, e.g. \"Google Chrome\". Defaults to the front or running browser."]
                ],
                required: ["action"]
            )) { [unowned self] args in
                try self.requireObserving()
                let action = try args.requiredString("action")
                let browser = try BrowserBridge.pick(args.optionalString("browser"), front: self.targetApp)
                switch action {
                case "current":
                    let info = try BrowserBridge.current(browser)
                    return .ok("\(browser): \(info.title)\n\(info.url)")
                case "read":
                    let info = try BrowserBridge.current(browser)
                    if let text = try? BrowserBridge.pageText(browser), !text.isEmpty {
                        return .ok("\(info.title)\n\(info.url)\n\n\(text.prefix(14_000))", summary: "Read the page in \(browser)")
                    }
                    // JavaScript from Apple Events is off; fall back to the accessibility tree.
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == browser }), AXIsProcessTrusted() {
                        let snapshot = self.reader.snapshot(of: app)
                        return .ok("\(info.title)\n\(info.url)\n\n\(snapshot.text)", summary: "Read the page in \(browser)")
                    }
                    throw ToolError("Couldn't read the page text. Use look_at_screen instead.")
                case "open":
                    var raw = try args.requiredString("url")
                    if !raw.contains("://") { raw = "https://" + raw }
                    try await self.authorize("open \(URL(string: raw)?.host ?? raw) in \(browser)")
                    try BrowserBridge.open(raw, in: browser)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == browser }) {
                        self.targetApp = app
                    }
                    return .ok("Opened \(raw) in \(browser). Give it a moment, then read or look at the page.",
                               summary: "Opened \(URL(string: raw)?.host ?? raw)")
                default:
                    throw ToolError("Unknown browser action '\(action)'.")
                }
            },

            AgentTool(spec: .object(
                "run_applescript",
                "Run an AppleScript to control scriptable apps (Finder, Music, Mail drafts, System Events, Notes…). Returns the result. Prefer simpler tools when they work.",
                properties: ["script": ["type": "string"]],
                required: ["script"]
            )) { [unowned self] args in
                let source = try args.requiredString("script")
                try await self.authorize("run an AppleScript")
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else { throw ToolError("Invalid AppleScript.") }
                let result = script.executeAndReturnError(&error)
                if let error {
                    throw ToolError("AppleScript error: \(error[NSAppleScript.errorMessage] ?? error)")
                }
                return .ok(result.stringValue ?? "Done.", summary: "Ran an AppleScript")
            },

            AgentTool(spec: .object(
                "wait",
                "Wait a few seconds for something to load or finish.",
                properties: ["seconds": ["type": "number"]],
                required: ["seconds"]
            )) { args in
                let seconds = min(15, max(0.2, args["seconds"]?.doubleValue ?? 1))
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .ok("Waited \(seconds)s.")
            }
        ]
    }

    private func resolveApp(_ name: String?) throws -> NSRunningApplication {
        if let name {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else { throw ToolError("\(name) isn't running.") }
            return app
        }
        guard let app = targetApp else { throw ToolError("No app is in front.") }
        return app
    }
}

/// AppleScript bridge to the user's browser (their real, signed-in session).
enum BrowserBridge {
    static let chromium = ["Google Chrome", "Arc", "Brave Browser", "Microsoft Edge", "Chromium", "Vivaldi"]
    static let all = chromium + ["Safari"]

    static func pick(_ requested: String?, front: NSRunningApplication?) throws -> String {
        if let requested, let match = all.first(where: { $0.localizedCaseInsensitiveContains(requested) || requested.localizedCaseInsensitiveContains($0) }) {
            return match
        }
        if let name = front?.localizedName, all.contains(name) { return name }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        if let name = all.first(where: running.contains) { return name }
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
           let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String, all.contains(name) {
            return name
        }
        throw ToolError("No supported browser found (Chrome, Safari, Arc, Brave, Edge).")
    }

    static func current(_ browser: String) throws -> (url: String, title: String) {
        let script = browser == "Safari"
            ? "tell application \"Safari\" to return (URL of current tab of front window) & linefeed & (name of current tab of front window)"
            : "tell application \"\(browser)\" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"
        let parts = try run(script).components(separatedBy: "\n")
        return (parts.first ?? "", parts.dropFirst().joined(separator: " "))
    }

    /// Needs "Allow JavaScript from Apple Events" (Chrome: View → Developer; Safari: Develop menu).
    static func pageText(_ browser: String) throws -> String {
        try runJavaScript("document.body.innerText", in: browser)
    }

    /// Runs JavaScript in the active tab. `js` must not contain double quotes.
    @discardableResult
    static func runJavaScript(_ js: String, in browser: String) throws -> String {
        let script = browser == "Safari"
            ? "tell application \"Safari\" to do JavaScript \"\(js)\" in current tab of front window"
            : "tell application \"\(browser)\" to execute active tab of front window javascript \"\(js)\""
        return try run(script)
    }

    static func open(_ url: String, in browser: String) throws {
        let escaped = url.replacingOccurrences(of: "\"", with: "%22")
        let script = browser == "Safari"
            ? "tell application \"Safari\"\nactivate\nif (count of windows) = 0 then make new document\ntell front window to set current tab to (make new tab with properties {URL:\"\(escaped)\"})\nend tell"
            : "tell application \"\(browser)\"\nactivate\nif (count of windows) = 0 then make new window\ntell front window to make new tab with properties {URL:\"\(escaped)\"}\nend tell"
        _ = try run(script)
    }

    @discardableResult
    static func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw ToolError("Invalid script.") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            if message.contains("not allowed") || message.contains("-1743") {
                throw ToolError("macOS blocked controlling the browser. Allow Miss Minute under System Settings → Privacy & Security → Automation.")
            }
            throw ToolError(message)
        }
        return result.stringValue ?? ""
    }
}
