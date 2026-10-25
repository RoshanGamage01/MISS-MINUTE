import Foundation

/// Catches replies that promise or claim an action without calling a tool ("Let me check that!",
/// "I've opened YouTube for you"), which smaller local models do often. The chat loop then nudges the model
/// once to actually do it, so a request doesn't end in talk.
public enum FollowThrough {
    public enum Gap: Equatable, Sendable {
        /// "I'll…", "Let me…", "One sec": said she'd do something, then stopped.
        case promised
        /// "I've opened…": said it happened, but no tool ran.
        case claimed
    }

    private static let actions = "open|check|look|take|start|search|find|set|add|create|dive|get|pull|grab|play|put|go|peek|run|make|send|write|fix|do|handle|schedule|remind|launch|switch|close|read|see|try|turn|bring|load|queue|install|update|change|move|book"
    private static let doneActions = "opened|added|set|created|started|sent|scheduled|launched|played|put|saved|searched|checked|changed|updated|removed|deleted|closed|turned|queued|pulled|found|moved|booked|made|written|fixed"

    private static let promise = try! NSRegularExpression(pattern:
        #"\b(i'll|i will|i'm going to|i am going to|i'm about to|let me|lemme)\s+(just\s+|quickly\s+|go\s+ahead\s+and\s+|start\s+by\s+)?(\#(actions))\b"#
        + #"|\b(give me|gimme)\s+(a|one)\s+(quick\s+)?(sec|second|moment|minute)\b|\bone (quick )?sec\b|\b(hang|hold) on\b|\bjust a (sec|second|moment)\b"#,
        options: [.caseInsensitive])
    private static let claim = try! NSRegularExpression(pattern:
        #"\b(i've|i have|i just)\s+(just\s+|gone\s+ahead\s+and\s+)?(\#(doneActions))\b"#,
        options: [.caseInsensitive])
    private static let askingFirst = try! NSRegularExpression(pattern:
        #"\b(want me to|should i|would you like( me)? to|shall i|do you want me to|which (one|vibe|song|app))\b[^.!]*\?"#,
        options: [.caseInsensitive])

    /// Whether this reply needs a follow-through nudge. Only for replies that called no tools.
    public static func gap(in reply: String) -> Gap? {
        let text = reply.replacingOccurrences(of: "’", with: "'")
        let range = NSRange(text.startIndex..., in: text)
        // Asking permission or a choice first is fine.
        if askingFirst.firstMatch(in: text, range: range) != nil { return nil }
        if claim.firstMatch(in: text, range: range) != nil { return .claimed }
        if promise.firstMatch(in: text, range: range) != nil { return .promised }
        return nil
    }

    /// Sent to the model as a hidden user-role note.
    public static func nudge(for gap: Gap) -> String {
        switch gap {
        case .promised:
            return "(Note from the app, not the user: you said you'd do that, but you didn't call a tool, so nothing has happened yet. Do it now by calling the right tool in this reply. If no tool can do it, say so in one short sentence.)"
        case .claimed:
            return "(Note from the app, not the user: you said it's done, but no tool ran, so it did NOT happen. Do it now by calling the right tool. If no tool can do it, correct yourself in one short sentence.)"
        }
    }
}

/// A short line spoken the instant the user finishes a spoken request, before the model has answered, so
/// there's never dead air: "On it!" for tasks, "Hmm, let's see…" for questions, nothing for small talk.
public enum InstantAck {
    public static let taskLines = ["On it!", "Sure thing!", "You got it!", "Okay, hon!"]
    public static let questionLines = ["Hmm, let's see…", "Ooh, let me think…", "Let's see…"]

    private static let smallTalk: Set<String> = [
        "hi", "hello", "hey", "yo", "thanks", "thank", "ok", "okay", "yes", "yeah", "yep", "no", "nope", "nothing",
        "cool", "nice", "great", "bye", "goodbye", "good", "morning", "night", "lol", "sure", "alright", "awesome"
    ]
    private static let taskVerbs: Set<String> = [
        "open", "play", "set", "remind", "add", "create", "make", "start", "stop", "search", "find", "look", "check",
        "send", "write", "show", "turn", "close", "launch", "schedule", "put", "take", "go", "read", "summarize",
        "fix", "help", "book", "call", "text", "email", "pause", "resume", "skip", "mute", "delete", "remove",
        "cancel", "move", "switch", "translate", "draft", "plan", "track", "note", "save", "pull", "run", "build"
    ]
    private static let questionWords: Set<String> = [
        "what", "what's", "whats", "when", "where", "who", "whose", "why", "how", "how's", "is", "are", "am", "was",
        "were", "do", "does", "did", "should", "which", "will", "would", "have", "has"
    ]

    public enum Kind: Equatable, Sendable { case task, question }

    public static func kind(of request: String) -> Kind? {
        let lower = request.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = lower.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard let first = words.first else { return nil }
        // "thanks!", "hi there", "ok cool": no filler before small talk.
        if words.count <= 3, words.allSatisfy({ smallTalk.contains($0) || $0.count <= 2 || $0 == "there" || $0 == "you" }) {
            return nil
        }
        var start = 0
        while start < words.count, ["please", "hey", "ok", "okay", "so", "and", "now", "minute", "miss"].contains(words[start]) {
            start += 1
        }
        let lead = start < words.count ? words[start] : first
        let joined = " " + words.joined(separator: " ") + " "
        let asksToDo = [" can you ", " could you ", " would you ", " will you ", " i need you to ", " i want you to ",
                        " go ahead ", " do it ", " you can choose ", " for me "].contains(where: joined.contains)
        if taskVerbs.contains(lead) || asksToDo { return .task }
        if questionWords.contains(lead) || request.trimmingCharacters(in: .whitespaces).hasSuffix("?") { return .question }
        return nil
    }

    /// The line to say now, or nil to stay quiet until the real answer.
    public static func line(for request: String, index: Int) -> String? {
        switch kind(of: request) {
        case .task: return taskLines[abs(index) % taskLines.count]
        case .question: return questionLines[abs(index) % questionLines.count]
        case nil: return nil
        }
    }
}
