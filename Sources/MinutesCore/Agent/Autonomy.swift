import Foundation

/// Keeps a delegated task going until it's really done: she checks her work before wrapping up, and makes
/// ordinary choices herself instead of handing them back ("What would you like to play?").
public enum Autonomy {
    /// Tools that change something in a way their result can't confirm. After the last one, she should look
    /// before saying it's done. Low-risk launches (open_app, open_url, focus_app, play_youtube, scroll) report
    /// their own success, so she moves on without a second look.
    public static let actionTools: Set<String> = [
        "click", "press_element", "set_text", "type_text", "press_keys",
        "drag", "browser", "run_applescript", "run_shortcut", "create_calendar_event"
    ]
    /// Tools whose result shows what actually happened (a shell command's output is its own check).
    public static let checkTools: Set<String> = ["look_at_screen", "read_screen", "run_shell", "coding_job_status"]

    /// Whether the turn acted without looking afterwards.
    public static func needsCheck(toolsUsed: [String]) -> Bool {
        guard let lastAction = toolsUsed.lastIndex(where: actionTools.contains) else { return false }
        return !toolsUsed[(lastAction + 1)...].contains(where: checkTools.contains)
    }

    public static let checkNudge = "(Note from the app, not the user: that last step went through the UI, so take one quick look (or run a quick command) to confirm it worked. If anything is off or unfinished, fix it and keep going. If it's done, just reply in one short sentence.)"

    /// Asking before these is right; for everything else she picks herself.
    private static let sensitive = try! NSRegularExpression(pattern:
        #"\b(send|email|e-mail|message|text|post|tweet|reply|buy|order|pay|purchase|checkout|delete|remove|erase|wipe|password|sign up|subscribe|book)\b"#,
        options: [.caseInsensitive])
    private static let choiceQuestion = try! NSRegularExpression(pattern:
        #"\b(what|which)\b[^.!?]*\b(would you like|do you want|you'd like|you want|should i|shall i|to play|to watch|to listen|to build|to name|vibe|song|video|track|artist|genre|one)\b[^.!?]*\?"#
        + #"|\blet me know (what|which)\b|\btell me (what|which)\b|\bdo you have (a|any) (preference|favorite|favourite)\b|\bany (preference|requests?)\b[^.!?]*\?"#,
        options: [.caseInsensitive])

    /// The user asked her to do something, and she asked them to choose instead of choosing.
    public static func handedBack(reply: String, request: String) -> Bool {
        guard InstantAck.kind(of: request) == .task else { return false }
        let requestRange = NSRange(request.startIndex..., in: request)
        if sensitive.firstMatch(in: request, range: requestRange) != nil { return false }
        let text = reply.replacingOccurrences(of: "’", with: "'")
        return choiceQuestion.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static let chooseNudge = "(Note from the app, not the user: they asked you to handle this, so don't hand the choice back. Pick something sensible yourself, using what you remember about their taste or a popular pick, and do it now. Only ask if it truly can't be done without them.)"
}

// MARK: - Noticing when the user needs a hand

/// Watches the front window over time and decides when the user looks stuck: an error that stays on screen,
/// or the same screen for a long stretch while they're actively at the keyboard. Pure bookkeeping; the app
/// feeds it what's in front every tick and what the screen watcher noticed.
public struct StuckDetector: Sendable {
    public enum Finding: Sendable, Equatable {
        /// Something that looks like an error has stayed on screen for `minutes`.
        case error(app: String?, detail: String, minutes: Int)
        /// Same window for `minutes` while active. Might be focus, might be stuck; the model decides.
        case dwelling(app: String, title: String?, minutes: Int)

        public var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    /// How long an error must stay up before she offers (a quick fix shouldn't trigger her).
    public var errorPersistence: TimeInterval
    /// How long on one window before she gently checks in.
    public var dwellThreshold: TimeInterval
    /// Idle longer than this means they stepped away: the clocks start over.
    public var awayAfter: TimeInterval

    private var signature = ""
    private var app: String?
    private var title: String?
    private var signatureSince: Date?
    private var errorSince: Date?
    private var errorDetail: String?
    /// Per-finding cooldowns, so the same error or screen is only mentioned once in a while.
    private var offered: [String: Date] = [:]

    public init(errorPersistence: TimeInterval = 150, dwellThreshold: TimeInterval = 25 * 60, awayAfter: TimeInterval = 180) {
        self.errorPersistence = errorPersistence
        self.dwellThreshold = dwellThreshold
        self.awayAfter = awayAfter
    }

    /// Records what's in front. `note` is a fresh screen-watcher note, when one just arrived.
    public mutating func observe(app: String?, title: String?, note: String? = nil, idleSeconds: TimeInterval, at now: Date = Date()) {
        if idleSeconds > awayAfter {
            // They're away; a screen nobody is looking at isn't "stuck".
            signatureSince = nil
            errorSince = nil
            errorDetail = nil
            return
        }
        let newSignature = "\(app ?? "")|\(title ?? "")"
        if newSignature != signature || signatureSince == nil {
            signature = newSignature
            self.app = app
            self.title = title
            signatureSince = now
            errorSince = nil
            errorDetail = nil
        }
        let found = title.flatMap(Self.errorDetail(in:)) ?? note.flatMap(Self.errorDetail(in:))
        if let found {
            if errorSince == nil { errorSince = now }
            errorDetail = found
        } else if note != nil, title.flatMap(Self.errorDetail(in:)) == nil {
            // A fresh look found no error: whatever it was is resolved.
            errorSince = nil
            errorDetail = nil
        }
    }

    /// What she should speak up about now, if anything. Marks it as offered.
    public mutating func assess(at now: Date = Date()) -> Finding? {
        offered = offered.filter { now.timeIntervalSince($0.value) < 4 * 3_600 }
        if let errorSince, let detail = errorDetail, now.timeIntervalSince(errorSince) >= errorPersistence {
            let key = "error|\(signature)|\(detail.lowercased())"
            if offered[key].map({ now.timeIntervalSince($0) > 30 * 60 }) ?? true {
                offered[key] = now
                return .error(app: app, detail: detail, minutes: Int(now.timeIntervalSince(errorSince) / 60))
            }
        }
        if let since = signatureSince, let app, !app.isEmpty, now.timeIntervalSince(since) >= dwellThreshold {
            let key = "dwell|\(signature)"
            if offered[key].map({ now.timeIntervalSince($0) > 90 * 60 }) ?? true {
                offered[key] = now
                return .dwelling(app: app, title: title, minutes: Int(now.timeIntervalSince(since) / 60))
            }
        }
        return nil
    }

    private static let errorPattern = try! NSRegularExpression(pattern:
        #"\b(error|errors|exception|failed|failure|fatal|traceback|panic|segmentation fault|crash(ed)?|permission denied|access denied|not found|cannot|can't connect|couldn't|unable to|timed out|undefined|unexpected token|invalid|refused|build failed|tests? failed|404|500|502|503)\b"#,
        options: [.caseInsensitive])

    /// The error-looking phrase in `text` with a little context, or nil.
    public static func errorDetail(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = errorPattern.firstMatch(in: text, range: range), let hit = Range(match.range, in: text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 { return trimmed }
        let start = text.index(hit.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(hit.upperBound, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// When and how to suggest a break. The first nudge comes at the user's threshold (sooner when they're stressed
/// or it's late), follow-ups get closer together if they keep going, and each one suggests something different.
public enum BreakCoach {
    public static func threshold(base: Int, stressed: Bool, lateNight: Bool) -> Int {
        var minutes = Double(base)
        if stressed { minutes *= 0.8 }
        if lateNight { minutes *= 0.8 }
        return max(20, Int(minutes))
    }

    /// Minutes to wait after the `nudges`-th nudge in the same stretch before the next one.
    public static func followUpGap(afterNudges nudges: Int) -> TimeInterval {
        TimeInterval(max(20, 40 - 10 * max(0, nudges - 1))) * 60
    }

    public static func shouldNudge(activeMinutes: Int, threshold: Int, nudgesThisStretch: Int, lastNudgeAt: Date?, now: Date = Date()) -> Bool {
        guard activeMinutes >= threshold else { return false }
        guard nudgesThisStretch > 0, let lastNudgeAt else { return true }
        return now.timeIntervalSince(lastNudgeAt) >= followUpGap(afterNudges: nudgesThisStretch)
    }

    public static let stretches = [
        "roll your shoulders back five times and unclench that jaw",
        "look at somethin' twenty feet away for twenty seconds — your eyes'll thank you",
        "stand up, reach for the ceiling, then let your arms flop down",
        "go top up your water glass",
        "take a quick lap around the room",
        "do a slow neck roll each way and take three deep breaths"
    ]

    /// An offline line: the stretch varies with `index`, and the tone firms up with each follow-up.
    public static func line(activeMinutes: Int, nudgesThisStretch: Int, index: Int) -> String {
        let stretch = stretches[abs(index) % stretches.count]
        let time = UsageTracker.duration(activeMinutes)
        switch nudgesThisStretch {
        case 0: return "You've been goin' for \(time) straight, sugar. Quick favor: \(stretch). I'll hold the timeline."
        case 1: return "Still at it after \(time), hon? Two minutes, tops: \(stretch)."
        default: return "Okay, sugar, \(time) without a break is a lot. Step away for five. Everything'll be right here."
        }
    }
}
