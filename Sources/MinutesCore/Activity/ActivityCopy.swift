import Foundation

/// Short spoken lines in Miss Minute's voice for proactive alerts when no model is available.
public enum ActivityCopy {
    public static func line(for event: ActivityEvent, now: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        switch event {
        case .appActivated(let name, _):
            switch name.lowercased() {
            case let n where n.contains("xcode"):
                return "Back in Xcode, sugar. I'll holler when that build wraps."
            case let n where n.contains("terminal") || n.contains("iterm") || n.contains("warp"):
                return "Terminal time. I'll keep an eye on any long jobs."
            case let n where n.contains("safari") || n.contains("chrome") || n.contains("firefox") || n.contains("arc"):
                return "Off browsing? Holler if you want me to look something up."
            case let n where n.contains("slack") || n.contains("messages") || n.contains("discord"):
                return "Catching up on messages. I'll keep quiet unless something needs you."
            case let n where n.contains("mail"):
                return "Mail's open. Want me to track anything from there?"
            default:
                return "Over in \(name) now. I'm right here if you need me."
            }
        case .processFinished(let name, let seconds):
            if seconds >= 120 {
                return "Your \(name) job just finished, hon — ran about \(minutesPhrase(seconds))."
            }
            return "Looks like \(name) just wrapped up."
        case .returnedFromIdle(let minutes):
            if hour < 12 {
                return "Welcome back, sugar! You were gone about \(minutes) minutes. Ready to pick up where we left off?"
            }
            if hour < 18 {
                return "There you are! About \(minutes) minutes away. Let's get you back on the timeline."
            }
            return "Evenin', hon. You stepped away about \(minutes) minutes. Need a hand winding down?"
        case .screenDidWake:
            return "Mornin', sunshine. Still tickin' over here."
        case .screenDidSleep:
            return "I'll keep watch while the screen rests."
        }
    }

    public static func greeting(at now: Date = Date(), name: String? = nil) -> String {
        let who = (name?.isEmpty == false) ? ", \(name!)" : ", sugar"
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: return "Well, good mornin'\(who)! Miss Minute, reporting for duty."
        case 12..<17: return "Afternoon\(who)! Miss Minute here. Let's keep this timeline tidy."
        case 17..<22: return "Evenin'\(who)! I'm here if you need anything."
        default: return "Burnin' the midnight oil\(who)? I've got your back."
        }
    }

    public static func breakSuggestion(activeMinutes: Int) -> String {
        "You've been goin' for \(UsageTracker.duration(activeMinutes)) straight, sugar. Stretch, sip some water — I'll hold the timeline."
    }

    private static func minutesPhrase(_ seconds: Int) -> String {
        let minutes = max(1, seconds / 60)
        return minutes == 1 ? "a minute" : "\(minutes) minutes"
    }
}
