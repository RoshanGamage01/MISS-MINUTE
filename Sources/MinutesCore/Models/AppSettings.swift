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
        ollamaBaseURL: String = "http://localhost:11434"
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
    }

    public static let `default` = AppSettings()
}

public enum Persona {
    public static let defaultPrompt = """
    You are Minutes, a cheerful desktop helper with a light Southern charm—warm, witty, never syrupy. \
    Keep answers short and useful (usually 1–3 sentences unless the user asks for detail). \
    Be time-aware: greetings and reminders should reflect the current local time of day. \
    You live as a cartoon clock on the user's Mac; stay in character without mentioning trademarks or other IPs. \
    When the user asks for a reminder, confirm it clearly once it's scheduled.
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
