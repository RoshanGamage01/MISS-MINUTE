import Foundation

/// A deliberate hand/body movement that goes with what she's doing.
public enum BodyGesture: String, Sendable, Equatable, CaseIterable {
    /// Arm out, index finger aimed at the thing she's working on or talking about.
    case point
    /// Fist up, thumb up: a step went well.
    case thumbsUp
    /// Glove tapping her chin, eyes up: chewing on a lookup or a background job.
    case think
    /// Both arms up, a hop and confetti: a task or build finished.
    case celebrate
    /// Palms up: something didn't work.
    case shrug
    /// Hand shading her eyes: looking at or reading the screen.
    case peer
    /// A spin with a "ta-da" flourish: she's changing into a new look.
    case twirl
}

/// How she looks overall (a glow or look layered on top of her mood).
public enum BodyAura: String, Sendable, Equatable, CaseIterable {
    case none
    /// A pulsing halo around the clock rim while she's thinking or running tools.
    case processing
    /// Half-lidded, brows set, `</>` orbiting: she's coding or a build is running.
    case focused
    /// Bright golden glow and sparkles.
    case celebrating
    /// A short red-orange pulse when something fails.
    case alert
}

/// Somewhere on screen worth heading to.
public enum BodyDestination: Sendable, Equatable {
    /// The front app's main window (she perches on its top edge).
    case activeWindow
    /// Next to the mouse pointer.
    case cursor
    /// Beside a point she's acting on, in global Cocoa screen coordinates (bottom-left origin).
    case screenPoint(x: Double, y: Double)
    /// Back to her usual spot.
    case home
}

/// How she gets there.
public enum BodyTravel: String, Sendable, Equatable {
    /// A smooth float across the screen.
    case glide
    /// Gone in a flash of a TVA time door, there in the next: for jumps between apps.
    case teleport
}

/// One instruction for the body: any mix of gesture, look, and movement.
public struct BodyCue: Sendable, Equatable {
    public var gesture: BodyGesture?
    public var gestureSeconds: TimeInterval
    /// A look that lasts `auraSeconds` on top of the steady one.
    public var aura: BodyAura?
    public var auraSeconds: TimeInterval
    public var destination: BodyDestination?
    public var travel: BodyTravel
    /// Wait this long before moving (lets a just-opened app's window appear first).
    public var delay: TimeInterval

    public init(
        gesture: BodyGesture? = nil,
        gestureSeconds: TimeInterval = 1.8,
        aura: BodyAura? = nil,
        auraSeconds: TimeInterval = 2,
        destination: BodyDestination? = nil,
        travel: BodyTravel = .glide,
        delay: TimeInterval = 0
    ) {
        self.gesture = gesture
        self.gestureSeconds = gestureSeconds
        self.aura = aura
        self.auraSeconds = auraSeconds
        self.destination = destination
        self.travel = travel
        self.delay = delay
    }
}

/// Things happening in the agent and on the Mac that her body reacts to.
public enum AgentBodyEvent: Sendable, Equatable {
    case toolStarted(name: String)
    case toolFinished(name: String, isError: Bool)
    /// She's about to click/scroll/drag here (global Cocoa coordinates).
    case actingAt(x: Double, y: Double)
    /// A turn finished normally with this reply, having used these tools.
    case turnCompleted(reply: String, toolsUsed: [String])
    case turnFailed
    /// A background job (coding agent) reported a new step.
    case backgroundJobProgress
    case backgroundJobFinished(success: Bool)
    /// She's changing into a new look (asked for, or picked in Settings).
    case lookChanged(to: AvatarLook)
}

/// Turns agent activity into body language: where she goes, how she gets there, what her hands do, and
/// how she glows. Pure logic, so the mapping is testable; the app's behavior engine carries it out.
public struct BodyDirector: Sendable {
    /// What a tool is, as far as her body is concerned.
    public enum ToolKind: Sendable, Equatable {
        /// Opens or switches to another app or page: a context jump.
        case contextSwitch
        /// Clicks, types, scrolls in the front app.
        case screenAction
        /// Looks at or reads the screen.
        case observe
        /// Writes code or runs commands.
        case coding
        /// Searches, reads, or recalls something.
        case lookup
        /// Quick bookkeeping (tasks, reminders, memories).
        case bookkeeping
        case other
    }

    public init() {}

    public static func kind(of tool: String) -> ToolKind {
        switch tool {
        case "open_app", "focus_app", "open_url", "browser", "play_youtube":
            return .contextSwitch
        case "click", "press_element", "set_text", "type_text", "press_keys", "scroll", "drag":
            return .screenAction
        case "look_at_screen", "read_screen":
            return .observe
        case "run_shell", "start_coding_agent", "run_applescript", "coding_job_status":
            return .coding
        case "search_web", "read_webpage", "recall", "get_calendar_events", "get_activity_summary", "read_clipboard", "list_tasks", "list_reminders":
            return .lookup
        case "add_task", "update_task", "complete_task", "delete_task", "set_reminder", "start_timer",
             "cancel_reminder", "remember", "forget", "create_calendar_event", "copy_to_clipboard", "run_shortcut":
            return .bookkeeping
        case "change_look":
            // The look change has its own flourish (`lookChanged`); no extra thumbs up.
            return .other
        default:
            return .other
        }
    }

    public func cue(for event: AgentBodyEvent) -> BodyCue? {
        switch event {
        case .toolStarted(let name):
            switch Self.kind(of: name) {
            case .observe:
                return BodyCue(gesture: .peer, gestureSeconds: 2.2, destination: .activeWindow)
            case .coding:
                return BodyCue(aura: .focused, auraSeconds: 6)
            case .lookup:
                return BodyCue(gesture: .think, gestureSeconds: 2.5)
            case .screenAction:
                // `actingAt` refines the spot when there's an exact point.
                return BodyCue(gesture: .point, gestureSeconds: 1.6, destination: .activeWindow)
            case .contextSwitch, .bookkeeping, .other:
                return nil
            }

        case .toolFinished(let name, let isError):
            if isError { return BodyCue(gesture: .shrug, gestureSeconds: 1.6, aura: .alert, auraSeconds: 1.2) }
            switch Self.kind(of: name) {
            case .contextSwitch:
                // The new app is in front now: jump straight over to it.
                return BodyCue(gesture: .point, gestureSeconds: 1.4, destination: .activeWindow, travel: .teleport, delay: 0.6)
            case .bookkeeping:
                return BodyCue(gesture: name == "complete_task" ? .celebrate : .thumbsUp,
                               gestureSeconds: name == "complete_task" ? 2.4 : 1.4,
                               aura: name == "complete_task" ? .celebrating : nil, auraSeconds: 2.4)
            case .coding where name == "start_coding_agent":
                return BodyCue(gesture: .thumbsUp, gestureSeconds: 1.2, aura: .focused, auraSeconds: 6,
                               destination: .activeWindow, travel: .teleport, delay: 1.2)
            default:
                return nil
            }

        case .actingAt(let x, let y):
            return BodyCue(gesture: .point, gestureSeconds: 1.8, destination: .screenPoint(x: x, y: y))

        case .turnCompleted(let reply, let toolsUsed):
            if toolsUsed.contains("complete_task") { return nil } // Already celebrated.
            if Self.mentionsFile(reply) { return BodyCue(gesture: .point, gestureSeconds: 2.2, destination: .activeWindow) }
            let kinds = Set(toolsUsed.map(Self.kind(of:)))
            if kinds.contains(.screenAction) || kinds.contains(.contextSwitch) || kinds.contains(.coding) {
                return BodyCue(gesture: .thumbsUp, gestureSeconds: 1.6)
            }
            return nil

        case .turnFailed:
            return BodyCue(gesture: .shrug, gestureSeconds: 2, aura: .alert, auraSeconds: 1.5)

        case .backgroundJobProgress:
            return BodyCue(gesture: .think, gestureSeconds: 2.5, aura: .focused, auraSeconds: 3)

        case .backgroundJobFinished(let success):
            return success
                ? BodyCue(gesture: .celebrate, gestureSeconds: 2.6, aura: .celebrating, auraSeconds: 2.6)
                : BodyCue(gesture: .shrug, gestureSeconds: 2, aura: .alert, auraSeconds: 1.5)

        case .lookChanged(let look):
            // A twirl that covers the color change; sunny gets a burst of sparkles to show off.
            return BodyCue(gesture: .twirl, gestureSeconds: Self.twirlSeconds,
                           aura: look == .sunny ? .celebrating : nil, auraSeconds: 1.6)
        }
    }

    /// How long the look-change spin lasts (shorter than the color blend, which settles after it).
    public static let twirlSeconds: TimeInterval = 1.1

    /// The glow color (0xRRGGBB) for a task aura while wearing `look`. The look is a separate layer from what
    /// she's doing: the signals that carry meaning (focused cyan, celebrating gold, alert red) read the same
    /// in every look, and only the ambient "processing" halo takes on the look's own tint.
    public static func auraColor(_ aura: BodyAura, look: AvatarLook) -> UInt32? {
        switch aura {
        case .none: return nil
        case .focused: return 0x7FE7FF
        case .celebrating: return 0xFFE27A
        case .alert: return 0xFF4D3A
        case .processing:
            switch look {
            case .signature: return 0xFFB566
            case .night: return 0xB89CFF
            case .sunny: return 0xFFD66B
            case .tvaFormal: return 0xE8B27A
            case .variant: return 0x8FF0BE
            }
        }
    }

    /// The look she holds while nothing more specific is going on.
    public func steadyAura(mood: CharacterMood, backgroundJobsRunning: Int, lastToolKind: ToolKind?) -> BodyAura {
        switch mood {
        case .thinking, .working:
            return lastToolKind == .coding ? .focused : .processing
        case .idle where backgroundJobsRunning > 0:
            return .focused
        default:
            return .none
        }
    }

    /// Whether a reply refers to a file or folder ("saved it to ~/Desktop/notes.md", "check `App.swift`").
    public static func mentionsFile(_ text: String) -> Bool {
        let pattern = #"(?:~|/Users|/tmp|\.)/[\w.\-/]+|\b[\w\-]+\.(?:swift|py|js|ts|tsx|jsx|json|md|txt|pdf|png|jpe?g|html|css|csv|xlsx?|docx?|pptx?|zip|sh|yml|yaml|plist|app|rb|go|rs|java|kt|c|cpp|h)\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
