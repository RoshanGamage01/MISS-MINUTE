import Foundation

/// Short spoken-friendly lines for proactive alerts (no LLM required).
public enum ActivityCopy {
    public static func line(for event: ActivityEvent, now: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        switch event {
        case .appActivated(let name, _):
            switch name.lowercased() {
            case let n where n.contains("xcode"):
                return "Back in Xcode—want me to keep an eye on that build?"
            case let n where n.contains("terminal") || n.contains("iterm") || n.contains("warp"):
                return "Terminal time. I'll holler if a long job wraps up."
            case let n where n.contains("safari") || n.contains("chrome") || n.contains("firefox") || n.contains("edge"):
                return "Browsing for a spell—tap me if you need a quick answer."
            case let n where n.contains("slack") || n.contains("messages") || n.contains("discord"):
                return "Chat hop. I'll stay quiet unless something finishes in the background."
            case let n where n.contains("mail"):
                return "Mail's up. Say the word if you want a reminder later."
            default:
                return "Switched over to \(name)."
            }
        case .processFinished(let name, let seconds):
            if seconds >= 120 {
                return "That \(name) job just finished—ran about \(minutesPhrase(seconds))."
            }
            return "Looks like \(name) just wrapped up."
        case .returnedFromIdle(let minutes):
            if hour < 12 {
                return "Welcome back—you were away about \(minutes) minutes. Mornin' still treatin' you alright?"
            }
            if hour < 18 {
                return "There you are—about \(minutes) minutes quiet. Ready to pick it back up?"
            }
            return "Evenin'—you've been away about \(minutes) minutes. Need a hand?"
        case .screenDidWake:
            return "Display's awake. I'm still tickin' if you need me."
        case .screenDidSleep:
            return "Alright, I'll keep watch while the screen rests."
        }
    }

    private static func minutesPhrase(_ seconds: Int) -> String {
        let minutes = max(1, seconds / 60)
        return minutes == 1 ? "a minute" : "\(minutes) minutes"
    }
}
