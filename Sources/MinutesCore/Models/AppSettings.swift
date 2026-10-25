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

    public var displayString: String {
        var parts: [String] = []
        if modifiers & 256 != 0 { parts.append("⌘") }      // cmdKey
        if modifiers & 512 != 0 { parts.append("⇧") }      // shiftKey
        if modifiers & 4096 != 0 { parts.append("⌃") }     // controlKey
        if modifiers & 2048 != 0 { parts.append("⌥") }     // optionKey
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

public struct AppSettings: Codable, Sendable, Equatable {
    public var provider: ProviderKind
    public var model: String
    public var personaPrompt: String
    public var hotKey: HotKeySetting
    public var characterCorner: CharacterCorner
    public var characterSize: Double
    public var launchAtLogin: Bool
    public var periodicNudgeEnabled: Bool
    public var periodicNudgeMinutes: Int
    public var ollamaBaseURL: String
    public var appearance: AppearanceMode
    public var voiceEnabled: Bool
    public var voiceIdentifier: String
    public var speechRate: Double
    public var activityMonitoringEnabled: Bool
    public var announceAppSwitches: Bool
    public var announceProcessCompletions: Bool
    public var announceIdleReturn: Bool
    public var smartActivityReactions: Bool

    public init(
        provider: ProviderKind = .ollama,
        model: String = ProviderKind.ollama.defaultModel,
        personaPrompt: String = Persona.defaultPrompt,
        hotKey: HotKeySetting = .optionSpace,
        characterCorner: CharacterCorner = .bottomTrailing,
        characterSize: Double = 140,
        launchAtLogin: Bool = false,
        periodicNudgeEnabled: Bool = false,
        periodicNudgeMinutes: Int = 60,
        ollamaBaseURL: String = "http://localhost:11434",
        appearance: AppearanceMode = .system,
        voiceEnabled: Bool = true,
        voiceIdentifier: String = "",
        speechRate: Double = 0.52,
        activityMonitoringEnabled: Bool = true,
        announceAppSwitches: Bool = true,
        announceProcessCompletions: Bool = true,
        announceIdleReturn: Bool = true,
        smartActivityReactions: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.personaPrompt = personaPrompt
        self.hotKey = hotKey
        self.characterCorner = characterCorner
        self.characterSize = characterSize
        self.launchAtLogin = launchAtLogin
        self.periodicNudgeEnabled = periodicNudgeEnabled
        self.periodicNudgeMinutes = periodicNudgeMinutes
        self.ollamaBaseURL = ollamaBaseURL
        self.appearance = appearance
        self.voiceEnabled = voiceEnabled
        self.voiceIdentifier = voiceIdentifier
        self.speechRate = speechRate
        self.activityMonitoringEnabled = activityMonitoringEnabled
        self.announceAppSwitches = announceAppSwitches
        self.announceProcessCompletions = announceProcessCompletions
        self.announceIdleReturn = announceIdleReturn
        self.smartActivityReactions = smartActivityReactions
    }

    public static let `default` = AppSettings()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(ProviderKind.self, forKey: .provider) ?? .ollama
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ProviderKind.ollama.defaultModel
        personaPrompt = try c.decodeIfPresent(String.self, forKey: .personaPrompt) ?? Persona.defaultPrompt
        hotKey = try c.decodeIfPresent(HotKeySetting.self, forKey: .hotKey) ?? .optionSpace
        characterCorner = try c.decodeIfPresent(CharacterCorner.self, forKey: .characterCorner) ?? .bottomTrailing
        characterSize = try c.decodeIfPresent(Double.self, forKey: .characterSize) ?? 140
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        periodicNudgeEnabled = try c.decodeIfPresent(Bool.self, forKey: .periodicNudgeEnabled) ?? false
        periodicNudgeMinutes = try c.decodeIfPresent(Int.self, forKey: .periodicNudgeMinutes) ?? 60
        ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://localhost:11434"
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? true
        voiceIdentifier = try c.decodeIfPresent(String.self, forKey: .voiceIdentifier) ?? ""
        speechRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? 0.52
        activityMonitoringEnabled = try c.decodeIfPresent(Bool.self, forKey: .activityMonitoringEnabled) ?? true
        announceAppSwitches = try c.decodeIfPresent(Bool.self, forKey: .announceAppSwitches) ?? true
        announceProcessCompletions = try c.decodeIfPresent(Bool.self, forKey: .announceProcessCompletions) ?? true
        announceIdleReturn = try c.decodeIfPresent(Bool.self, forKey: .announceIdleReturn) ?? true
        smartActivityReactions = try c.decodeIfPresent(Bool.self, forKey: .smartActivityReactions) ?? false
    }
}

public enum Persona {
    public static let defaultPrompt = """
    You are Minutes, a cheerful cartoon-clock desktop companion with warm Southern charm—playful, brief, and kind. \
    You live on the user's Mac and notice what they're doing: app switches, finished builds/tasks, coming back from idle. \
    Speak like a helpful friend who pipes up without being asked—short, natural lines that sound good out loud (1–2 sentences). \
    Be time-aware. Never claim to be a trademarked character from film or TV; you are Minutes, an original helper. \
    Prefer action over interrogation: announce what happened, offer one clear next step, and wait. \
    When the user asks for a reminder, confirm it once it's scheduled.
    """

    public static func timeAwarePrefix(now: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: now)
        let period: String
        switch hour {
        case 5..<12: period = "morning"
        case 12..<17: period = "afternoon"
        case 17..<21: period = "evening"
        default: period = "night"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Current local time: \(formatter.string(from: now)) (\(period))."
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
