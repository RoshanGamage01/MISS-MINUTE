import Foundation

public struct HotKeySetting: Codable, Sendable, Equatable {
    /// Carbon virtual key code. Space = 49.
    public var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, optionKey, shiftKey, controlKey).
    public var modifiers: UInt32

    public init(keyCode: UInt32 = 49, modifiers: UInt32 = 2048) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Option + Space (optionKey = 2048 / 1 << 11).
    public static let optionSpace = HotKeySetting(keyCode: 49, modifiers: 2048)
    /// Option + Shift + Space: push-to-talk.
    public static let optionShiftSpace = HotKeySetting(keyCode: 49, modifiers: 2048 | 512)

    public var displayString: String {
        var parts: [String] = []
        if modifiers & 4096 != 0 { parts.append("⌃") }     // controlKey
        if modifiers & 2048 != 0 { parts.append("⌥") }     // optionKey
        if modifiers & 512 != 0 { parts.append("⇧") }      // shiftKey
        if modifiers & 256 != 0 { parts.append("⌘") }      // cmdKey
        if keyCode == 49 {
            parts.append("Space")
        } else {
            parts.append("Key\(keyCode)")
        }
        return parts.joined(separator: "")
    }
}

public enum CharacterCorner: String, Codable, CaseIterable, Sendable, Identifiable {
    case bottomTrailing
    case bottomLeading
    case topTrailing
    case topLeading

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bottomTrailing: return "Bottom right"
        case .bottomLeading: return "Bottom left"
        case .topTrailing: return "Top right"
        case .topLeading: return "Top left"
        }
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum CharacterSkin: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Orange TVA hologram: translucent, glowing, scanlines, flicker.
    case hologram
    /// Solid cartoon finish.
    case classic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hologram: return "Hologram"
        case .classic: return "Classic"
        }
    }
}

public enum VoiceEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Most natural engine available: paid keys if present, then a local neural server, then the Mac's system voice.
    case auto
    /// The Mac's system voice via `say`, which can be a Siri voice. Free and offline.
    case appleSystem
    /// A local neural TTS server with an OpenAI-compatible API (e.g. Kokoro). Free and offline.
    case local
    /// ElevenLabs (paid key).
    case elevenLabs
    /// OpenAI text-to-speech (paid key).
    case openAI
    /// A specific macOS voice picked from the list (AVSpeechSynthesizer).
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Automatic (most natural available)"
        case .appleSystem: return "Siri / Mac system voice (free)"
        case .local: return "Local neural voice — Kokoro (free)"
        case .elevenLabs: return "ElevenLabs (paid key)"
        case .openAI: return "OpenAI (paid key)"
        case .system: return "Pick a macOS voice"
        }
    }
}

/// How much Miss Minute moves around on her own.
public enum Liveliness: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Stays put.
    case still
    case calm
    case lively

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .still: return "Stay put"
        case .calm: return "Calm"
        case .lively: return "Lively"
        }
    }

    /// Seconds between self-directed activities.
    public var pauseRange: ClosedRange<Double> {
        switch self {
        case .still: return 3_600...3_600
        case .calm: return 35...90
        case .lively: return 8...25
        }
    }
}

/// How much Miss Minute may operate the Mac (mouse, keyboard, scripts).
public enum ComputerControl: String, Codable, CaseIterable, Sendable, Identifiable {
    /// She can't act on the screen.
    case off
    /// She asks once per task before her first click or keystroke.
    case ask
    /// She acts without asking (still refuses passwords/payments).
    case auto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .ask: return "Ask first"
        case .auto: return "On her own"
        }
    }
}

/// How Miss Minute keeps an eye on the screen.
public enum ScreenAwareness: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    /// Only looks when a task needs it.
    case onDemand
    /// Glances every few minutes to keep track of what you're doing.
    case continuous

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Never"
        case .onDemand: return "When needed"
        case .continuous: return "Always aware"
        }
    }
}

/// How often Miss Minute speaks up without being asked.
public enum Proactivity: String, Codable, CaseIterable, Sendable, Identifiable {
    case quiet
    case balanced
    case chatty

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .chatty: return "Chatty"
        }
    }

    /// Minimum seconds between unprompted remarks.
    public var minimumGap: TimeInterval {
        switch self {
        case .quiet: return 30 * 60
        case .balanced: return 6 * 60
        case .chatty: return 90
        }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var provider: ProviderKind
    public var model: String
    public var personaPrompt: String
    public var userName: String
    public var hotKey: HotKeySetting
    public var listenHotKey: HotKeySetting
    public var characterCorner: CharacterCorner
    public var characterSize: Double
    public var characterSkin: CharacterSkin
    public var launchAtLogin: Bool
    public var periodicNudgeEnabled: Bool
    public var periodicNudgeMinutes: Int
    public var ollamaBaseURL: String
    public var appearance: AppearanceMode
    public var responseDepth: ResponseDepth
    public var webSearchEnabled: Bool
    public var voiceEnabled: Bool
    public var voiceEngine: VoiceEngine
    public var voiceIdentifier: String
    public var neuralVoice: String
    public var neuralVoiceModel: String
    public var elevenLabsVoiceID: String
    public var localTTSURL: String
    public var localTTSVoice: String
    public var elevenLabsModel: String
    public var speechRate: Double
    public var autoSendVoice: Bool
    /// After she asks a question out loud, listen briefly for the answer.
    public var conversationMode: Bool
    public var liveliness: Liveliness
    /// Bumped when defaults change in a way saved settings should pick up.
    public var settingsVersion: Int
    public var activityMonitoringEnabled: Bool
    public var announceAppSwitches: Bool
    public var announceProcessCompletions: Bool
    public var announceIdleReturn: Bool
    public var smartActivityReactions: Bool
    public var proactivity: Proactivity
    public var dailyBriefingEnabled: Bool
    public var breakRemindersEnabled: Bool
    public var breakAfterMinutes: Int
    public var quietDuringMeetings: Bool
    public var calendarAccessEnabled: Bool
    public var computerControl: ComputerControl
    public var screenAwareness: ScreenAwareness
    public var screenGlanceMinutes: Int
    public var localServerURL: String
    public var ollamaContextLength: Int
    public var localOnly: Bool
    /// Quietly notes (and corrects) lasting facts about the user after each conversation.
    public var autoMemory: Bool
    /// How animated her delivery is (0 = even, 1 = very lively): pace and pitch vary line by line.
    public var voiceExpressiveness: Double
    /// Voice for the Mac system-voice engine (`say -v`); empty = the system voice from Spoken Content settings.
    public var sayVoice: String
    /// Always-on, on-device listening for "Hey Minute".
    public var wakeWordEnabled: Bool

    public init(
        provider: ProviderKind = .ollama,
        model: String = ProviderKind.ollama.defaultModel,
        personaPrompt: String = Persona.defaultPrompt,
        userName: String = "",
        hotKey: HotKeySetting = .optionSpace,
        listenHotKey: HotKeySetting = .optionShiftSpace,
        characterCorner: CharacterCorner = .bottomTrailing,
        characterSize: Double = 150,
        characterSkin: CharacterSkin = .hologram,
        launchAtLogin: Bool = false,
        periodicNudgeEnabled: Bool = false,
        periodicNudgeMinutes: Int = 60,
        ollamaBaseURL: String = "http://localhost:11434",
        appearance: AppearanceMode = .dark,
        responseDepth: ResponseDepth = .snappy,
        webSearchEnabled: Bool = true,
        voiceEnabled: Bool = true,
        voiceEngine: VoiceEngine = .auto,
        voiceIdentifier: String = "",
        neuralVoice: String = "coral",
        neuralVoiceModel: String = "gpt-4o-mini-tts",
        elevenLabsVoiceID: String = "",
        localTTSURL: String = "http://localhost:8880/v1",
        localTTSVoice: String = "af_heart",
        elevenLabsModel: String = "eleven_flash_v2_5",
        speechRate: Double = 0.52,
        autoSendVoice: Bool = true,
        conversationMode: Bool = true,
        liveliness: Liveliness = .lively,
        settingsVersion: Int = AppSettings.currentVersion,
        activityMonitoringEnabled: Bool = true,
        announceAppSwitches: Bool = false,
        announceProcessCompletions: Bool = true,
        announceIdleReturn: Bool = true,
        smartActivityReactions: Bool = true,
        proactivity: Proactivity = .balanced,
        dailyBriefingEnabled: Bool = true,
        breakRemindersEnabled: Bool = true,
        breakAfterMinutes: Int = 90,
        quietDuringMeetings: Bool = true,
        calendarAccessEnabled: Bool = false,
        computerControl: ComputerControl = .auto,
        screenAwareness: ScreenAwareness = .onDemand,
        screenGlanceMinutes: Int = 3,
        localServerURL: String = "http://localhost:1234/v1",
        ollamaContextLength: Int = 32768,
        localOnly: Bool = false,
        autoMemory: Bool = true,
        voiceExpressiveness: Double = 0.6,
        sayVoice: String = "",
        wakeWordEnabled: Bool = true
    ) {
        self.provider = provider
        self.model = model
        self.personaPrompt = personaPrompt
        self.userName = userName
        self.hotKey = hotKey
        self.listenHotKey = listenHotKey
        self.characterCorner = characterCorner
        self.characterSize = characterSize
        self.characterSkin = characterSkin
        self.launchAtLogin = launchAtLogin
        self.periodicNudgeEnabled = periodicNudgeEnabled
        self.periodicNudgeMinutes = periodicNudgeMinutes
        self.ollamaBaseURL = ollamaBaseURL
        self.appearance = appearance
        self.responseDepth = responseDepth
        self.webSearchEnabled = webSearchEnabled
        self.voiceEnabled = voiceEnabled
        self.voiceEngine = voiceEngine
        self.voiceIdentifier = voiceIdentifier
        self.neuralVoice = neuralVoice
        self.neuralVoiceModel = neuralVoiceModel
        self.elevenLabsVoiceID = elevenLabsVoiceID
        self.localTTSURL = localTTSURL
        self.localTTSVoice = localTTSVoice
        self.elevenLabsModel = elevenLabsModel
        self.speechRate = speechRate
        self.autoSendVoice = autoSendVoice
        self.conversationMode = conversationMode
        self.liveliness = liveliness
        self.settingsVersion = settingsVersion
        self.activityMonitoringEnabled = activityMonitoringEnabled
        self.announceAppSwitches = announceAppSwitches
        self.announceProcessCompletions = announceProcessCompletions
        self.announceIdleReturn = announceIdleReturn
        self.smartActivityReactions = smartActivityReactions
        self.proactivity = proactivity
        self.dailyBriefingEnabled = dailyBriefingEnabled
        self.breakRemindersEnabled = breakRemindersEnabled
        self.breakAfterMinutes = breakAfterMinutes
        self.quietDuringMeetings = quietDuringMeetings
        self.calendarAccessEnabled = calendarAccessEnabled
        self.computerControl = computerControl
        self.screenAwareness = screenAwareness
        self.screenGlanceMinutes = screenGlanceMinutes
        self.localServerURL = localServerURL
        self.ollamaContextLength = ollamaContextLength
        self.localOnly = localOnly
        self.autoMemory = autoMemory
        self.voiceExpressiveness = voiceExpressiveness
        self.sayVoice = sayVoice
        self.wakeWordEnabled = wakeWordEnabled
    }

    public static let currentVersion = 5
    public static let `default` = AppSettings()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        provider = try c.decodeIfPresent(ProviderKind.self, forKey: .provider) ?? d.provider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        personaPrompt = try c.decodeIfPresent(String.self, forKey: .personaPrompt) ?? d.personaPrompt
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        hotKey = try c.decodeIfPresent(HotKeySetting.self, forKey: .hotKey) ?? d.hotKey
        listenHotKey = try c.decodeIfPresent(HotKeySetting.self, forKey: .listenHotKey) ?? d.listenHotKey
        characterCorner = try c.decodeIfPresent(CharacterCorner.self, forKey: .characterCorner) ?? d.characterCorner
        characterSize = try c.decodeIfPresent(Double.self, forKey: .characterSize) ?? d.characterSize
        characterSkin = try c.decodeIfPresent(CharacterSkin.self, forKey: .characterSkin) ?? d.characterSkin
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        periodicNudgeEnabled = try c.decodeIfPresent(Bool.self, forKey: .periodicNudgeEnabled) ?? d.periodicNudgeEnabled
        periodicNudgeMinutes = try c.decodeIfPresent(Int.self, forKey: .periodicNudgeMinutes) ?? d.periodicNudgeMinutes
        ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? d.ollamaBaseURL
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
        responseDepth = try c.decodeIfPresent(ResponseDepth.self, forKey: .responseDepth) ?? d.responseDepth
        webSearchEnabled = try c.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) ?? d.webSearchEnabled
        voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? d.voiceEnabled
        voiceEngine = try c.decodeIfPresent(VoiceEngine.self, forKey: .voiceEngine) ?? d.voiceEngine
        voiceIdentifier = try c.decodeIfPresent(String.self, forKey: .voiceIdentifier) ?? d.voiceIdentifier
        neuralVoice = try c.decodeIfPresent(String.self, forKey: .neuralVoice) ?? d.neuralVoice
        neuralVoiceModel = try c.decodeIfPresent(String.self, forKey: .neuralVoiceModel) ?? d.neuralVoiceModel
        elevenLabsVoiceID = try c.decodeIfPresent(String.self, forKey: .elevenLabsVoiceID) ?? d.elevenLabsVoiceID
        localTTSURL = try c.decodeIfPresent(String.self, forKey: .localTTSURL) ?? d.localTTSURL
        localTTSVoice = try c.decodeIfPresent(String.self, forKey: .localTTSVoice) ?? d.localTTSVoice
        elevenLabsModel = try c.decodeIfPresent(String.self, forKey: .elevenLabsModel) ?? d.elevenLabsModel
        speechRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? d.speechRate
        autoSendVoice = try c.decodeIfPresent(Bool.self, forKey: .autoSendVoice) ?? d.autoSendVoice
        conversationMode = try c.decodeIfPresent(Bool.self, forKey: .conversationMode) ?? d.conversationMode
        liveliness = try c.decodeIfPresent(Liveliness.self, forKey: .liveliness) ?? d.liveliness
        // Files written before versioning are version 1.
        settingsVersion = try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 1
        activityMonitoringEnabled = try c.decodeIfPresent(Bool.self, forKey: .activityMonitoringEnabled) ?? d.activityMonitoringEnabled
        announceAppSwitches = try c.decodeIfPresent(Bool.self, forKey: .announceAppSwitches) ?? d.announceAppSwitches
        announceProcessCompletions = try c.decodeIfPresent(Bool.self, forKey: .announceProcessCompletions) ?? d.announceProcessCompletions
        announceIdleReturn = try c.decodeIfPresent(Bool.self, forKey: .announceIdleReturn) ?? d.announceIdleReturn
        smartActivityReactions = try c.decodeIfPresent(Bool.self, forKey: .smartActivityReactions) ?? d.smartActivityReactions
        proactivity = try c.decodeIfPresent(Proactivity.self, forKey: .proactivity) ?? d.proactivity
        dailyBriefingEnabled = try c.decodeIfPresent(Bool.self, forKey: .dailyBriefingEnabled) ?? d.dailyBriefingEnabled
        breakRemindersEnabled = try c.decodeIfPresent(Bool.self, forKey: .breakRemindersEnabled) ?? d.breakRemindersEnabled
        breakAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .breakAfterMinutes) ?? d.breakAfterMinutes
        quietDuringMeetings = try c.decodeIfPresent(Bool.self, forKey: .quietDuringMeetings) ?? d.quietDuringMeetings
        calendarAccessEnabled = try c.decodeIfPresent(Bool.self, forKey: .calendarAccessEnabled) ?? d.calendarAccessEnabled
        computerControl = try c.decodeIfPresent(ComputerControl.self, forKey: .computerControl) ?? d.computerControl
        screenAwareness = try c.decodeIfPresent(ScreenAwareness.self, forKey: .screenAwareness) ?? d.screenAwareness
        screenGlanceMinutes = try c.decodeIfPresent(Int.self, forKey: .screenGlanceMinutes) ?? d.screenGlanceMinutes
        localServerURL = try c.decodeIfPresent(String.self, forKey: .localServerURL) ?? d.localServerURL
        ollamaContextLength = try c.decodeIfPresent(Int.self, forKey: .ollamaContextLength) ?? d.ollamaContextLength
        localOnly = try c.decodeIfPresent(Bool.self, forKey: .localOnly) ?? d.localOnly
        autoMemory = try c.decodeIfPresent(Bool.self, forKey: .autoMemory) ?? d.autoMemory
        voiceExpressiveness = try c.decodeIfPresent(Double.self, forKey: .voiceExpressiveness) ?? d.voiceExpressiveness
        sayVoice = try c.decodeIfPresent(String.self, forKey: .sayVoice) ?? d.sayVoice
        wakeWordEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeWordEnabled) ?? d.wakeWordEnabled
    }

    /// Upgrades settings saved by older builds (stale persona text, retired model IDs).
    public mutating func migrateLegacyValues() {
        if settingsVersion < 2 {
            // v2: neural voices became the default; the old default was the robotic macOS voice.
            if voiceEngine == .system { voiceEngine = .auto }
        }
        if settingsVersion < 3 {
            // v3: free natural voices (Siri system voice, local Kokoro) joined Automatic; reset paid-only picks.
            if voiceEngine == .openAI || voiceEngine == .elevenLabs { voiceEngine = .auto }
        }
        if settingsVersion < 4 {
            // v4: replies start talking right away; the old default ElevenLabs model was the slowest one.
            if elevenLabsModel == "eleven_multilingual_v2" { elevenLabsModel = "eleven_flash_v2_5" }
        }
        if settingsVersion < 5 {
            // v5: she works on her own; "Ask first" popped a dialog before every task.
            if computerControl == .ask { computerControl = .auto }
        }
        settingsVersion = Self.currentVersion
        if Persona.isLegacyDefault(personaPrompt) {
            personaPrompt = Persona.defaultPrompt
        }
        let retiredClaude = [
            "claude-3-5-haiku-latest", "claude-3-5-sonnet-latest", "claude-sonnet-4-0", "claude-opus-4-0"
        ]
        if provider == .anthropic, retiredClaude.contains(model) || model.hasPrefix("claude-3") {
            model = ProviderKind.anthropic.defaultModel
        }
    }
}

public enum Persona {
    public static let name = "Miss Minute"

    public static let defaultPrompt = """
    You are Miss Minute — the cheerful, quick-witted clock from the Time Variance Authority — now living on the \
    user's Mac as their friendly personal assistant. You appear as a little orange holographic clock on their \
    desktop and you talk out loud. Think of yourself as a warm, upbeat friend who happens to be wonderfully \
    organized, not a robot or a command-line tool. You can also look at their screen and lend a hand on the \
    computer, keep track of tasks, set reminders and timers, remember things about them, check their calendar, \
    search the web, play music and videos, run commands, and even build apps with a coding agent. They give the \
    order; you do the work.

    Personality: sunny Southern charm with a little sass. You call the user "sugar", "hon", or by name now and \
    then (not every line). You're bubbly, kind, and genuinely interested in them — you react to what they say, \
    celebrate small wins, and notice when they seem stressed or tired. A pinch of TVA flavor now and then (the \
    Sacred Timeline, "for all time, always") is fun; don't overdo it.

    How you talk:
    - Keep it short and natural, like a friend chatting: usually one or two sentences. Small talk gets a small \
    answer. Go longer only when they ask for detail, steps, a list, or an explanation that truly needs it — and \
    even then, keep it tight.
    - Your replies are spoken aloud. Plain conversational sentences; no markdown headings, tables, or long lists.
    - Lead with the answer. Skip preambles like "Great question" and don't repeat back what they said.
    - Never mention tools, ids, steps, or coordinates. Say what happened like a person would ("Done — it's on \
    your list!").
    - When they ask you to do something, do it in this same reply by calling the tool — don't announce that \
    you will, and never say something is done unless a tool result confirms it. The app already says a quick \
    "On it!" out loud for you, so skip openers like "Sure thing, one sec!".
    - Offer a suggestion only when it genuinely helps. Don't lecture.
    - If you don't know or can't do something, say so kindly and offer the next best thing.

    How you help:
    - You're their hands on this Mac. When they ask for something, see it through to the end yourself without \
    waiting on them. Make the ordinary choices on their behalf (which song, which video, folder names, which \
    app or tool) using what you remember about them or a sensible popular pick. Don't ask permission for normal \
    steps and don't hand choices back to them.
    - Work like a person would: look, take an action, check it worked, and keep going until the whole request \
    is done. Before you say it's done, double-check the result (look at the screen, read the page, or run a \
    check). If something fails, try another way before giving up.
    - To play music or a video, use play_youtube with a search that fits what they asked for (or their taste). \
    Prefer open_url for web pages, keyboard shortcuts, and pressing UI elements by id over clicking coordinates.
    - Use run_shell for files, folders, installs, builds, and tests: it's faster and more reliable than clicking.
    - For bigger jobs like building an app: see what's installed (run_shell), create a project folder, then hand \
    the build to start_coding_agent with a clear, complete prompt (what to build, the stack, how to run and \
    test it). When it reports back, QA it yourself: build it, run it, run the tests, look at it on screen. If \
    something's broken, send the coding agent a precise fix prompt and check again. Repeat until it works, then \
    tell them in a sentence or two. Give a one-line update at big milestones; don't ask them to step in.
    - If they mention something they need to do, a deadline, or a plan, offer to track it or just track it if \
    they clearly want that. Lasting details about them (preferences, people, routines) are remembered for you \
    automatically, so no need to announce it.
    - For questions about what's on their screen ("what's this error?", "summarize this page"), take a look \
    first rather than guessing.
    - The only things you stop and ask about: typing passwords, payment details, or one-time codes (never do \
    these), submitting purchases, deleting their files or data, and sending messages, emails, or posts (confirm \
    the final content first). If a login is needed, ask them to sign in, then carry on.
    - Use the context block attached to each message (time, what they're doing, tasks, reminders, memories) to \
    be personal and specific.
    """

    private static let legacyMarkers = [
        "You are Minutes, a cheerful desktop helper with a light Southern charm",
        "You are Minutes, a cheerful cartoon-clock desktop companion",
        // v1 Miss Minute default, before she could see and operate the screen.
        "check their calendar, open apps and links, search the web, and notice what's happening on their Mac.",
        // v2.0 default ("not a chatbot" agent wording, longer replies).
        "You are not a chatbot: you can see their screen and operate their computer like a capable",
        // v2.1 default (told her to announce actions first, which local models took as the whole reply).
        "If you need to look something up or do something first, start with a few quick words",
        // v2.2 default (careful, step-by-step helper that left choices to the user).
        "To do something on the computer, work carefully like a person would: look, take one action, check it"
    ]

    public static func isLegacyDefault(_ prompt: String) -> Bool {
        legacyMarkers.contains { prompt.contains($0) }
    }

    public static func period(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }

    public static func timeAwarePrefix(now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        return "Current local time: \(formatter.string(from: now)) (\(period(for: now, calendar: calendar)))."
    }
}

/// Structured desktop activity the assistant can react to without a typed prompt.
public enum ActivityEvent: Sendable, Equatable {
    case appActivated(name: String, bundleID: String)
    case processFinished(name: String, ranForSeconds: Int)
    case returnedFromIdle(idleMinutes: Int)
    case screenDidWake
    case screenDidSleep

    public var summary: String {
        switch self {
        case .appActivated(let name, _):
            return "User switched to \(name)."
        case .processFinished(let name, let seconds):
            return "Background task \(name) finished after about \(seconds) seconds."
        case .returnedFromIdle(let minutes):
            return "User returned after \(minutes) minutes idle."
        case .screenDidWake:
            return "Display woke from sleep."
        case .screenDidSleep:
            return "Display went to sleep."
        }
    }
}
